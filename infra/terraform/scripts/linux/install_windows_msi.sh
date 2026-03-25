#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install_windows_msi.sh [options]

Install the already-copied silent MSI on the Windows validation VM by
temporarily replacing the instance startup script, rebooting the VM, and
waiting for serial-port markers from the install/verification script.

Options:
  --server-url <URL>                  Full SCEP URL. Defaults to http://<server_internal_ip>:3000/scep when available, otherwise external IP
  --client-uid <UID>                  Required client UID
  --enrollment-secret <SECRET>        Required one-time enrollment secret
  --device-id-override <DEVICE_ID>    Required device_id override for the current phase
  --poll-interval <DURATION>          Optional MSI property (default: 1h)
  --renew-before <DURATION>           Optional MSI property (default: 14d)
  --log-level <LEVEL>                 Optional MSI property (default: info)
  --msi-path <WINDOWS_PATH>           MSI path on the Windows VM (default: C:\Users\Public\MyTunnelApp.msi)
  --wait-seconds <SECONDS>            Wait budget for serial markers (default: 300)
  --force-fresh-install               Uninstall existing MSI-managed config before reinstalling
                                      (the helper also auto-falls back to this path if same-version reinstall leaves stale config)
  --apply-registry-overrides          Rewrite HKLM config after msiexec and restart the service
  --converge-to-local-service         Grant HKLM config access to LocalService and reconfigure
                                      MyTunnelService to run as NT AUTHORITY\LocalService
  --require-thumbprint-change         Wait until managed cert thumbprint changes before succeeding
  --tamper-activation-proof-renewal   After install observation, submit a renewal with tampered
                                      activation_proof_b64 and require thumbprint stability
  --project <PROJECT_ID>              GCP project ID (optional; auto-detected from Terraform)
  --zone <ZONE>                       GCP zone (optional; auto-detected from Terraform)
  --instance <INSTANCE_NAME>          Windows instance name (optional; auto-detected from Terraform)
  --terraform-dir <PATH>              Terraform working directory (default: <repo-root>/infra/terraform)
  --repo-root <PATH>                  Repository root (default: auto-detected)
  -h, --help                          Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
SERVER_URL=""
CLIENT_UID=""
ENROLLMENT_SECRET=""
DEVICE_ID_OVERRIDE=""
POLL_INTERVAL="1h"
RENEW_BEFORE="14d"
LOG_LEVEL="info"
MSI_PATH='C:\Users\Public\MyTunnelApp.msi'
WAIT_SECONDS=300
FORCE_FRESH_INSTALL=0
APPLY_REGISTRY_OVERRIDES=0
CONVERGE_TO_LOCAL_SERVICE=0
REQUIRE_THUMBPRINT_CHANGE=0
TAMPER_ACTIVATION_PROOF_RENEWAL=0
SERIAL_WAIT_GRACE_SECONDS=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url)
      SERVER_URL="${2:?missing value for --server-url}"
      shift 2
      ;;
    --client-uid)
      CLIENT_UID="${2:?missing value for --client-uid}"
      shift 2
      ;;
    --enrollment-secret)
      ENROLLMENT_SECRET="${2:?missing value for --enrollment-secret}"
      shift 2
      ;;
    --device-id-override)
      DEVICE_ID_OVERRIDE="${2:?missing value for --device-id-override}"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL="${2:?missing value for --poll-interval}"
      shift 2
      ;;
    --renew-before)
      RENEW_BEFORE="${2:?missing value for --renew-before}"
      shift 2
      ;;
    --log-level)
      LOG_LEVEL="${2:?missing value for --log-level}"
      shift 2
      ;;
    --msi-path)
      MSI_PATH="${2:?missing value for --msi-path}"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:?missing value for --wait-seconds}"
      shift 2
      ;;
    --force-fresh-install)
      FORCE_FRESH_INSTALL=1
      shift
      ;;
    --apply-registry-overrides)
      APPLY_REGISTRY_OVERRIDES=1
      shift
      ;;
    --converge-to-local-service)
      CONVERGE_TO_LOCAL_SERVICE=1
      shift
      ;;
    --require-thumbprint-change)
      REQUIRE_THUMBPRINT_CHANGE=1
      shift
      ;;
    --tamper-activation-proof-renewal)
      TAMPER_ACTIVATION_PROOF_RENEWAL=1
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

if [[ -z "$CLIENT_UID" || -z "$ENROLLMENT_SECRET" || -z "$DEVICE_ID_OVERRIDE" ]]; then
  echo "--client-uid, --enrollment-secret, and --device-id-override are required." >&2
  exit 1
fi

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi

WINDOWS_STARTUP_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/windows-client-startup.ps1"
WINDOWS_INSTALL_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/install-mytunnelapp.ps1"

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

wait_for_install_result() {
  local install_id="$1"
  local deadline serial_output
  deadline=$(( $(date +%s) + WAIT_SECONDS + SERIAL_WAIT_GRACE_SECONDS ))

  echo "Waiting for Windows MSI install markers"
  while (( $(date +%s) <= deadline )); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null | tr -d '\000' || true)"
    if printf '%s\n' "$serial_output" | grep -q "MYTUNNEL_MSI_INSTALL_DONE id=${install_id}"; then
      printf '%s\n' "$serial_output" | grep "MYTUNNEL_MSI_INSTALL_.*id=${install_id}" | tail -n 20
      return 0
    fi
    if printf '%s\n' "$serial_output" | grep -q "MYTUNNEL_MSI_INSTALL_FAILED id=${install_id}"; then
      printf '%s\n' "$serial_output" | grep "MYTUNNEL_MSI_INSTALL_.*id=${install_id}" | tail -n 20 >&2
      return 1
    fi
    sleep 15
  done

  echo "Timed out waiting for Windows MSI install markers." >&2
  printf '%s\n' "$serial_output" | tail -n 120 >&2 || true
  return 1
}

ensure_command gcloud

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" || -z "$SERVER_URL" ]]; then
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
if [[ -z "$SERVER_URL" ]]; then
  server_ip="$(terraform_output_raw server_internal_ip)"
  if [[ -z "$server_ip" ]]; then
    server_ip="$(terraform_output_raw server_external_ip)"
  fi
  if [[ -z "$server_ip" ]]; then
    echo "Unable to resolve server_internal_ip or server_external_ip from Terraform output; provide --server-url." >&2
    exit 1
  fi
  SERVER_URL="http://${server_ip}:3000/scep"
fi

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  echo "Unable to resolve --project, --zone, or --instance." >&2
  exit 1
fi

if [[ ! -f "$WINDOWS_STARTUP_SCRIPT" ]]; then
  echo "Windows startup script not found: $WINDOWS_STARTUP_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$WINDOWS_INSTALL_SCRIPT" ]]; then
  echo "Windows install helper not found: $WINDOWS_INSTALL_SCRIPT" >&2
  exit 1
fi

install_id="copilot-install-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
temp_script="$(mktemp)"
trap 'restore_windows_startup_script; rm -f "$temp_script"' EXIT

cat "$WINDOWS_STARTUP_SCRIPT" > "$temp_script"
printf '\n' >> "$temp_script"
cat "$WINDOWS_INSTALL_SCRIPT" >> "$temp_script"
cat >> "$temp_script" <<EOF

\$copilotInstallId = '$(escape_ps_single_quoted "$install_id")'
try {
  Write-Output "MYTUNNEL_MSI_INSTALL_START id=\$copilotInstallId client_uid=$(escape_ps_single_quoted "$CLIENT_UID") device_id=$(escape_ps_single_quoted "$DEVICE_ID_OVERRIDE")"
  \$copilotInstallSummary = Invoke-MyTunnelAppSilentInstall -MsiPath '$(escape_ps_single_quoted "$MSI_PATH")' -ServerUrl '$(escape_ps_single_quoted "$SERVER_URL")' -ClientUid '$(escape_ps_single_quoted "$CLIENT_UID")' -EnrollmentSecret '$(escape_ps_single_quoted "$ENROLLMENT_SECRET")' -DeviceIdOverride '$(escape_ps_single_quoted "$DEVICE_ID_OVERRIDE")' -PollInterval '$(escape_ps_single_quoted "$POLL_INTERVAL")' -RenewBefore '$(escape_ps_single_quoted "$RENEW_BEFORE")' -LogLevel '$(escape_ps_single_quoted "$LOG_LEVEL")' $(if [[ "$FORCE_FRESH_INSTALL" -eq 1 ]]; then printf -- "-ForceFreshInstall "; fi)$(if [[ "$APPLY_REGISTRY_OVERRIDES" -eq 1 ]]; then printf -- "-ApplyRegistryOverrides "; fi)$(if [[ "$CONVERGE_TO_LOCAL_SERVICE" -eq 1 ]]; then printf -- "-ConvergeToLocalService "; fi)$(if [[ "$REQUIRE_THUMBPRINT_CHANGE" -eq 1 ]]; then printf -- "-RequireManagedThumbprintChange "; fi)-WaitSeconds $WAIT_SECONDS
$(if [[ "$TAMPER_ACTIVATION_PROOF_RENEWAL" -eq 1 ]]; then cat <<PS
  \$copilotActivationNegative = Invoke-MyTunnelTamperedActivationRenewal -ServerUrl '$(escape_ps_single_quoted "$SERVER_URL")' -ClientUid '$(escape_ps_single_quoted "$CLIENT_UID")' -DeviceIdOverride '$(escape_ps_single_quoted "$DEVICE_ID_OVERRIDE")'
  \$copilotInstallSummary['activation_negative'] = \$copilotActivationNegative
PS
fi)
  \$copilotInstallMarkerSummary = ConvertTo-MyTunnelMarkerSummary -Summary \$copilotInstallSummary
  \$copilotInstallJson = \$copilotInstallMarkerSummary | ConvertTo-Json -Depth 6 -Compress
  Write-Output ("MYTUNNEL_MSI_INSTALL_DONE id=\$copilotInstallId summary={0}" -f \$copilotInstallJson)
} catch {
  \$copilotInstallMessage = \$_.Exception.Message -replace '[\\r\\n]+', ' '
  Write-Output ("MYTUNNEL_MSI_INSTALL_FAILED id=\$copilotInstallId message={0}" -f \$copilotInstallMessage)
  throw
}
EOF

gcloud compute instances add-metadata "$INSTANCE" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --metadata-from-file "windows-startup-script-ps1=${temp_script}" \
  >/dev/null
gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

wait_for_install_result "$install_id"
