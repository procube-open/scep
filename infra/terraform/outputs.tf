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

output "server_internal_ip" {
  description = "Internal IP for Linux SCEP server VM."
  value       = google_compute_instance.scep_server.network_interface[0].network_ip
}

output "server_external_ip" {
  description = "External IP for Linux SCEP server VM."
  value       = try(google_compute_instance.scep_server.network_interface[0].access_config[0].nat_ip, "")
}

output "client_internal_ip" {
  description = "Internal IP for Windows SCEP client VM."
  value       = google_compute_instance.scep_client_windows.network_interface[0].network_ip
}

output "client_external_ip" {
  description = "External IP for Windows SCEP client VM."
  value       = try(google_compute_instance.scep_client_windows.network_interface[0].access_config[0].nat_ip, "")
}
