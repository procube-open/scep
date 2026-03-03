project_id       = "admingate"
region           = "us-central1"
zone             = "us-central1-a"
credentials_file = "/workspaces/scep/gcp_credential.json"

network_name = "scep-vpc"
subnet_name  = "scep-subnet"
subnet_cidr  = "10.42.0.0/24"

internal_source_ranges = ["10.42.0.0/24"]
scep_source_ranges     = ["160.86.236.182/32"]
mysql_source_ranges    = ["10.42.0.0/24"]
ssh_source_ranges      = ["160.86.236.182/32"]
rdp_source_ranges      = ["160.86.236.182/32"]

server_instance_name = "scep-server-vm"
client_instance_name = "scep-client-vm"

server_machine_type = "e2-standard-2"
client_machine_type = "e2-standard-2"

linux_image   = "projects/debian-cloud/global/images/family/debian-12"
windows_image = "projects/windows-cloud/global/images/family/windows-2022"

mysql_database = "scep"
mysql_user     = "scep"
mysql_password = "change-me"

# Optional explicit DSN override; keep empty to auto-generate from mysql_* values.
scep_dsn          = ""
scep_dsn_timezone = "UTC"

scep_http_listen_port = "3000"
scep_file_depot       = "/var/lib/scep/ca-certs"
scep_download_path    = "/var/lib/scep/download"
scep_ticker           = "24h"
scep_cert_valid       = "365"
scep_ca_pass          = ""
