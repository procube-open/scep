gcloud_instance_nat_ip() {
  local project_id="$1"
  local zone="$2"
  local instance_name="$3"

  gcloud compute instances describe "$instance_name" \
    --project "$project_id" \
    --zone "$zone" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true
}

gcloud_instance_internal_ip() {
  local project_id="$1"
  local zone="$2"
  local instance_name="$3"

  gcloud compute instances describe "$instance_name" \
    --project "$project_id" \
    --zone "$zone" \
    --format='get(networkInterfaces[0].networkIP)' 2>/dev/null || true
}

assert_gcloud_instance_private_only() {
  local project_id="$1"
  local zone="$2"
  local instance_name="$3"
  local instance_label="${4:-instance}"
  local nat_ip

  nat_ip="$(gcloud_instance_nat_ip "$project_id" "$zone" "$instance_name")"
  if [[ -n "$nat_ip" ]]; then
    echo "${instance_label} ${instance_name} has external IP ${nat_ip}; expected private-only topology." >&2
    return 1
  fi
}
