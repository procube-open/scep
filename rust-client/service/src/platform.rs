use crate::config::{EnrollmentSettings, RenewalSettings};
#[cfg(windows)]
use crate::windows_paths;
use base64::Engine;
#[cfg(windows)]
use rsa::pkcs8::EncodePublicKey;
#[cfg(windows)]
use rsa::{BigUint, RsaPublicKey};
use serde::{Deserialize, Serialize};
#[cfg(windows)]
use std::fs;
use std::io::Write;
use std::path::Path;
#[cfg(windows)]
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::ptr::null_mut;
#[cfg(windows)]
use windows_sys::Win32::Security::Cryptography::{
    NCryptCreatePersistedKey, NCryptExportKey, NCryptFinalizeKey, NCryptFreeObject, NCryptOpenKey,
    NCryptOpenStorageProvider, NCryptSetProperty,
};

const MACHINE_STORE_PATH: &str = r"LocalMachine\My";
const TPM_KEY_PROVIDER: &str = "Microsoft Platform Crypto Provider";
const DEFAULT_KEY_ALGORITHM: &str = "rsa-2048";
const CANONICAL_ATTESTATION_FORMAT: &str = "tpm2-windows-v1";
const PLACEHOLDER_ATTESTATION_FORMAT_INITIAL: &str = "tpm2-windows-v1-placeholder-initial";
const PLACEHOLDER_ATTESTATION_FORMAT_RENEWAL: &str = "tpm2-windows-v1-placeholder-renewal";

#[cfg(windows)]
const NCRYPT_MACHINE_KEY_FLAG_VALUE: u32 = 0x20;
#[cfg(windows)]
const NCRYPT_ALLOW_DECRYPT_FLAG_VALUE: u32 = 0x1;
#[cfg(windows)]
const NCRYPT_ALLOW_SIGNING_FLAG_VALUE: u32 = 0x2;
#[cfg(windows)]
const NTE_BAD_KEYSET_STATUS: i32 = -2146893802;
#[cfg(windows)]
const BCRYPT_RSAPUBLIC_MAGIC_VALUE: u32 = 0x3141_5352;

#[cfg(windows)]
const REGISTRY_PATH: &str = r"SOFTWARE\MyTunnelApp";
#[cfg(windows)]
const REGISTRY_ENROLLMENT_SECRET_VALUE: &str = "EnrollmentSecret";
#[cfg(windows)]
const REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE: &str = "EnrollmentSecretProtected";

type NowFn = dyn Fn() -> SystemTime + Send + Sync;
type StageSecretFn =
    dyn Fn(&EnrollmentSettings) -> Result<StagedEnrollmentSecret, PlatformError> + Send + Sync;
type ClearSecretFn = dyn Fn(&StagedEnrollmentSecret) -> Result<(), PlatformError> + Send + Sync;
type EnsureMachineKeyFn = dyn Fn(&EnrollmentSettings, &StagedEnrollmentSecret) -> Result<TpmKeyHandle, PlatformError>
    + Send
    + Sync;
type ProbeCurrentCertificateFn = dyn Fn(&RenewalSettings, Duration, Duration) -> Result<CertificateInventory, PlatformError>
    + Send
    + Sync;
type ResolveExpectedDeviceIdentityFn =
    dyn Fn(&str) -> Result<ResolvedDeviceIdentity, PlatformError> + Send + Sync;
type InstallIssuedCertificateFn =
    dyn Fn(&PendingEnrollment, &[u8]) -> Result<InstalledCertificate, PlatformError> + Send + Sync;
type InstallRenewedCertificateFn =
    dyn Fn(&RenewalContext, &[u8]) -> Result<InstalledCertificate, PlatformError> + Send + Sync;
type FetchInitialNonceFn =
    dyn Fn(&EnrollmentSettings) -> Result<AttestationNonce, PlatformError> + Send + Sync;
type BuildInitialAttestationFn = dyn Fn(&PendingEnrollment, &AttestationNonce) -> Result<AttestationPayload, PlatformError>
    + Send
    + Sync;
type SubmitInitialScepFn = dyn Fn(PreparedInitialEnrollment) -> Result<IssuedCertificateArtifact, PlatformError>
    + Send
    + Sync;
type FetchRenewalNonceFn =
    dyn Fn(&RenewalContext) -> Result<AttestationNonce, PlatformError> + Send + Sync;
type BuildRenewalAttestationFn = dyn Fn(
        &RenewalContext,
        &TpmKeyHandle,
        &AttestationNonce,
    ) -> Result<AttestationPayload, PlatformError>
    + Send
    + Sync;
type SubmitRenewalScepFn =
    dyn Fn(PreparedRenewal) -> Result<IssuedCertificateArtifact, PlatformError> + Send + Sync;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlatformErrorKind {
    NotImplemented,
    Temporary,
    Permanent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlatformErrorContext {
    DeviceIdentityMismatch {
        expected_device_id: String,
        current_device_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformError {
    pub kind: PlatformErrorKind,
    pub component: &'static str,
    pub message: String,
    pub context: Option<PlatformErrorContext>,
}

impl PlatformError {
    #[cfg(not(windows))]
    pub fn not_implemented(component: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::NotImplemented,
            component,
            message: message.into(),
            context: None,
        }
    }

    pub fn temporary(component: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::Temporary,
            component,
            message: message.into(),
            context: None,
        }
    }

    pub fn permanent(component: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind: PlatformErrorKind::Permanent,
            component,
            message: message.into(),
            context: None,
        }
    }

    pub fn with_device_identity_mismatch(
        component: &'static str,
        expected_device_id: impl Into<String>,
        current_device_id: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            kind: PlatformErrorKind::Permanent,
            component,
            message: message.into(),
            context: Some(PlatformErrorContext::DeviceIdentityMismatch {
                expected_device_id: expected_device_id.into(),
                current_device_id: current_device_id.into(),
            }),
        }
    }

    pub fn is_not_implemented(&self) -> bool {
        self.kind == PlatformErrorKind::NotImplemented
    }

    pub fn device_identity_mismatch_details(&self) -> Option<(&str, &str)> {
        match &self.context {
            Some(PlatformErrorContext::DeviceIdentityMismatch {
                expected_device_id,
                current_device_id,
            }) => Some((expected_device_id.as_str(), current_device_id.as_str())),
            None => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnrollmentSecretSource {
    InlineConfig,
}

impl EnrollmentSecretSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InlineConfig => "inline-config",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagedEnrollmentSecret {
    pub source: EnrollmentSecretSource,
    pub remove_after_issue: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyMaterialState {
    Planned,
    Existing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyReusePolicy {
    SameKey,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TpmKeyHandle {
    pub provider: &'static str,
    pub algorithm: &'static str,
    pub key_name_hint: String,
    pub material_state: KeyMaterialState,
    pub reuse_policy: KeyReusePolicy,
    pub public_key_spki_b64: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingEnrollment {
    pub plan: EnrollmentSettings,
    pub secret: StagedEnrollmentSecret,
    pub key: TpmKeyHandle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledCertificate {
    pub store_path: &'static str,
    pub thumbprint: Option<String>,
    pub key_name_hint: Option<String>,
    pub not_before: Option<SystemTime>,
    pub not_after: Option<SystemTime>,
}

impl InstalledCertificate {
    pub fn effective_renew_before(
        &self,
        renew_before: Duration,
        poll_interval: Duration,
    ) -> Duration {
        let Some(not_before) = self.not_before else {
            return renew_before;
        };
        let Some(not_after) = self.not_after else {
            return renew_before;
        };
        let Ok(lifetime) = not_after.duration_since(not_before) else {
            return renew_before;
        };
        let latest_safe = lifetime.checked_sub(poll_interval).unwrap_or_default();
        renew_before.min(latest_safe)
    }

    pub fn renewal_due_at(
        &self,
        renew_before: Duration,
        poll_interval: Duration,
    ) -> Option<SystemTime> {
        let not_after = self.not_after?;
        let effective_renew_before = self.effective_renew_before(renew_before, poll_interval);
        Some(
            not_after
                .checked_sub(effective_renew_before)
                .unwrap_or(not_after),
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenewalContext {
    pub plan: RenewalSettings,
    pub certificate: InstalledCertificate,
}

#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CertificateInventory {
    Missing,
    Active(InstalledCertificate),
    RenewalDue(RenewalContext),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttestationNonce {
    pub endpoint: String,
    pub value: String,
    pub expires_at: Option<String>,
    pub device_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttestationPayload {
    pub format: String,
    pub encoded: String,
    pub nonce: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedInitialEnrollment {
    pub pending: PendingEnrollment,
    pub nonce: AttestationNonce,
    pub attestation: AttestationPayload,
    pub challenge_password: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenewalAuthorization {
    ExistingCertificate {
        store_path: &'static str,
        thumbprint: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedRenewal {
    pub context: RenewalContext,
    pub key: TpmKeyHandle,
    pub nonce: AttestationNonce,
    pub attestation: AttestationPayload,
    pub authorization: RenewalAuthorization,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssuedCertificateArtifact {
    pub certificate_der: Vec<u8>,
    pub transport: &'static str,
}

#[derive(Clone, Default)]
pub struct ServicePlatform {
    pub clock: PlatformClock,
    pub secrets: SecretLifecycle,
    pub tpm_keys: TpmKeyManager,
    pub machine_store: MachineCertificateStore,
    pub device_identity: DeviceIdentityProbe,
    pub renewal: RenewalProcessor,
}

#[derive(Clone, Default)]
pub struct PlatformClock {
    now_override: Option<Arc<NowFn>>,
}

impl PlatformClock {
    pub fn now(&self) -> SystemTime {
        self.now_override
            .as_ref()
            .map(|now| now())
            .unwrap_or_else(SystemTime::now)
    }

    #[cfg(test)]
    pub fn with_now<F>(mut self, now: F) -> Self
    where
        F: Fn() -> SystemTime + Send + Sync + 'static,
    {
        self.now_override = Some(Arc::new(now));
        self
    }
}

#[derive(Clone, Default)]
pub struct SecretLifecycle {
    stage_override: Option<Arc<StageSecretFn>>,
    clear_override: Option<Arc<ClearSecretFn>>,
}

impl SecretLifecycle {
    pub fn stage_enrollment_secret(
        &self,
        plan: &EnrollmentSettings,
    ) -> Result<StagedEnrollmentSecret, PlatformError> {
        if let Some(stage) = &self.stage_override {
            return stage(plan);
        }

        default_stage_enrollment_secret(plan)
    }

    pub fn clear_after_success(
        &self,
        secret: &StagedEnrollmentSecret,
    ) -> Result<(), PlatformError> {
        if let Some(clear) = &self.clear_override {
            return clear(secret);
        }

        default_clear_after_success(secret)
    }

    #[cfg(test)]
    pub fn with_clear_after_success<F>(mut self, clear: F) -> Self
    where
        F: Fn(&StagedEnrollmentSecret) -> Result<(), PlatformError> + Send + Sync + 'static,
    {
        self.clear_override = Some(Arc::new(clear));
        self
    }
}

#[derive(Clone, Default)]
pub struct TpmKeyManager {
    ensure_override: Option<Arc<EnsureMachineKeyFn>>,
}

impl TpmKeyManager {
    pub fn ensure_machine_key(
        &self,
        plan: &EnrollmentSettings,
        secret: &StagedEnrollmentSecret,
    ) -> Result<TpmKeyHandle, PlatformError> {
        if let Some(ensure) = &self.ensure_override {
            return ensure(plan, secret);
        }

        default_ensure_machine_key(plan, secret)
    }
}

#[derive(Clone, Default)]
pub struct MachineCertificateStore {
    probe_override: Option<Arc<ProbeCurrentCertificateFn>>,
    install_issued_override: Option<Arc<InstallIssuedCertificateFn>>,
    install_renewed_override: Option<Arc<InstallRenewedCertificateFn>>,
}

#[derive(Clone, Default)]
pub struct DeviceIdentityProbe {
    resolve_override: Option<Arc<ResolveExpectedDeviceIdentityFn>>,
}

impl DeviceIdentityProbe {
    pub fn resolve_expected_device_identity(
        &self,
        expected_device_id: &str,
    ) -> Result<ResolvedDeviceIdentity, PlatformError> {
        if let Some(resolve) = &self.resolve_override {
            return resolve(expected_device_id);
        }

        resolve_expected_device_identity(expected_device_id)
    }

    #[cfg(test)]
    pub fn with_resolve_expected_device_identity<F>(mut self, resolve: F) -> Self
    where
        F: Fn(&str) -> Result<ResolvedDeviceIdentity, PlatformError> + Send + Sync + 'static,
    {
        self.resolve_override = Some(Arc::new(resolve));
        self
    }
}

impl MachineCertificateStore {
    pub fn probe_current_certificate(
        &self,
        plan: &RenewalSettings,
        renew_before: Duration,
        poll_interval: Duration,
    ) -> Result<CertificateInventory, PlatformError> {
        if let Some(probe) = &self.probe_override {
            return probe(plan, renew_before, poll_interval);
        }

        default_probe_current_certificate(plan, renew_before, poll_interval)
    }

    pub fn install_issued_certificate(
        &self,
        pending: &PendingEnrollment,
        certificate_der: &[u8],
    ) -> Result<InstalledCertificate, PlatformError> {
        if let Some(install) = &self.install_issued_override {
            return install(pending, certificate_der);
        }

        default_install_issued_certificate(pending, certificate_der)
    }

    pub fn install_renewed_certificate(
        &self,
        context: &RenewalContext,
        certificate_der: &[u8],
    ) -> Result<InstalledCertificate, PlatformError> {
        if let Some(install) = &self.install_renewed_override {
            return install(context, certificate_der);
        }

        default_install_renewed_certificate(context, certificate_der)
    }

    #[cfg(test)]
    pub fn with_probe_current_certificate<F>(mut self, probe: F) -> Self
    where
        F: Fn(&RenewalSettings, Duration, Duration) -> Result<CertificateInventory, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.probe_override = Some(Arc::new(probe));
        self
    }

    #[cfg(test)]
    pub fn with_install_issued_certificate<F>(mut self, install: F) -> Self
    where
        F: Fn(&PendingEnrollment, &[u8]) -> Result<InstalledCertificate, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.install_issued_override = Some(Arc::new(install));
        self
    }

    #[cfg(test)]
    pub fn with_install_renewed_certificate<F>(mut self, install: F) -> Self
    where
        F: Fn(&RenewalContext, &[u8]) -> Result<InstalledCertificate, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.install_renewed_override = Some(Arc::new(install));
        self
    }
}

#[derive(Clone, Default)]
pub struct RenewalProcessor {
    fetch_initial_nonce_override: Option<Arc<FetchInitialNonceFn>>,
    build_initial_attestation_override: Option<Arc<BuildInitialAttestationFn>>,
    submit_initial_scep_override: Option<Arc<SubmitInitialScepFn>>,
    fetch_renewal_nonce_override: Option<Arc<FetchRenewalNonceFn>>,
    build_renewal_attestation_override: Option<Arc<BuildRenewalAttestationFn>>,
    submit_renewal_scep_override: Option<Arc<SubmitRenewalScepFn>>,
}

impl RenewalProcessor {
    pub fn submit_initial_enrollment(
        &self,
        pending: PendingEnrollment,
    ) -> Result<IssuedCertificateArtifact, PlatformError> {
        let nonce = if let Some(fetch) = &self.fetch_initial_nonce_override {
            fetch(&pending.plan)?
        } else {
            default_fetch_initial_nonce(&pending.plan)?
        };

        let attestation = if let Some(build) = &self.build_initial_attestation_override {
            build(&pending, &nonce)?
        } else {
            default_build_initial_attestation(&pending, &nonce)?
        };

        let request = PreparedInitialEnrollment {
            challenge_password: build_initial_challenge_password(&pending.plan),
            pending,
            nonce,
            attestation,
        };

        if let Some(submit) = &self.submit_initial_scep_override {
            return submit(request);
        }

        default_submit_initial_scep(request)
    }

    pub fn renew_existing_certificate(
        &self,
        context: RenewalContext,
    ) -> Result<IssuedCertificateArtifact, PlatformError> {
        let key = same_key_handle_for_renewal(&context)?;
        let nonce = if let Some(fetch) = &self.fetch_renewal_nonce_override {
            fetch(&context)?
        } else {
            default_fetch_renewal_nonce(&context)?
        };

        let attestation = if let Some(build) = &self.build_renewal_attestation_override {
            build(&context, &key, &nonce)?
        } else {
            default_build_renewal_attestation(&context, &key, &nonce)?
        };

        let request = PreparedRenewal {
            authorization: RenewalAuthorization::ExistingCertificate {
                store_path: context.certificate.store_path,
                thumbprint: context.certificate.thumbprint.clone(),
            },
            context,
            key,
            nonce,
            attestation,
        };

        if let Some(submit) = &self.submit_renewal_scep_override {
            return submit(request);
        }

        default_submit_renewal_scep(request)
    }

    #[cfg(test)]
    pub fn with_fetch_initial_nonce<F>(mut self, fetch: F) -> Self
    where
        F: Fn(&EnrollmentSettings) -> Result<AttestationNonce, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.fetch_initial_nonce_override = Some(Arc::new(fetch));
        self
    }

    #[cfg(test)]
    pub fn with_build_initial_attestation<F>(mut self, build: F) -> Self
    where
        F: Fn(&PendingEnrollment, &AttestationNonce) -> Result<AttestationPayload, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.build_initial_attestation_override = Some(Arc::new(build));
        self
    }

    #[cfg(test)]
    pub fn with_submit_initial_scep<F>(mut self, submit: F) -> Self
    where
        F: Fn(PreparedInitialEnrollment) -> Result<IssuedCertificateArtifact, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.submit_initial_scep_override = Some(Arc::new(submit));
        self
    }

    #[cfg(test)]
    pub fn with_fetch_renewal_nonce<F>(mut self, fetch: F) -> Self
    where
        F: Fn(&RenewalContext) -> Result<AttestationNonce, PlatformError> + Send + Sync + 'static,
    {
        self.fetch_renewal_nonce_override = Some(Arc::new(fetch));
        self
    }

    #[cfg(test)]
    pub fn with_build_renewal_attestation<F>(mut self, build: F) -> Self
    where
        F: Fn(
                &RenewalContext,
                &TpmKeyHandle,
                &AttestationNonce,
            ) -> Result<AttestationPayload, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.build_renewal_attestation_override = Some(Arc::new(build));
        self
    }

    #[cfg(test)]
    pub fn with_submit_renewal_scep<F>(mut self, submit: F) -> Self
    where
        F: Fn(PreparedRenewal) -> Result<IssuedCertificateArtifact, PlatformError>
            + Send
            + Sync
            + 'static,
    {
        self.submit_renewal_scep_override = Some(Arc::new(submit));
        self
    }
}

fn default_stage_enrollment_secret(
    plan: &EnrollmentSettings,
) -> Result<StagedEnrollmentSecret, PlatformError> {
    if plan.enrollment_secret.trim().is_empty() {
        return Err(PlatformError::permanent(
            "dpapi-secret-lifecycle",
            "enrollment_secret is empty after configuration validation",
        ));
    }

    Ok(StagedEnrollmentSecret {
        source: EnrollmentSecretSource::InlineConfig,
        remove_after_issue: true,
    })
}

#[cfg(windows)]
fn default_clear_after_success(secret: &StagedEnrollmentSecret) -> Result<(), PlatformError> {
    use std::io::ErrorKind;
    use winreg::RegKey;
    use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_SET_VALUE};

    if !secret.remove_after_issue {
        return Ok(());
    }

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = hklm
        .open_subkey_with_flags(REGISTRY_PATH, KEY_READ | KEY_SET_VALUE)
        .map_err(|err| match err.kind() {
            ErrorKind::NotFound => PlatformError::permanent(
                "dpapi-secret-lifecycle",
                format!(
                    "registry key {REGISTRY_PATH} is missing; the bootstrap secret cannot be removed after first issuance"
                ),
            ),
            ErrorKind::PermissionDenied => PlatformError::permanent(
                "dpapi-secret-lifecycle",
                format!(
                    "registry key {REGISTRY_PATH} is not writable; LocalService may need explicit ACLs before bootstrap secrets can be removed"
                ),
            ),
            _ => PlatformError::temporary(
                "dpapi-secret-lifecycle",
                format!("failed to open registry key {REGISTRY_PATH} for cleanup: {err}"),
            ),
        })?;

    delete_registry_value(&key, REGISTRY_ENROLLMENT_SECRET_PROTECTED_VALUE)?;
    delete_registry_value(&key, REGISTRY_ENROLLMENT_SECRET_VALUE)?;

    Ok(())
}

#[cfg(not(windows))]
fn default_clear_after_success(_secret: &StagedEnrollmentSecret) -> Result<(), PlatformError> {
    Err(PlatformError::not_implemented(
        "dpapi-secret-lifecycle",
        "post-issuance enrollment secret cleanup is only implemented for Windows registry storage",
    ))
}

fn default_ensure_machine_key(
    plan: &EnrollmentSettings,
    _secret: &StagedEnrollmentSecret,
) -> Result<TpmKeyHandle, PlatformError> {
    #[cfg(windows)]
    {
        return ensure_windows_managed_key(plan);
    }

    #[cfg(not(windows))]
    {
        Ok(TpmKeyHandle {
            provider: TPM_KEY_PROVIDER,
            algorithm: DEFAULT_KEY_ALGORITHM,
            key_name_hint: format!("{}-{}", plan.client_uid, plan.expected_device_id),
            material_state: KeyMaterialState::Planned,
            reuse_policy: KeyReusePolicy::SameKey,
            public_key_spki_b64: None,
        })
    }
}

fn default_probe_current_certificate(
    plan: &RenewalSettings,
    renew_before: Duration,
    poll_interval: Duration,
) -> Result<CertificateInventory, PlatformError> {
    #[cfg(windows)]
    {
        return probe_windows_machine_store(plan, renew_before, poll_interval);
    }

    #[cfg(not(windows))]
    {
        let _ = (plan, renew_before, poll_interval);
        Err(PlatformError::not_implemented(
            "machine-store",
            format!(
                "{MACHINE_STORE_PATH} certificate discovery and renewal window inspection are not wired yet"
            ),
        ))
    }
}

fn default_install_issued_certificate(
    pending: &PendingEnrollment,
    certificate_der: &[u8],
) -> Result<InstalledCertificate, PlatformError> {
    #[cfg(windows)]
    {
        return install_windows_issued_certificate(pending, certificate_der);
    }

    #[cfg(not(windows))]
    {
        let _ = certificate_der;
        Err(PlatformError::not_implemented(
            "machine-store",
            format!(
                "{MACHINE_STORE_PATH} certificate installation is not wired yet for key {}",
                pending.key.key_name_hint
            ),
        ))
    }
}

fn default_install_renewed_certificate(
    context: &RenewalContext,
    certificate_der: &[u8],
) -> Result<InstalledCertificate, PlatformError> {
    #[cfg(windows)]
    {
        return install_windows_certificate_for_key(
            context
                .certificate
                .key_name_hint
                .as_deref()
                .ok_or_else(|| {
                    PlatformError::permanent(
                        "machine-store",
                        "renewal certificate installation requires an existing key association"
                            .to_owned(),
                    )
                })?,
            TPM_KEY_PROVIDER,
            certificate_der,
        );
    }

    #[cfg(not(windows))]
    {
        let _ = certificate_der;
        Err(PlatformError::not_implemented(
            "machine-store",
            format!(
                "{MACHINE_STORE_PATH} certificate replacement is not wired yet for same-key renewal on {}",
                context
                    .certificate
                    .key_name_hint
                    .as_deref()
                    .unwrap_or("<missing-key-reference>")
            ),
        ))
    }
}

fn default_fetch_initial_nonce(
    plan: &EnrollmentSettings,
) -> Result<AttestationNonce, PlatformError> {
    fetch_attestation_nonce(&plan.server_url, &plan.client_uid, &plan.expected_device_id)
}

fn default_fetch_renewal_nonce(
    context: &RenewalContext,
) -> Result<AttestationNonce, PlatformError> {
    fetch_attestation_nonce(
        &context.plan.server_url,
        &context.plan.client_uid,
        &context.plan.expected_device_id,
    )
}

fn default_build_initial_attestation(
    pending: &PendingEnrollment,
    nonce: &AttestationNonce,
) -> Result<AttestationPayload, PlatformError> {
    let key = key_with_public_spki(&pending.key)?;
    let attestation =
        build_placeholder_attestation(PLACEHOLDER_ATTESTATION_FORMAT_INITIAL, &key, nonce)?;

    #[cfg(windows)]
    {
        return finalize_windows_attestation_via_helper(
            &pending.plan.server_url,
            &pending.plan.client_uid,
            &pending.plan.expected_device_id,
            attestation,
            &key,
        );
    }

    #[cfg(not(windows))]
    {
        Ok(attestation)
    }
}

fn default_build_renewal_attestation(
    _context: &RenewalContext,
    key: &TpmKeyHandle,
    nonce: &AttestationNonce,
) -> Result<AttestationPayload, PlatformError> {
    let key = key_with_public_spki(key)?;
    let attestation =
        build_placeholder_attestation(PLACEHOLDER_ATTESTATION_FORMAT_RENEWAL, &key, nonce)?;

    #[cfg(windows)]
    {
        return finalize_windows_attestation_via_helper(
            &_context.plan.server_url,
            &_context.plan.client_uid,
            &_context.plan.expected_device_id,
            attestation,
            &key,
        );
    }

    #[cfg(not(windows))]
    {
        Ok(attestation)
    }
}

fn default_submit_initial_scep(
    request: PreparedInitialEnrollment,
) -> Result<IssuedCertificateArtifact, PlatformError> {
    #[cfg(windows)]
    {
        return submit_initial_scep_via_helper(request);
    }

    #[cfg(not(windows))]
    {
        Err(PlatformError::not_implemented(
            "scep-submission",
            format!(
                "CSR construction and SCEP PKIOperation submission are not wired yet for expected_device_id={} using reserved key {}; nonce {} from {} and attestation format {} were prepared",
                request.pending.plan.expected_device_id,
                request.pending.key.key_name_hint,
                request.nonce.value,
                request.nonce.endpoint,
                request.attestation.format
            ),
        ))
    }
}

#[cfg(windows)]
fn ensure_windows_managed_key(plan: &EnrollmentSettings) -> Result<TpmKeyHandle, PlatformError> {
    let dir = managed_dir_for_plan(plan);
    fs::create_dir_all(&dir).map_err(|err| {
        PlatformError::temporary(
            "key-management",
            format!(
                "failed to create managed key directory {}: {err}",
                dir.display()
            ),
        )
    })?;
    let key_name_hint = windows_paths::key_dir_name(&plan.client_uid, &plan.expected_device_id);
    let (material_state, public_key_spki_b64) = ensure_windows_persisted_key(&key_name_hint)?;

    Ok(TpmKeyHandle {
        provider: TPM_KEY_PROVIDER,
        algorithm: DEFAULT_KEY_ALGORITHM,
        key_name_hint,
        material_state,
        reuse_policy: KeyReusePolicy::SameKey,
        public_key_spki_b64: Some(public_key_spki_b64),
    })
}

#[cfg(windows)]
fn ensure_windows_persisted_key(
    key_name_hint: &str,
) -> Result<(KeyMaterialState, String), PlatformError> {
    let provider_name = wide_null(TPM_KEY_PROVIDER);
    let key_name = wide_null(key_name_hint);
    let rsa_algorithm = wide_null("RSA");
    let length_property = wide_null("Length");
    let key_usage_property = wide_null("Key Usage");

    let mut provider = 0usize;
    ncrypt_status(
        "key-management",
        unsafe { NCryptOpenStorageProvider(&mut provider, provider_name.as_ptr(), 0) },
        format!("failed to open NCrypt provider {TPM_KEY_PROVIDER}"),
    )?;

    let mut key = 0usize;
    let open_status = unsafe {
        NCryptOpenKey(
            provider,
            &mut key,
            key_name.as_ptr(),
            0,
            NCRYPT_MACHINE_KEY_FLAG_VALUE,
        )
    };

    let material_state = if open_status == 0 {
        KeyMaterialState::Existing
    } else if open_status == NTE_BAD_KEYSET_STATUS {
        ncrypt_status(
            "key-management",
            unsafe {
                NCryptCreatePersistedKey(
                    provider,
                    &mut key,
                    rsa_algorithm.as_ptr(),
                    key_name.as_ptr(),
                    0,
                    NCRYPT_MACHINE_KEY_FLAG_VALUE,
                )
            },
            format!("failed to create persisted TPM key {key_name_hint}"),
        )?;

        let length_bytes = 2048u32.to_le_bytes();
        ncrypt_status(
            "key-management",
            unsafe {
                NCryptSetProperty(
                    key,
                    length_property.as_ptr(),
                    length_bytes.as_ptr(),
                    length_bytes.len() as u32,
                    0,
                )
            },
            format!("failed to set key length for persisted TPM key {key_name_hint}"),
        )?;

        let usage_bytes =
            (NCRYPT_ALLOW_DECRYPT_FLAG_VALUE | NCRYPT_ALLOW_SIGNING_FLAG_VALUE).to_le_bytes();
        ncrypt_status(
            "key-management",
            unsafe {
                NCryptSetProperty(
                    key,
                    key_usage_property.as_ptr(),
                    usage_bytes.as_ptr(),
                    usage_bytes.len() as u32,
                    0,
                )
            },
            format!("failed to set key usage for persisted TPM key {key_name_hint}"),
        )?;

        ncrypt_status(
            "key-management",
            unsafe { NCryptFinalizeKey(key, 0) },
            format!("failed to finalize persisted TPM key {key_name_hint}"),
        )?;

        KeyMaterialState::Planned
    } else {
        unsafe {
            NCryptFreeObject(provider);
        }
        return Err(PlatformError::temporary(
            "key-management",
            format!(
                "failed to open persisted TPM key {}: 0x{:08x}",
                key_name_hint, open_status as u32
            ),
        ));
    };

    let public_key_spki_b64 = export_public_key_spki_b64(key)?;

    unsafe {
        NCryptFreeObject(key);
        NCryptFreeObject(provider);
    }

    Ok((material_state, public_key_spki_b64))
}

#[cfg(windows)]
fn encode_rsa_public_key_b64(public_key: &RsaPublicKey) -> Result<String, PlatformError> {
    let public_key_der = public_key.to_public_key_der().map_err(|err| {
        PlatformError::temporary(
            "key-management",
            format!("failed to encode public key for attestation: {err}"),
        )
    })?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(public_key_der.as_ref()))
}

#[cfg(windows)]
fn export_public_key_spki_b64(key: usize) -> Result<String, PlatformError> {
    let blob_type = wide_null("RSAPUBLICBLOB");
    let mut blob_len = 0u32;
    ncrypt_status(
        "key-management",
        unsafe {
            NCryptExportKey(
                key,
                0,
                blob_type.as_ptr(),
                null_mut(),
                null_mut(),
                0,
                &mut blob_len,
                0,
            )
        },
        "failed to measure persisted TPM public key blob".to_owned(),
    )?;

    let mut blob = vec![0u8; blob_len as usize];
    ncrypt_status(
        "key-management",
        unsafe {
            NCryptExportKey(
                key,
                0,
                blob_type.as_ptr(),
                null_mut(),
                blob.as_mut_ptr(),
                blob_len,
                &mut blob_len,
                0,
            )
        },
        "failed to export persisted TPM public key blob".to_owned(),
    )?;

    let public_key = parse_rsa_public_blob(&blob)?;
    encode_rsa_public_key_b64(&public_key)
}

#[cfg(windows)]
fn load_windows_persisted_key_public_spki_b64(
    key_name_hint: &str,
) -> Result<String, PlatformError> {
    let provider_name = wide_null(TPM_KEY_PROVIDER);
    let key_name = wide_null(key_name_hint);

    let mut provider = 0usize;
    ncrypt_status(
        "renewal-processing",
        unsafe { NCryptOpenStorageProvider(&mut provider, provider_name.as_ptr(), 0) },
        format!("failed to open NCrypt provider {TPM_KEY_PROVIDER}"),
    )?;

    let mut key = 0usize;
    let open_result = ncrypt_status(
        "renewal-processing",
        unsafe {
            NCryptOpenKey(
                provider,
                &mut key,
                key_name.as_ptr(),
                0,
                NCRYPT_MACHINE_KEY_FLAG_VALUE,
            )
        },
        format!("failed to open persisted TPM key {key_name_hint} for same-key renewal"),
    );
    if let Err(err) = open_result {
        unsafe {
            NCryptFreeObject(provider);
        }
        return Err(err);
    }

    let public_key_spki_b64 = export_public_key_spki_b64(key)?;

    unsafe {
        NCryptFreeObject(key);
        NCryptFreeObject(provider);
    }

    Ok(public_key_spki_b64)
}

#[cfg(windows)]
fn managed_dir_for_plan(plan: &EnrollmentSettings) -> PathBuf {
    windows_paths::managed_dir(&plan.client_uid, &plan.expected_device_id)
}

#[cfg(windows)]
fn managed_dir_for_key_name(key_name_hint: &str) -> PathBuf {
    Path::new(windows_paths::MANAGED_ROOT).join(key_name_hint)
}

#[cfg(windows)]
fn probe_windows_machine_store(
    plan: &RenewalSettings,
    renew_before: Duration,
    poll_interval: Duration,
) -> Result<CertificateInventory, PlatformError> {
    let managed_cert_path = windows_paths::cert_path(&windows_paths::managed_dir(
        &plan.client_uid,
        &plan.expected_device_id,
    ));
    let script = build_windows_machine_store_probe_script(
        &plan.server_url,
        &plan.client_uid,
        &managed_cert_path,
    );
    let output = run_windows_command(
        "machine-store",
        Command::new("powershell.exe")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg(script),
    )?;
    let value: serde_json::Value = serde_json::from_slice(&output).map_err(|err| {
        PlatformError::temporary(
            "machine-store",
            format!("failed to decode PowerShell store probe output: {err}"),
        )
    })?;
    if value
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("missing")
        == "missing"
    {
        return Ok(CertificateInventory::Missing);
    }

    let certificate = InstalledCertificate {
        store_path: MACHINE_STORE_PATH,
        thumbprint: value
            .get("Thumbprint")
            .and_then(|v| v.as_str())
            .map(|v| v.to_owned()),
        key_name_hint: Some(windows_paths::key_dir_name(
            &plan.client_uid,
            &plan.expected_device_id,
        )),
        not_before: parse_optional_unix_seconds(value.get("NotBeforeUnix")),
        not_after: parse_optional_unix_seconds(value.get("NotAfterUnix")),
    };
    let now = SystemTime::now();
    match certificate.renewal_due_at(renew_before, poll_interval) {
        Some(renewal_due_at) if renewal_due_at <= now => {
            Ok(CertificateInventory::RenewalDue(RenewalContext {
                plan: plan.clone(),
                certificate,
            }))
        }
        _ => Ok(CertificateInventory::Active(certificate)),
    }
}

#[cfg(any(windows, test))]
fn build_windows_machine_store_probe_script(
    server_url: &str,
    client_uid: &str,
    managed_cert_path: &Path,
) -> String {
    format!(
        r#"
$ErrorActionPreference = 'Stop'
$serverUrl = '{server_url}'
$managedCertPath = '{managed_cert_path}'
$managedCert = $null
$managedCertThumbprint = $null
$serverActiveThumbprint = $null
$serverActivePemText = $null
$cert = $null
function ConvertFrom-MyTunnelPemText {{
  param([Parameter(Mandatory = $true)][string]$PemText)
  $match = [regex]::Match($PemText, '-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----')
  if (-not $match.Success) {{
    throw 'PEM data does not contain a certificate body'
  }}
  $body = (($match.Groups['body'].Value -split "`r?`n") | Where-Object {{ $_ }}) -join ''
  if (-not $body) {{
    throw 'PEM data does not contain a certificate body'
  }}
  $bytes = [Convert]::FromBase64String($body)
  New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
}}
function Resolve-MyTunnelServerApiBaseUrl {{
  param([Parameter(Mandatory = $true)][string]$ServerUrl)
  $trimmed = $ServerUrl.TrimEnd('/')
  if ($trimmed -match '/scep$') {{
    return ($trimmed -replace '/scep$', '')
  }}
  $trimmed
}}
if (-not [string]::IsNullOrWhiteSpace($serverUrl)) {{
  try {{
    $serverBase = Resolve-MyTunnelServerApiBaseUrl -ServerUrl $serverUrl
    $certListEndpoint = "{{0}}/api/cert/list/{{1}}" -f $serverBase, [System.Uri]::EscapeDataString('{client_uid}')
    $serverCerts = Invoke-RestMethod -Method Get -Uri $certListEndpoint
    $activeCerts = @(
      $serverCerts |
        Where-Object {{
          $null -ne $_ -and
          $_.PSObject.Properties.Match('status').Count -gt 0 -and
          [string]$_.status -eq 'V'
        }}
    )
    if ($activeCerts.Count -gt 0) {{
      $serverActive = @(
        $activeCerts |
          Sort-Object -Property @(
            @{{
              Expression = {{
                if ([string]::IsNullOrWhiteSpace([string]$_.valid_till)) {{
                  [DateTime]::MinValue
                }} else {{
                  try {{
                    [DateTime]::Parse([string]$_.valid_till).ToUniversalTime()
                  }} catch {{
                    [DateTime]::MinValue
                  }}
                }}
              }}
            }},
            @{{
              Expression = {{
                try {{
                  [bigint]([string]$_.serial)
                }} catch {{
                  [bigint]0
                }}
              }}
            }}
          ) -Descending |
          Select-Object -First 1
      )
      if ($serverActive.Count -gt 0) {{
        if (
          $serverActive[0].PSObject.Properties.Match('cert_data').Count -gt 0 -and
          -not [string]::IsNullOrWhiteSpace([string]$serverActive[0].cert_data)
        ) {{
          try {{
            $serverActiveCert = ConvertFrom-MyTunnelPemText -PemText ([string]$serverActive[0].cert_data)
            $serverActiveThumbprint = $serverActiveCert.Thumbprint
            $serverActivePemBody = [Convert]::ToBase64String($serverActiveCert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
            $serverActivePemText = "-----BEGIN CERTIFICATE-----`r`n$($serverActivePemBody)`r`n-----END CERTIFICATE-----`r`n"
          }} catch {{
            $serverActiveThumbprint = $null
            $serverActivePemText = $null
          }}
        }}
      }}
    }}
  }} catch {{
    $serverActiveThumbprint = $null
    $serverActivePemText = $null
  }}
}}
if (Test-Path $managedCertPath) {{
  try {{
    $pem = Get-Content $managedCertPath -Raw
    $managedCert = ConvertFrom-MyTunnelPemText -PemText $pem
    $managedCertThumbprint = $managedCert.Thumbprint
  }} catch {{
    $managedCert = $null
    $managedCertThumbprint = $null
  }}
}}
if (-not [string]::IsNullOrWhiteSpace($serverActiveThumbprint)) {{
  $cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {{ $_.Thumbprint -eq $serverActiveThumbprint }} |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
  if (
    $null -eq $cert -and
    $null -ne $managedCert -and
    $managedCertThumbprint -eq $serverActiveThumbprint
  ) {{
    [Console]::Out.Write(($managedCert | Select-Object @{{n='status';e={{'present'}}}},Thumbprint,Subject,@{{n='NotBeforeUnix';e={{([DateTimeOffset]$_.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()}}}},@{{n='NotAfterUnix';e={{([DateTimeOffset]$_.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()}}}} | ConvertTo-Json -Compress))
    exit 0
  }}
  if ($null -eq $cert) {{
    if (-not [string]::IsNullOrWhiteSpace($serverActivePemText)) {{
      $managedCert = ConvertFrom-MyTunnelPemText -PemText $serverActivePemText
      $managedCertThumbprint = $managedCert.Thumbprint
      $managedCertDir = [System.IO.Path]::GetDirectoryName($managedCertPath)
      if (-not [string]::IsNullOrWhiteSpace($managedCertDir)) {{
        [System.IO.Directory]::CreateDirectory($managedCertDir) | Out-Null
      }}
      [System.IO.File]::WriteAllText($managedCertPath, $serverActivePemText, [System.Text.Encoding]::ASCII)
      [Console]::Out.Write(($managedCert | Select-Object @{{n='status';e={{'present'}}}},Thumbprint,Subject,@{{n='NotBeforeUnix';e={{([DateTimeOffset]$_.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()}}}},@{{n='NotAfterUnix';e={{([DateTimeOffset]$_.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()}}}} | ConvertTo-Json -Compress))
      exit 0
    }}
    [Console]::Out.Write('{{"status":"missing"}}')
    exit 0
  }}
}}
if ($null -eq $cert -and $null -ne $managedCertThumbprint) {{
  $cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {{ $_.Thumbprint -eq $managedCertThumbprint }} |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
}}
if ($null -eq $cert) {{
  $cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {{ $_.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -eq '{client_uid}' }} |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
}}
if ($null -eq $cert) {{
  [Console]::Out.Write('{{"status":"missing"}}')
  exit 0
}}
if ($managedCertThumbprint -ne $cert.Thumbprint) {{
  $managedCertDir = [System.IO.Path]::GetDirectoryName($managedCertPath)
  if (-not [string]::IsNullOrWhiteSpace($managedCertDir)) {{
    [System.IO.Directory]::CreateDirectory($managedCertDir) | Out-Null
  }}
  $pemBody = [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
  $pemText = "-----BEGIN CERTIFICATE-----`r`n$($pemBody)`r`n-----END CERTIFICATE-----`r`n"
  [System.IO.File]::WriteAllText($managedCertPath, $pemText, [System.Text.Encoding]::ASCII)
}}
[Console]::Out.Write(($cert | Select-Object @{{n='status';e={{'present'}}}},Thumbprint,Subject,@{{n='NotBeforeUnix';e={{([DateTimeOffset]$_.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()}}}},@{{n='NotAfterUnix';e={{([DateTimeOffset]$_.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()}}}} | ConvertTo-Json -Compress))
"#,
        server_url = escape_ps_single_quoted(server_url),
        managed_cert_path = escape_ps_single_quoted(&managed_cert_path.display().to_string()),
        client_uid = escape_ps_single_quoted(client_uid),
    )
}

#[cfg(windows)]
fn submit_initial_scep_via_helper(
    request: PreparedInitialEnrollment,
) -> Result<IssuedCertificateArtifact, PlatformError> {
    let dir = managed_dir_for_plan(&request.pending.plan);
    fs::create_dir_all(&dir).map_err(|err| {
        PlatformError::temporary(
            "scep-submission",
            format!(
                "failed to create enrollment directory {}: {err}",
                dir.display()
            ),
        )
    })?;
    let helper = bundled_helper_path("scepclient.exe")?;
    let helper_out = windows_paths::cert_path(&dir);
    let output = run_windows_command(
        "scep-submission",
        Command::new(helper)
            .arg("-out")
            .arg(&helper_out)
            .arg("-key-provider")
            .arg(request.pending.key.provider)
            .arg("-key-name")
            .arg(&request.pending.key.key_name_hint)
            .arg("-public-key-spki-b64")
            .arg(
                request
                    .pending
                    .key
                    .public_key_spki_b64
                    .as_deref()
                    .ok_or_else(|| {
                        PlatformError::permanent(
                            "scep-submission",
                            format!(
                                "TPM key {} is missing SubjectPublicKeyInfo required for attestation",
                                request.pending.key.key_name_hint
                            ),
                        )
                    })?,
            )
            .arg("-uid")
            .arg(&request.pending.plan.client_uid)
            .arg("-secret")
            .arg(&request.pending.plan.enrollment_secret)
            .arg("-server-url")
            .arg(&request.pending.plan.server_url)
            .arg("-attestation")
            .arg(&request.attestation.encoded),
    )?;
    let cert_path = windows_paths::cert_path(&dir);
    let cert_der = read_pem_certificate(&cert_path)?;
    let _ = output;
    Ok(IssuedCertificateArtifact {
        certificate_der: cert_der,
        transport: "bundled-scepclient",
    })
}

#[cfg(windows)]
fn install_windows_issued_certificate(
    pending: &PendingEnrollment,
    certificate_der: &[u8],
) -> Result<InstalledCertificate, PlatformError> {
    install_windows_certificate_for_key(
        &pending.key.key_name_hint,
        pending.key.provider,
        certificate_der,
    )
}

#[cfg(windows)]
fn install_windows_certificate_for_key(
    key_name_hint: &str,
    provider: &str,
    certificate_der: &[u8],
) -> Result<InstalledCertificate, PlatformError> {
    let dir = managed_dir_for_key_name(key_name_hint);
    fs::create_dir_all(&dir).map_err(|err| {
        PlatformError::temporary(
            "machine-store",
            format!(
                "failed to create managed cert directory {}: {err}",
                dir.display()
            ),
        )
    })?;
    let cert_path = windows_paths::cert_path(&dir);
    write_pem_certificate(&cert_path, certificate_der)?;
    let script = format!(
        r#"
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes('{cert_path}')
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
$provider = New-Object System.Security.Cryptography.CngProvider('{provider}')
$key = [System.Security.Cryptography.CngKey]::Open('{key_name_hint}', $provider, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)
$rsa = New-Object System.Security.Cryptography.RSACng($key)
$bound = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($cert, $rsa)
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$store.Add($bound)
$store.Close()
[Console]::Out.Write(($bound | Select-Object Thumbprint,Subject,@{{n='NotBeforeUnix';e={{([DateTimeOffset]$_.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()}}}},@{{n='NotAfterUnix';e={{([DateTimeOffset]$_.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()}}}} | ConvertTo-Json -Compress))
"#,
        cert_path = escape_ps_single_quoted(&cert_path.display().to_string()),
        provider = escape_ps_single_quoted(provider),
        key_name_hint = escape_ps_single_quoted(key_name_hint),
    );
    let output = run_windows_command(
        "machine-store",
        Command::new("powershell.exe")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg(script),
    )?;
    let value: serde_json::Value = serde_json::from_slice(&output).map_err(|err| {
        PlatformError::temporary(
            "machine-store",
            format!("failed to decode imported certificate metadata: {err}"),
        )
    })?;
    Ok(InstalledCertificate {
        store_path: MACHINE_STORE_PATH,
        thumbprint: value
            .get("Thumbprint")
            .and_then(|v| v.as_str())
            .map(|v| v.to_owned()),
        key_name_hint: Some(key_name_hint.to_owned()),
        not_before: parse_optional_unix_seconds(value.get("NotBeforeUnix")),
        not_after: parse_optional_unix_seconds(value.get("NotAfterUnix")),
    })
}

#[cfg(windows)]
fn parse_optional_unix_seconds(value: Option<&serde_json::Value>) -> Option<SystemTime> {
    let seconds = value.and_then(|raw| match raw {
        serde_json::Value::Number(number) => number.as_u64(),
        serde_json::Value::String(text) => text.parse::<u64>().ok(),
        _ => None,
    })?;
    Some(UNIX_EPOCH + Duration::from_secs(seconds))
}

#[cfg(windows)]
fn bundled_helper_path(name: &str) -> Result<PathBuf, PlatformError> {
    let exe = std::env::current_exe().map_err(|err| {
        PlatformError::temporary(
            "helper-discovery",
            format!("failed to resolve current executable path: {err}"),
        )
    })?;
    let dir = exe.parent().ok_or_else(|| {
        PlatformError::temporary(
            "helper-discovery",
            "service executable directory is missing",
        )
    })?;
    let helper = dir.join(name);
    if helper.exists() {
        Ok(helper)
    } else {
        Err(PlatformError::permanent(
            "helper-discovery",
            format!("required helper binary is missing: {}", helper.display()),
        ))
    }
}

#[cfg(windows)]
fn run_windows_command(
    component: &'static str,
    command: &mut Command,
) -> Result<Vec<u8>, PlatformError> {
    let output = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| {
            PlatformError::temporary(component, format!("failed to spawn helper command: {err}"))
        })?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    let combined = [stdout.as_str(), stderr.as_str()]
        .into_iter()
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    Err(PlatformError::temporary(
        component,
        if combined.is_empty() {
            format!("helper command failed with status {}", output.status)
        } else {
            combined
        },
    ))
}

#[cfg(windows)]
#[repr(C)]
struct BcryptRsaKeyBlobHeader {
    magic: u32,
    bit_length: u32,
    cb_public_exp: u32,
    cb_modulus: u32,
    cb_prime1: u32,
    cb_prime2: u32,
}

#[cfg(windows)]
fn parse_rsa_public_blob(blob: &[u8]) -> Result<RsaPublicKey, PlatformError> {
    if blob.len() < std::mem::size_of::<BcryptRsaKeyBlobHeader>() {
        return Err(PlatformError::permanent(
            "key-management",
            "persisted TPM public key blob was shorter than the RSA header".to_owned(),
        ));
    }

    let header = unsafe { &*(blob.as_ptr() as *const BcryptRsaKeyBlobHeader) };
    if header.magic != BCRYPT_RSAPUBLIC_MAGIC_VALUE {
        return Err(PlatformError::permanent(
            "key-management",
            format!(
                "persisted TPM public key blob had unexpected magic 0x{:08x}",
                header.magic
            ),
        ));
    }

    let exponent_offset = std::mem::size_of::<BcryptRsaKeyBlobHeader>();
    let modulus_offset = exponent_offset + header.cb_public_exp as usize;
    let modulus_end = modulus_offset + header.cb_modulus as usize;
    if blob.len() < modulus_end {
        return Err(PlatformError::permanent(
            "key-management",
            "persisted TPM public key blob was truncated".to_owned(),
        ));
    }

    let exponent = BigUint::from_bytes_be(&blob[exponent_offset..modulus_offset]);
    let modulus = BigUint::from_bytes_be(&blob[modulus_offset..modulus_end]);
    RsaPublicKey::new(modulus, exponent).map_err(|err| {
        PlatformError::permanent(
            "key-management",
            format!("failed to decode persisted TPM public key: {err}"),
        )
    })
}

#[cfg(windows)]
fn ncrypt_status(
    component: &'static str,
    status: i32,
    detail: String,
) -> Result<(), PlatformError> {
    if status == 0 {
        return Ok(());
    }

    Err(PlatformError::temporary(
        component,
        format!("{detail}: 0x{:08x}", status as u32),
    ))
}

#[cfg(windows)]
fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
fn write_pem_certificate(path: &Path, certificate_der: &[u8]) -> Result<(), PlatformError> {
    let body = base64::engine::general_purpose::STANDARD.encode(certificate_der);
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");
    fs::write(path, pem).map_err(|err| {
        PlatformError::temporary(
            "machine-store",
            format!("failed to write certificate PEM {}: {err}", path.display()),
        )
    })
}

#[cfg(windows)]
fn read_pem_certificate(path: &Path) -> Result<Vec<u8>, PlatformError> {
    let pem = fs::read_to_string(path).map_err(|err| {
        PlatformError::temporary(
            "scep-submission",
            format!(
                "failed to read issued certificate {}: {err}",
                path.display()
            ),
        )
    })?;
    let body: String = pem
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(body.as_bytes())
        .map_err(|err| {
            PlatformError::permanent(
                "scep-submission",
                format!(
                    "failed to decode issued certificate PEM {}: {err}",
                    path.display()
                ),
            )
        })
}

#[cfg(any(windows, test))]
fn escape_ps_single_quoted(value: &str) -> String {
    value.replace('\'', "''")
}

#[cfg(windows)]
fn submit_renewal_scep_via_helper(
    request: PreparedRenewal,
) -> Result<IssuedCertificateArtifact, PlatformError> {
    let key = key_with_public_spki(&request.key)?;
    let dir = managed_dir_for_key_name(&key.key_name_hint);
    fs::create_dir_all(&dir).map_err(|err| {
        PlatformError::temporary(
            "renewal-processing",
            format!(
                "failed to create renewal directory {}: {err}",
                dir.display()
            ),
        )
    })?;

    let cert_path = windows_paths::cert_path(&dir);
    if !cert_path.exists() {
        return Err(PlatformError::permanent(
            "renewal-processing",
            format!(
                "same-key renewal requires an existing managed certificate at {}",
                cert_path.display()
            ),
        ));
    }

    let helper = bundled_helper_path("scepclient.exe")?;
    let output = run_windows_command(
        "renewal-processing",
        Command::new(helper)
            .arg("-out")
            .arg(&cert_path)
            .arg("-key-provider")
            .arg(key.provider)
            .arg("-key-name")
            .arg(&key.key_name_hint)
            .arg("-public-key-spki-b64")
            .arg(key.public_key_spki_b64.as_deref().ok_or_else(|| {
                PlatformError::permanent(
                    "renewal-processing",
                    format!(
                        "TPM key {} is missing SubjectPublicKeyInfo required for renewal attestation",
                        key.key_name_hint
                    ),
                )
            })?)
            .arg("-uid")
            .arg(&request.context.plan.client_uid)
            .arg("-server-url")
            .arg(&request.context.plan.server_url)
            .arg("-attestation")
            .arg(&request.attestation.encoded),
    )?;
    let _ = output;

    let cert_der = read_pem_certificate(&cert_path)?;
    Ok(IssuedCertificateArtifact {
        certificate_der: cert_der,
        transport: "bundled-scepclient",
    })
}

fn default_submit_renewal_scep(
    request: PreparedRenewal,
) -> Result<IssuedCertificateArtifact, PlatformError> {
    #[cfg(windows)]
    {
        return submit_renewal_scep_via_helper(request);
    }

    #[cfg(not(windows))]
    {
        Err(PlatformError::not_implemented(
            "renewal-processing",
            format!(
                "same-key renewal submission is not wired yet for expected_device_id={} using existing key {}; nonce {} from {} and attestation format {} were prepared",
                request.context.plan.expected_device_id,
                request.key.key_name_hint,
                request.nonce.value,
                request.nonce.endpoint,
                request.attestation.format
            ),
        ))
    }
}

fn build_initial_challenge_password(plan: &EnrollmentSettings) -> String {
    format!("{}\\{}", plan.client_uid, plan.enrollment_secret)
}

fn same_key_handle_for_renewal(context: &RenewalContext) -> Result<TpmKeyHandle, PlatformError> {
    let Some(key_name_hint) = context.certificate.key_name_hint.clone() else {
        return Err(PlatformError::permanent(
            "renewal-processing",
            format!(
                "{} certificate is missing its TPM key association; same-key renewal cannot proceed",
                context.certificate.store_path
            ),
        ));
    };

    Ok(TpmKeyHandle {
        provider: TPM_KEY_PROVIDER,
        algorithm: DEFAULT_KEY_ALGORITHM,
        key_name_hint,
        material_state: KeyMaterialState::Existing,
        reuse_policy: KeyReusePolicy::SameKey,
        public_key_spki_b64: None,
    })
}

fn key_with_public_spki(key: &TpmKeyHandle) -> Result<TpmKeyHandle, PlatformError> {
    if key.public_key_spki_b64.is_some() {
        return Ok(key.clone());
    }

    #[cfg(windows)]
    {
        let mut key = key.clone();
        key.public_key_spki_b64 = Some(load_windows_persisted_key_public_spki_b64(
            &key.key_name_hint,
        )?);
        return Ok(key);
    }

    #[cfg(not(windows))]
    {
        Ok(key.clone())
    }
}

#[cfg(windows)]
fn finalize_windows_attestation_via_helper(
    server_url: &str,
    client_uid: &str,
    expected_device_id: &str,
    attestation: AttestationPayload,
    key: &TpmKeyHandle,
) -> Result<AttestationPayload, PlatformError> {
    let public_key_spki_b64 = key.public_key_spki_b64.as_deref().ok_or_else(|| {
        PlatformError::permanent(
            "attestation-assembly",
            format!(
                "TPM key {} is missing SubjectPublicKeyInfo required for attestation assembly",
                key.key_name_hint
            ),
        )
    })?;

    let helper = bundled_helper_path("scepclient.exe")?;
    let output = run_windows_command(
        "attestation-assembly",
        Command::new(helper)
            .arg("-uid")
            .arg(client_uid)
            .arg("-server-url")
            .arg(server_url)
            .arg("-emit-attestation")
            .arg("-attestation")
            .arg(&attestation.encoded)
            .arg("-key-provider")
            .arg(key.provider)
            .arg("-key-name")
            .arg(&key.key_name_hint)
            .arg("-public-key-spki-b64")
            .arg(public_key_spki_b64),
    )?;

    let encoded = String::from_utf8(output).map_err(|err| {
        PlatformError::temporary(
            "attestation-assembly",
            format!("helper returned non-UTF-8 attestation payload: {err}"),
        )
    })?;
    let encoded = encoded.trim().to_owned();
    if encoded.is_empty() {
        return Err(PlatformError::temporary(
            "attestation-assembly",
            "helper returned an empty attestation payload".to_owned(),
        ));
    }

    let claims = decode_attestation_payload(&encoded)?;
    if claims.attestation.format != CANONICAL_ATTESTATION_FORMAT {
        return Err(PlatformError::permanent(
            "attestation-assembly",
            format!(
                "expected helper to emit {CANONICAL_ATTESTATION_FORMAT}, got {}",
                claims.attestation.format
            ),
        ));
    }
    if claims.attestation.nonce != attestation.nonce {
        return Err(PlatformError::permanent(
            "attestation-assembly",
            format!(
                "helper attestation nonce mismatch for key {}",
                key.key_name_hint
            ),
        ));
    }
    if claims.device_id != normalize_device_id(expected_device_id) {
        return Err(PlatformError::with_device_identity_mismatch(
            "attestation-assembly",
            normalize_device_id(expected_device_id),
            claims.device_id.clone(),
            format!(
                "helper attestation device_id mismatch for key {}",
                key.key_name_hint
            ),
        ));
    }
    if claims.key.public_key_spki_b64.as_deref() != Some(public_key_spki_b64) {
        return Err(PlatformError::permanent(
            "attestation-assembly",
            format!(
                "helper attestation public key mismatch for key {}",
                key.key_name_hint
            ),
        ));
    }
    if claims.attestation.aik_public_b64.is_none()
        || claims.attestation.quote_b64.is_none()
        || claims.attestation.quote_signature_b64.is_none()
    {
        return Err(PlatformError::permanent(
            "attestation-assembly",
            format!(
                "helper attestation for key {} was missing canonical quote material",
                key.key_name_hint
            ),
        ));
    }
    if !server_url.trim().is_empty()
        && !client_uid.trim().is_empty()
        && (claims.attestation.activation_id.is_none()
            || claims.attestation.activation_proof_b64.is_none())
    {
        return Err(PlatformError::permanent(
            "attestation-assembly",
            format!(
                "helper attestation for key {} was missing credential-activation proof",
                key.key_name_hint
            ),
        ));
    }

    Ok(AttestationPayload {
        format: claims.attestation.format,
        encoded,
        nonce: claims.attestation.nonce,
    })
}

fn fetch_attestation_nonce(
    server_url: &str,
    client_uid: &str,
    expected_device_id: &str,
) -> Result<AttestationNonce, PlatformError> {
    let endpoint = derive_attestation_nonce_endpoint(server_url);
    let device_identity = resolve_expected_device_identity(expected_device_id)?;
    let ek_public_b64 = device_identity.ek_public_b64.as_deref();
    let request_body = serde_json::to_vec(&AttestationNonceRequest {
        client_uid,
        device_id: &device_identity.device_id,
        ek_public_b64,
    })
    .map_err(|err| {
        PlatformError::permanent(
            "attestation-nonce",
            format!("failed to encode nonce request for {endpoint}: {err}"),
        )
    })?;

    let response_bytes = post_json_with_curl(&endpoint, &request_body)?;
    let response: AttestationNonceResponse =
        serde_json::from_slice(&response_bytes).map_err(|err| {
            PlatformError::temporary(
                "attestation-nonce",
                format!("failed to decode nonce response from {endpoint}: {err}"),
            )
        })?;

    let nonce = response.nonce.trim().to_owned();
    if nonce.is_empty() {
        return Err(PlatformError::temporary(
            "attestation-nonce",
            format!("nonce response from {endpoint} did not include a nonce"),
        ));
    }

    if let Some(returned_device_id) = response.device_id.as_deref() {
        if normalize_device_id(returned_device_id) != device_identity.device_id {
            return Err(PlatformError::permanent(
                "attestation-nonce",
                format!(
                    "nonce response from {endpoint} was issued for device_id={} instead of {}",
                    normalize_device_id(returned_device_id),
                    device_identity.device_id
                ),
            ));
        }
    }

    Ok(AttestationNonce {
        endpoint,
        value: nonce,
        expires_at: response
            .expires_at
            .and_then(|value| non_empty_trimmed(Some(value))),
        device_id: device_identity.device_id,
    })
}

fn post_json_with_curl(endpoint: &str, request_body: &[u8]) -> Result<Vec<u8>, PlatformError> {
    let mut child = Command::new(curl_binary())
        .arg("-fsS")
        .arg("-X")
        .arg("POST")
        .arg("-H")
        .arg("Content-Type: application/json")
        .arg("--data-binary")
        .arg("@-")
        .arg(endpoint)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                PlatformError::permanent(
                    "attestation-nonce",
                    format!(
                        "{} was not found in PATH; bundle curl or replace the nonce transport implementation",
                        curl_binary()
                    ),
                )
            } else {
                PlatformError::temporary(
                    "attestation-nonce",
                    format!("failed to spawn {} for {endpoint}: {err}", curl_binary()),
                )
            }
        })?;

    let mut stdin = child.stdin.take().ok_or_else(|| {
        PlatformError::temporary(
            "attestation-nonce",
            format!(
                "failed to open stdin for {} when posting to {endpoint}",
                curl_binary()
            ),
        )
    })?;
    stdin.write_all(request_body).map_err(|err| {
        PlatformError::temporary(
            "attestation-nonce",
            format!("failed to send nonce request body to {endpoint}: {err}"),
        )
    })?;
    drop(stdin);

    let output = child.wait_with_output().map_err(|err| {
        PlatformError::temporary(
            "attestation-nonce",
            format!("failed while waiting for nonce response from {endpoint}: {err}"),
        )
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        let detail = if stderr.is_empty() {
            format!("{} exited with {}", curl_binary(), output.status)
        } else {
            stderr
        };

        return Err(PlatformError::temporary(
            "attestation-nonce",
            format!("nonce request to {endpoint} failed: {detail}"),
        ));
    }

    Ok(output.stdout)
}

fn derive_attestation_nonce_endpoint(server_url: &str) -> String {
    let trimmed = server_url.trim().trim_end_matches('/');
    if let Some(prefix) = trimmed.strip_suffix("/scep") {
        format!("{prefix}/api/attestation/nonce")
    } else {
        format!("{trimmed}/api/attestation/nonce")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedDeviceIdentity {
    pub device_id: String,
    pub ek_public_b64: Option<String>,
}

#[cfg(windows)]
fn resolve_expected_device_identity(
    expected_device_id: &str,
) -> Result<ResolvedDeviceIdentity, PlatformError> {
    let helper = bundled_helper_path("scepclient.exe")?;
    let output = run_windows_command(
        "device-identity",
        Command::new(helper).arg("-print-device-id").arg("-json"),
    )?;
    let response: CurrentDeviceIdentityResponse =
        serde_json::from_slice(&output).map_err(|err| {
            PlatformError::temporary(
                "device-identity",
                format!("failed to decode helper device identity response: {err}"),
            )
        })?;
    let device_id = normalize_device_id(&response.device_id);
    if device_id.is_empty() {
        return Err(PlatformError::temporary(
            "device-identity",
            "helper device identity response was missing device_id",
        ));
    }
    let expected_device_id = normalize_device_id(expected_device_id);
    if !expected_device_id.is_empty() && device_id != expected_device_id {
        return Err(PlatformError::with_device_identity_mismatch(
            "device-identity",
            expected_device_id,
            device_id,
            format!("current TPM device identity did not match the configured expected_device_id"),
        ));
    }
    Ok(ResolvedDeviceIdentity {
        device_id,
        ek_public_b64: response
            .ek_public_b64
            .and_then(|value| non_empty_trimmed(Some(value))),
    })
}

#[cfg(not(windows))]
fn resolve_expected_device_identity(
    expected_device_id: &str,
) -> Result<ResolvedDeviceIdentity, PlatformError> {
    Ok(ResolvedDeviceIdentity {
        device_id: normalize_device_id(expected_device_id),
        ek_public_b64: None,
    })
}

fn build_placeholder_attestation(
    format: &str,
    key: &TpmKeyHandle,
    nonce: &AttestationNonce,
) -> Result<AttestationPayload, PlatformError> {
    let claims = AttestationClaims {
        device_id: normalize_device_id(&nonce.device_id),
        key: AttestationKey {
            algorithm: key.algorithm.to_owned(),
            provider: key.provider.to_owned(),
            public_key_spki_b64: key.public_key_spki_b64.clone(),
        },
        attestation: AttestationBundle {
            format: format.to_owned(),
            nonce: nonce.value.clone(),
            aik_public_b64: None,
            aik_tpm_public_b64: None,
            quote_b64: None,
            quote_signature_b64: None,
            ek_public_b64: None,
            ek_cert_b64: None,
            ek_certificate_url: None,
            activation_id: None,
            activation_proof_b64: None,
        },
        meta: AttestationMeta {
            hostname: current_hostname(),
            os_version: std::env::consts::OS.to_owned(),
            generated_at: format!("unix:{}", unix_timestamp(SystemTime::now())),
        },
    };

    let raw_json = serde_json::to_vec(&claims).map_err(|err| {
        PlatformError::permanent(
            "attestation-assembly",
            format!(
                "failed to encode attestation payload for device_id={}: {err}",
                claims.device_id
            ),
        )
    })?;

    Ok(AttestationPayload {
        format: claims.attestation.format,
        encoded: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw_json),
        nonce: nonce.value.clone(),
    })
}

fn current_hostname() -> String {
    non_empty_trimmed(std::env::var("COMPUTERNAME").ok())
        .or_else(|| non_empty_trimmed(std::env::var("HOSTNAME").ok()))
        .unwrap_or_else(|| "unknown-host".to_owned())
}

fn non_empty_trimmed(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        }
    })
}

fn normalize_device_id(value: &str) -> String {
    value.trim().to_lowercase()
}

fn unix_timestamp(value: SystemTime) -> u64 {
    value
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(windows)]
fn delete_registry_value(key: &winreg::RegKey, value_name: &str) -> Result<(), PlatformError> {
    use std::io::ErrorKind;

    match key.delete_value(value_name) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(()),
        Err(err) if err.kind() == ErrorKind::PermissionDenied => Err(PlatformError::permanent(
            "dpapi-secret-lifecycle",
            format!(
                "failed to delete registry value {REGISTRY_PATH}\\{value_name}; LocalService may need explicit ACLs: {err}"
            ),
        )),
        Err(err) => Err(PlatformError::temporary(
            "dpapi-secret-lifecycle",
            format!("failed to delete registry value {REGISTRY_PATH}\\{value_name}: {err}"),
        )),
    }
}

fn curl_binary() -> &'static str {
    #[cfg(windows)]
    {
        "curl.exe"
    }

    #[cfg(not(windows))]
    {
        "curl"
    }
}

#[derive(Serialize, Deserialize)]
struct AttestationClaims {
    device_id: String,
    key: AttestationKey,
    attestation: AttestationBundle,
    meta: AttestationMeta,
}

#[derive(Serialize, Deserialize)]
struct AttestationKey {
    algorithm: String,
    provider: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    public_key_spki_b64: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct AttestationBundle {
    format: String,
    nonce: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    aik_public_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    aik_tpm_public_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    activation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    activation_proof_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    quote_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    quote_signature_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ek_public_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ek_cert_b64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ek_certificate_url: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct AttestationMeta {
    hostname: String,
    os_version: String,
    generated_at: String,
}

fn decode_attestation_payload(encoded: &str) -> Result<AttestationClaims, PlatformError> {
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded.trim().as_bytes())
        .map_err(|err| {
            PlatformError::permanent(
                "attestation-assembly",
                format!("failed to decode attestation payload: {err}"),
            )
        })?;
    let mut claims: AttestationClaims = serde_json::from_slice(&raw).map_err(|err| {
        PlatformError::permanent(
            "attestation-assembly",
            format!("failed to decode attestation JSON: {err}"),
        )
    })?;

    claims.device_id = normalize_device_id(&claims.device_id);
    claims.key.algorithm = claims.key.algorithm.trim().to_owned();
    claims.key.provider = claims.key.provider.trim().to_owned();
    claims.key.public_key_spki_b64 = claims
        .key
        .public_key_spki_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.format = claims.attestation.format.trim().to_owned();
    claims.attestation.nonce = claims.attestation.nonce.trim().to_owned();
    claims.attestation.aik_public_b64 = claims
        .attestation
        .aik_public_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.aik_tpm_public_b64 = claims
        .attestation
        .aik_tpm_public_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.activation_id = claims
        .attestation
        .activation_id
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.activation_proof_b64 = claims
        .attestation
        .activation_proof_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.quote_b64 = claims
        .attestation
        .quote_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.quote_signature_b64 = claims
        .attestation
        .quote_signature_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.ek_cert_b64 = claims
        .attestation
        .ek_cert_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.ek_public_b64 = claims
        .attestation
        .ek_public_b64
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.attestation.ek_certificate_url = claims
        .attestation
        .ek_certificate_url
        .take()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    claims.meta.hostname = claims.meta.hostname.trim().to_owned();
    claims.meta.os_version = claims.meta.os_version.trim().to_owned();
    claims.meta.generated_at = claims.meta.generated_at.trim().to_owned();

    Ok(claims)
}

#[derive(Serialize)]
struct AttestationNonceRequest<'a> {
    client_uid: &'a str,
    device_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    ek_public_b64: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
struct AttestationNonceResponse {
    nonce: String,
    #[serde(default)]
    device_id: Option<String>,
    #[serde(default)]
    expires_at: Option<String>,
}

#[cfg(windows)]
#[derive(Debug, Deserialize)]
struct CurrentDeviceIdentityResponse {
    device_id: String,
    #[serde(default)]
    ek_public_b64: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_endpoint_reuses_scep_origin() {
        assert_eq!(
            derive_attestation_nonce_endpoint("https://example.invalid/scep"),
            "https://example.invalid/api/attestation/nonce"
        );
        assert_eq!(
            derive_attestation_nonce_endpoint("https://example.invalid/scep/"),
            "https://example.invalid/api/attestation/nonce"
        );
        assert_eq!(
            derive_attestation_nonce_endpoint("https://example.invalid/custom"),
            "https://example.invalid/custom/api/attestation/nonce"
        );
    }

    #[test]
    fn placeholder_attestation_contains_device_id_and_nonce() {
        let key = TpmKeyHandle {
            provider: TPM_KEY_PROVIDER,
            algorithm: DEFAULT_KEY_ALGORITHM,
            key_name_hint: "client-001-device-001".to_owned(),
            material_state: KeyMaterialState::Planned,
            reuse_policy: KeyReusePolicy::SameKey,
            public_key_spki_b64: Some("YWJj".to_owned()),
        };
        let nonce = AttestationNonce {
            endpoint: "https://example.invalid/api/attestation/nonce".to_owned(),
            value: "nonce-123".to_owned(),
            expires_at: Some("later".to_owned()),
            device_id: "device-001".to_owned(),
        };

        let payload =
            build_placeholder_attestation(PLACEHOLDER_ATTESTATION_FORMAT_INITIAL, &key, &nonce)
                .expect("attestation payload");
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(payload.encoded.as_bytes())
            .expect("decode");
        let value: serde_json::Value = serde_json::from_slice(&decoded).expect("json");

        assert_eq!(value["device_id"], "device-001");
        assert_eq!(value["attestation"]["nonce"], "nonce-123");
        assert_eq!(value["key"]["provider"], TPM_KEY_PROVIDER);
        assert_eq!(payload.nonce, "nonce-123");
    }

    #[test]
    fn decode_attestation_payload_normalizes_and_reads_canonical_fields() {
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            serde_json::json!({
                "device_id": " Device-001 ",
                "key": {
                    "algorithm": " rsa-2048 ",
                    "provider": " Microsoft Platform Crypto Provider ",
                    "public_key_spki_b64": " abc "
                },
                "attestation": {
                    "format": " tpm2-windows-v1 ",
                    "nonce": " nonce-123 ",
                    "aik_public_b64": " aik ",
                    "aik_tpm_public_b64": " aik-tpm ",
                    "activation_id": " activation-001 ",
                    "activation_proof_b64": " proof ",
                    "quote_b64": " quote ",
                    "quote_signature_b64": " sig ",
                    "ek_public_b64": " ek-public ",
                    "ek_cert_b64": " ek ",
                    "ek_certificate_url": " https://example.invalid/ek "
                },
                "meta": {
                    "hostname": " host ",
                    "os_version": " windows ",
                    "generated_at": " unix:1 "
                }
            })
            .to_string(),
        );

        let claims = decode_attestation_payload(&encoded).expect("decode");
        assert_eq!(claims.device_id, "device-001");
        assert_eq!(claims.key.algorithm, "rsa-2048");
        assert_eq!(claims.key.provider, TPM_KEY_PROVIDER);
        assert_eq!(claims.key.public_key_spki_b64.as_deref(), Some("abc"));
        assert_eq!(claims.attestation.format, CANONICAL_ATTESTATION_FORMAT);
        assert_eq!(claims.attestation.nonce, "nonce-123");
        assert_eq!(claims.attestation.aik_public_b64.as_deref(), Some("aik"));
        assert_eq!(
            claims.attestation.aik_tpm_public_b64.as_deref(),
            Some("aik-tpm")
        );
        assert_eq!(
            claims.attestation.activation_id.as_deref(),
            Some("activation-001")
        );
        assert_eq!(
            claims.attestation.activation_proof_b64.as_deref(),
            Some("proof")
        );
        assert_eq!(claims.attestation.quote_b64.as_deref(), Some("quote"));
        assert_eq!(
            claims.attestation.quote_signature_b64.as_deref(),
            Some("sig")
        );
        assert_eq!(
            claims.attestation.ek_public_b64.as_deref(),
            Some("ek-public")
        );
        assert_eq!(claims.attestation.ek_cert_b64.as_deref(), Some("ek"));
        assert_eq!(
            claims.attestation.ek_certificate_url.as_deref(),
            Some("https://example.invalid/ek")
        );
        assert_eq!(claims.meta.hostname, "host");
        assert_eq!(claims.meta.os_version, "windows");
        assert_eq!(claims.meta.generated_at, "unix:1");
    }

    #[test]
    fn same_key_renewal_requires_key_reference() {
        let context = RenewalContext {
            plan: RenewalSettings {
                server_url: "https://example.invalid/scep".to_owned(),
                client_uid: "client-001".to_owned(),
                expected_device_id: "device-001".to_owned(),
            },
            certificate: InstalledCertificate {
                store_path: MACHINE_STORE_PATH,
                thumbprint: Some("thumbprint".to_owned()),
                key_name_hint: None,
                not_before: None,
                not_after: None,
            },
        };

        let err = same_key_handle_for_renewal(&context).expect_err("missing key reference");
        assert_eq!(err.kind, PlatformErrorKind::Permanent);
        assert!(err.message.contains("same-key renewal"));
    }

    #[test]
    fn machine_store_probe_script_prefers_server_active_certificate() {
        let script = build_windows_machine_store_probe_script(
            "https://example.invalid/scep",
            "client-001",
            Path::new(r"C:\ProgramData\MyTunnelApp\managed\client-001-device-001\cert.pem"),
        );

        assert!(script.contains("$serverUrl = 'https://example.invalid/scep'"));
        assert!(script.contains("$managedCertPath = 'C:\\ProgramData\\MyTunnelApp\\managed\\client-001-device-001\\cert.pem'"));
        assert!(script.contains("Resolve-MyTunnelServerApiBaseUrl"));
        assert!(script.contains("/api/cert/list/"));
        assert!(script.contains("$serverActiveThumbprint = $null"));
        assert!(script.contains("$serverActivePemText = $null"));
        assert!(script.contains("$managedCertThumbprint = $null"));
        assert!(script.contains("$_.Thumbprint -eq $serverActiveThumbprint"));
        assert!(script.contains("$_.Thumbprint -eq $managedCertThumbprint"));
        assert!(script.contains("X509NameType]::SimpleName"));
        assert!(script.contains("-eq 'client-001'"));
        assert!(script.contains("$cert.RawData"));
        assert!(script.contains("WriteAllText($managedCertPath, $serverActivePemText"));
        assert!(script.contains("status\":\"missing"));
        assert!(script.contains("WriteAllText($managedCertPath"));
        assert!(script.contains("NotBeforeUnix"));
        assert!(script.contains("NotAfterUnix"));
        assert!(!script.contains("$_.Subject -eq 'CN=client-001'"));
    }

    #[test]
    fn renewal_due_is_clamped_to_after_one_poll_interval() {
        let issued_at = UNIX_EPOCH + Duration::from_secs(10_000);
        let certificate = InstalledCertificate {
            store_path: MACHINE_STORE_PATH,
            thumbprint: Some("thumbprint".to_owned()),
            key_name_hint: Some("client-001-device-001".to_owned()),
            not_before: Some(issued_at),
            not_after: Some(issued_at + Duration::from_secs(3_600)),
        };

        assert_eq!(
            certificate
                .effective_renew_before(Duration::from_secs(7_200), Duration::from_secs(300)),
            Duration::from_secs(3_300)
        );
        assert_eq!(
            certificate.renewal_due_at(Duration::from_secs(7_200), Duration::from_secs(300)),
            Some(issued_at + Duration::from_secs(300))
        );
    }
}
