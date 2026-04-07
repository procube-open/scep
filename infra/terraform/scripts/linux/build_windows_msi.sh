#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_windows_msi.sh [options]

Cross-builds service.exe for Windows, stages installer inputs locally, builds a
Windows MSI on Linux, and optionally copies the MSI to the Windows client VM.

WiX v4 (`wix`) is the only supported packaging path. The script always builds
`installer/main.wxs` as the source-of-truth MSI.

On Linux hosts, the WiX v4 path runs `wix.dll` under Wine with a cached Windows
.NET runtime because WiX binds through Windows Installer APIs that are not
available to the native Linux apphost.

When --windows-user is provided, the script first tries gcloud compute scp to
<user>:\~/MyTunnelApp.msi and <user>:\~/device-id-probe.exe. If the Windows VM
does not accept SSH on port 22, the script falls back to a one-time GCS +
Windows startup-script transfer and places the MSI at C:\Users\Public\MyTunnelApp.msi
and the probe at C:\Users\Public\device-id-probe.exe after an automatic reboot.

Options:
  --windows-user <USERNAME>         Copy the built MSI to the Windows VM user's home directory
  --project <PROJECT_ID>            GCP project ID (optional; auto-detected from Terraform)
  --zone <ZONE>                     GCP zone (optional; auto-detected from Terraform)
  --instance <INSTANCE_NAME>        Windows GCE instance name (optional; auto-detected from Terraform)
  --terraform-dir <PATH>            Terraform working directory used for output lookup
                                    (default: <repo-root>/infra/terraform)
  --repo-root <PATH>                Repository root containing installer/ and rust-client/service
                                    (default: auto-detected from script location)
  --stage-dir <PATH>                Local staging directory for WiX inputs
                                     (default: <repo-root>/build/windows-msi)
  --output-path <PATH>              Output MSI path
                                     (default: <stage-dir>/installer/dist/MyTunnelApp.msi)
  --skip-rustup-target              Skip rustup target add x86_64-pc-windows-gnu
  -h, --help                        Show this help text
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
WINDOWS_USER=""
STAGE_DIR=""
OUTPUT_PATH=""
SKIP_RUSTUP_TARGET=0
WINDOWS_TARGET="x86_64-pc-windows-gnu"
WINDOWS_BINARY_RELATIVE="rust-client/target/${WINDOWS_TARGET}/release/service.exe"
SCEPCLIENT_BINARY_RELATIVE="cmd/scepclient/scepclient.exe"
DEVICE_ID_PROBE_BINARY_RELATIVE="cmd/scepclient/device-id-probe.exe"
WIX_SOURCE_RELATIVE="installer/main.wxs"
WINDOWS_STARTUP_SCRIPT_RELATIVE="infra/terraform/scripts/windows/windows-client-startup.ps1"
WINDOWS_PUBLIC_MSI_PATH='C:\Users\Public\MyTunnelApp.msi'
WINDOWS_PUBLIC_PROBE_PATH='C:\Users\Public\device-id-probe.exe'
SSH_COPY_TIMEOUT_SECONDS=45
while [[ $# -gt 0 ]]; do
  case "$1" in
    --windows-user)
      [[ $# -ge 2 ]] || { echo "Missing value for --windows-user" >&2; usage; exit 1; }
      WINDOWS_USER="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || { echo "Missing value for --project" >&2; usage; exit 1; }
      PROJECT_ID="$2"
      shift 2
      ;;
    --zone)
      [[ $# -ge 2 ]] || { echo "Missing value for --zone" >&2; usage; exit 1; }
      ZONE="$2"
      shift 2
      ;;
    --instance)
      [[ $# -ge 2 ]] || { echo "Missing value for --instance" >&2; usage; exit 1; }
      INSTANCE="$2"
      shift 2
      ;;
    --terraform-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --terraform-dir" >&2; usage; exit 1; }
      TERRAFORM_DIR="$2"
      shift 2
      ;;
    --repo-root)
      [[ $# -ge 2 ]] || { echo "Missing value for --repo-root" >&2; usage; exit 1; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --stage-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --stage-dir" >&2; usage; exit 1; }
      STAGE_DIR="$2"
      shift 2
      ;;
    --output-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --output-path" >&2; usage; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --skip-rustup-target)
      SKIP_RUSTUP_TARGET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi
if [[ -z "$STAGE_DIR" ]]; then
  STAGE_DIR="${REPO_ROOT}/build/windows-msi"
fi
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="${STAGE_DIR}/installer/dist/MyTunnelApp.msi"
fi
STAGE_DIR="$(realpath -m "$STAGE_DIR")"
OUTPUT_PATH="$(realpath -m "$OUTPUT_PATH")"

read_tfvars_value() {
  local key="$1"
  local tfvars_path="${TERRAFORM_DIR}/terraform.tfvars"
  local raw_value
  [[ -f "$tfvars_path" ]] || return 1
  raw_value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$tfvars_path" | head -n 1 || true)"
  raw_value="${raw_value%%#*}"
  raw_value="${raw_value#*=}"
  raw_value="$(printf '%s' "$raw_value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  raw_value="${raw_value#\'}"
  raw_value="${raw_value%\'}"
  [[ -n "$raw_value" ]] || return 1
  printf '%s' "$raw_value"
}

ensure_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

wix_store_root() {
  local wix_path
  wix_path="$(command -v wix 2>/dev/null || true)"
  [[ -n "$wix_path" ]] || return 1
  printf '%s' "$(dirname "$wix_path")/.store/wix"
}

wix_version() {
  local version store_root
  version="$(wix --version 2>/dev/null | tr -d '\r' | awk 'NF { print $1 }' | tail -n 1 || true)"
  if [[ -z "$version" ]]; then
    store_root="$(wix_store_root || true)"
    if [[ -n "$store_root" && -d "$store_root" ]]; then
      version="$(find "$store_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1 || true)"
    fi
  fi
  printf '%s' "$version"
}

wix_major_version() {
  local version
  version="$(wix_version)"
  printf '%s' "${version%%.*}"
}

wix_extension_version() {
  local version
  version="$(wix_version)"
  printf '%s' "${version%%+*}"
}

wix_tool_dir() {
  local store_root version tool_dir
  store_root="$(wix_store_root || true)"
  version="$(wix_extension_version)"
  [[ -n "$store_root" && -n "$version" ]] || return 1
  tool_dir="${store_root}/${version}/wix/${version}/tools/net6.0/any"
  [[ -d "$tool_dir" ]] || return 1
  printf '%s' "$tool_dir"
}

wix_runtime_channel() {
  local tool_dir runtimeconfig
  tool_dir="$(wix_tool_dir)" || return 1
  runtimeconfig="${tool_dir}/wix.runtimeconfig.json"
  [[ -f "$runtimeconfig" ]] || return 1
  python3 - "$runtimeconfig" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
version = data["runtimeOptions"]["framework"]["version"]
parts = version.split(".")
print(f"{parts[0]}.{parts[1]}")
PY
}

wix_windows_runtime_url() {
  local channel
  channel="$(wix_runtime_channel)" || return 1
  curl -fsSL "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/${channel}/releases.json" \
    | jq -r 'first(.releases[] | .runtime.files[]? | select((.rid // "") == "win-x64" and ((.url // "") | endswith(".zip"))) | .url)'
}

ensure_wix_windows_runtime() {
  local runtime_url runtime_name cache_root archive_path
  runtime_url="$(wix_windows_runtime_url)" || {
    echo "Failed to resolve a Windows .NET runtime download URL for the active WiX tool." >&2
    exit 1
  }
  if [[ -z "$runtime_url" || "$runtime_url" == "null" ]]; then
    echo "Failed to resolve a Windows .NET runtime download URL for the active WiX tool." >&2
    exit 1
  fi
  runtime_name="${runtime_url##*/}"
  runtime_name="${runtime_name%.zip}"
  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/scep/${runtime_name}"
  if [[ ! -f "${cache_root}/dotnet.exe" ]]; then
    mkdir -p "$cache_root"
    archive_path="$(mktemp)"
    curl -fsSL "$runtime_url" -o "$archive_path"
    unzip -q -o "$archive_path" -d "$cache_root"
    rm -f "$archive_path"
  fi
  if [[ ! -f "${cache_root}/dotnet.exe" ]]; then
    echo "Windows .NET runtime cache did not contain dotnet.exe: ${cache_root}" >&2
    exit 1
  fi
  printf '%s' "$cache_root"
}

ensure_wix_ui_extension() {
  local version
  version="$(wix_extension_version)"
  if [[ -z "$version" ]]; then
    echo "Failed to determine the WiX CLI version for WixToolset.UI.wixext." >&2
    exit 1
  fi
  if ! wix extension add "WixToolset.UI.wixext/${version}" >/dev/null 2>&1; then
    echo "Failed to add WixToolset.UI.wixext/${version}. Install or pre-cache the matching WiX UI extension before running this build script." >&2
    exit 1
  fi
}

build_with_wix_under_wine() {
  local tool_dir runtime_dir wine_prefix xdg_runtime_dir dotnet_win wix_dll_win output_win
  ensure_command wine
  ensure_command winepath
  ensure_command curl
  ensure_command unzip
  ensure_command jq
  ensure_command python3

  tool_dir="$(wix_tool_dir)" || {
    echo "Failed to locate wix.dll for WiX v4 under the current wix tool installation." >&2
    exit 1
  }
  runtime_dir="$(ensure_wix_windows_runtime)"
  wine_prefix="${XDG_CACHE_HOME:-$HOME/.cache}/scep/wine-wix-prefix"
  xdg_runtime_dir="${TMPDIR:-/tmp}/scep-wix-xdg-runtime"
  mkdir -p "$wine_prefix" "$xdg_runtime_dir"

  export WINEDEBUG=-all
  export WINEPREFIX="$wine_prefix"
  export XDG_RUNTIME_DIR="$xdg_runtime_dir"

  wineboot -u >/dev/null 2>&1 || true
  dotnet_win="$(winepath -w "${runtime_dir}/dotnet.exe")"
  wix_dll_win="$(winepath -w "${tool_dir}/wix.dll")"
  output_win="$(winepath -w "$OUTPUT_PATH")"

  (
    cd "${STAGE_DIR}/installer"
    wine "$dotnet_win" "$wix_dll_win" extension add "WixToolset.UI.wixext/$(wix_extension_version)" >/dev/null
    wine "$dotnet_win" "$wix_dll_win" build -arch x64 -dcl none -ext WixToolset.UI.wixext -o "$output_win" main.wxs
  )
}

restore_windows_startup_script() {
  gcloud compute instances add-metadata "$INSTANCE" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --metadata-from-file "windows-startup-script-ps1=${REPO_ROOT}/${WINDOWS_STARTUP_SCRIPT_RELATIVE}" \
    >/dev/null 2>&1 || true
}

cleanup_transfer_bucket() {
  local bucket_name="$1"
  [[ -n "$bucket_name" ]] || return 0
  gcloud storage rm -r "gs://${bucket_name}" >/dev/null 2>&1 || true
  gcloud storage buckets delete "gs://${bucket_name}" >/dev/null 2>&1 || true
}

transfer_via_startup_script() {
  local bucket_name="scep-msi-transfer-$(date +%s)-$RANDOM"
  local msi_object_name="MyTunnelApp.msi"
  local probe_object_name="device-id-probe.exe"
  local transfer_id="copilot-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  local expected_msi_hash
  local expected_probe_hash
  local transfer_script=""
  local serial_output=""

  expected_msi_hash="$(sha256sum "$OUTPUT_PATH" | awk '{print $1}')"
  expected_probe_hash="$(sha256sum "${REPO_ROOT}/${DEVICE_ID_PROBE_BINARY_RELATIVE}" | awk '{print $1}')"
  transfer_script="$(mktemp)"
  trap "restore_windows_startup_script; cleanup_transfer_bucket '$bucket_name'; rm -f '$transfer_script'" EXIT

  echo "SSH transfer unavailable; falling back to GCS + startup-script delivery to ${WINDOWS_PUBLIC_MSI_PATH} and ${WINDOWS_PUBLIC_PROBE_PATH}"

  gcloud storage buckets create "gs://${bucket_name}" \
    --project "$PROJECT_ID" \
    --location us-central1 \
    --uniform-bucket-level-access \
    >/dev/null
  gcloud storage buckets add-iam-policy-binding "gs://${bucket_name}" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    >/dev/null
  gcloud storage cp "$OUTPUT_PATH" "gs://${bucket_name}/${msi_object_name}" >/dev/null
  gcloud storage cp "${REPO_ROOT}/${DEVICE_ID_PROBE_BINARY_RELATIVE}" "gs://${bucket_name}/${probe_object_name}" >/dev/null

  cat "${REPO_ROOT}/${WINDOWS_STARTUP_SCRIPT_RELATIVE}" > "$transfer_script"
  cat >> "$transfer_script" <<EOF
 \$msiUrl = 'https://storage.googleapis.com/${bucket_name}/${msi_object_name}'
 \$msiPath = '${WINDOWS_PUBLIC_MSI_PATH}'
 \$probeUrl = 'https://storage.googleapis.com/${bucket_name}/${probe_object_name}'
 \$probePath = '${WINDOWS_PUBLIC_PROBE_PATH}'
 Write-Output 'COPILOT_MSI_TRANSFER_START id=${transfer_id} msi_url=https://storage.googleapis.com/${bucket_name}/${msi_object_name} probe_url=https://storage.googleapis.com/${bucket_name}/${probe_object_name}'
 New-Item -ItemType Directory -Path (Split-Path -Parent \$msiPath) -Force | Out-Null
 Invoke-WebRequest -UseBasicParsing -Uri \$msiUrl -OutFile \$msiPath
 Invoke-WebRequest -UseBasicParsing -Uri \$probeUrl -OutFile \$probePath
 \$msiHash = (Get-FileHash -Path \$msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
 \$msiSize = (Get-Item \$msiPath).Length
 \$probeHash = (Get-FileHash -Path \$probePath -Algorithm SHA256).Hash.ToLowerInvariant()
 \$probeSize = (Get-Item \$probePath).Length
 Write-Output ("COPILOT_MSI_TRANSFER_DONE id=${transfer_id} msi_path={0} msi_size={1} msi_sha256={2} probe_path={3} probe_size={4} probe_sha256={5}" -f \$msiPath, \$msiSize, \$msiHash, \$probePath, \$probeSize, \$probeHash)
EOF

  gcloud compute instances add-metadata "$INSTANCE" \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    --metadata-from-file "windows-startup-script-ps1=${transfer_script}" \
    >/dev/null
  gcloud compute instances reset "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" >/dev/null

  echo "Waiting for Windows startup-script transfer to complete"
  for _ in $(seq 1 40); do
    serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE" --project "$PROJECT_ID" --zone "$ZONE" --port 1 2>/dev/null | tr -d '\000' || true)"
    if [[ "$serial_output" == *"COPILOT_MSI_TRANSFER_DONE id=${transfer_id}"* ]]; then
      grep "COPILOT_MSI_TRANSFER_.*id=${transfer_id}" <<<"$serial_output" || true
      if [[ "$serial_output" != *"msi_sha256=${expected_msi_hash}"* ]]; then
        echo "Windows transfer completed but MSI SHA-256 verification did not match expected hash ${expected_msi_hash}" >&2
        return 1
      fi
      if [[ "$serial_output" != *"probe_sha256=${expected_probe_hash}"* ]]; then
        echo "Windows transfer completed but device-id-probe SHA-256 verification did not match expected hash ${expected_probe_hash}" >&2
        return 1
      fi
      echo "MSI copied to ${WINDOWS_PUBLIC_MSI_PATH}; device-id-probe copied to ${WINDOWS_PUBLIC_PROBE_PATH}"
      return 0
    fi
    sleep 15
  done

  echo "Timed out waiting for Windows startup-script transfer output." >&2
  printf '%s\n' "$serial_output" | tail -n 120 >&2 || true
  return 1
}

if [[ -n "$WINDOWS_USER" && ( -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ) ]]; then
  ensure_command terraform
  if [[ ! -d "$TERRAFORM_DIR" ]]; then
    echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
    exit 1
  fi
  if ! terraform -chdir="$TERRAFORM_DIR" output -json >/dev/null 2>&1; then
    echo "Terraform outputs unavailable in ${TERRAFORM_DIR}; run terraform apply first." >&2
    exit 1
  fi
  if [[ -z "$INSTANCE" ]]; then
    INSTANCE="$(terraform -chdir="$TERRAFORM_DIR" output -raw client_instance_name 2>/dev/null || true)"
  fi
  if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID="$(terraform -chdir="$TERRAFORM_DIR" output -raw project_id 2>/dev/null || true)"
    if [[ -z "$PROJECT_ID" ]]; then
      PROJECT_ID="$(read_tfvars_value project_id || true)"
    fi
  fi
  if [[ -z "$ZONE" ]]; then
    ZONE="$(terraform -chdir="$TERRAFORM_DIR" output -raw deployment_zone 2>/dev/null || true)"
    if [[ -z "$ZONE" ]]; then
      ZONE="$(read_tfvars_value zone || true)"
    fi
  fi
fi

ensure_command cargo
ensure_command rustup
ensure_command x86_64-w64-mingw32-gcc
ensure_command sha256sum
ensure_command wix
if [[ "$(wix_major_version)" != "4" ]]; then
  echo "WiX v4 is required. Found: $(wix_version)" >&2
  exit 1
fi

if [[ -n "$WINDOWS_USER" ]]; then
  ensure_command gcloud
  if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
    echo "Unable to resolve --project, --zone, and --instance for Windows copy. Provide overrides or run terraform apply in ${TERRAFORM_DIR}." >&2
    exit 1
  fi
fi

if [[ "$SKIP_RUSTUP_TARGET" -eq 0 ]]; then
  rustup target add "$WINDOWS_TARGET" >/dev/null
fi

echo "Building Windows service binary: ${WINDOWS_BINARY_RELATIVE}"
(
  cd "$REPO_ROOT"
  cargo build --manifest-path rust-client/service/Cargo.toml --release --target "$WINDOWS_TARGET"
)

echo "Building Windows helper binaries"
(
  cd "$REPO_ROOT"
  GOOS=windows GOARCH=amd64 go build -o "$SCEPCLIENT_BINARY_RELATIVE" ./cmd/scepclient
  cp "$SCEPCLIENT_BINARY_RELATIVE" "$DEVICE_ID_PROBE_BINARY_RELATIVE"
)

echo "Staging WiX inputs: ${STAGE_DIR}"
rm -rf "$STAGE_DIR"
mkdir -p \
  "${STAGE_DIR}/installer" \
  "${STAGE_DIR}/rust-client/service/target/release" \
  "${STAGE_DIR}/rust-client/target/release" \
  "${STAGE_DIR}/cmd/scepclient" \
  "$(dirname "$OUTPUT_PATH")"
cp "${REPO_ROOT}/${WIX_SOURCE_RELATIVE}" "${STAGE_DIR}/installer/main.wxs"
cp "${REPO_ROOT}/installer/device_identity_prereg.vbs" "${STAGE_DIR}/installer/device_identity_prereg.vbs"
cp "${REPO_ROOT}/${WINDOWS_BINARY_RELATIVE}" "${STAGE_DIR}/rust-client/service/target/release/service.exe"
cp "${REPO_ROOT}/${WINDOWS_BINARY_RELATIVE}" "${STAGE_DIR}/rust-client/target/release/service.exe"
cp "${REPO_ROOT}/${SCEPCLIENT_BINARY_RELATIVE}" "${STAGE_DIR}/cmd/scepclient/scepclient.exe"
cp "${REPO_ROOT}/${DEVICE_ID_PROBE_BINARY_RELATIVE}" "${STAGE_DIR}/cmd/scepclient/device-id-probe.exe"

echo "Building MSI locally with WiX v4: ${OUTPUT_PATH}"
if [[ "$(uname -s)" == "Linux" ]]; then
  build_with_wix_under_wine
else
  (
    cd "${STAGE_DIR}/installer"
    ensure_wix_ui_extension
    wix build -arch x64 -ext WixToolset.UI.wixext -o "$OUTPUT_PATH" main.wxs
  )
fi

if [[ -n "$WINDOWS_USER" ]]; then
  echo "Copying MSI and device-id-probe.exe to ${WINDOWS_USER}@${INSTANCE}:~/"
  if ! timeout "${SSH_COPY_TIMEOUT_SECONDS}" gcloud compute scp "$OUTPUT_PATH" "${REPO_ROOT}/${DEVICE_ID_PROBE_BINARY_RELATIVE}" "${WINDOWS_USER}@${INSTANCE}:~/" --project "$PROJECT_ID" --zone "$ZONE"; then
    transfer_via_startup_script
  fi
fi

echo "MSI ready: ${OUTPUT_PATH}"
