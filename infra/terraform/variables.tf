variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources."
  type        = string
}

variable "zone" {
  description = "GCP zone for VM instances."
  type        = string
}

variable "credentials_file" {
  description = "Path to Google service account credentials JSON file."
  type        = string
}

variable "network_name" {
  description = "Custom VPC name."
  type        = string
  default     = "scep-vpc"
}

variable "subnet_name" {
  description = "Custom subnet name."
  type        = string
  default     = "scep-subnet"
}

variable "subnet_cidr" {
  description = "CIDR range for subnet."
  type        = string
  default     = "10.42.0.0/24"
}

variable "internal_source_ranges" {
  description = "Source CIDRs allowed for east-west internal traffic."
  type        = list(string)
  default     = ["10.42.0.0/24"]
}

variable "scep_source_ranges" {
  description = "Source CIDRs allowed to access SCEP service on TCP/3000."
  type        = list(string)
  default     = ["10.42.0.0/24"]
}

variable "mysql_source_ranges" {
  description = "Source CIDRs allowed to access MySQL on TCP/3306."
  type        = list(string)
  default     = ["10.42.0.0/24"]
}

variable "ssh_source_ranges" {
  description = "Source CIDRs allowed to SSH on TCP/22."
  type        = list(string)
  default     = ["203.0.113.10/32"]
}

variable "rdp_source_ranges" {
  description = "Source CIDRs allowed to RDP on TCP/3389."
  type        = list(string)
  default     = ["203.0.113.10/32"]
}

variable "server_instance_name" {
  description = "Linux SCEP server VM name."
  type        = string
  default     = "scep-server-vm"
}

variable "client_instance_name" {
  description = "Windows SCEP client VM name."
  type        = string
  default     = "scep-client-vm"
}

variable "server_machine_type" {
  description = "Machine type for Linux SCEP server."
  type        = string
  default     = "e2-standard-2"
}

variable "client_machine_type" {
  description = "Machine type for Windows client VM."
  type        = string
  default     = "e2-standard-2"
}

variable "linux_image" {
  description = "Boot image for Linux SCEP server."
  type        = string
  default     = "projects/debian-cloud/global/images/family/debian-12"
}

variable "windows_image" {
  description = "Boot image for Windows client."
  type        = string
  default     = "projects/windows-cloud/global/images/family/windows-2022"
}

variable "server_boot_disk_size_gb" {
  description = "Boot disk size in GB for Linux SCEP server."
  type        = number
  default     = 50
}

variable "client_boot_disk_size_gb" {
  description = "Boot disk size in GB for Windows client."
  type        = number
  default     = 64
}

variable "server_tags" {
  description = "Network tags for Linux SCEP server VM."
  type        = list(string)
  default     = ["scep-server", "scep", "mysql", "ssh"]
}

variable "client_tags" {
  description = "Network tags for Windows client VM."
  type        = list(string)
  default     = ["scep-client", "rdp"]
}

variable "mysql_database" {
  description = "Database name used by SCEP on the co-located MySQL server."
  type        = string
  default     = "scep"
}

variable "mysql_user" {
  description = "MySQL user created for SCEP."
  type        = string
  default     = "scep"
}

variable "mysql_password" {
  description = "MySQL password for mysql_user; override in tfvars/secrets for production."
  type        = string
  sensitive   = true
  default     = "change-me"
}

variable "scep_dsn" {
  description = "Optional explicit SCEP_DSN override. Leave empty to auto-build from MySQL variables."
  type        = string
  default     = ""
}

variable "scep_dsn_timezone" {
  description = "Timezone name encoded into generated SCEP_DSN loc parameter (for example UTC or Asia/Tokyo)."
  type        = string
  default     = "UTC"
}

variable "scep_http_listen_port" {
  description = "SCEP server HTTP listen port exported via SCEP_HTTP_LISTEN_PORT."
  type        = string
  default     = "3000"
}

variable "scep_file_depot" {
  description = "Path used by SCEP_FILE_DEPOT to store CA materials."
  type        = string
  default     = "/var/lib/scep/ca-certs"
}

variable "scep_download_path" {
  description = "Path exposed via SCEP_DOWNLOAD_PATH for downloadable assets."
  type        = string
  default     = "/var/lib/scep/download"
}

variable "scep_ticker" {
  description = "Value for SCEP_TICKER certificate/secret maintenance interval."
  type        = string
  default     = "24h"
}

variable "scep_cert_valid" {
  description = "Value for SCEP_CERT_VALID in days."
  type        = string
  default     = "365"
}

variable "scep_ca_pass" {
  description = "Optional passphrase for CA key and SCEP_CA_PASS. Keep empty for an unencrypted key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "server_startup_script" {
  description = "Optional full startup script override. Keep empty to render scripts/linux/scep-server-startup.sh.tftpl."
  type        = string
  default     = ""
}

variable "client_startup_script_ps1" {
  description = "Startup PowerShell script placeholder for Windows client."
  type        = string
  default     = <<-EOT
    # TODO: configure Windows SCEP client bootstrap steps.
  EOT
}
