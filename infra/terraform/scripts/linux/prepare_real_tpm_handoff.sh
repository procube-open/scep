#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare_real_tpm_handoff.sh [options]

Build the Windows MSI, expose the current SCEP server on a public IP restricted
to a specific source IP, reserve an enrollment secret on the server, and create
one folder that can be copied to an external real-TPM Windows machine.

Options:
  --source-ip <IP_OR_CIDR>          Public source IP allowed to reach TCP/3000
                                    (default: 160.86.236.182/32)
  --client-uid <UID>                Client UID to reserve (default: generated)
  --secret <SECRET>                 Enrollment secret to reserve (default: generated)
  --available-period <DURATION>     Secret availability window (default: 168h)
  --pending-period <DURATION>       Secret pending window (default: 0s)
  --output-dir <PATH>               Handoff folder path
                                    (default: <repo-root>/build/windows-real-tpm-handoff/<uid>)
  --build-stage-dir <PATH>          build_windows_msi.sh stage directory
                                    (default: <repo-root>/build/windows-real-tpm-build/<uid>)
  --skip-build                      Reuse existing MSI/helper binaries
  --project <PROJECT_ID>            GCP project override
  --zone <ZONE>                     GCP zone override
  --server-instance <INSTANCE>      Server VM name override
  --terraform-dir <PATH>            Terraform working directory
                                    (default: <repo-root>/infra/terraform)
  --repo-root <PATH>                Repository root
                                    (default: auto-detected)
  -h, --help                        Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
PROJECT_ID=""
ZONE=""
SERVER_INSTANCE=""
SOURCE_RANGE="160.86.236.182/32"
CLIENT_UID=""
SECRET_VALUE=""
AVAILABLE_PERIOD="168h"
PENDING_PERIOD="0s"
OUTPUT_DIR=""
BUILD_STAGE_DIR=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-ip)
      SOURCE_RANGE="${2:?missing value for --source-ip}"
      shift 2
      ;;
    --client-uid)
      CLIENT_UID="${2:?missing value for --client-uid}"
      shift 2
      ;;
    --secret)
      SECRET_VALUE="${2:?missing value for --secret}"
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
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --build-stage-dir)
      BUILD_STAGE_DIR="${2:?missing value for --build-stage-dir}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --project)
      PROJECT_ID="${2:?missing value for --project}"
      shift 2
      ;;
    --zone)
      ZONE="${2:?missing value for --zone}"
      shift 2
      ;;
    --server-instance)
      SERVER_INSTANCE="${2:?missing value for --server-instance}"
      shift 2
      ;;
    --terraform-dir)
      TERRAFORM_DIR="${2:?missing value for --terraform-dir}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:?missing value for --repo-root}"
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

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi

ensure_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

normalize_source_range() {
  local value="$1"
  if [[ "$value" == */* ]]; then
    printf '%s' "$value"
  else
    printf '%s/32' "$value"
  fi
}

terraform_output_raw() {
  local key="$1"
  terraform -chdir="$TERRAFORM_DIR" output -raw "$key" 2>/dev/null || true
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

json_get_client_status() {
  python3 - "$1" <<'PY'
import json
import sys

payload = sys.argv[1].strip()
if payload == "null" or not payload:
    print("")
else:
    data = json.loads(payload)
    print(str(data.get("status", "")))
PY
}

api_request() {
  local method="$1"
  local base_url="$2"
  local path="$3"
  local payload="${4:-}"
  local expected_status="$5"
  local body_file status body

  body_file="$(mktemp)"
  if [[ -n "$payload" ]]; then
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "${base_url%/}${path}" -H 'Content-Type: application/json' --data "$payload")"
  else
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "${base_url%/}${path}" -H 'Content-Type: application/json')"
  fi
  body="$(cat "$body_file")"
  rm -f "$body_file"

  if [[ "$status" != "$expected_status" ]]; then
    echo "API request failed: $method ${base_url%/}${path} returned HTTP $status (expected $expected_status)" >&2
    if [[ -n "$body" ]]; then
      echo "Response: $body" >&2
    fi
    exit 1
  fi

  printf '%s' "$body"
}

python_json() {
  python3 - "$@" <<'PY'
import json
import sys

mode = sys.argv[1]
if mode == "client-add":
    print(json.dumps({
        "uid": sys.argv[2],
        "attributes": {},
    }, separators=(",", ":")))
elif mode == "client-revoke":
    print(json.dumps({
        "uid": sys.argv[2],
        "attributes": {},
    }, separators=(",", ":")))
elif mode == "secret-create":
    print(json.dumps({
        "target": sys.argv[2],
        "secret": sys.argv[3],
        "available_period": sys.argv[4],
        "pending_period": sys.argv[5],
    }, separators=(",", ":")))
elif mode == "secret-delete-at":
    payload = sys.argv[2].strip()
    if not payload:
        print("")
    else:
        data = json.loads(payload)
        print(str(data.get("delete_at", "")))
elif mode == "random-secret":
    import secrets
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    print("".join(secrets.choice(alphabet) for _ in range(32)))
elif mode == "generated-uid":
    import secrets
    from datetime import datetime, timezone
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    print(f"real-tpm-{stamp}-{secrets.token_hex(2)}")
elif mode == "to-json":
    print(json.dumps({
        "generated_at_utc": sys.argv[2],
        "server_base_url": sys.argv[3],
        "server_url": sys.argv[4],
        "server_internal_base_url": sys.argv[5],
        "server_internal_ip": sys.argv[6],
        "server_public_ip": sys.argv[7],
        "client_uid": sys.argv[8],
        "enrollment_secret": sys.argv[9],
        "managed_client_type": sys.argv[10],
        "allowed_source_range": sys.argv[11],
        "secret_delete_at": sys.argv[12],
        "firewall_rule_name": sys.argv[13],
        "server_instance": sys.argv[14],
        "project_id": sys.argv[15],
        "zone": sys.argv[16],
    }, indent=2))
else:
    raise SystemExit(f"unsupported mode: {mode}")
PY
}

ensure_command curl
ensure_command gcloud
ensure_command python3
ensure_command terraform
ensure_command jq

if [[ ! -d "$TERRAFORM_DIR" ]]; then
  echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
  exit 1
fi
if ! terraform -chdir="$TERRAFORM_DIR" output -json >/dev/null 2>&1; then
  echo "Terraform outputs unavailable in ${TERRAFORM_DIR}; run terraform apply first." >&2
  exit 1
fi

SOURCE_RANGE="$(normalize_source_range "$SOURCE_RANGE")"
SOURCE_IP_ONLY="${SOURCE_RANGE%/*}"
if [[ -z "$CLIENT_UID" ]]; then
  CLIENT_UID="$(python_json random-secret | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
  CLIENT_UID="real-tpm-$(date -u +%Y%m%d%H%M%S)-${CLIENT_UID}"
fi
if [[ -z "$SECRET_VALUE" ]]; then
  SECRET_VALUE="$(python_json random-secret)"
fi
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(terraform_output_raw project_id)"
fi
if [[ -z "$ZONE" ]]; then
  ZONE="$(terraform_output_raw deployment_zone)"
fi
if [[ -z "$SERVER_INSTANCE" ]]; then
  SERVER_INSTANCE="$(terraform_output_raw server_instance_name)"
fi
SERVER_INTERNAL_IP="$(terraform_output_raw server_internal_ip)"

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$SERVER_INSTANCE" || -z "$SERVER_INTERNAL_IP" ]]; then
  echo "Unable to resolve project, zone, server instance, or server internal IP from Terraform outputs." >&2
  exit 1
fi

if [[ -z "$BUILD_STAGE_DIR" ]]; then
  BUILD_STAGE_DIR="${REPO_ROOT}/build/windows-real-tpm-build/${CLIENT_UID}"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${REPO_ROOT}/build/windows-real-tpm-handoff/${CLIENT_UID}"
fi

MSI_OUTPUT_PATH="${BUILD_STAGE_DIR}/installer/dist/MyTunnelApp.msi"
DEVICE_ID_PROBE_PATH="${REPO_ROOT}/cmd/scepclient/device-id-probe.exe"
WINDOWS_PREREG_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/preregister-mytunnelapp.ps1"

INTERNAL_SERVER_BASE_URL="http://${SERVER_INTERNAL_IP}:3000"
curl -fsS "${INTERNAL_SERVER_BASE_URL}/admin/api/ping" >/dev/null
curl -fsS "${INTERNAL_SERVER_BASE_URL}/scep?operation=GetCACaps" >/dev/null

SERVER_NETWORK_FULL="$(gcloud compute instances describe "$SERVER_INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --format='value(networkInterfaces[0].network)')"
SERVER_NETWORK_NAME="${SERVER_NETWORK_FULL##*/}"
FIREWALL_HASH="$(printf '%s' "$SOURCE_RANGE" | sha256sum | awk '{print substr($1,1,8)}')"
FIREWALL_RULE_NAME="scep-realtpm-3000-${FIREWALL_HASH}"

SERVER_PUBLIC_IP="$(gcloud compute instances describe "$SERVER_INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' || true)"
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  echo "Assigning a public IP to ${SERVER_INSTANCE}"
  gcloud compute instances add-access-config "$SERVER_INSTANCE" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --access-config-name "External NAT" \
    >/dev/null
  for _ in $(seq 1 20); do
    SERVER_PUBLIC_IP="$(gcloud compute instances describe "$SERVER_INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' || true)"
    if [[ -n "$SERVER_PUBLIC_IP" ]]; then
      break
    fi
    sleep 3
  done
fi
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  echo "Failed to resolve a public IP for ${SERVER_INSTANCE}." >&2
  exit 1
fi

if gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules update "$FIREWALL_RULE_NAME" \
    --project "$PROJECT_ID" \
    --allow tcp:3000 \
    --source-ranges "$SOURCE_RANGE" \
    --target-tags scep \
    >/dev/null
else
  gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --project "$PROJECT_ID" \
    --network "$SERVER_NETWORK_NAME" \
    --direction INGRESS \
    --priority 1000 \
    --allow tcp:3000 \
    --source-ranges "$SOURCE_RANGE" \
    --target-tags scep \
    --description "Temporary real TPM validation access to SCEP/admin endpoint on TCP/3000" \
    >/dev/null
fi

ENCODED_UID="$(urlencode "$CLIENT_UID")"
CLIENT_JSON="$(api_request GET "$INTERNAL_SERVER_BASE_URL" "/api/client/${ENCODED_UID}" "" 200)"
CLIENT_STATUS="$(json_get_client_status "$CLIENT_JSON")"

if [[ "$CLIENT_JSON" == "null" ]]; then
  api_request POST "$INTERNAL_SERVER_BASE_URL" "/admin/api/client/add" "$(python_json client-add "$CLIENT_UID")" 200 >/dev/null
  CLIENT_STATUS="INACTIVE"
fi

case "$CLIENT_STATUS" in
  INACTIVE)
    ;;
  ISSUABLE)
    api_request POST "$INTERNAL_SERVER_BASE_URL" "/admin/api/client/revoke" "$(python_json client-revoke "$CLIENT_UID")" 200 >/dev/null
    CLIENT_STATUS="INACTIVE"
    ;;
  "")
    CLIENT_STATUS="INACTIVE"
    ;;
  *)
    echo "Client ${CLIENT_UID} is already in status ${CLIENT_STATUS}; refusing to overwrite an issued or updating record." >&2
    exit 1
    ;;
esac

api_request POST "$INTERNAL_SERVER_BASE_URL" "/admin/api/secret/create" "$(python_json secret-create "$CLIENT_UID" "$SECRET_VALUE" "$AVAILABLE_PERIOD" "$PENDING_PERIOD")" 201 >/dev/null
SECRET_INFO_JSON="$(api_request GET "$INTERNAL_SERVER_BASE_URL" "/admin/api/secret/get/${ENCODED_UID}" "" 200)"
SECRET_DELETE_AT="$(python_json secret-delete-at "$SECRET_INFO_JSON")"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "${REPO_ROOT}/infra/terraform/scripts/linux/build_windows_msi.sh" \
    --repo-root "$REPO_ROOT" \
    --terraform-dir "$TERRAFORM_DIR" \
    --stage-dir "$BUILD_STAGE_DIR" \
    --output-path "$MSI_OUTPUT_PATH"
fi

if [[ ! -f "$MSI_OUTPUT_PATH" ]]; then
  echo "MSI not found at ${MSI_OUTPUT_PATH}" >&2
  exit 1
fi
if [[ ! -f "$DEVICE_ID_PROBE_PATH" ]]; then
  echo "device-id-probe.exe not found at ${DEVICE_ID_PROBE_PATH}" >&2
  exit 1
fi
if [[ ! -f "$WINDOWS_PREREG_SCRIPT" ]]; then
  echo "Windows preregistration helper not found at ${WINDOWS_PREREG_SCRIPT}" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$MSI_OUTPUT_PATH" "${OUTPUT_DIR}/MyTunnelApp.msi"
cp "$DEVICE_ID_PROBE_PATH" "${OUTPUT_DIR}/device-id-probe.exe"
cp "$WINDOWS_PREREG_SCRIPT" "${OUTPUT_DIR}/preregister-mytunnelapp.ps1"

PUBLIC_SERVER_BASE_URL="http://${SERVER_PUBLIC_IP}:3000"
PUBLIC_SERVER_URL="${PUBLIC_SERVER_BASE_URL}/scep"
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${OUTPUT_DIR}/01-preregister-and-check.ps1" <<EOF
[CmdletBinding()]
param(
  [switch]\$RefreshEnrollmentSecret
)

\$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

\$params = @{
  ServerBaseUrl        = '${PUBLIC_SERVER_BASE_URL}'
  ServerUrl            = '${PUBLIC_SERVER_URL}'
  ClientUid            = '${CLIENT_UID}'
  EnrollmentSecret     = '${SECRET_VALUE}'
  ManagedClientType    = 'windows-msi'
  AvailablePeriod      = '${AVAILABLE_PERIOD}'
  PendingPeriod        = '${PENDING_PERIOD}'
  ProbePath            = (Join-Path \$PSScriptRoot 'device-id-probe.exe')
  SecretRefreshLeadMinutes = 15
}

if (\$RefreshEnrollmentSecret) {
  \$params.RefreshEnrollmentSecret = \$true
}

& (Join-Path \$PSScriptRoot 'preregister-mytunnelapp.ps1') @params
EOF

cat > "${OUTPUT_DIR}/REALTPM-HANDOFF.txt" <<EOF
MyTunnelApp real TPM validation handoff
Generated at UTC: ${GENERATED_AT_UTC}

Files in this folder:
- MyTunnelApp.msi
- device-id-probe.exe
- preregister-mytunnelapp.ps1
- 01-preregister-and-check.ps1
- REALTPM-HANDOFF.txt
- handoff.json

Input values for the MSI:
- SERVER_URL: ${PUBLIC_SERVER_URL}
- CLIENT_UID: ${CLIENT_UID}
- ENROLLMENT_SECRET: ${SECRET_VALUE}
- managed_client_type: windows-msi

Server access prepared for this validation:
- Allowed public source range: ${SOURCE_RANGE}
- Server public base URL: ${PUBLIC_SERVER_BASE_URL}
- Server internal base URL: ${INTERNAL_SERVER_BASE_URL}
- Server instance: ${SERVER_INSTANCE}
- GCP project / zone: ${PROJECT_ID} / ${ZONE}
- Firewall rule: ${FIREWALL_RULE_NAME}
- Enrollment secret delete_at (UTC): ${SECRET_DELETE_AT}

What to do on the Windows machine:
1. Confirm the machine egresses as ${SOURCE_IP_ONLY} before using this folder.
2. Run 01-preregister-and-check.ps1 from this folder. It probes the canonical TPM device_id, updates the server-side device binding, and verifies prereg-check=ready.
3. If you want to force a fresh initial secret before the MSI install, rerun:
   powershell -ExecutionPolicy Bypass -File .\01-preregister-and-check.ps1 -RefreshEnrollmentSecret
4. Start MyTunnelApp.msi.
5. In Step 1, confirm CURRENT_DEVICE_ID matches the expected_device_id printed by the script.
6. In Step 2, enter SERVER_URL and CLIENT_UID above, then confirm prereg-check returns ready.
7. In Step 3, enter ENROLLMENT_SECRET above and continue the install.

Post-install checks:
1. Confirm a client certificate appears in LocalMachine\My.
2. Confirm the service is installed and running.
3. Confirm HKLM\SOFTWARE\MyTunnelApp no longer retains the bootstrap enrollment secret after the first issuance completes.

Important notes:
- TCP/3000 is exposed publicly only to ${SOURCE_RANGE}, but that source can reach both the SCEP path and the admin API paths during this validation window.
- This folder contains the one-time enrollment secret. Delete it from the Windows machine after the issuance test finishes.

Manual prereg path if you do not want to run the PowerShell helper:
1. Confirm the Windows machine's public egress IP is ${SOURCE_IP_ONLY}.
2. Double-click device-id-probe.exe. It opens a text report in Notepad showing expected_device_id, ek_public_b64, ek_cert_b64, and attestation_ek_cert_sha256. For scripted use, .\device-id-probe.exe -json prints the same values as JSON.
3. Confirm the MSI Step 1 CURRENT_DEVICE_ID matches expected_device_id from the probe report.
4. Send expected_device_id to the operator for device binding. If you want strict EK Certificate pinning, also send attestation_ek_cert_sha256.
5. After the operator updates the server-side record, return to MSI Step 2 and check that prereg-check returns ready for CLIENT_UID ${CLIENT_UID}.
EOF

python_json to-json \
  "$GENERATED_AT_UTC" \
  "$PUBLIC_SERVER_BASE_URL" \
  "$PUBLIC_SERVER_URL" \
  "$INTERNAL_SERVER_BASE_URL" \
  "$SERVER_INTERNAL_IP" \
  "$SERVER_PUBLIC_IP" \
  "$CLIENT_UID" \
  "$SECRET_VALUE" \
  "windows-msi" \
  "$SOURCE_RANGE" \
  "$SECRET_DELETE_AT" \
  "$FIREWALL_RULE_NAME" \
  "$SERVER_INSTANCE" \
  "$PROJECT_ID" \
  "$ZONE" \
  > "${OUTPUT_DIR}/handoff.json"

chmod +x "${OUTPUT_DIR}/01-preregister-and-check.ps1" >/dev/null 2>&1 || true

printf 'handoff_dir=%s\n' "$OUTPUT_DIR"
printf 'server_public_ip=%s\n' "$SERVER_PUBLIC_IP"
printf 'server_base_url=%s\n' "$PUBLIC_SERVER_BASE_URL"
printf 'server_url=%s\n' "$PUBLIC_SERVER_URL"
printf 'client_uid=%s\n' "$CLIENT_UID"
printf 'enrollment_secret=%s\n' "$SECRET_VALUE"
printf 'secret_delete_at=%s\n' "$SECRET_DELETE_AT"
printf 'allowed_source_range=%s\n' "$SOURCE_RANGE"
printf 'firewall_rule=%s\n' "$FIREWALL_RULE_NAME"
