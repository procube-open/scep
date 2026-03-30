#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: probe_windows_device_id.sh [options]

Run device-id-probe.exe on the Windows VM and print the canonical TPM identity as
JSON so operators can preregister EXPECTED_DEVICE_ID before MSI installation.

Options:
  --windows-user <USER>           Windows username used for build_windows_msi.sh copy
  --probe-path <WINDOWS_PATH>     Full Windows path to device-id-probe.exe
                                  (default: C:\Users\<USER>\device-id-probe.exe)
  --project <PROJECT_ID>          GCP project override
  --zone <ZONE>                   GCP zone override
  --instance <INSTANCE_NAME>      Windows VM override
  --terraform-dir <PATH>          Terraform working directory
                                  (default: <repo-root>/infra/terraform)
  --repo-root <PATH>              Repository root
                                  (default: auto-detected)
  --wait-seconds <SECONDS>        Wait budget for serial markers (default: 180)
  -h, --help                      Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
WINDOWS_USER=""
PROBE_PATH=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
WAIT_SECONDS=180
SERIAL_WAIT_GRACE_SECONDS=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --windows-user)
      WINDOWS_USER="${2:?missing value for --windows-user}"
      shift 2
      ;;
    --probe-path)
      PROBE_PATH="${2:?missing value for --probe-path}"
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

if [[ -z "$WINDOWS_USER" && -z "$PROBE_PATH" ]]; then
  echo "--windows-user or --probe-path is required." >&2
  exit 1
fi

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi

WINDOWS_STARTUP_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/windows/windows-client-startup.ps1"

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

wait_for_probe_result() {
  local probe_id="$1"
  local deadline serial_output probe_line
  deadline=$(( $(date +%s) + WAIT_SECONDS + SERIAL_WAIT_GRACE_SECONDS ))

  while (( $(date +%s) <= deadline )); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null | tr -d '\000' || true)"
    probe_line="$(printf '%s\n' "$serial_output" | grep "MYTUNNEL_DEVICE_ID_PROBE_DONE id=${probe_id} " | tail -n 1 || true)"
    if [[ -n "$probe_line" ]]; then
      printf '%s\n' "${probe_line#*json=}"
      return 0
    fi
    if printf '%s\n' "$serial_output" | grep -q "MYTUNNEL_DEVICE_ID_PROBE_FAILED id=${probe_id}"; then
      printf '%s\n' "$serial_output" | grep "MYTUNNEL_DEVICE_ID_PROBE_.*id=${probe_id}" | tail -n 20 >&2
      return 1
    fi
    sleep 15
  done

  echo "Timed out waiting for Windows device-id probe markers." >&2
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

if [[ -z "$PROBE_PATH" ]]; then
  PROBE_PATH="C:\\Users\\${WINDOWS_USER}\\device-id-probe.exe"
fi

probe_id="copilot-probe-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
temp_script="$(mktemp)"
trap 'restore_windows_startup_script; rm -f "$temp_script"' EXIT

cat "$WINDOWS_STARTUP_SCRIPT" > "$temp_script"
cat >> "$temp_script" <<EOF

\$copilotProbeId = '$(escape_ps_single_quoted "$probe_id")'
\$copilotProbePath = '$(escape_ps_single_quoted "$PROBE_PATH")'
try {
  if (-not (Test-Path -LiteralPath \$copilotProbePath)) {
    \$copilotFallbackProbePath = 'C:\Users\Public\device-id-probe.exe'
    if (Test-Path -LiteralPath \$copilotFallbackProbePath) {
      \$copilotProbePath = \$copilotFallbackProbePath
    } else {
      throw "device-id-probe.exe was not found at \$copilotProbePath or \$copilotFallbackProbePath"
    }
  }
  \$copilotProbeStdout = Join-Path \$env:TEMP ("copilot-probe-{0}.out" -f \$copilotProbeId)
  \$copilotProbeStderr = Join-Path \$env:TEMP ("copilot-probe-{0}.err" -f \$copilotProbeId)
  \$copilotProbeProcess = Start-Process -FilePath \$copilotProbePath -ArgumentList @('-json') -PassThru -NoNewWindow -RedirectStandardOutput \$copilotProbeStdout -RedirectStandardError \$copilotProbeStderr
  [void]\$copilotProbeProcess.WaitForExit()
  \$copilotProbeJson = ''
  if (Test-Path -LiteralPath \$copilotProbeStdout) {
    \$copilotProbeJson = (Get-Content -LiteralPath \$copilotProbeStdout -Raw).Trim()
  }
  if (\$copilotProbeProcess.ExitCode -ne 0) {
    \$copilotProbeErrorText = ''
    if (Test-Path -LiteralPath \$copilotProbeStderr) {
      \$copilotProbeErrorText = ((Get-Content -LiteralPath \$copilotProbeStderr -Raw) -replace '[\\r\\n]+', ' ').Trim()
    }
    if ([string]::IsNullOrWhiteSpace(\$copilotProbeErrorText)) {
      \$copilotProbeErrorText = "device-id-probe.exe exited with code \$($copilotProbeProcess.ExitCode)"
    }
    throw \$copilotProbeErrorText
  }
  if ([string]::IsNullOrWhiteSpace(\$copilotProbeJson)) {
    throw 'device-id-probe.exe returned an empty payload'
  }
  Write-Output ("MYTUNNEL_DEVICE_ID_PROBE_DONE id=\$copilotProbeId json={0}" -f \$copilotProbeJson)
} catch {
  \$copilotProbeMessage = \$_.Exception.Message -replace '[\\r\\n]+', ' '
  Write-Output ("MYTUNNEL_DEVICE_ID_PROBE_FAILED id=\$copilotProbeId message={0}" -f \$copilotProbeMessage)
  throw
}
EOF

gcloud compute instances add-metadata "$INSTANCE" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --metadata-from-file "windows-startup-script-ps1=${temp_script}" \
  >/dev/null
gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

wait_for_probe_result "$probe_id"
