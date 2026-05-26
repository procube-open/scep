output "server_instance_name" {
  description = "Linux SCEP server VM name."
  value       = google_compute_instance.scep_server.name
}

output "client_instance_name" {
  description = "Windows SCEP client VM name."
  value       = google_compute_instance.scep_client_windows.name
}

output "project_id" {
  description = "GCP project ID used for this deployment."
  value       = var.project_id
}

output "deployment_zone" {
  description = "GCP zone used for VM deployment."
  value       = var.zone
}

output "operator_private_source_ranges" {
  description = "Private source CIDRs automatically allowed from the peered operator network."
  value       = local.operator_source_ranges
}

output "server_internal_ip" {
  description = "Internal IP for Linux SCEP server VM."
  value       = google_compute_instance.scep_server.network_interface[0].network_ip
}

output "client_internal_ip" {
  description = "Internal IP for Windows SCEP client VM."
  value       = google_compute_instance.scep_client_windows.network_interface[0].network_ip
}
