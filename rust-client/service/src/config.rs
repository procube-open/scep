use serde::Deserialize;
use std::fs;

#[cfg(windows)]
const REGISTRY_PATH: &str = r"SOFTWARE\MyTunnelApp";
#[cfg(windows)]
const REGISTRY_VALUE: &str = "ConfigURL";
const FALLBACK_CONFIG_PATH: &str = r"C:\ProgramData\MyTunnelApp\config.json";

#[derive(Debug, Clone, Deserialize)]
pub struct ServiceConfig {
    #[serde(alias = "ConfigURL", alias = "SERVICE_URL", alias = "service_url")]
    pub config_url: String,
}

impl ServiceConfig {
    pub fn load() -> Result<Self, String> {
        if let Some(config_url) = load_from_registry()? {
            return Ok(Self { config_url });
        }
        load_from_file(FALLBACK_CONFIG_PATH)
    }
}

#[cfg(windows)]
fn load_from_registry() -> Result<Option<String>, String> {
    use winreg::RegKey;
    use winreg::enums::HKEY_LOCAL_MACHINE;

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = match hklm.open_subkey(REGISTRY_PATH) {
        Ok(key) => key,
        Err(_) => return Ok(None),
    };

    match key.get_value::<String, _>(REGISTRY_VALUE) {
        Ok(value) if !value.trim().is_empty() => Ok(Some(value.trim().to_owned())),
        Ok(_) => Ok(None),
        Err(err) => Err(format!(
            "failed to read registry value {}\\{}: {err}",
            REGISTRY_PATH, REGISTRY_VALUE
        )),
    }
}

#[cfg(not(windows))]
fn load_from_registry() -> Result<Option<String>, String> {
    Ok(None)
}

fn load_from_file(path: &str) -> Result<ServiceConfig, String> {
    let raw = fs::read(path).map_err(|err| format!("failed to read config file {path}: {err}"))?;
    let mut config = serde_json::from_slice::<ServiceConfig>(&raw)
        .map_err(|err| format!("failed to parse config file {path}: {err}"))?;
    if config.config_url.trim().is_empty() {
        return Err(format!("config file {path} has empty config_url"));
    }
    config.config_url = config.config_url.trim().to_owned();
    Ok(config)
}
