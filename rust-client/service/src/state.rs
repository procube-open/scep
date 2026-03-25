use crate::config::{EnrollmentSettings, RequiredField, ServiceConfig};
use crate::platform::{
    CertificateInventory, InstalledCertificate, PendingEnrollment, PlatformError,
    PlatformErrorKind, RenewalContext, ServicePlatform, StagedEnrollmentSecret,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServicePhase {
    NotConfigured,
    WaitingForEnrollment,
    GeneratingKey,
    SubmittingCsr,
    Issued,
    RenewalDue,
    ErrorBackoff,
}

impl ServicePhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotConfigured => "NotConfigured",
            Self::WaitingForEnrollment => "WaitingForEnrollment",
            Self::GeneratingKey => "GeneratingKey",
            Self::SubmittingCsr => "SubmittingCSR",
            Self::Issued => "Issued",
            Self::RenewalDue => "RenewalDue",
            Self::ErrorBackoff => "ErrorBackoff",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServiceState {
    NotConfigured {
        missing: Vec<RequiredField>,
        note: String,
    },
    WaitingForEnrollment {
        plan: EnrollmentSettings,
        note: String,
    },
    GeneratingKey {
        plan: EnrollmentSettings,
        secret: StagedEnrollmentSecret,
    },
    SubmittingCsr {
        pending: PendingEnrollment,
    },
    Issued {
        certificate: InstalledCertificate,
    },
    RenewalDue {
        context: RenewalContext,
    },
    ErrorBackoff {
        failed_phase: ServicePhase,
        component: &'static str,
        message: String,
        attempt: u32,
        retry_after: Duration,
        retry_at: SystemTime,
    },
}

impl ServiceState {
    pub fn phase(&self) -> ServicePhase {
        match self {
            Self::NotConfigured { .. } => ServicePhase::NotConfigured,
            Self::WaitingForEnrollment { .. } => ServicePhase::WaitingForEnrollment,
            Self::GeneratingKey { .. } => ServicePhase::GeneratingKey,
            Self::SubmittingCsr { .. } => ServicePhase::SubmittingCsr,
            Self::Issued { .. } => ServicePhase::Issued,
            Self::RenewalDue { .. } => ServicePhase::RenewalDue,
            Self::ErrorBackoff { .. } => ServicePhase::ErrorBackoff,
        }
    }

    pub fn summary(&self) -> String {
        match self {
            Self::NotConfigured { missing, note } => format!(
                "waiting for configuration (missing: {}): {note}",
                format_missing_fields(missing)
            ),
            Self::WaitingForEnrollment { plan, note } => format!(
                "device_id={} is ready for initial enrollment: {note}",
                plan.device_id
            ),
            Self::GeneratingKey { plan, secret } => format!(
                "preparing TPM-backed key for device_id={} using {} bootstrap secret staging",
                plan.device_id,
                secret.source.as_str()
            ),
            Self::SubmittingCsr { pending } => format!(
                "submitting an attested CSR for device_id={} via {} ({:?}, {:?})",
                pending.plan.device_id,
                pending.key.provider,
                pending.key.material_state,
                pending.key.reuse_policy
            ),
            Self::Issued { certificate } => format!(
                "certificate is installed in {} (thumbprint={}, key={})",
                certificate.store_path,
                certificate
                    .thumbprint
                    .as_deref()
                    .unwrap_or("<unknown-thumbprint>"),
                certificate
                    .key_name_hint
                    .as_deref()
                    .unwrap_or("<unknown-key>")
            ),
            Self::RenewalDue { context } => format!(
                "certificate in {} requires same-key renewal for device_id={} using key {}",
                context.certificate.store_path,
                context.plan.device_id,
                context
                    .certificate
                    .key_name_hint
                    .as_deref()
                    .unwrap_or("<missing-key-reference>")
            ),
            Self::ErrorBackoff {
                failed_phase,
                component,
                message,
                attempt,
                retry_after,
                retry_at,
            } => format!(
                "{component} failed while in {} (attempt {}, retry in {}s, not before {}): {message}",
                failed_phase.as_str(),
                attempt,
                retry_after.as_secs(),
                format_system_time(retry_at.clone())
            ),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateTransition {
    pub previous: ServicePhase,
    pub current: ServicePhase,
    pub detail: String,
    pub changed: bool,
}

#[derive(Clone)]
pub struct ServiceEngine {
    platform: ServicePlatform,
    state: ServiceState,
}

impl ServiceEngine {
    pub fn new(platform: ServicePlatform) -> Self {
        Self {
            platform,
            state: ServiceState::NotConfigured {
                missing: Vec::new(),
                note: "service state has not been evaluated yet".to_owned(),
            },
        }
    }

    pub fn state(&self) -> &ServiceState {
        &self.state
    }

    pub fn bootstrap(&mut self, config: &ServiceConfig) -> StateTransition {
        let next = self.resolve_configuration_state(config);
        self.transition_to(next)
    }

    pub fn next_tick_delay(&self, config: &ServiceConfig) -> Duration {
        let default_delay = config.effective_poll_interval();
        match &self.state {
            ServiceState::ErrorBackoff { retry_at, .. } => {
                let remaining = retry_at
                    .duration_since(self.platform.clock.now())
                    .unwrap_or_default();
                if remaining.is_zero() {
                    default_delay
                } else {
                    remaining.min(default_delay)
                }
            }
            ServiceState::Issued { certificate } => {
                let now = self.platform.clock.now();
                let Some(renewal_due_at) =
                    certificate.renewal_due_at(config.renew_before, default_delay)
                else {
                    return default_delay;
                };
                let remaining = renewal_due_at.duration_since(now).unwrap_or_default();
                if remaining.is_zero() {
                    default_delay
                } else {
                    remaining.min(default_delay)
                }
            }
            _ => default_delay,
        }
    }

    pub fn tick(&mut self, config: &ServiceConfig) -> StateTransition {
        if let ServiceState::ErrorBackoff { retry_at, .. } = &self.state {
            if self.platform.clock.now() < retry_at.clone() {
                return self.transition_to(self.state.clone());
            }
        }

        if let Err(missing) = config.renewal_settings() {
            return self.transition_to(ServiceState::NotConfigured {
                missing,
                note: "server_url, client_uid, and device_id must be configured before the service can enroll or renew certificates"
                    .to_owned(),
            });
        }

        let next = match &self.state {
            ServiceState::NotConfigured { .. } => self.resolve_configuration_state(config),
            ServiceState::WaitingForEnrollment { plan, .. } => {
                match self.platform.secrets.stage_enrollment_secret(plan) {
                    Ok(secret) => ServiceState::GeneratingKey {
                        plan: plan.clone(),
                        secret,
                    },
                    Err(err) => self.error_backoff(config, ServicePhase::WaitingForEnrollment, err),
                }
            }
            ServiceState::GeneratingKey { plan, secret } => {
                match self.platform.tpm_keys.ensure_machine_key(plan, secret) {
                    Ok(key) => ServiceState::SubmittingCsr {
                        pending: PendingEnrollment {
                            plan: plan.clone(),
                            secret: secret.clone(),
                            key,
                        },
                    },
                    Err(err) => self.error_backoff(config, ServicePhase::GeneratingKey, err),
                }
            }
            ServiceState::SubmittingCsr { pending } => {
                match self.submit_initial_enrollment(pending) {
                    Ok(certificate) => ServiceState::Issued { certificate },
                    Err(err) => self.error_backoff(config, ServicePhase::SubmittingCsr, err),
                }
            }
            ServiceState::Issued { .. } => self.resolve_configuration_state(config),
            ServiceState::RenewalDue { context } => match self.renew_certificate(context) {
                Ok(certificate) => ServiceState::Issued { certificate },
                Err(err) => self.error_backoff(config, ServicePhase::RenewalDue, err),
            },
            ServiceState::ErrorBackoff { .. } => self.resolve_configuration_state(config),
        };

        self.transition_to(next)
    }

    fn submit_initial_enrollment(
        &self,
        pending: &PendingEnrollment,
    ) -> Result<InstalledCertificate, PlatformError> {
        let issued = self
            .platform
            .renewal
            .submit_initial_enrollment(pending.clone())?;
        let certificate = self
            .platform
            .machine_store
            .install_issued_certificate(pending, &issued.certificate_der)?;

        if pending.secret.remove_after_issue {
            self.platform.secrets.clear_after_success(&pending.secret)?;
        }

        Ok(certificate)
    }

    fn renew_certificate(
        &self,
        context: &RenewalContext,
    ) -> Result<InstalledCertificate, PlatformError> {
        let issued = self
            .platform
            .renewal
            .renew_existing_certificate(context.clone())?;
        self.platform
            .machine_store
            .install_renewed_certificate(context, &issued.certificate_der)
    }

    fn resolve_configuration_state(&self, config: &ServiceConfig) -> ServiceState {
        let renewal = match config.renewal_settings() {
            Ok(settings) => settings,
            Err(missing) => {
                return ServiceState::NotConfigured {
                    missing,
                    note: "server_url, client_uid, and device_id must be configured before the service can enroll or renew certificates"
                        .to_owned(),
                };
            }
        };

        match self
            .platform
            .machine_store
            .probe_current_certificate(&renewal, config.renew_before, config.effective_poll_interval())
        {
            Ok(CertificateInventory::Active(certificate)) => ServiceState::Issued { certificate },
            Ok(CertificateInventory::RenewalDue(context)) => ServiceState::RenewalDue { context },
            Ok(CertificateInventory::Missing) => match config.initial_enrollment() {
                Ok(plan) => ServiceState::WaitingForEnrollment {
                    plan,
                    note: "bootstrap enrollment prerequisites are present; awaiting nonce retrieval, attestation assembly, SCEP submission, and LocalMachine\\My installation"
                        .to_owned(),
                },
                Err(missing) => ServiceState::NotConfigured {
                    missing,
                    note: "LocalMachine\\My does not contain a managed certificate and enrollment_secret is still required for the first enrollment"
                        .to_owned(),
                },
            },
            Err(err) if err.is_not_implemented() => match &self.state {
                ServiceState::Issued { certificate }
                    if issued_certificate_matches_config(certificate, &renewal) =>
                {
                    ServiceState::Issued {
                        certificate: certificate.clone(),
                    }
                }
                _ => match config.initial_enrollment() {
                    Ok(plan) => ServiceState::WaitingForEnrollment {
                        plan,
                        note: format!(
                            "{}; startup will remain in a waiting state until LocalMachine\\My inspection is implemented",
                            err.message
                        ),
                    },
                    Err(missing) => ServiceState::NotConfigured {
                        missing,
                        note: format!(
                            "{}; enrollment_secret is absent, so the service cannot assume same-key renewal is possible until Machine Store discovery exists",
                            err.message
                        ),
                    },
                },
            },
            Err(err) => self.error_backoff(config, ServicePhase::Issued, err),
        }
    }

    fn error_backoff(
        &self,
        config: &ServiceConfig,
        failed_phase: ServicePhase,
        err: PlatformError,
    ) -> ServiceState {
        let attempt = match &self.state {
            ServiceState::ErrorBackoff {
                failed_phase: previous_phase,
                component,
                attempt,
                ..
            } if *previous_phase == failed_phase && *component == err.component => {
                attempt.saturating_add(1)
            }
            _ => 1,
        };
        let retry_after = retry_delay_for(err.kind, attempt, config.effective_poll_interval());
        let now = self.platform.clock.now();
        let retry_at = now.checked_add(retry_after).unwrap_or(now);

        ServiceState::ErrorBackoff {
            failed_phase,
            component: err.component,
            message: err.message,
            attempt,
            retry_after,
            retry_at,
        }
    }

    fn transition_to(&mut self, next: ServiceState) -> StateTransition {
        let previous = self.state.phase();
        let changed = self.state != next;
        let current = next.phase();
        let detail = next.summary();
        self.state = next;

        StateTransition {
            previous,
            current,
            detail,
            changed,
        }
    }
}

fn retry_delay_for(kind: PlatformErrorKind, attempt: u32, poll_interval: Duration) -> Duration {
    match kind {
        PlatformErrorKind::Temporary => {
            let shift = attempt.saturating_sub(1).min(5);
            let seconds = 30u64.saturating_mul(1u64 << shift).min(15 * 60);
            Duration::from_secs(seconds)
        }
        PlatformErrorKind::NotImplemented => {
            Duration::from_secs(poll_interval.as_secs().max(10 * 60))
        }
        PlatformErrorKind::Permanent => Duration::from_secs(poll_interval.as_secs().max(15 * 60)),
    }
}

fn format_missing_fields(missing: &[RequiredField]) -> String {
    if missing.is_empty() {
        return "none".to_owned();
    }

    missing
        .iter()
        .map(|field| field.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

fn issued_certificate_matches_config(
    certificate: &InstalledCertificate,
    renewal: &crate::config::RenewalSettings,
) -> bool {
    certificate
        .key_name_hint
        .as_deref()
        .map(|key_name_hint| {
            key_name_hint == format!("{}-{}", renewal.client_uid, renewal.device_id)
        })
        .unwrap_or(false)
}

fn format_system_time(value: SystemTime) -> String {
    format!(
        "unix:{}",
        value
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RenewalSettings;
    use crate::platform::{
        AttestationNonce, AttestationPayload, IssuedCertificateArtifact, MachineCertificateStore,
        PlatformClock, RenewalProcessor, SecretLifecycle,
    };
    use std::sync::{Arc, Mutex};

    fn ready_config() -> ServiceConfig {
        ServiceConfig {
            server_url: Some("https://example.invalid/scep".to_owned()),
            client_uid: Some("client-001".to_owned()),
            enrollment_secret: Some("bootstrap-secret".to_owned()),
            device_id: Some("device-001".to_owned()),
            poll_interval: Duration::from_secs(300),
            renew_before: Duration::from_secs(3600),
            log_level: "info".to_owned(),
            sources: Vec::new(),
            warnings: Vec::new(),
        }
    }

    fn test_nonce() -> AttestationNonce {
        AttestationNonce {
            endpoint: "https://example.invalid/api/attestation/nonce".to_owned(),
            value: "nonce-123".to_owned(),
            expires_at: Some("later".to_owned()),
        }
    }

    fn test_attestation() -> AttestationPayload {
        AttestationPayload {
            format: "test-attestation".to_owned(),
            encoded: "encoded-attestation".to_owned(),
            nonce: "nonce-123".to_owned(),
        }
    }

    fn failing_submission_platform(err: PlatformError) -> ServicePlatform {
        ServicePlatform {
            renewal: RenewalProcessor::default()
                .with_fetch_initial_nonce(|_| Ok(test_nonce()))
                .with_build_initial_attestation(|_, _| Ok(test_attestation()))
                .with_submit_initial_scep(move |_| Err(err.clone())),
            ..ServicePlatform::default()
        }
    }

    #[test]
    fn bootstrap_without_identity_fields_is_not_configured() {
        let mut engine = ServiceEngine::new(ServicePlatform::default());
        let transition = engine.bootstrap(&ServiceConfig::default());

        assert_eq!(transition.current, ServicePhase::NotConfigured);
        match engine.state() {
            ServiceState::NotConfigured { missing, .. } => {
                assert!(missing.contains(&RequiredField::ServerUrl));
                assert!(missing.contains(&RequiredField::ClientUid));
                assert!(missing.contains(&RequiredField::DeviceId));
            }
            other => panic!("expected NotConfigured, got {other:?}"),
        }
    }

    #[test]
    fn bootstrap_ready_config_waits_for_enrollment_when_machine_store_is_pending() {
        let mut engine = ServiceEngine::new(ServicePlatform::default());
        let transition = engine.bootstrap(&ready_config());

        assert_eq!(transition.current, ServicePhase::WaitingForEnrollment);
        match engine.state() {
            ServiceState::WaitingForEnrollment { note, .. } => {
                assert!(note.contains("LocalMachine\\My"));
            }
            other => panic!("expected WaitingForEnrollment, got {other:?}"),
        }
    }

    #[test]
    fn waiting_enrollment_advances_to_generating_key_submitting_and_backoff() {
        let config = ready_config();
        let mut engine = ServiceEngine::new(failing_submission_platform(PlatformError::temporary(
            "scep-submission",
            "simulated transport failure",
        )));

        let _ = engine.bootstrap(&config);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::GeneratingKey);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::SubmittingCsr);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::ErrorBackoff);
        assert!(transition.detail.contains("scep-submission"));
    }

    #[test]
    fn temporary_backoff_waits_for_retry_deadline() {
        let now = Arc::new(Mutex::new(UNIX_EPOCH + Duration::from_secs(1_000)));
        let mut engine = ServiceEngine::new(ServicePlatform {
            clock: PlatformClock::default().with_now({
                let now = now.clone();
                move || now.lock().expect("clock").clone()
            }),
            renewal: RenewalProcessor::default()
                .with_fetch_initial_nonce(|_| Ok(test_nonce()))
                .with_build_initial_attestation(|_, _| Ok(test_attestation()))
                .with_submit_initial_scep(|_| {
                    Err(PlatformError::temporary(
                        "scep-submission",
                        "transient network failure",
                    ))
                }),
            ..ServicePlatform::default()
        });
        let config = ready_config();

        let _ = engine.bootstrap(&config);
        let _ = engine.tick(&config);
        let _ = engine.tick(&config);
        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::ErrorBackoff);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::ErrorBackoff);
        assert!(!transition.changed);

        let mut guard = now.lock().expect("clock");
        let advanced = guard.clone() + Duration::from_secs(31);
        *guard = advanced;
        drop(guard);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::WaitingForEnrollment);
        assert!(transition.changed);
    }

    #[test]
    fn issued_state_shortens_next_tick_to_renewal_due_time() {
        let now = UNIX_EPOCH + Duration::from_secs(10_000);
        let mut engine = ServiceEngine::new(ServicePlatform {
            clock: PlatformClock::default().with_now(move || now),
            ..ServicePlatform::default()
        });
        engine.state = ServiceState::Issued {
            certificate: InstalledCertificate {
                store_path: r"LocalMachine\My",
                thumbprint: Some("thumbprint-001".to_owned()),
                key_name_hint: Some("client-001-device-001".to_owned()),
                not_before: Some(now - Duration::from_secs(3_000)),
                not_after: Some(now + Duration::from_secs(900)),
            },
        };

        let config = ServiceConfig {
            poll_interval: Duration::from_secs(3_600),
            renew_before: Duration::from_secs(600),
            ..ready_config()
        };

        assert_eq!(engine.next_tick_delay(&config), Duration::from_secs(600));
    }

    #[test]
    fn successful_initial_enrollment_installs_certificate_and_clears_secret() {
        let clear_calls = Arc::new(Mutex::new(0usize));
        let submitted_keys = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut engine = ServiceEngine::new(ServicePlatform {
            secrets: SecretLifecycle::default().with_clear_after_success({
                let clear_calls = clear_calls.clone();
                move |_| {
                    *clear_calls.lock().expect("clear calls") += 1;
                    Ok(())
                }
            }),
            machine_store: MachineCertificateStore::default().with_install_issued_certificate(
                |pending, certificate_der| {
                    assert_eq!(certificate_der, &[0x30, 0x82, 0x01]);
                    Ok(InstalledCertificate {
                        store_path: r"LocalMachine\My",
                        thumbprint: Some("thumbprint-001".to_owned()),
                        key_name_hint: Some(pending.key.key_name_hint.clone()),
                        not_before: None,
                        not_after: None,
                    })
                },
            ),
            renewal: RenewalProcessor::default()
                .with_fetch_initial_nonce(|_| Ok(test_nonce()))
                .with_build_initial_attestation(|_, _| Ok(test_attestation()))
                .with_submit_initial_scep({
                    let submitted_keys = submitted_keys.clone();
                    move |request| {
                        submitted_keys
                            .lock()
                            .expect("submitted keys")
                            .push(request.pending.key.key_name_hint.clone());
                        Ok(IssuedCertificateArtifact {
                            certificate_der: vec![0x30, 0x82, 0x01],
                            transport: "test-transport",
                        })
                    }
                }),
            ..ServicePlatform::default()
        });
        let config = ready_config();

        let _ = engine.bootstrap(&config);
        let _ = engine.tick(&config);
        let _ = engine.tick(&config);
        let transition = engine.tick(&config);

        assert_eq!(transition.current, ServicePhase::Issued);
        match engine.state() {
            ServiceState::Issued { certificate } => {
                assert_eq!(certificate.thumbprint.as_deref(), Some("thumbprint-001"));
                assert_eq!(
                    certificate.key_name_hint.as_deref(),
                    Some("client-001-device-001")
                );
            }
            other => panic!("expected Issued, got {other:?}"),
        }
        assert_eq!(*clear_calls.lock().expect("clear calls"), 1);
        assert_eq!(
            submitted_keys.lock().expect("submitted keys").as_slice(),
            ["client-001-device-001"]
        );

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::Issued);
        assert!(!transition.changed);
    }

    #[test]
    fn renewal_due_uses_same_key_context() {
        let renewal_context = RenewalContext {
            plan: RenewalSettings {
                server_url: "https://example.invalid/scep".to_owned(),
                client_uid: "client-001".to_owned(),
                device_id: "device-001".to_owned(),
            },
            certificate: InstalledCertificate {
                store_path: r"LocalMachine\My",
                thumbprint: Some("thumbprint-001".to_owned()),
                key_name_hint: Some("client-001-device-001".to_owned()),
                not_before: None,
                not_after: None,
            },
        };
        let observed_keys = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut engine = ServiceEngine::new(ServicePlatform {
            machine_store: MachineCertificateStore::default()
                .with_probe_current_certificate({
                    let renewal_context = renewal_context.clone();
                    move |_, _, _| Ok(CertificateInventory::RenewalDue(renewal_context.clone()))
                })
                .with_install_renewed_certificate(|context, certificate_der| {
                    assert_eq!(certificate_der, &[0x30, 0x82, 0x02]);
                    Ok(context.certificate.clone())
                }),
            renewal: RenewalProcessor::default()
                .with_fetch_renewal_nonce(|_| Ok(test_nonce()))
                .with_build_renewal_attestation(|_, key, _| {
                    Ok(AttestationPayload {
                        format: "renewal-attestation".to_owned(),
                        encoded: format!("renewal:{}", key.key_name_hint),
                        nonce: "nonce-123".to_owned(),
                    })
                })
                .with_submit_renewal_scep({
                    let observed_keys = observed_keys.clone();
                    move |request| {
                        observed_keys
                            .lock()
                            .expect("observed keys")
                            .push(request.key.key_name_hint.clone());
                        Ok(IssuedCertificateArtifact {
                            certificate_der: vec![0x30, 0x82, 0x02],
                            transport: "test-transport",
                        })
                    }
                }),
            ..ServicePlatform::default()
        });
        let config = ready_config();

        let transition = engine.bootstrap(&config);
        assert_eq!(transition.current, ServicePhase::RenewalDue);

        let transition = engine.tick(&config);
        assert_eq!(transition.current, ServicePhase::Issued);
        assert_eq!(
            observed_keys.lock().expect("observed keys").as_slice(),
            ["client-001-device-001"]
        );
    }

    #[test]
    fn missing_secret_without_machine_store_stays_not_configured() {
        let mut config = ready_config();
        config.enrollment_secret = None;

        let mut engine = ServiceEngine::new(ServicePlatform::default());
        let transition = engine.bootstrap(&config);

        assert_eq!(transition.current, ServicePhase::NotConfigured);
        match engine.state() {
            ServiceState::NotConfigured { missing, note } => {
                assert_eq!(missing, &vec![RequiredField::EnrollmentSecret]);
                assert!(note.contains("same-key renewal"));
            }
            other => panic!("expected NotConfigured, got {other:?}"),
        }
    }
}
