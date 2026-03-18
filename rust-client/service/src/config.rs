use base64::Engine;
use serde::Deserialize;
use std::fmt;
use std::fs;
use std::path::Path;
use std::time::Duration;

#[cfg(windows)]
const REGISTRY_PATH: &str = r"SOFTWARE\MyTunnelApp";
#[cfg(windows)]
const REGISTRY_SERVER_URL_VALUES: &[&str] = &["ServerUrl", "ConfigURL"];
#[cfg(windows)]
const REGISTRY_CLIENT_UID_VALUE: &str = "ClientUid";
#[cfg(windows)]
const REGISTRY_ENROLLMENT_SECRET_VALUE: &str = "EnrollmentSecret";
#[cfg(windows)]
const REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE: &str = "EnrollmentSecretProtected";
#[cfg(windows)]
const REGISTRY_DEVICE_ID_VALUES: &[&str] = &["DeviceId", "DeviceID", "DeviceIdOverride"];
#[cfg(windows)]
const REGISTRY_POLL_INTERVAL_VALUE: &str = "PollInterval";
#[cfg(windows)]
const REGISTRY_RENEW_BEFORE_VALUE: &str = "RenewBefore";
#[cfg(windows)]
const REGISTRY_LOG_LEVEL_VALUE: &str = "LogLevel";
const FALLBACK_CONFIG_PATH: &str = r"C:\ProgramData\MyTunnelApp\config.json";
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(60 * 60);
pub const DEFAULT_RENEW_BEFORE: Duration = Duration::from_secs(14 * 24 * 60 * 60);
pub const DEFAULT_LOG_LEVEL: &str = "info";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigSource {
    File,
    Registry,
}

impl ConfigSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Registry => "registry",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequiredField {
    ServerUrl,
    ClientUid,
    DeviceId,
    EnrollmentSecret,
}

impl RequiredField {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ServerUrl => "server_url",
            Self::ClientUid => "client_uid",
            Self::DeviceId => "device_id",
            Self::EnrollmentSecret => "enrollment_secret",
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ServiceConfig {
    pub server_url: Option<String>,
    pub client_uid: Option<String>,
    pub enrollment_secret: Option<String>,
    pub device_id: Option<String>,
    pub poll_interval: Duration,
    pub renew_before: Duration,
    pub log_level: String,
    pub sources: Vec<ConfigSource>,
    pub warnings: Vec<String>,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        Self {
            server_url: None,
            client_uid: None,
            enrollment_secret: None,
            device_id: None,
            poll_interval: DEFAULT_POLL_INTERVAL,
            renew_before: DEFAULT_RENEW_BEFORE,
            log_level: DEFAULT_LOG_LEVEL.to_owned(),
            sources: Vec::new(),
            warnings: Vec::new(),
        }
    }
}

impl fmt::Debug for ServiceConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ServiceConfig")
            .field("server_url", &self.server_url)
            .field("client_uid", &self.client_uid)
            .field(
                "enrollment_secret",
                &self.enrollment_secret.as_ref().map(|_| "<redacted>"),
            )
            .field("device_id", &self.device_id)
            .field("poll_interval", &self.poll_interval)
            .field("renew_before", &self.renew_before)
            .field("log_level", &self.log_level)
            .field("sources", &self.sources)
            .field("warnings", &self.warnings)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct EnrollmentSettings {
    pub server_url: String,
    pub client_uid: String,
    pub enrollment_secret: String,
    pub device_id: String,
}

impl fmt::Debug for EnrollmentSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EnrollmentSettings")
            .field("server_url", &self.server_url)
            .field("client_uid", &self.client_uid)
            .field("enrollment_secret", &"<redacted>")
            .field("device_id", &self.device_id)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenewalSettings {
    pub server_url: String,
    pub client_uid: String,
    pub device_id: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct RawServiceConfig {
    #[serde(
        alias = "ConfigURL",
        alias = "SERVICE_URL",
        alias = "SERVER_URL",
        alias = "service_url",
        alias = "server_url"
    )]
    server_url: Option<String>,
    #[serde(alias = "CLIENT_UID", alias = "client_uid")]
    client_uid: Option<String>,
    #[serde(alias = "ENROLLMENT_SECRET", alias = "enrollment_secret")]
    enrollment_secret: Option<String>,
    #[serde(
        alias = "DEVICE_ID",
        alias = "DEVICE_ID_OVERRIDE",
        alias = "device_id",
        alias = "device_id_override"
    )]
    device_id: Option<String>,
    #[serde(alias = "POLL_INTERVAL", alias = "poll_interval")]
    poll_interval: Option<String>,
    #[serde(alias = "RENEW_BEFORE", alias = "renew_before")]
    renew_before: Option<String>,
    #[serde(alias = "LOG_LEVEL", alias = "log_level")]
    log_level: Option<String>,
}

#[derive(Debug, Default)]
struct SourceLoad {
    raw: Option<RawServiceConfig>,
    warnings: Vec<String>,
}

impl ServiceConfig {
    pub fn load() -> Self {
        let mut merged = RawServiceConfig::default();
        let mut sources = Vec::new();
        let mut warnings = Vec::new();

        let file_load = load_from_file(FALLBACK_CONFIG_PATH);
        if let Some(raw) = file_load.raw {
            merged.merge(raw);
            sources.push(ConfigSource::File);
        }
        warnings.extend(file_load.warnings);

        let registry_load = load_from_registry();
        if let Some(raw) = registry_load.raw {
            merged.merge(raw);
            sources.push(ConfigSource::Registry);
        }
        warnings.extend(registry_load.warnings);

        build_service_config(merged, sources, warnings)
    }

    pub fn renewal_settings(&self) -> Result<RenewalSettings, Vec<RequiredField>> {
        let missing = self.missing_identity_fields();
        if !missing.is_empty() {
            return Err(missing);
        }

        Ok(RenewalSettings {
            server_url: self.server_url.clone().unwrap_or_default(),
            client_uid: self.client_uid.clone().unwrap_or_default(),
            device_id: self.device_id.clone().unwrap_or_default(),
        })
    }

    pub fn initial_enrollment(&self) -> Result<EnrollmentSettings, Vec<RequiredField>> {
        let mut missing = self.missing_identity_fields();
        if self.enrollment_secret.is_none() {
            missing.push(RequiredField::EnrollmentSecret);
        }
        if !missing.is_empty() {
            return Err(missing);
        }

        Ok(EnrollmentSettings {
            server_url: self.server_url.clone().unwrap_or_default(),
            client_uid: self.client_uid.clone().unwrap_or_default(),
            enrollment_secret: self.enrollment_secret.clone().unwrap_or_default(),
            device_id: self.device_id.clone().unwrap_or_default(),
        })
    }

    pub fn has_bootstrap_secret(&self) -> bool {
        self.enrollment_secret.is_some()
    }

    pub fn effective_poll_interval(&self) -> Duration {
        if self.poll_interval.is_zero() {
            DEFAULT_POLL_INTERVAL
        } else {
            self.poll_interval
        }
    }

    pub fn source_summary(&self) -> String {
        if self.sources.is_empty() {
            "none".to_owned()
        } else {
            self.sources
                .iter()
                .map(|source| source.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    fn missing_identity_fields(&self) -> Vec<RequiredField> {
        let mut missing = Vec::new();
        push_missing(
            &mut missing,
            self.server_url.as_ref(),
            RequiredField::ServerUrl,
        );
        push_missing(
            &mut missing,
            self.client_uid.as_ref(),
            RequiredField::ClientUid,
        );
        push_missing(
            &mut missing,
            self.device_id.as_ref(),
            RequiredField::DeviceId,
        );
        missing
    }
}

impl RawServiceConfig {
    fn is_empty(&self) -> bool {
        self.server_url.is_none()
            && self.client_uid.is_none()
            && self.enrollment_secret.is_none()
            && self.device_id.is_none()
            && self.poll_interval.is_none()
            && self.renew_before.is_none()
            && self.log_level.is_none()
    }

    fn merge(&mut self, other: Self) {
        if other.server_url.is_some() {
            self.server_url = other.server_url;
        }
        if other.client_uid.is_some() {
            self.client_uid = other.client_uid;
        }
        if other.enrollment_secret.is_some() {
            self.enrollment_secret = other.enrollment_secret;
        }
        if other.device_id.is_some() {
            self.device_id = other.device_id;
        }
        if other.poll_interval.is_some() {
            self.poll_interval = other.poll_interval;
        }
        if other.renew_before.is_some() {
            self.renew_before = other.renew_before;
        }
        if other.log_level.is_some() {
            self.log_level = other.log_level;
        }
    }
}

#[cfg(windows)]
fn load_from_registry() -> SourceLoad {
    use winreg::RegKey;
    use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE};

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let (key, writable) = match hklm.open_subkey_with_flags(REGISTRY_PATH, KEY_READ | KEY_WRITE) {
        Ok(key) => (key, true),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return SourceLoad::default(),
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
            let read_only_key = match hklm.open_subkey_with_flags(REGISTRY_PATH, KEY_READ) {
                Ok(key) => key,
                Err(read_err) => {
                    return SourceLoad {
                        raw: None,
                        warnings: vec![format!(
                            "failed to open registry key {REGISTRY_PATH} for reading: {read_err}"
                        )],
                    };
                }
            };
            (read_only_key, false)
        }
        Err(err) => {
            return SourceLoad {
                raw: None,
                warnings: vec![format!(
                    "failed to open registry key {REGISTRY_PATH}: {err}"
                )],
            };
        }
    };

    let mut warnings = Vec::new();
    let raw = RawServiceConfig {
        server_url: capture_registry_value_list(&key, REGISTRY_SERVER_URL_VALUES, &mut warnings),
        client_uid: capture_registry_value(&key, REGISTRY_CLIENT_UID_VALUE, &mut warnings),
        enrollment_secret: capture_enrollment_secret(&key, writable, &mut warnings),
        device_id: capture_registry_value_list(&key, REGISTRY_DEVICE_ID_VALUES, &mut warnings),
        poll_interval: capture_registry_value(&key, REGISTRY_POLL_INTERVAL_VALUE, &mut warnings),
        renew_before: capture_registry_value(&key, REGISTRY_RENEW_BEFORE_VALUE, &mut warnings),
        log_level: capture_registry_value(&key, REGISTRY_LOG_LEVEL_VALUE, &mut warnings),
    };

    SourceLoad {
        raw: (!raw.is_empty()).then_some(raw),
        warnings,
    }
}

#[cfg(not(windows))]
fn load_from_registry() -> SourceLoad {
    SourceLoad::default()
}

fn load_from_file(path: &str) -> SourceLoad {
    let path = Path::new(path);
    if !path.exists() {
        return SourceLoad::default();
    }

    let raw = match fs::read(path) {
        Ok(raw) => raw,
        Err(err) => {
            return SourceLoad {
                raw: None,
                warnings: vec![format!(
                    "failed to read config file {}: {err}",
                    path.display()
                )],
            };
        }
    };

    let config = match serde_json::from_slice::<RawServiceConfig>(&raw) {
        Ok(config) => config,
        Err(err) => {
            return SourceLoad {
                raw: None,
                warnings: vec![format!(
                    "failed to parse config file {}: {err}",
                    path.display()
                )],
            };
        }
    };

    SourceLoad {
        raw: (!config.is_empty()).then_some(config),
        warnings: Vec::new(),
    }
}

fn build_service_config(
    raw: RawServiceConfig,
    sources: Vec<ConfigSource>,
    mut warnings: Vec<String>,
) -> ServiceConfig {
    let (poll_interval, poll_warning) = parse_duration_field(
        raw.poll_interval.as_deref(),
        DEFAULT_POLL_INTERVAL,
        "poll_interval / POLL_INTERVAL",
    );
    if let Some(warning) = poll_warning {
        warnings.push(warning);
    }

    let (renew_before, renew_warning) = parse_duration_field(
        raw.renew_before.as_deref(),
        DEFAULT_RENEW_BEFORE,
        "renew_before / RENEW_BEFORE",
    );
    if let Some(warning) = renew_warning {
        warnings.push(warning);
    }

    let (log_level, log_warning) = normalize_log_level(raw.log_level.as_deref());
    if let Some(warning) = log_warning {
        warnings.push(warning);
    }

    ServiceConfig {
        server_url: optional_value(raw.server_url),
        client_uid: optional_value(raw.client_uid),
        enrollment_secret: optional_value(raw.enrollment_secret),
        device_id: optional_value(raw.device_id).map(|value| value.to_lowercase()),
        poll_interval,
        renew_before,
        log_level,
        sources,
        warnings,
    }
}

fn push_missing<T>(missing: &mut Vec<RequiredField>, value: Option<&T>, field: RequiredField) {
    if value.is_none() {
        missing.push(field);
    }
}

fn optional_value(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        }
    })
}

fn parse_duration_field(
    value: Option<&str>,
    default: Duration,
    field_name: &str,
) -> (Duration, Option<String>) {
    let Some(value) = value else {
        return (default, None);
    };
    let value = value.trim();
    if value.is_empty() {
        return (default, None);
    }

    match parse_duration_value(value) {
        Ok(duration) => (duration, None),
        Err(err) => (
            default,
            Some(format!(
                "invalid {field_name} value {value:?}: {err}; using default {}s",
                default.as_secs()
            )),
        ),
    }
}

fn parse_duration_value(value: &str) -> Result<Duration, String> {
    let value = value.trim().to_lowercase();
    if value.is_empty() {
        return Err("duration is empty".to_owned());
    }

    if let Ok(seconds) = value.parse::<u64>() {
        return Ok(Duration::from_secs(seconds));
    }

    let (number, unit) = value.split_at(value.len().saturating_sub(1));
    let amount = number
        .parse::<u64>()
        .map_err(|_| format!("unsupported duration value {value}"))?;
    let seconds = match unit {
        "s" => amount,
        "m" => amount * 60,
        "h" => amount * 60 * 60,
        "d" => amount * 24 * 60 * 60,
        _ => return Err(format!("unsupported duration unit {unit}")),
    };
    Ok(Duration::from_secs(seconds))
}

fn normalize_log_level(value: Option<&str>) -> (String, Option<String>) {
    let Some(value) = value else {
        return (DEFAULT_LOG_LEVEL.to_owned(), None);
    };
    let value = value.trim().to_lowercase();
    if value.is_empty() {
        return (DEFAULT_LOG_LEVEL.to_owned(), None);
    }

    let normalized = match value.as_str() {
        "trace" | "debug" | "info" | "warn" | "error" => value,
        "warning" => "warn".to_owned(),
        _ => {
            return (
                DEFAULT_LOG_LEVEL.to_owned(),
                Some(format!(
                    "invalid log_level / LOG_LEVEL value {value:?}; using {DEFAULT_LOG_LEVEL}"
                )),
            );
        }
    };

    (normalized, None)
}

#[cfg(windows)]
fn capture_registry_value_list(
    key: &winreg::RegKey,
    value_names: &[&str],
    warnings: &mut Vec<String>,
) -> Option<String> {
    match read_registry_value_list(key, value_names) {
        Ok(value) => value,
        Err(err) => {
            warnings.push(err);
            None
        }
    }
}

#[cfg(windows)]
fn capture_registry_value(
    key: &winreg::RegKey,
    value_name: &str,
    warnings: &mut Vec<String>,
) -> Option<String> {
    match read_registry_value(key, value_name) {
        Ok(value) => value,
        Err(err) => {
            warnings.push(err);
            None
        }
    }
}

#[cfg(windows)]
fn capture_enrollment_secret(
    key: &winreg::RegKey,
    writable: bool,
    warnings: &mut Vec<String>,
) -> Option<String> {
    let protected_secret =
        capture_registry_value(key, REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE, warnings);
    let legacy_secret = capture_registry_value(key, REGISTRY_ENROLLMENT_SECRET_VALUE, warnings);

    if let Some(protected_secret) = protected_secret {
        match decrypt_enrollment_secret(&protected_secret) {
            Ok(secret) => {
                if legacy_secret.is_some() && writable {
                    if let Err(err) = delete_registry_value(key, REGISTRY_ENROLLMENT_SECRET_VALUE) {
                        warnings.push(format!(
                            "{err}; keeping EnrollmentSecretProtected and leaving the legacy plaintext value in place"
                        ));
                    }
                }
                return Some(secret);
            }
            Err(err) => warnings.push(format!(
                "{err}; falling back to the legacy registry value if it is still present"
            )),
        }
    }

    let Some(legacy_secret) = legacy_secret else {
        return None;
    };

    if writable {
        match protect_enrollment_secret(&legacy_secret) {
            Ok(protected_secret) => {
                if let Err(err) = write_registry_value(
                    key,
                    REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE,
                    &protected_secret,
                ) {
                    warnings.push(format!(
                        "{err}; leaving {}\\{} in plaintext until migration succeeds",
                        REGISTRY_PATH, REGISTRY_ENROLLMENT_SECRET_VALUE
                    ));
                } else if let Err(err) =
                    delete_registry_value(key, REGISTRY_ENROLLMENT_SECRET_VALUE)
                {
                    warnings.push(format!(
                        "{err}; a protected copy was written but the legacy plaintext value could not be removed"
                    ));
                }
            }
            Err(err) => warnings.push(format!(
                "{err}; leaving {}\\{} in plaintext until migration succeeds",
                REGISTRY_PATH, REGISTRY_ENROLLMENT_SECRET_VALUE
            )),
        }
    } else {
        warnings.push(format!(
            "opened {REGISTRY_PATH} read-only; {}\\{} remains plaintext until the service can migrate it to DPAPI-protected storage",
            REGISTRY_PATH, REGISTRY_ENROLLMENT_SECRET_VALUE
        ));
    }

    Some(legacy_secret)
}

#[cfg(windows)]
fn read_registry_value_list(
    key: &winreg::RegKey,
    value_names: &[&str],
) -> Result<Option<String>, String> {
    for value_name in value_names {
        if let Some(value) = read_registry_value(key, value_name)? {
            return Ok(Some(value));
        }
    }
    Ok(None)
}

#[cfg(windows)]
fn read_registry_value(key: &winreg::RegKey, value_name: &str) -> Result<Option<String>, String> {
    match key.get_value::<String, _>(value_name) {
        Ok(value) if !value.trim().is_empty() => Ok(Some(value.trim().to_owned())),
        Ok(_) => Ok(None),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!(
            "failed to read registry value {}\\{}: {err}",
            REGISTRY_PATH, value_name
        )),
    }
}

#[cfg(windows)]
fn write_registry_value(key: &winreg::RegKey, value_name: &str, value: &str) -> Result<(), String> {
    key.set_value(value_name, &value).map_err(|err| {
        format!(
            "failed to write registry value {}\\{}: {err}",
            REGISTRY_PATH, value_name
        )
    })
}

#[cfg(windows)]
fn delete_registry_value(key: &winreg::RegKey, value_name: &str) -> Result<(), String> {
    match key.delete_value(value_name) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(format!(
            "failed to delete registry value {}\\{}: {err}",
            REGISTRY_PATH, value_name
        )),
    }
}

#[cfg(windows)]
fn protect_enrollment_secret(secret: &str) -> Result<String, String> {
    let protected = protect_with_dpapi(secret.as_bytes())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(protected))
}

#[cfg(windows)]
fn decrypt_enrollment_secret(encoded: &str) -> Result<String, String> {
    let protected = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|err| {
            format!(
                "failed to decode registry value {}\\{} as base64: {err}",
                REGISTRY_PATH, REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE
            )
        })?;
    let secret = unprotect_with_dpapi(&protected)?;
    String::from_utf8(secret).map_err(|err| {
        format!(
            "failed to decode registry value {}\\{} as UTF-8: {err}",
            REGISTRY_PATH, REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE
        )
    })
}

#[cfg(windows)]
fn protect_with_dpapi(secret: &[u8]) -> Result<Vec<u8>, String> {
    use std::ptr::{null, null_mut};
    use std::slice;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_LOCAL_MACHINE, CryptProtectData,
    };

    let mut input = CRYPT_INTEGER_BLOB {
        cbData: secret
            .len()
            .try_into()
            .map_err(|_| "enrollment secret is too large to protect with DPAPI".to_owned())?,
        pbData: secret.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: null_mut(),
    };

    unsafe {
        let result = CryptProtectData(
            &mut input,
            null(),
            null(),
            null_mut(),
            null(),
            CRYPTPROTECT_LOCAL_MACHINE,
            &mut output,
        );
        if result == 0 || output.pbData.is_null() {
            return Err(format!(
                "CryptProtectData failed for registry value {}\\{}: {}",
                REGISTRY_PATH,
                REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE,
                std::io::Error::last_os_error()
            ));
        }

        let protected = slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        let _ = LocalFree(output.pbData.cast());
        Ok(protected)
    }
}

#[cfg(windows)]
fn unprotect_with_dpapi(protected: &[u8]) -> Result<Vec<u8>, String> {
    use std::ptr::{null, null_mut};
    use std::slice;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CRYPT_INTEGER_BLOB, CryptUnprotectData};

    let mut input = CRYPT_INTEGER_BLOB {
        cbData: protected
            .len()
            .try_into()
            .map_err(|_| "protected enrollment secret is too large to decrypt".to_owned())?,
        pbData: protected.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: null_mut(),
    };

    unsafe {
        let result = CryptUnprotectData(
            &mut input,
            null_mut(),
            null(),
            null_mut(),
            null(),
            0,
            &mut output,
        );
        if result == 0 || output.pbData.is_null() {
            return Err(format!(
                "CryptUnprotectData failed for registry value {}\\{}: {}",
                REGISTRY_PATH,
                REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE,
                std::io::Error::last_os_error()
            ));
        }

        let secret = slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        let _ = LocalFree(output.pbData.cast());
        Ok(secret)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_prefers_later_sources() {
        let mut merged = RawServiceConfig {
            server_url: Some("https://file.example/scep".to_owned()),
            client_uid: Some("file-client".to_owned()),
            poll_interval: Some("30m".to_owned()),
            ..RawServiceConfig::default()
        };
        merged.merge(RawServiceConfig {
            client_uid: Some("registry-client".to_owned()),
            log_level: Some("debug".to_owned()),
            ..RawServiceConfig::default()
        });

        let config = build_service_config(
            merged,
            vec![ConfigSource::File, ConfigSource::Registry],
            Vec::new(),
        );

        assert_eq!(
            config.server_url.as_deref(),
            Some("https://file.example/scep")
        );
        assert_eq!(config.client_uid.as_deref(), Some("registry-client"));
        assert_eq!(config.log_level, "debug");
        assert_eq!(config.poll_interval, Duration::from_secs(30 * 60));
    }

    #[test]
    fn initial_enrollment_requires_bootstrap_secret() {
        let config = ServiceConfig {
            server_url: Some("https://example.invalid/scep".to_owned()),
            client_uid: Some("client-001".to_owned()),
            device_id: Some("device-001".to_owned()),
            ..ServiceConfig::default()
        };

        let renewal = config.renewal_settings().expect("renewal settings");
        assert_eq!(renewal.device_id, "device-001");
        assert_eq!(
            config.initial_enrollment().expect_err("missing secret"),
            vec![RequiredField::EnrollmentSecret]
        );
    }

    #[test]
    fn invalid_duration_and_log_level_fall_back_to_defaults() {
        let config = build_service_config(
            RawServiceConfig {
                poll_interval: Some("later".to_owned()),
                renew_before: Some("12w".to_owned()),
                log_level: Some("verbose".to_owned()),
                ..RawServiceConfig::default()
            },
            vec![ConfigSource::File],
            Vec::new(),
        );

        assert_eq!(config.poll_interval, DEFAULT_POLL_INTERVAL);
        assert_eq!(config.renew_before, DEFAULT_RENEW_BEFORE);
        assert_eq!(config.log_level, DEFAULT_LOG_LEVEL);
        assert_eq!(config.warnings.len(), 3);
    }

    #[test]
    fn device_id_is_normalized() {
        let config = build_service_config(
            RawServiceConfig {
                device_id: Some("  DEVICE-ABC  ".to_owned()),
                ..RawServiceConfig::default()
            },
            vec![ConfigSource::Registry],
            Vec::new(),
        );

        assert_eq!(config.device_id.as_deref(), Some("device-abc"));
    }
}
