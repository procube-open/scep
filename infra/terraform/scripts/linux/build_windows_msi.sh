#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_windows_msi.sh [options]

Cross-builds service.exe for Windows, stages installer inputs locally, builds a
Windows MSI on Linux, and optionally copies the MSI to the Windows client VM.

When WiX v4 (`wix`) is available, the script prefers `installer/main.wxs` as the
source of truth and builds the converged MSI from that WiX definition. Otherwise
it falls back to the existing `wixl`-based silent-install package.

When --windows-user is provided, the script first tries gcloud compute scp to
<user>:\~/MyTunnelApp.msi. If the Windows VM does not accept SSH on port 22,
the script falls back to a one-time GCS + Windows startup-script transfer and
places the MSI at C:\Users\Public\MyTunnelApp.msi after an automatic reboot.

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
  --msi-builder <auto|wix|wixl>     Packaging backend to use
                                    (default: auto; prefer WiX v4 when available)
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
WIX_SOURCE_RELATIVE="installer/main.wxs"
WIXL_SOURCE_RELATIVE="installer/main.wixl.wxs"
WINDOWS_STARTUP_SCRIPT_RELATIVE="infra/terraform/scripts/windows/windows-client-startup.ps1"
WINDOWS_PUBLIC_MSI_PATH='C:\Users\Public\MyTunnelApp.msi'
SSH_COPY_TIMEOUT_SECONDS=45
MSI_BUILDER="auto"

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
    --msi-builder)
      [[ $# -ge 2 ]] || { echo "Missing value for --msi-builder" >&2; usage; exit 1; }
      MSI_BUILDER="$2"
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

resolve_msi_builder() {
  case "$MSI_BUILDER" in
    auto)
      if command -v wix >/dev/null 2>&1; then
        MSI_BUILDER="wix"
      else
        MSI_BUILDER="wixl"
      fi
      ;;
    wix|wixl)
      ;;
    *)
      echo "Unsupported --msi-builder value: ${MSI_BUILDER}" >&2
      exit 1
      ;;
  esac
}

ensure_wix_ui_extension() {
  if ! wix extension add WixToolset.UI.wixext >/dev/null 2>&1; then
    echo "Failed to add WixToolset.UI.wixext. Install or pre-cache the WiX UI extension before using --msi-builder wix." >&2
    exit 1
  fi
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
  local object_name="MyTunnelApp.msi"
  local transfer_id="copilot-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  local expected_hash
  local transfer_script=""
  local serial_output=""

  expected_hash="$(sha256sum "$OUTPUT_PATH" | awk '{print $1}')"
  transfer_script="$(mktemp)"
  trap "restore_windows_startup_script; cleanup_transfer_bucket '$bucket_name'; rm -f '$transfer_script'" EXIT

  echo "SSH transfer unavailable; falling back to GCS + startup-script delivery to ${WINDOWS_PUBLIC_MSI_PATH}"

  gcloud storage buckets create "gs://${bucket_name}" \
    --project "$PROJECT_ID" \
    --location us-central1 \
    --uniform-bucket-level-access \
    >/dev/null
  gcloud storage buckets add-iam-policy-binding "gs://${bucket_name}" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    >/dev/null
  gcloud storage cp "$OUTPUT_PATH" "gs://${bucket_name}/${object_name}" >/dev/null

  cat "${REPO_ROOT}/${WINDOWS_STARTUP_SCRIPT_RELATIVE}" > "$transfer_script"
  cat >> "$transfer_script" <<EOF
\$msiUrl = 'https://storage.googleapis.com/${bucket_name}/${object_name}'
\$msiPath = '${WINDOWS_PUBLIC_MSI_PATH}'
Write-Output 'COPILOT_MSI_TRANSFER_START id=${transfer_id} url=https://storage.googleapis.com/${bucket_name}/${object_name}'
New-Item -ItemType Directory -Path (Split-Path -Parent \$msiPath) -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri \$msiUrl -OutFile \$msiPath
\$msiHash = (Get-FileHash -Path \$msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
\$msiSize = (Get-Item \$msiPath).Length
Write-Output ("COPILOT_MSI_TRANSFER_DONE id=${transfer_id} path={0} size={1} sha256={2}" -f \$msiPath, \$msiSize, \$msiHash)
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
    if printf '%s\n' "$serial_output" | grep -q "COPILOT_MSI_TRANSFER_DONE id=${transfer_id}"; then
      printf '%s\n' "$serial_output" | grep "COPILOT_MSI_TRANSFER_.*id=${transfer_id}"
      if ! printf '%s\n' "$serial_output" | grep -q "sha256=${expected_hash}"; then
        echo "Windows transfer completed but SHA-256 verification did not match expected hash ${expected_hash}" >&2
        return 1
      fi
      echo "MSI copied to ${WINDOWS_PUBLIC_MSI_PATH}"
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
resolve_msi_builder
if [[ "$MSI_BUILDER" == "wix" ]]; then
  ensure_command wix
else
  ensure_command wixl
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
cp "${REPO_ROOT}/${WIXL_SOURCE_RELATIVE}" "${STAGE_DIR}/installer/main.wixl.wxs"
cp "${REPO_ROOT}/${WINDOWS_BINARY_RELATIVE}" "${STAGE_DIR}/rust-client/service/target/release/service.exe"
cp "${REPO_ROOT}/${WINDOWS_BINARY_RELATIVE}" "${STAGE_DIR}/rust-client/target/release/service.exe"
cp "${REPO_ROOT}/${SCEPCLIENT_BINARY_RELATIVE}" "${STAGE_DIR}/cmd/scepclient/scepclient.exe"

echo "Building MSI locally with ${MSI_BUILDER}: ${OUTPUT_PATH}"
if [[ "$MSI_BUILDER" == "wix" ]]; then
  (
    cd "$STAGE_DIR"
    ensure_wix_ui_extension
    wix build -arch x64 -ext WixToolset.UI.wixext -o "$OUTPUT_PATH" installer/main.wxs
  )
else
  (
    cd "$STAGE_DIR"
    wixl -a x64 -o "$OUTPUT_PATH" installer/main.wixl.wxs
  )
fi

if [[ -n "$WINDOWS_USER" ]]; then
  echo "Copying MSI to ${WINDOWS_USER}@${INSTANCE}:~/MyTunnelApp.msi"
  if ! timeout "${SSH_COPY_TIMEOUT_SECONDS}" gcloud compute scp "$OUTPUT_PATH" "${WINDOWS_USER}@${INSTANCE}:~/MyTunnelApp.msi" --project "$PROJECT_ID" --zone "$ZONE"; then
    transfer_via_startup_script
  fi
fi

echo "MSI ready: ${OUTPUT_PATH}"
