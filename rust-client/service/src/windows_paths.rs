use std::path::{Path, PathBuf};

pub const MANAGED_ROOT: &str = r"C:\ProgramData\MyTunnelApp\managed";

pub fn key_dir_name(client_uid: &str, device_id: &str) -> String {
	format!("{}-{}", sanitize_component(client_uid), sanitize_component(device_id))
}

pub fn managed_dir(client_uid: &str, device_id: &str) -> PathBuf {
	Path::new(MANAGED_ROOT).join(key_dir_name(client_uid, device_id))
}

pub fn key_path(dir: &Path) -> PathBuf {
	dir.join("key.pem")
}

pub fn cert_path(dir: &Path) -> PathBuf {
	dir.join("cert.pem")
}

pub fn csr_path(dir: &Path) -> PathBuf {
	dir.join("csr.pem")
}

pub fn self_signed_path(dir: &Path) -> PathBuf {
	dir.join("self.pem")
}

pub fn pfx_path(dir: &Path) -> PathBuf {
	dir.join("cert.pfx")
}

fn sanitize_component(value: &str) -> String {
	value
		.chars()
		.map(|ch| match ch {
			'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => ch,
			_ => '-',
		})
		.collect()
}