#!/usr/bin/env bash
set -euo pipefail

# Pre-register a client/device for issuance using admin APIs.
# Required env vars / flags:
#   TEST_UID / --uid
#   SECRET / --secret
# Optional env vars / flags:
#   SERVER_BASE_URL  / --server-base-url  (default: http://localhost:3000)
#   DEVICE_ID        / --device-id        (default: generate_device_id.sh output)
#   AVAILABLE_PERIOD / --available-period (default: 30m)
#   PENDING_PERIOD   / --pending-period   (default: 0s)
#
# Expected API success status:
#   GET  /api/client/{uid}          -> 200 ("null" or client JSON)
#   POST /admin/api/client/add      -> 200
#   PUT  /admin/api/client/update   -> 200
#   POST /admin/api/secret/create   -> 201

usage() {
  cat <<'EOF'
Usage: preregister_client.sh [options]

Options:
  --server-base-url URL
  --uid TEST_UID
  --device-id DEVICE_ID
  --secret SECRET
  --available-period DURATION
  --pending-period DURATION
  -h, --help

Example:
  TEST_UID=test SECRET=pass ./preregister_client.sh
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local expected_status="$4"
  local url="${SERVER_BASE_URL%/}${path}"
  local body_file body status

  body_file="$(mktemp)"
  if [[ -n "$payload" ]]; then
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "$url" -H 'Content-Type: application/json' --data "$payload")"
  else
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "$url" -H 'Content-Type: application/json')"
  fi

  body="$(cat "$body_file")"
  rm -f "$body_file"

  if [[ "$status" != "$expected_status" ]]; then
    echo "API request failed: $method $path returned HTTP $status (expected $expected_status)" >&2
    if [[ -n "$body" ]]; then
      echo "Response: $body" >&2
    fi
    exit 1
  fi

  printf '%s' "$body"
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

SERVER_BASE_URL="${SERVER_BASE_URL:-http://localhost:3000}"
TEST_UID="${TEST_UID:-}"
DEVICE_ID="${DEVICE_ID:-}"
SECRET="${SECRET:-}"
AVAILABLE_PERIOD="${AVAILABLE_PERIOD:-30m}"
PENDING_PERIOD="${PENDING_PERIOD:-0s}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-base-url)
      SERVER_BASE_URL="${2:?missing value for --server-base-url}"
      shift 2
      ;;
    --uid)
      TEST_UID="${2:?missing value for --uid}"
      shift 2
      ;;
    --device-id)
      DEVICE_ID="${2:?missing value for --device-id}"
      shift 2
      ;;
    --secret)
      SECRET="${2:?missing value for --secret}"
      shift 2
      ;;
    --available-period)
      AVAILABLE_PERIOD="${2:?missing value for --available-period}"
      shift 2
      ;;
    --pending-period)
      PENDING_PERIOD="${2:?missing value for --pending-period}"
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

if [[ -z "$TEST_UID" ]]; then
  echo "TEST_UID is required (set TEST_UID or use --uid)." >&2
  exit 1
fi
if [[ -z "$SECRET" ]]; then
  echo "SECRET is required (set SECRET or use --secret)." >&2
  exit 1
fi

require_command curl
require_command python3

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$("$script_dir/generate_device_id.sh")"
fi

encoded_uid="$(urlencode "$TEST_UID")"
client_json="$(api_request "GET" "/api/client/${encoded_uid}" "" "200")"

if [[ "$client_json" == "null" ]]; then
  add_payload="$(python3 - "$TEST_UID" "$DEVICE_ID" <<'PY'
import json
import sys
print(json.dumps({
    "uid": sys.argv[1],
    "attributes": {"device_id": sys.argv[2]},
}, separators=(",", ":")))
PY
)"
  api_request "POST" "/admin/api/client/add" "$add_payload" "200" >/dev/null
else
  readarray -t update_data < <(printf '%s' "$client_json" | python3 - "$TEST_UID" "$DEVICE_ID" <<'PY'
import json
import sys
uid = sys.argv[1]
device_id = sys.argv[2]
client = json.load(sys.stdin)
attributes = client.get("attributes") or {}
current = attributes.get("device_id")
needs_update = str(current) != device_id
attributes["device_id"] = device_id
print("1" if needs_update else "0")
print(json.dumps({
    "uid": uid,
    "attributes": attributes,
}, separators=(",", ":")))
PY
)
  if [[ "${update_data[0]}" == "1" ]]; then
    api_request "PUT" "/admin/api/client/update" "${update_data[1]}" "200" >/dev/null
  fi
fi

secret_payload="$(python3 - "$TEST_UID" "$SECRET" "$AVAILABLE_PERIOD" "$PENDING_PERIOD" <<'PY'
import json
import sys
print(json.dumps({
    "target": sys.argv[1],
    "secret": sys.argv[2],
    "available_period": sys.argv[3],
    "pending_period": sys.argv[4],
}, separators=(",", ":")))
PY
)"
api_request "POST" "/admin/api/secret/create" "$secret_payload" "201" >/dev/null

printf 'uid=%s\n' "$TEST_UID"
printf 'secret=%s\n' "$SECRET"
printf 'device_id=%s\n' "$DEVICE_ID"
printf 'export SCEP_TEST_UID=%q\n' "$TEST_UID"
printf 'export SCEP_SECRET=%q\n' "$SECRET"
printf 'export SCEP_DEVICE_ID=%q\n' "$DEVICE_ID"
