#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: attestation_e2e.sh [options]

Execute attestation E2E issuance checks against a deployed SCEP endpoint.

Preconditions:
  1) preregister_client.sh has already run for the target uid/secret/device_id
  2) target server is reachable and supports POST PKIOperation
  3) curl, openssl, python3, and go are available (go required only when building scepclient)

Inputs (choose one approach):
  - provide SCEP_UID / SCEP_SECRET / SCEP_DEVICE_ID env vars
  - or pass --prereg-output <file> with captured preregister_client.sh output

Options:
  --server-base-url URL   Base URL for API checks (default: http://localhost:3000)
  --scep-url URL          Full SCEP URL (default: <server-base-url>/scep)
  --prereg-output FILE    preregister_client.sh output file (uid/secret/device_id lines)
  --uid UID               Override UID
  --secret SECRET         Override secret
  --device-id DEVICE_ID   Override device_id
  --artifact-dir DIR      Artifact output directory
  --scepclient-bin PATH   Use existing scepclient binary (otherwise builds one)
  -h, --help              Show help
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

load_prereg_output() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    echo "prereg output file is not readable: $file" >&2
    exit 1
  fi

  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    case "$key" in
      uid)
        [[ -z "${SCEP_UID}" ]] && SCEP_UID="$value"
        ;;
      secret)
        [[ -z "${SCEP_SECRET}" ]] && SCEP_SECRET="$value"
        ;;
      device_id)
        [[ -z "${SCEP_DEVICE_ID}" ]] && SCEP_DEVICE_ID="$value"
        ;;
    esac
  done < "$file"
}

write_attestation_payload() {
  local device_id="$1"
  local public_key_spki_b64="$2"
  local nonce="$3"
  local out_file="$4"
  python3 - "$device_id" "$public_key_spki_b64" "$nonce" <<'PY' > "$out_file"
import json
import sys
print(json.dumps({
    "device_id": sys.argv[1],
    "key": {
        "algorithm": "rsa-2048",
        "provider": "openssl-test-key",
        "public_key_spki_b64": sys.argv[2],
    },
    "attestation": {
        "format": "test-nonce-key-binding-v1",
        "nonce": sys.argv[3],
    },
}, separators=(",", ":")))
PY
}

encode_base64url_file() {
  local payload_file="$1"
  python3 - "$payload_file" <<'PY'
import base64
import pathlib
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
print(base64.urlsafe_b64encode(payload).decode().rstrip("="))
PY
}

ensure_case_key() {
  local key_file="$1"
  if [[ -f "$key_file" ]]; then
    return 0
  fi
  openssl genrsa -traditional -out "$key_file" 2048 >/dev/null 2>&1
}

public_key_spki_b64() {
  local key_file="$1"
  python3 - "$key_file" <<'PY'
import base64
import pathlib
import subprocess
import sys

key_file = pathlib.Path(sys.argv[1])
result = subprocess.run(
    ["openssl", "rsa", "-in", str(key_file), "-pubout", "-outform", "DER"],
    check=True,
    capture_output=True,
)
print(base64.urlsafe_b64encode(result.stdout).decode().rstrip("="))
PY
}

fetch_nonce() {
  local device_id="$1"
  python3 - "${SERVER_BASE_URL%/}/api/attestation/nonce" "$SCEP_UID" "$device_id" <<'PY'
import json
import sys
import urllib.error
import urllib.request

endpoint, client_uid, device_id = sys.argv[1:4]
request = urllib.request.Request(
    endpoint,
    data=json.dumps({"client_uid": client_uid, "device_id": device_id}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request) as response:
    payload = json.load(response)
nonce = str(payload.get("nonce", "")).strip()
if not nonce:
    raise SystemExit(f"nonce response from {endpoint} did not include a nonce")
print(nonce)
PY
}

run_case() {
  local case_name="$1"
  local payload_device_id="$2"
  local expected="$3"
  local case_dir="$ARTIFACT_DIR/$case_name"
  mkdir -p "$case_dir"
  local attestation=""

  if [[ "$expected" == "success" || "$case_name" == "failure_mismatched_device_id" ]]; then
    local key_file="$case_dir/key.pem"
    local payload_file="$case_dir/attestation.json"
    local nonce_file="$case_dir/nonce.txt"
    ensure_case_key "$key_file"
    local public_key_b64
    public_key_b64="$(public_key_spki_b64 "$key_file")"
    local nonce
    nonce="$(fetch_nonce "$SCEP_DEVICE_ID")"
    printf '%s\n' "$nonce" > "$nonce_file"
    write_attestation_payload "$payload_device_id" "$public_key_b64" "$nonce" "$payload_file"
    attestation="$(encode_base64url_file "$payload_file")"
  else
    attestation='%%%'
  fi

  {
    printf 'case=%s\n' "$case_name"
    printf 'scep_url=%s\n' "$SCEP_SERVER_URL"
    printf 'uid=%s\n' "$SCEP_UID"
    printf 'device_id=%s\n' "$SCEP_DEVICE_ID"
    printf 'attestation=%s\n' "$attestation"
  } > "$case_dir/input.txt"

  set +e
  (
    cd "$case_dir"
    "$SCEPCLIENT_BIN" \
      -uid "$SCEP_UID" \
      -secret "$SCEP_SECRET" \
      -server-url "$SCEP_SERVER_URL" \
      -attestation "$attestation"
  ) > "$case_dir/stdout.log" 2> "$case_dir/stderr.log"
  local rc=$?
  set -e

  printf '%s\n' "$rc" > "$case_dir/exit_code.txt"

  if [[ "$expected" == "success" ]]; then
    if [[ "$rc" -ne 0 ]]; then
      echo "Case $case_name failed unexpectedly. See $case_dir/stderr.log" >&2
      return 1
    fi
    if [[ ! -s "$case_dir/cert.pem" ]]; then
      echo "Case $case_name did not produce cert.pem" >&2
      return 1
    fi
  else
    if [[ "$rc" -eq 0 ]]; then
      echo "Case $case_name succeeded unexpectedly" >&2
      return 1
    fi
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SERVER_BASE_URL_EXPLICIT=0
SCEP_URL_EXPLICIT=0
if [[ -n "${SERVER_BASE_URL+x}" ]]; then
  SERVER_BASE_URL_EXPLICIT=1
fi
if [[ -n "${SCEP_SERVER_URL+x}" ]]; then
  SCEP_URL_EXPLICIT=1
fi
SERVER_BASE_URL="${SERVER_BASE_URL:-http://localhost:3000}"
SCEP_SERVER_URL="${SCEP_SERVER_URL:-${SERVER_BASE_URL%/}/scep}"
PREREG_OUTPUT_FILE="${PREREG_OUTPUT_FILE:-}"
SCEP_UID="${SCEP_UID:-}"
SCEP_SECRET="${SCEP_SECRET:-}"
SCEP_DEVICE_ID="${SCEP_DEVICE_ID:-}"
SCEPCLIENT_BIN="${SCEPCLIENT_BIN:-}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/attestation-e2e-$timestamp}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-base-url)
      SERVER_BASE_URL="${2:?missing value for --server-base-url}"
      SERVER_BASE_URL_EXPLICIT=1
      shift 2
      ;;
    --scep-url)
      SCEP_SERVER_URL="${2:?missing value for --scep-url}"
      SCEP_URL_EXPLICIT=1
      shift 2
      ;;
    --prereg-output)
      PREREG_OUTPUT_FILE="${2:?missing value for --prereg-output}"
      shift 2
      ;;
    --uid)
      SCEP_UID="${2:?missing value for --uid}"
      shift 2
      ;;
    --secret)
      SCEP_SECRET="${2:?missing value for --secret}"
      shift 2
      ;;
    --device-id)
      SCEP_DEVICE_ID="${2:?missing value for --device-id}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:?missing value for --artifact-dir}"
      shift 2
      ;;
    --scepclient-bin)
      SCEPCLIENT_BIN="${2:?missing value for --scepclient-bin}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PREREG_OUTPUT_FILE" ]]; then
  load_prereg_output "$PREREG_OUTPUT_FILE"
fi

if [[ "$SCEP_URL_EXPLICIT" -eq 0 ]]; then
  SCEP_SERVER_URL="${SERVER_BASE_URL%/}/scep"
elif [[ "$SERVER_BASE_URL_EXPLICIT" -eq 0 ]]; then
  SERVER_BASE_URL="${SCEP_SERVER_URL%/}"
  SERVER_BASE_URL="${SERVER_BASE_URL%/scep}"
fi

if [[ -z "$SCEP_UID" ]]; then
  echo "SCEP_UID is required (or pass --uid / --prereg-output)." >&2
  exit 1
fi
if [[ -z "$SCEP_SECRET" ]]; then
  echo "SCEP_SECRET is required (or pass --secret / --prereg-output)." >&2
  exit 1
fi
if [[ -z "$SCEP_DEVICE_ID" ]]; then
  echo "SCEP_DEVICE_ID is required (or pass --device-id / --prereg-output)." >&2
  exit 1
fi

require_command curl
require_command openssl
require_command python3
if [[ -z "$SCEPCLIENT_BIN" ]]; then
  require_command go
fi

mkdir -p "$ARTIFACT_DIR"

if ! curl -fsS "${SERVER_BASE_URL%/}/admin/api/ping" > "$ARTIFACT_DIR/admin_ping.txt"; then
  echo "Unable to reach ${SERVER_BASE_URL%/}/admin/api/ping" >&2
  exit 1
fi

if ! curl -fsS "${SCEP_SERVER_URL}?operation=GetCACaps" > "$ARTIFACT_DIR/cacaps.txt"; then
  echo "Unable to fetch GetCACaps from $SCEP_SERVER_URL" >&2
  exit 1
fi
if ! grep -q "POSTPKIOperation" "$ARTIFACT_DIR/cacaps.txt"; then
  echo "Server does not advertise POSTPKIOperation capability." >&2
  exit 1
fi

if [[ -z "$SCEPCLIENT_BIN" ]]; then
  SCEPCLIENT_BIN="$ARTIFACT_DIR/scepclient-opt"
  (
    cd "$REPO_ROOT"
    go build -o "$SCEPCLIENT_BIN" ./cmd/scepclient
  ) > "$ARTIFACT_DIR/build.log" 2>&1
fi
if [[ ! -x "$SCEPCLIENT_BIN" ]]; then
  echo "scepclient binary is not executable: $SCEPCLIENT_BIN" >&2
  exit 1
fi

run_case "success_matching_device_id" "$SCEP_DEVICE_ID" "success"
run_case "failure_mismatched_device_id" "${SCEP_DEVICE_ID}-mismatch" "failure"
run_case "failure_invalid_attestation" "$SCEP_DEVICE_ID" "failure"

cat > "$ARTIFACT_DIR/summary.txt" <<EOF
artifact_dir=$ARTIFACT_DIR
success_case=success_matching_device_id
failure_cases=failure_mismatched_device_id,failure_invalid_attestation
EOF

echo "Attestation E2E checks completed. Artifacts: $ARTIFACT_DIR"
