#!/usr/bin/env bash
set -euo pipefail

# Deterministically generate a device_id from host identifiers.
# Optional env vars / flags:
#   DEVICE_ID_PREFIX / --prefix : Prefix for generated device_id (default: device-)
#   DEVICE_ID_SEED   / --seed   : Explicit seed string (default: hostname + machine-id)

usage() {
  cat <<'EOF'
Usage: generate_device_id.sh [--prefix PREFIX] [--seed SEED]

Outputs a deterministic device_id.
EOF
}

prefix="${DEVICE_ID_PREFIX:-device-}"
seed="${DEVICE_ID_SEED:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:?missing value for --prefix}"
      shift 2
      ;;
    --seed)
      seed="${2:?missing value for --seed}"
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

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum is required." >&2
  exit 1
fi

if [[ -z "$seed" ]]; then
  host_id="$(hostname 2>/dev/null || true)"
  machine_id=""
  if [[ -r /etc/machine-id ]]; then
    machine_id="$(tr -d '\n' < /etc/machine-id)"
  fi
  seed="${host_id}|${machine_id}"
fi

if [[ -z "$seed" || "$seed" == "|" ]]; then
  echo "Unable to derive a seed for device_id generation." >&2
  exit 1
fi

digest="$(printf '%s' "$seed" | sha256sum | awk '{print $1}')"
printf '%s%s\n' "$prefix" "${digest:0:24}"
