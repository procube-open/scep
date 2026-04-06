locals {
  # Generate Linux VM bootstrap script from template unless an explicit override is provided.
  computed_scep_dsn = "${var.mysql_user}:${var.mysql_password}@tcp(127.0.0.1:3306)/${var.mysql_database}?parseTime=true&loc=${urlencode(var.scep_dsn_timezone)}"
  compute_service_account_scopes = [
    "https://www.googleapis.com/auth/devstorage.read_only",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring.write",
    "https://www.googleapis.com/auth/pubsub",
    "https://www.googleapis.com/auth/service.management.readonly",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/trace.append",
  ]
  server_startup_script = trimspace(var.server_startup_script) != "" ? var.server_startup_script : templatefile("${path.module}/scripts/linux/scep-server-startup.sh.tftpl", {
    mysql_database        = var.mysql_database
    mysql_user            = var.mysql_user
    mysql_password        = var.mysql_password
    scep_dsn              = trimspace(var.scep_dsn) != "" ? var.scep_dsn : local.computed_scep_dsn
    scep_http_listen_port = var.scep_http_listen_port
    scep_file_depot       = var.scep_file_depot
    scep_download_path    = var.scep_download_path
    scep_ticker           = var.scep_ticker
    scep_cert_valid       = var.scep_cert_valid
    scep_ca_pass          = var.scep_ca_pass
  })
}

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

resource "google_compute_network" "scep" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "scep" {
  name                     = var.subnet_name
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.scep.id
  private_ip_google_access = true
}

resource "google_compute_router" "scep" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.scep.id
}

resource "google_compute_router_nat" "scep" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.scep.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.scep.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_compute_firewall" "internal" {
  name          = "${var.network_name}-allow-internal"
  network       = google_compute_network.scep.name
  direction     = "INGRESS"
  source_ranges = var.internal_source_ranges

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "scep" {
  name          = "${var.network_name}-allow-scep-3000"
  network       = google_compute_network.scep.name
  direction     = "INGRESS"
  source_ranges = var.scep_source_ranges
  target_tags   = ["scep"]

  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }
}

resource "google_compute_firewall" "mysql" {
  name          = "${var.network_name}-allow-mysql-3306"
  network       = google_compute_network.scep.name
  direction     = "INGRESS"
  source_ranges = var.mysql_source_ranges
  target_tags   = ["mysql"]

  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.network_name}-allow-ssh-22"
  network       = google_compute_network.scep.name
  direction     = "INGRESS"
  source_ranges = var.ssh_source_ranges
  target_tags   = ["ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "rdp" {
  name          = "${var.network_name}-allow-rdp-3389"
  network       = google_compute_network.scep.name
  direction     = "INGRESS"
  source_ranges = var.rdp_source_ranges
  target_tags   = ["rdp"]

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }
}

resource "google_compute_instance" "scep_server" {
  name         = var.server_instance_name
  machine_type = var.server_machine_type
  zone         = var.zone
  tags         = var.server_tags

  boot_disk {
    initialize_params {
      image = var.linux_image
      size  = var.server_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.scep.id
  }

  metadata = {
    startup-script = local.server_startup_script
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = local.compute_service_account_scopes
  }
}

resource "google_compute_instance" "scep_client_windows" {
  name         = var.client_instance_name
  machine_type = var.client_machine_type
  zone         = var.zone
  tags         = var.client_tags

  boot_disk {
    initialize_params {
      image = var.windows_image
      size  = var.client_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.scep.id
  }

  metadata = {
    windows-startup-script-ps1 = file("${path.module}/scripts/windows/windows-client-startup.ps1")
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = local.compute_service_account_scopes
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
}
