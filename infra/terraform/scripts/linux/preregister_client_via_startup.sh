#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: preregister_client_via_startup.sh [options]

Pre-register a unique client/device pair by temporarily replacing the Linux VM
startup script, rebooting the server VM, and executing the admin API requests
from localhost on the VM itself. This is intended for validation environments
where the operator cannot reach the admin API externally.

Options:
  --uid <UID>                        Required client UID
  --secret <SECRET>                  Required one-time enrollment secret
  --device-id <DEVICE_ID>            Required device_id
  --managed-client-type windows-msi  Optional managed client type
  --available-period <DURATION>      Secret availability window (default: 30m)
  --pending-period <DURATION>        Secret pending window (default: 0s)
  --server-base-url <URL>            Base URL on the server VM (default: http://127.0.0.1:3000)
  --wait-seconds <SECONDS>           Wait budget for serial markers (default: 240)
  --project <PROJECT_ID>             GCP project ID (optional; auto-detected from Terraform)
  --zone <ZONE>                      GCP zone (optional; auto-detected from Terraform)
  --instance <INSTANCE_NAME>         Server instance name (optional; auto-detected from Terraform)
  --terraform-dir <PATH>             Terraform working directory (default: <repo-root>/infra/terraform)
  --repo-root <PATH>                 Repository root (default: auto-detected)
  -h, --help                         Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
UID_VALUE=""
SECRET_VALUE=""
DEVICE_ID=""
MANAGED_CLIENT_TYPE=""
MANAGED_CLIENT_TYPE_SET=0
AVAILABLE_PERIOD="30m"
PENDING_PERIOD="0s"
SERVER_BASE_URL="http://127.0.0.1:3000"
WAIT_SECONDS=240

normalize_managed_client_type() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$value" in
    windows-msi)
      printf '%s' "$value"
      ;;
    *)
      echo "managed client type must be windows-msi" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uid)
      UID_VALUE="${2:?missing value for --uid}"
      shift 2
      ;;
    --secret)
      SECRET_VALUE="${2:?missing value for --secret}"
      shift 2
      ;;
    --device-id)
      DEVICE_ID="${2:?missing value for --device-id}"
      shift 2
      ;;
    --managed-client-type)
      MANAGED_CLIENT_TYPE="$(normalize_managed_client_type "${2:?missing value for --managed-client-type}")"
      MANAGED_CLIENT_TYPE_SET=1
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
    --server-base-url)
      SERVER_BASE_URL="${2:?missing value for --server-base-url}"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:?missing value for --wait-seconds}"
      shift 2
      ;;
    --project)
      PROJECT_ID="${2:?missing value for --project}"
      shift 2
      ;;
    --zone)
      ZONE="${2:?missing value for --zone}"
      shift 2
      ;;
    --instance)
      INSTANCE="${2:?missing value for --instance}"
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

if [[ -z "$UID_VALUE" || -z "$SECRET_VALUE" || -z "$DEVICE_ID" ]]; then
  echo "--uid, --secret, and --device-id are required." >&2
  exit 1
fi

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

escape_bash_single_quoted() {
  printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

capture_linux_startup_script() {
  local output_path="$1"
  local metadata_file

  metadata_file="$(mktemp)"
  gcloud compute instances describe "$INSTANCE" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --format=json >"$metadata_file"

  python3 - "$metadata_file" "$output_path" <<'PY'
import json
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
data = json.loads(metadata_path.read_text(encoding="utf-8"))
items = data.get("metadata", {}).get("items", [])
for item in items:
    if item.get("key") == "startup-script":
        output_path.write_text(item.get("value", ""), encoding="utf-8")
        break
else:
    output_path.write_text("", encoding="utf-8")
PY

  rm -f "$metadata_file"
}

restore_linux_startup_script() {
  local saved_script="$1"
  if [[ -s "$saved_script" ]]; then
    gcloud compute instances add-metadata "$INSTANCE" \
      --project "$PROJECT_ID" \
      --zone "$ZONE" \
      --metadata-from-file "startup-script=${saved_script}" \
      >/dev/null 2>&1 || true
  else
    gcloud compute instances remove-metadata "$INSTANCE" \
      --project "$PROJECT_ID" \
      --zone "$ZONE" \
      --keys startup-script \
      >/dev/null 2>&1 || true
  fi
}

wait_for_marker() {
  local action_id="$1"
  local deadline serial_output
  deadline=$(( $(date +%s) + WAIT_SECONDS ))

  echo "Waiting for preregistration markers"
  while (( $(date +%s) <= deadline )); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null || true)"
    if [[ "$serial_output" == *"COPILOT_PREREGISTER_DONE id=${action_id}"* ]]; then
      grep "COPILOT_PREREGISTER_.*id=${action_id}" <<<"$serial_output" | tail -n 20 || true
      return 0
    fi
    if [[ "$serial_output" == *"COPILOT_PREREGISTER_FAILED id=${action_id}"* ]]; then
      grep "COPILOT_PREREGISTER_.*id=${action_id}" <<<"$serial_output" | tail -n 20 >&2 || true
      return 1
    fi
    sleep 15
  done

  echo "Timed out waiting for preregistration markers." >&2
  printf '%s\n' "$serial_output" | tail -n 120 >&2 || true
  return 1
}

ensure_command gcloud
ensure_command python3

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  ensure_command terraform
  if [[ ! -d "$TERRAFORM_DIR" ]]; then
    echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
    exit 1
  fi
  if ! terraform -chdir="$TERRAFORM_DIR" output -json >/dev/null 2>&1; then
    echo "Terraform outputs unavailable in ${TERRAFORM_DIR}; run terraform apply first." >&2
    exit 1
  fi
fi

if [[ -z "$INSTANCE" ]]; then
  INSTANCE="$(terraform -chdir="$TERRAFORM_DIR" output -raw server_instance_name 2>/dev/null || true)"
fi
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(terraform -chdir="$TERRAFORM_DIR" output -raw project_id 2>/dev/null || true)"
fi
if [[ -z "$ZONE" ]]; then
  ZONE="$(terraform -chdir="$TERRAFORM_DIR" output -raw deployment_zone 2>/dev/null || true)"
fi

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  echo "Unable to resolve --project, --zone, or --instance." >&2
  exit 1
fi

action_id="copilot-preregister-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
original_startup_script="$(mktemp)"
temp_script="$(mktemp)"
capture_linux_startup_script "$original_startup_script"
trap 'restore_linux_startup_script "$original_startup_script"; rm -f "$temp_script" "$original_startup_script"' EXIT

cat "$original_startup_script" >"$temp_script"
printf '\n' >>"$temp_script"
cat >>"$temp_script" <<EOF
command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y --no-install-recommends curl; }
uid='$(escape_bash_single_quoted "$UID_VALUE")'
secret='$(escape_bash_single_quoted "$SECRET_VALUE")'
device_id='$(escape_bash_single_quoted "$DEVICE_ID")'
available_period='$(escape_bash_single_quoted "$AVAILABLE_PERIOD")'
pending_period='$(escape_bash_single_quoted "$PENDING_PERIOD")'
server_base_url='$(escape_bash_single_quoted "$SERVER_BASE_URL")'
managed_client_type='$(escape_bash_single_quoted "$MANAGED_CLIENT_TYPE")'
managed_client_type_set='$(escape_bash_single_quoted "$MANAGED_CLIENT_TYPE_SET")'
encoded_uid="\${uid}"

api_request() {
  local method="\$1"
  local path="\$2"
  local payload="\${3:-}"
  local expected_status="\$4"
  local body_file body status
  body_file="\$(mktemp)"
  if [[ -n "\$payload" ]]; then
    status="\$(curl -sS -o "\$body_file" -w '%{http_code}' -X "\$method" "\${server_base_url%/}\${path}" -H 'Content-Type: application/json' --data "\$payload")"
  else
    status="\$(curl -sS -o "\$body_file" -w '%{http_code}' -X "\$method" "\${server_base_url%/}\${path}" -H 'Content-Type: application/json')"
  fi
  body="\$(cat "\$body_file")"
  rm -f "\$body_file"
  if [[ "\$status" != "\$expected_status" ]]; then
    echo "COPILOT_PREREGISTER_FAILED id=${action_id} reason=http_\${status} path=\$path"
    if [[ -n "\$body" ]]; then
      echo "COPILOT_PREREGISTER_FAILED id=${action_id} response=\$body"
    fi
    exit 1
  fi
  printf '%s' "\$body"
}

echo "COPILOT_PREREGISTER_START id=${action_id} uid=\$uid device_id=\$device_id"
existing_client="\$(api_request GET "/api/client/\${encoded_uid}" "" 200)"
if [[ "\$existing_client" != "null" ]]; then
  echo "COPILOT_PREREGISTER_FAILED id=${action_id} reason=uid_exists uid=\$uid"
  exit 1
fi

if [[ "\$managed_client_type_set" == "1" ]]; then
  add_payload="\$(printf '{"uid":"%s","attributes":{"device_id":"%s","managed_client_type":"%s"}}' "\$uid" "\$device_id" "\$managed_client_type")"
else
  add_payload="\$(printf '{"uid":"%s","attributes":{"device_id":"%s"}}' "\$uid" "\$device_id")"
fi
api_request POST "/admin/api/client/add" "\$add_payload" 200 >/dev/null

secret_payload="\$(printf '{"target":"%s","secret":"%s","available_period":"%s","pending_period":"%s"}' "\$uid" "\$secret" "\$available_period" "\$pending_period")"
api_request POST "/admin/api/secret/create" "\$secret_payload" 201 >/dev/null

echo "COPILOT_PREREGISTER_DONE id=${action_id} uid=\$uid device_id=\$device_id"
EOF

gcloud compute instances add-metadata "$INSTANCE" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --metadata-from-file "startup-script=${temp_script}" \
  >/dev/null
gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

wait_for_marker "$action_id"
