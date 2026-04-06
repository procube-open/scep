#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: windows_gui_issuance_e2e.sh [options]

Drive the WiX GUI MSI on the live Windows VM through page 1 TPM probe,
page 2 prereg-check, and page 3 ENROLLMENT_SECRET entry using Windows UI
Automation from the VM startup script. This captures release-blocker evidence
for the real GUI path instead of the silent helper path.

Optional:
  --windows-user <USER>               If provided, rebuild and transfer the
                                      current MSI/probe to the Windows VM first
  --client-uid <UID>                  Preregistered opaque client UID
                                      (default: auto-generate)
  --enrollment-secret <SECRET>        Initial one-time secret
                                      (default: auto-generate)
  --expected-device-id <DEVICE_ID>    Canonical TPM identity to preregister
                                      (default: probe device-id-probe.exe)
  --server-url <URL>                  Full SCEP URL (default: Terraform-derived)
  --msi-path <WINDOWS_PATH>           GUI MSI path on the Windows VM
                                      (default: C:\Users\Public\MyTunnelApp.msi)
  --probe-path <WINDOWS_PATH>         device-id-probe path on the Windows VM
                                      (default: C:\Users\Public\device-id-probe.exe)
  --poll-interval <DURATION>          Service poll interval
                                      (default: 10s)
  --renew-before <DURATION>           Renew-before value
                                      (default: 9000h)
  --log-level <LEVEL>                 Service log level
                                      (default: debug)
  --wait-seconds <SECONDS>            Wait budget for the GUI install run
                                      (default: 2100)
  --artifact-dir <DIR>                Directory for build/probe/install artifacts
  --msi-builder <auto|wix|wixl>       Packaging backend for local build
                                      (default: wix)
  --project <PROJECT_ID>              GCP project override
  --zone <ZONE>                       GCP zone override
  --instance <INSTANCE_NAME>          Windows VM override
  --terraform-dir <PATH>              Terraform working directory
  --repo-root <PATH>                  Repository root
  --skip-build                        Skip the local MSI build step
  -h, --help                          Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
WINDOWS_USER=""
CLIENT_UID=""
ENROLLMENT_SECRET=""
EXPECTED_DEVICE_ID=""
SERVER_URL=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
MSI_PATH='C:\Users\Public\MyTunnelApp.msi'
PROBE_PATH='C:\Users\Public\device-id-probe.exe'
POLL_INTERVAL="10s"
RENEW_BEFORE="9000h"
LOG_LEVEL="debug"
WAIT_SECONDS=2100
ARTIFACT_DIR=""
MSI_BUILDER="wix"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --windows-user)
      WINDOWS_USER="${2:?missing value for --windows-user}"
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
    --expected-device-id)
      EXPECTED_DEVICE_ID="${2:?missing value for --expected-device-id}"
      shift 2
      ;;
    --server-url)
      SERVER_URL="${2:?missing value for --server-url}"
      shift 2
      ;;
    --msi-path)
      MSI_PATH="${2:?missing value for --msi-path}"
      shift 2
      ;;
    --probe-path)
      PROBE_PATH="${2:?missing value for --probe-path}"
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
    --wait-seconds)
      WAIT_SECONDS="${2:?missing value for --wait-seconds}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:?missing value for --artifact-dir}"
      shift 2
      ;;
    --msi-builder)
      MSI_BUILDER="${2:?missing value for --msi-builder}"
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
    --skip-build)
      SKIP_BUILD=1
      shift
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

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${REPO_ROOT}/build/windows-gui-issuance"
fi
mkdir -p "$ARTIFACT_DIR"

BUILD_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/linux/build_windows_msi.sh"
PREREG_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/linux/preregister_client_via_startup.sh"
PROBE_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/linux/probe_windows_device_id.sh"
WINDOWS_STARTUP_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/windows-client-startup.ps1"
WINDOWS_INSTALL_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/install-mytunnelapp.ps1"
WINDOWS_GUI_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/gui-mytunnelapp.ps1"

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

wait_for_gui_result() {
  local gui_id="$1"
  local deadline serial_output done_line
  deadline=$(( $(date +%s) + WAIT_SECONDS + 180 ))

  while (( $(date +%s) <= deadline )); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null | tr -d '\000' || true)"
    done_line="$(printf '%s\n' "$serial_output" | grep "MYTUNNEL_GUI_INSTALL_DONE id=${gui_id} " | tail -n 1 || true)"
    if [[ -n "$done_line" ]]; then
      printf '%s\n' "$serial_output" | awk -v start="MYTUNNEL_GUI_INSTALL_START id=${gui_id}" -v done="MYTUNNEL_GUI_INSTALL_DONE id=${gui_id}" '
        index($0, start) { capture = 1 }
        capture { print }
        index($0, done) { exit }
      '
      printf '%s' "${done_line#*summary=}"
      return 0
    fi
    if [[ "$serial_output" == *"MYTUNNEL_GUI_INSTALL_FAILED id=${gui_id}"* ]]; then
      printf '%s\n' "$serial_output" | awk -v start="MYTUNNEL_GUI_INSTALL_START id=${gui_id}" -v fail="MYTUNNEL_GUI_INSTALL_FAILED id=${gui_id}" '
        index($0, start) { capture = 1 }
        capture { print }
        index($0, fail) { exit }
      ' >&2
      return 1
    fi
    sleep 15
  done

  echo "Timed out waiting for GUI install markers." >&2
  printf '%s\n' "$serial_output" | tail -n 160 >&2 || true
  return 1
}

generate_client_uid() {
  python3 - <<'PY'
import secrets
from datetime import datetime, timezone
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
print(f"wcgui_{stamp}_{secrets.token_hex(12)}")
PY
}

generate_enrollment_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
}

ensure_command gcloud
ensure_command python3
ensure_command terraform

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "Build helper is not executable: $BUILD_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$PREREG_SCRIPT" ]]; then
  echo "Preregistration helper is not executable: $PREREG_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$PROBE_SCRIPT" ]]; then
  echo "Probe helper is not executable: $PROBE_SCRIPT" >&2
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
if [[ ! -f "$WINDOWS_GUI_SCRIPT" ]]; then
  echo "Windows GUI helper not found: $WINDOWS_GUI_SCRIPT" >&2
  exit 1
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
  server_internal_ip="$(terraform_output_raw server_internal_ip)"
  if [[ -n "$server_internal_ip" ]]; then
    SERVER_URL="http://${server_internal_ip}:3000/scep"
  fi
fi

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" || -z "$SERVER_URL" ]]; then
  echo "Unable to resolve project, zone, instance, or server URL." >&2
  exit 1
fi

build_log="${ARTIFACT_DIR}/build.log"
probe_json="${ARTIFACT_DIR}/probe.json"
preregister_log="${ARTIFACT_DIR}/preregister.log"
install_log="${ARTIFACT_DIR}/install.log"
summary_json="${ARTIFACT_DIR}/summary.json"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_args=(
    --repo-root "$REPO_ROOT"
    --terraform-dir "$TERRAFORM_DIR"
    --msi-builder "$MSI_BUILDER"
  )
  if [[ -n "$WINDOWS_USER" ]]; then
    build_args+=(--windows-user "$WINDOWS_USER")
  fi
  if [[ -n "$PROJECT_ID" ]]; then
    build_args+=(--project "$PROJECT_ID")
  fi
  if [[ -n "$ZONE" ]]; then
    build_args+=(--zone "$ZONE")
  fi
  if [[ -n "$INSTANCE" ]]; then
    build_args+=(--instance "$INSTANCE")
  fi

  echo "Building current Windows MSI"
  "$BUILD_SCRIPT" "${build_args[@]}" 2>&1 | tee "$build_log"
fi

if [[ -z "$EXPECTED_DEVICE_ID" ]]; then
  echo "Probing Windows TPM device identity"
  "$PROBE_SCRIPT" \
    --repo-root "$REPO_ROOT" \
    --terraform-dir "$TERRAFORM_DIR" \
    --probe-path "$PROBE_PATH" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --instance "$INSTANCE" \
    >"$probe_json"

  EXPECTED_DEVICE_ID="$(python3 - "$probe_json" <<'PY'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data["expected_device_id"])
PY
)"
fi

if [[ -z "$CLIENT_UID" ]]; then
  CLIENT_UID="$(generate_client_uid)"
fi
if [[ -z "$ENROLLMENT_SECRET" ]]; then
  ENROLLMENT_SECRET="$(generate_enrollment_secret)"
fi

echo "Preregistering GUI validation client ${CLIENT_UID}"
"$PREREG_SCRIPT" \
  --repo-root "$REPO_ROOT" \
  --terraform-dir "$TERRAFORM_DIR" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --uid "$CLIENT_UID" \
  --secret "$ENROLLMENT_SECRET" \
  --device-id "$EXPECTED_DEVICE_ID" \
  --managed-client-type windows-msi \
  2>&1 | tee "$preregister_log"

gui_id="copilot-gui-install-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
temp_script="$(mktemp)"
trap 'restore_windows_startup_script; rm -f "$temp_script"' EXIT

expected_service_sha256_argument=""
if [[ -f "${REPO_ROOT}/rust-client/target/x86_64-pc-windows-gnu/release/service.exe" ]]; then
  expected_service_sha256="$(sha256sum "${REPO_ROOT}/rust-client/target/x86_64-pc-windows-gnu/release/service.exe" | awk '{print $1}')"
  expected_service_sha256_argument="-ExpectedServiceSha256 '$(escape_ps_single_quoted "$expected_service_sha256")' "
fi

expected_bundled_helper_sha256_argument=""
if [[ -f "${REPO_ROOT}/cmd/scepclient/scepclient.exe" ]]; then
  expected_bundled_helper_sha256="$(sha256sum "${REPO_ROOT}/cmd/scepclient/scepclient.exe" | awk '{print $1}')"
  expected_bundled_helper_sha256_argument="-ExpectedBundledHelperSha256 '$(escape_ps_single_quoted "$expected_bundled_helper_sha256")' "
fi

cat "$WINDOWS_STARTUP_SCRIPT" >"$temp_script"
printf '\n' >>"$temp_script"
cat "$WINDOWS_INSTALL_SCRIPT" >>"$temp_script"
printf '\n' >>"$temp_script"
cat "$WINDOWS_GUI_SCRIPT" >>"$temp_script"
cat >>"$temp_script" <<EOF

\$copilotGuiInstallId = '$(escape_ps_single_quoted "$gui_id")'
try {
  Write-Output "MYTUNNEL_GUI_INSTALL_START id=\$copilotGuiInstallId client_uid=$(escape_ps_single_quoted "$CLIENT_UID") expected_device_id=$(escape_ps_single_quoted "$EXPECTED_DEVICE_ID")"
  \$copilotGuiSummary = Invoke-MyTunnelGuiInstall -MsiPath '$(escape_ps_single_quoted "$MSI_PATH")' -DeviceIdProbePath '$(escape_ps_single_quoted "$PROBE_PATH")' -ServerUrl '$(escape_ps_single_quoted "$SERVER_URL")' -ClientUid '$(escape_ps_single_quoted "$CLIENT_UID")' -EnrollmentSecret '$(escape_ps_single_quoted "$ENROLLMENT_SECRET")' ${expected_service_sha256_argument}${expected_bundled_helper_sha256_argument}-ExpectedDeviceId '$(escape_ps_single_quoted "$EXPECTED_DEVICE_ID")' -PollInterval '$(escape_ps_single_quoted "$POLL_INTERVAL")' -RenewBefore '$(escape_ps_single_quoted "$RENEW_BEFORE")' -LogLevel '$(escape_ps_single_quoted "$LOG_LEVEL")' -WaitSeconds $WAIT_SECONDS
  \$copilotGuiMarkerSummary = ConvertTo-MyTunnelGuiMarkerSummary -Summary \$copilotGuiSummary
  \$copilotGuiJson = \$copilotGuiMarkerSummary | ConvertTo-Json -Depth 8 -Compress
  Write-Output ("MYTUNNEL_GUI_INSTALL_DONE id=\$copilotGuiInstallId summary={0}" -f \$copilotGuiJson)
} catch {
  \$copilotGuiMessage = \$_.Exception.Message -replace '[\\r\\n]+', ' '
  Write-Output ("MYTUNNEL_GUI_INSTALL_FAILED id=\$copilotGuiInstallId message={0}" -f \$copilotGuiMessage)
  throw
}
EOF

echo "Running GUI MSI automation on Windows VM"
gcloud compute instances add-metadata "$INSTANCE" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --metadata-from-file "windows-startup-script-ps1=${temp_script}" \
  >/dev/null
gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

gui_output=""
gui_output="$(wait_for_gui_result "$gui_id")" || {
  printf '%s\n' "$gui_output" >"$install_log"
  exit 1
}

summary_payload="$(printf '%s\n' "$gui_output" | tail -n 1)"
printf '%s\n' "$gui_output" | tee "$install_log"
printf '%s' "$summary_payload" >"$summary_json"

python3 - "$summary_json" "$EXPECTED_DEVICE_ID" "$CLIENT_UID" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_device_id = sys.argv[2]
client_uid = sys.argv[3]

errors = []

if summary.get("prereg_check", {}).get("result") != "ready":
    errors.append(f"expected prereg_check.result=ready, got {summary.get('prereg_check')}")

gui = summary.get("gui") or {}
if gui.get("current_device_id_from_page1") != expected_device_id:
    errors.append(
        f"GUI page 1 device id mismatch: {gui.get('current_device_id_from_page1')} != {expected_device_id}"
    )
if gui.get("current_device_id_from_prereg") != expected_device_id:
    errors.append(
        f"GUI prereg page device id mismatch: {gui.get('current_device_id_from_prereg')} != {expected_device_id}"
    )

stages = [entry.get("stage") for entry in gui.get("dialogs_seen", [])]
for required_stage in (
    "device-identity",
    "preregistration-check-before-fill",
    "preregistration-check-filled",
    "enrollment-secret-before-fill",
    "enrollment-secret-filled",
):
    if required_stage not in stages:
        errors.append(f"missing GUI stage evidence: {required_stage}")

registry = summary.get("registry") or {}
if registry.get("client_uid") != client_uid:
    errors.append(f"registry.client_uid mismatch: {registry.get('client_uid')} != {client_uid}")
if registry.get("expected_device_id") != expected_device_id:
    errors.append(
        f"registry.expected_device_id mismatch: {registry.get('expected_device_id')} != {expected_device_id}"
    )
if registry.get("has_enrollment_secret"):
    errors.append("bootstrap EnrollmentSecret remained in registry after successful GUI issuance")
if registry.get("has_enrollment_secret_protected"):
    errors.append("bootstrap EnrollmentSecretProtected remained in registry after successful GUI issuance")

server = summary.get("server") or {}
if server.get("client_status") != "ISSUED":
    errors.append(f"server client status is not ISSUED: {server.get('client_status')}")

managed = summary.get("managed") or {}
if not managed.get("cert_exists"):
    errors.append("managed certificate was not written")
if not managed.get("present_in_machine_store"):
    errors.append("managed certificate is missing from LocalMachine\\\\My")

service = summary.get("service") or {}
if service.get("state") != "Running":
    errors.append(f"MyTunnelService is not Running: {service.get('state')}")

if not summary.get("managed_matches_server_active"):
    errors.append("managed certificate does not match server active certificate")

program_files_match_expected = summary.get("program_files_match_expected")
if program_files_match_expected is False:
    errors.append("installed Program Files binaries did not match the current local build")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY

printf '%s\n' "summary_json=${summary_json}"
printf '%s\n' "install_log=${install_log}"
printf '%s\n' "preregister_log=${preregister_log}"
if [[ -f "$probe_json" ]]; then
  printf '%s\n' "probe_json=${probe_json}"
fi
