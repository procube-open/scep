#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_and_scp_scepserver.sh [options]

Builds local linux/amd64 scepserver binary, transfers it to the VM, and activates it.

Options:
  --project <PROJECT_ID>             GCP project ID (optional; auto-detected from Terraform)
  --zone <ZONE>                      GCP zone (optional; auto-detected from Terraform)
  --instance <INSTANCE_NAME>         GCE instance name (optional; auto-detected from Terraform)
  --ssh-user <USERNAME>              SSH username for gcloud compute ssh/scp
                                     (default: current local user; if running as root,
                                     derive from active gcloud account)
  --terraform-dir <PATH>             Terraform working directory used for output lookup
                                     (default: <repo-root>/infra/terraform)
  --repo-root <PATH>                 Repository root containing ./cmd/scepserver
                                     (default: auto-detected from script location)
  --local-binary-path <PATH>         Local output path for built binary
                                     (default: /tmp/scepserver-opt)
  --remote-staged-path <PATH>        Remote staged binary path for SCP
                                     (default: /tmp/scepserver-opt)
  --remote-helper-path <PATH>        Remote activation helper script path
                                     (default: /usr/local/bin/deploy-scepserver-binary.sh)
  -h, --help                         Show this help text
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID=""
ZONE=""
INSTANCE=""
SSH_USER=""
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TERRAFORM_DIR=""
LOCAL_BINARY_PATH="/tmp/scepserver-opt"
REMOTE_STAGED_PATH="/tmp/scepserver-opt"
REMOTE_HELPER_PATH="/usr/local/bin/deploy-scepserver-binary.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --ssh-user)
      [[ $# -ge 2 ]] || { echo "Missing value for --ssh-user" >&2; usage; exit 1; }
      SSH_USER="$2"
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
    --local-binary-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --local-binary-path" >&2; usage; exit 1; }
      LOCAL_BINARY_PATH="$2"
      shift 2
      ;;
    --remote-staged-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --remote-staged-path" >&2; usage; exit 1; }
      REMOTE_STAGED_PATH="$2"
      shift 2
      ;;
    --remote-helper-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --remote-helper-path" >&2; usage; exit 1; }
      REMOTE_HELPER_PATH="$2"
      shift 2
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

derive_ssh_user() {
  local local_user active_account derived

  local_user="$(id -un)"
  if [[ -n "$local_user" && "$local_user" != "root" ]]; then
    printf '%s' "$local_user"
    return 0
  fi

  active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
  [[ -n "$active_account" ]] || return 1

  derived="${active_account,,}"
  derived="${derived//@/_}"
  derived="${derived//./_}"
  derived="$(printf '%s' "$derived" | sed -E 's/[^a-z0-9_-]+/_/g; s/^[^a-z_]+//; s/_+/_/g; s/_$//')"
  [[ -n "$derived" ]] || return 1

  printf '%s' "$derived"
}

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  if ! command -v terraform >/dev/null 2>&1; then
    echo "Required command not found: terraform (needed for auto-detected values)." >&2
    exit 1
  fi
  if [[ ! -d "$TERRAFORM_DIR" ]]; then
    echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
    exit 1
  fi
  if ! terraform -chdir="$TERRAFORM_DIR" output -json >/dev/null 2>&1; then
    echo "Terraform outputs unavailable in ${TERRAFORM_DIR}; run terraform apply first." >&2
    exit 1
  fi
  if [[ -z "$INSTANCE" ]]; then
    INSTANCE="$(terraform -chdir="$TERRAFORM_DIR" output -raw server_instance_name 2>/dev/null || true)"
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

if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE" ]]; then
  echo "Unable to resolve --project, --zone, and --instance. Provide overrides or run terraform apply in ${TERRAFORM_DIR}." >&2
  usage
  exit 1
fi

for required_cmd in go gcloud; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "Required command not found: $required_cmd" >&2
    exit 1
  fi
done

if [[ -z "$SSH_USER" ]]; then
  SSH_USER="$(derive_ssh_user || true)"
fi

if [[ -z "$SSH_USER" ]]; then
  echo "Unable to resolve SSH user. Provide --ssh-user explicitly." >&2
  exit 1
fi

INSTANCE_TARGET="${SSH_USER}@${INSTANCE}"

mkdir -p "$(dirname "$LOCAL_BINARY_PATH")"

echo "Building linux/amd64 scepserver binary: $LOCAL_BINARY_PATH"
(
  cd "$REPO_ROOT"
  GOOS=linux GOARCH=amd64 go build -o "$LOCAL_BINARY_PATH" ./cmd/scepserver
)

echo "Copying binary to ${INSTANCE_TARGET}:${REMOTE_STAGED_PATH}"
gcloud compute scp "$LOCAL_BINARY_PATH" "${INSTANCE_TARGET}:${REMOTE_STAGED_PATH}" --project "$PROJECT_ID" --zone "$ZONE"

echo "Activating binary via ${REMOTE_HELPER_PATH}"
remote_command="$(printf "sudo %q %q" "$REMOTE_HELPER_PATH" "$REMOTE_STAGED_PATH")"
gcloud compute ssh "${INSTANCE_TARGET}" --project "$PROJECT_ID" --zone "$ZONE" --command "$remote_command"

echo "SCEP server binary deployed and activated."
