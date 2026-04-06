#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: windows_activation_negative_renewal_e2e.sh [options]

Build and transfer the current Windows MSI, install it on the live Windows VM,
then submit a same-key renewal with tampered activation_proof_b64 and verify
that the server rejects it without rotating the managed certificate.

Required:
  --windows-user <USER>               Windows username for MSI transfer
  --client-uid <UID>                  Registered client UID
  --enrollment-secret <SECRET>        One-time enrollment secret
  --expected-device-id <DEVICE_ID>    Registered TPM identity for the VM

Optional:
  --server-url <URL>                  Full SCEP URL (default: Terraform-derived internal URL)
  --poll-interval <DURATION>          Poll interval for installed service (default: 1h)
  --renew-before <DURATION>           Renew-before for installed service (default: 14d)
  --log-level <LEVEL>                 Service log level (default: debug)
  --wait-seconds <SECONDS>            Wait budget per install run (default: 2100)
  --artifact-dir <DIR>                Directory for captured logs/summary
  --msi-builder <auto|wix|wixl>       Packaging backend for build_windows_msi.sh
                                      (default: wix for release-path validation)
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
EXPECTED_DEVICE_ID=""
SERVER_URL=""
PROJECT_ID=""
ZONE=""
INSTANCE=""
POLL_INTERVAL="1h"
RENEW_BEFORE="14d"
LOG_LEVEL="debug"
WAIT_SECONDS=2100
FORCE_FRESH_INSTALL=0
ARTIFACT_DIR=""
MSI_BUILDER="wix"

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
      EXPECTED_DEVICE_ID="${2:?missing value for $1}"
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

if [[ -z "$WINDOWS_USER" || -z "$CLIENT_UID" || -z "$ENROLLMENT_SECRET" || -z "$EXPECTED_DEVICE_ID" ]]; then
  echo "--windows-user, --client-uid, --enrollment-secret, and --expected-device-id are required." >&2
  exit 1
fi

if [[ -z "$TERRAFORM_DIR" ]]; then
  TERRAFORM_DIR="${REPO_ROOT}/infra/terraform"
fi

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${REPO_ROOT}/build/windows-activation-negative-renewal"
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
  --msi-builder "$MSI_BUILDER"
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
  --expected-device-id "$EXPECTED_DEVICE_ID"
  --poll-interval "$POLL_INTERVAL"
  --renew-before "$RENEW_BEFORE"
  --log-level "$LOG_LEVEL"
  --wait-seconds "$WAIT_SECONDS"
  --require-thumbprint-change
  --tamper-activation-proof-renewal
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
install_args+=(--require-thumbprint-change)
if [[ "$FORCE_FRESH_INSTALL" -eq 1 ]]; then
  install_args+=(--force-fresh-install)
fi

echo "Installing MSI and executing tampered activation renewal"
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
logs = summary.get("logs", {})
negative = summary.get("activation_negative") or {}
after = summary.get("managed_thumbprint_after")

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
if not negative:
    errors.append("activation_negative summary was missing")

negative_before = negative.get("managed_thumbprint_before")
negative_after = negative.get("managed_thumbprint_after")
renewal_exit_code = negative.get("renewal_exit_code")

if renewal_exit_code is None:
    errors.append("tampered renewal exit code was missing")
if negative.get("renewal_rejected") is not True:
    errors.append("tampered renewal was not marked as rejected")
if negative.get("managed_thumbprint_changed") is not False:
    errors.append("tampered renewal reported an unexpected thumbprint change")
if not negative_before or not negative_after:
    errors.append("tampered renewal thumbprints were incomplete")
if negative_before and negative_after and negative_before != negative_after:
    errors.append("tampered renewal rotated the managed certificate thumbprint")
if after and negative_after and after != negative_after:
    errors.append("marker summary thumbprint disagreed with activation_negative thumbprint")

if errors:
    print("windows_activation_negative_renewal_e2e: validation failed", file=sys.stderr)
    for error in errors:
        print(f" - {error}", file=sys.stderr)
    print(f"renewal_stdout={negative.get('renewal_stdout_excerpt')!r}", file=sys.stderr)
    print(f"renewal_stderr={negative.get('renewal_stderr_excerpt')!r}", file=sys.stderr)
    print(f"renewal_failure={negative.get('renewal_failure_excerpt')!r}", file=sys.stderr)
    print(f"latest_log_path={logs.get('latest_log_path')!r}", file=sys.stderr)
    print(f"log_excerpt={logs.get('latest_log_excerpt')!r}", file=sys.stderr)
    sys.exit(1)

result = {
    "result": "success_tampered_activation_rejected",
    "managed_thumbprint": after,
    "renewal_exit_code": renewal_exit_code,
    "service_state": service.get("state"),
    "renewal_rejected": negative.get("renewal_rejected"),
    "renewal_stdout_excerpt": negative.get("renewal_stdout_excerpt"),
    "renewal_stderr_excerpt": negative.get("renewal_stderr_excerpt"),
    "renewal_failure_excerpt": negative.get("renewal_failure_excerpt"),
}
print(json.dumps(result, indent=2))
PY
