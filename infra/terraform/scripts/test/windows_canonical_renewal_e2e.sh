#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: windows_canonical_renewal_e2e.sh [options]

Build and transfer the current Windows MSI, install it on the live Windows VM,
and verify that canonical TPM-backed issuance/renewal leaves a managed
certificate present in both the managed directory and LocalMachine\My.

This helper is intended to replace the ad hoc startup-script probes used during
the Phase 2 rollout. It reuses the existing MSI build/install scripts and then
compares the pre/post managed thumbprints emitted by install-mytunnelapp.ps1.

Required:
  --windows-user <USER>               Windows username for MSI transfer
  --client-uid <UID>                  Registered client UID
  --enrollment-secret <SECRET>        One-time enrollment secret
  --device-id-override <DEVICE_ID>    Registered device_id override currently used on the VM

Optional:
  --server-url <URL>                  Full SCEP URL (default: Terraform-derived)
  --poll-interval <DURATION>          Poll interval for installed service (default: 10s)
  --renew-before <DURATION>           Renew-before for validation (default: 9000h)
  --log-level <LEVEL>                 Service log level (default: debug)
  --wait-seconds <SECONDS>            Wait budget per install run (default: 420)
  --artifact-dir <DIR>                Directory for captured logs/summary
  --project <PROJECT_ID>              GCP project override
  --zone <ZONE>                       GCP zone override
  --instance <INSTANCE_NAME>          Windows VM override
  --terraform-dir <PATH>              Terraform working directory
  --repo-root <PATH>                  Repository root
  --force-fresh-install               Force uninstall/reinstall before validation
  -h, --help                          Show help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
WINDOWS_USER=""
CLIENT_UID=""
ENROLLMENT_SECRET=""
DEVICE_ID_OVERRIDE=""
SERVER_URL=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
POLL_INTERVAL="10s"
RENEW_BEFORE="9000h"
LOG_LEVEL="debug"
WAIT_SECONDS=420
FORCE_FRESH_INSTALL=0
ARTIFACT_DIR=""

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
    --device-id-override)
      DEVICE_ID_OVERRIDE="${2:?missing value for --device-id-override}"
      shift 2
      ;;
    --server-url)
      SERVER_URL="${2:?missing value for --server-url}"
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
    --force-fresh-install)
      FORCE_FRESH_INSTALL=1
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

if [[ -z "$WINDOWS_USER" || -z "$CLIENT_UID" || -z "$ENROLLMENT_SECRET" || -z "$DEVICE_ID_OVERRIDE" ]]; then
  echo "--windows-user, --client-uid, --enrollment-secret, and --device-id-override are required." >&2
  exit 1
fi

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${REPO_ROOT}/build/windows-canonical-renewal"
fi
mkdir -p "$ARTIFACT_DIR"

BUILD_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/linux/build_windows_msi.sh"
INSTALL_SCRIPT="${REPO_ROOT}/infra/terraform/scripts/linux/install_windows_msi.sh"

ensure_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

terraform_output_raw() {
  local key="$1"
  terraform -chdir="$TERRAFORM_DIR" output -raw "$key" 2>/dev/null || true
}

ensure_command python3

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "Build helper is not executable: $BUILD_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$INSTALL_SCRIPT" ]]; then
  echo "Install helper is not executable: $INSTALL_SCRIPT" >&2
  exit 1
fi

if [[ -z "$SERVER_URL" ]]; then
  server_internal_ip="$(terraform_output_raw server_internal_ip)"
  if [[ -n "$server_internal_ip" ]]; then
    SERVER_URL="http://${server_internal_ip}:3000/scep"
  fi
fi

build_log="${ARTIFACT_DIR}/build.log"
install_log="${ARTIFACT_DIR}/install.log"
summary_json="${ARTIFACT_DIR}/summary.json"

build_args=(
  --repo-root "$REPO_ROOT"
  --terraform-dir "$TERRAFORM_DIR"
  --windows-user "$WINDOWS_USER"
)
if [[ -n "$PROJECT_ID" ]]; then
  build_args+=(--project "$PROJECT_ID")
fi
if [[ -n "$ZONE" ]]; then
  build_args+=(--zone "$ZONE")
fi
if [[ -n "$INSTANCE" ]]; then
  build_args+=(--instance "$INSTANCE")
fi

echo "Building and transferring Windows MSI"
"$BUILD_SCRIPT" "${build_args[@]}" 2>&1 | tee "$build_log"

install_args=(
  --repo-root "$REPO_ROOT"
  --terraform-dir "$TERRAFORM_DIR"
  --client-uid "$CLIENT_UID"
  --enrollment-secret "$ENROLLMENT_SECRET"
  --device-id-override "$DEVICE_ID_OVERRIDE"
  --poll-interval "$POLL_INTERVAL"
  --renew-before "$RENEW_BEFORE"
  --log-level "$LOG_LEVEL"
  --wait-seconds "$WAIT_SECONDS"
  --apply-registry-overrides
)
if [[ -n "$SERVER_URL" ]]; then
  install_args+=(--server-url "$SERVER_URL")
fi
if [[ -n "$PROJECT_ID" ]]; then
  install_args+=(--project "$PROJECT_ID")
fi
if [[ -n "$ZONE" ]]; then
  install_args+=(--zone "$ZONE")
fi
if [[ -n "$INSTANCE" ]]; then
  install_args+=(--instance "$INSTANCE")
fi
if [[ "$FORCE_FRESH_INSTALL" -eq 1 ]]; then
  install_args+=(--force-fresh-install)
else
  install_args+=(--require-thumbprint-change)
fi

echo "Installing MSI and waiting for observation markers"
if ! install_output="$("$INSTALL_SCRIPT" "${install_args[@]}" 2>&1)"; then
  printf '%s\n' "$install_output" | tee "$install_log" >&2
  exit 1
fi
printf '%s\n' "$install_output" | tee "$install_log"

summary_line="$(printf '%s\n' "$install_output" | grep 'MYTUNNEL_MSI_INSTALL_DONE ' | tail -n 1 || true)"
if [[ -z "$summary_line" ]]; then
  echo "Install output did not include MYTUNNEL_MSI_INSTALL_DONE." >&2
  exit 1
fi

summary_payload="${summary_line#*summary=}"
printf '%s' "$summary_payload" > "$summary_json"

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
managed = summary.get("managed", {})
service = summary.get("service", {})
registry = summary.get("registry", {})
logs = summary.get("logs", {})
before = summary.get("managed_thumbprint_before")
after = summary.get("managed_thumbprint_after")
force_fresh = bool(summary.get("fresh_install_requested"))

errors = []
if not managed.get("cert_exists"):
    errors.append("managed cert.pem was not present after install")
if not managed.get("present_in_machine_store"):
    errors.append("managed certificate was not present in LocalMachine\\\\My after install")
if not service.get("exists"):
    errors.append("MyTunnelService was not found after install")
if service.get("state") != "Running":
    errors.append(f"MyTunnelService state was {service.get('state')!r}, expected 'Running'")
if not after:
    errors.append("post-install managed thumbprint was empty")
if before and not force_fresh and before == after:
    errors.append("managed thumbprint did not change across the validation run")

if errors:
    print("windows_canonical_renewal_e2e: validation failed", file=sys.stderr)
    for error in errors:
        print(f" - {error}", file=sys.stderr)
    print(
        f"poll_interval={registry.get('poll_interval')!r} renew_before={registry.get('renew_before')!r} "
        f"log_level={registry.get('log_level')!r}",
        file=sys.stderr,
    )
    print(f"latest_log_path={logs.get('latest_log_path')!r}", file=sys.stderr)
    print(f"log_excerpt={logs.get('latest_log_excerpt')!r}", file=sys.stderr)
    sys.exit(1)

result = {
    "result": "success_thumbprint_rotated" if before and before != after else "success_certificate_present",
    "before_thumbprint": before,
    "after_thumbprint": after,
    "service_state": service.get("state"),
    "managed_cert_path": managed.get("cert_path"),
    "present_in_machine_store": managed.get("present_in_machine_store"),
}
print(json.dumps(result, indent=2))
PY
