#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare_windows_chrome_remote_desktop.sh [options]

Prepare the Windows validation VM for Chrome Remote Desktop by installing the
Chrome Remote Desktop Host, reusing Microsoft Edge when it is already present
or installing Google Chrome when needed, then creating a one-shot startup
launcher that opens the CRD support page on the next interactive logon.

Important: Chrome Remote Desktop one-time support codes are not generated
headlessly by this script. Google requires an interactive browser session on
the host VM to sign in and click "Generate Code".

Options:
  --support-url <URL>             Support page to open on next logon
                                  (default: https://remotedesktop.google.com/support)
  --chrome-msi-url <URL>          Google Chrome MSI URL
                                  (default: official 64-bit enterprise MSI)
  --crd-host-msi-url <URL>        Chrome Remote Desktop Host MSI URL
                                  (default: official CRD host MSI)
  --project <PROJECT_ID>          GCP project override
  --zone <ZONE>                   GCP zone override
  --instance <INSTANCE_NAME>      Windows VM override
  --terraform-dir <PATH>          Terraform working directory
                                  (default: <repo-root>/infra/terraform)
  --repo-root <PATH>              Repository root
                                  (default: auto-detected)
  --wait-seconds <SECONDS>        Wait budget for serial markers (default: 600)
  -h, --help                      Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
WAIT_SECONDS=600
SERIAL_WAIT_GRACE_SECONDS=180
SUPPORT_URL="https://remotedesktop.google.com/support"
CHROME_MSI_URL="https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi"
CRD_HOST_MSI_URL="https://dl.google.com/dl/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --support-url)
      SUPPORT_URL="${2:?missing value for --support-url}"
      shift 2
      ;;
    --chrome-msi-url)
      CHROME_MSI_URL="${2:?missing value for --chrome-msi-url}"
      shift 2
      ;;
    --crd-host-msi-url)
      CRD_HOST_MSI_URL="${2:?missing value for --crd-host-msi-url}"
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
    --wait-seconds)
      WAIT_SECONDS="${2:?missing value for --wait-seconds}"
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

WINDOWS_STARTUP_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/windows-client-startup.ps1"
WINDOWS_CRD_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/prepare-chrome-remote-desktop.ps1"

ensure_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

escape_ps_single_quoted() {
  printf '%s' "$1" | sed "s/'/''/g"
}

terraform_output_raw() {
  local key="$1"
  terraform -chdir="$TERRAFORM_DIR" output -raw "$key" 2>/dev/null || true
}

restore_windows_startup_script() {
  gcloud compute instances add-metadata "$INSTANCE" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --metadata-from-file "windows-startup-script-ps1=${WINDOWS_STARTUP_SCRIPT}" \
    >/dev/null 2>&1 || true
}

wait_for_crd_result() {
  local action_id="$1"
  local deadline serial_output
  deadline=$(( $(date +%s) + WAIT_SECONDS + SERIAL_WAIT_GRACE_SECONDS ))

  echo "Waiting for Chrome Remote Desktop setup markers"
  while (( $(date +%s) <= deadline )); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null | tr -d '\000' || true)"
    if [[ "$serial_output" == *"COPILOT_CRD_SETUP_DONE id=${action_id}"* ]]; then
      grep "COPILOT_CRD_SETUP_.*id=${action_id}" <<<"$serial_output" | tail -n 40 || true
      return 0
    fi
    if [[ "$serial_output" == *"COPILOT_CRD_SETUP_FAILED id=${action_id}"* ]]; then
      grep "COPILOT_CRD_SETUP_.*id=${action_id}" <<<"$serial_output" | tail -n 40 >&2 || true
      return 1
    fi
    sleep 15
  done

  echo "Timed out waiting for Chrome Remote Desktop setup markers." >&2
  printf '%s\n' "$serial_output" | tail -n 120 >&2 || true
  return 1
}

ensure_command gcloud

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
  INSTANCE="$(terraform_output_raw client_instance_name)"
fi
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(terraform_output_raw project_id)"
fi
if [[ -z "$ZONE" ]]; then
  ZONE="$(terraform_output_raw deployment_zone)"
fi

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  echo "Unable to resolve --project, --zone, or --instance." >&2
  exit 1
fi

if [[ ! -f "$WINDOWS_STARTUP_SCRIPT" ]]; then
  echo "Windows startup script not found: $WINDOWS_STARTUP_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$WINDOWS_CRD_SCRIPT" ]]; then
  echo "Chrome Remote Desktop setup script not found: $WINDOWS_CRD_SCRIPT" >&2
  exit 1
fi

action_id="copilot-crd-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
temp_script="$(mktemp)"
trap 'restore_windows_startup_script; rm -f "$temp_script"' EXIT

cat "$WINDOWS_STARTUP_SCRIPT" > "$temp_script"
printf '\n' >> "$temp_script"
cat "$WINDOWS_CRD_SCRIPT" >> "$temp_script"
cat >> "$temp_script" <<EOF

try {
  Invoke-CopilotChromeRemoteDesktopSetup -ActionId '$(escape_ps_single_quoted "$action_id")' -ChromeMsiUrl '$(escape_ps_single_quoted "$CHROME_MSI_URL")' -ChromeRemoteDesktopHostMsiUrl '$(escape_ps_single_quoted "$CRD_HOST_MSI_URL")' -SupportUrl '$(escape_ps_single_quoted "$SUPPORT_URL")'
} catch {
  \$copilotCrdMessage = \$_.Exception.Message -replace '[\\r\\n]+', ' '
  Write-Host ("COPILOT_CRD_SETUP_FAILED id=$(escape_ps_single_quoted "$action_id") message={0}" -f \$copilotCrdMessage)
  throw
}
EOF

gcloud compute instances add-metadata "$INSTANCE" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --metadata-from-file "windows-startup-script-ps1=${temp_script}" \
  >/dev/null
gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

wait_for_crd_result "$action_id"

cat <<EOF
Chrome Remote Desktop bootstrap is ready on ${INSTANCE}.

Important:
- Google does not support headless generation of one-time Chrome Remote Desktop support codes.
- This script installed CRD Host and ensured a supported browser is available, then created a one-shot startup launcher that opens:
  ${SUPPORT_URL}
  on the next interactive Windows logon.

Next steps:
1. Reset or retrieve the Windows password:
   gcloud compute reset-windows-password "${INSTANCE}" --project "${PROJECT_ID}" --zone "${ZONE}"
2. Log into the VM once (for example with the existing internal-only RDP / IAP path).
3. Chrome should open the Chrome Remote Desktop support page automatically.
4. Sign in and click "Generate Code" to obtain the one-time access code.
EOF
