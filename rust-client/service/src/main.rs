mod config;
mod logging;
mod platform;
mod state;
mod windows_paths;

#[cfg(not(windows))]
use std::thread;
use std::time::Duration;
#[cfg(windows)]
use std::{sync::mpsc, sync::mpsc::RecvTimeoutError};

#[cfg(windows)]
use tracing::error;
use tracing::{info, warn};

#[cfg(windows)]
use windows_service::{
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};

#[cfg(windows)]
const SERVICE_NAME: &str = "MyTunnelService";
#[cfg(windows)]
windows_service::define_windows_service!(ffi_service_main, my_service_main);

fn main() {
    if let Err(err) = run() {
        logging::write_fatal_eventlog(&err);
        eprintln!("{err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let bootstrap_config = config::ServiceConfig::load();
    let _guard = logging::init_logging(&bootstrap_config.log_level)
        .map_err(|err| format!("failed to initialize logs: {err}"))?;

    #[cfg(windows)]
    {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)
            .map_err(|err| format!("failed to start service dispatcher: {err}"))?;
    }

    #[cfg(not(windows))]
    {
        info!("windows service bootstrap is disabled on non-windows targets");
        service_main()?;
    }

    Ok(())
}

#[cfg(windows)]
fn my_service_main(_arguments: Vec<std::ffi::OsString>) {
    if let Err(err) = service_main() {
        error!(error = %err, "service main failed");
    }
}

fn service_main() -> Result<(), String> {
    let mut current_config = config::ServiceConfig::load();
    log_config_snapshot("startup", &current_config);

    let mut engine = state::ServiceEngine::new(platform::ServicePlatform::default());

    #[cfg(windows)]
    {
        let (shutdown_tx, shutdown_rx) = mpsc::channel::<()>();
        let status_handle =
            service_control_handler::register(
                SERVICE_NAME,
                move |control_event| match control_event {
                    ServiceControl::Stop => {
                        let _ = shutdown_tx.send(());
                        ServiceControlHandlerResult::NoError
                    }
                    ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                    _ => ServiceControlHandlerResult::NotImplemented,
                },
            )
            .map_err(|err| format!("failed to register service control handler: {err}"))?;

        status_handle
            .set_service_status(ServiceStatus {
                service_type: ServiceType::OWN_PROCESS,
                current_state: ServiceState::Running,
                controls_accepted: ServiceControlAccept::STOP,
                exit_code: ServiceExitCode::Win32(0),
                checkpoint: 0,
                wait_hint: Duration::default(),
                process_id: None,
            })
            .map_err(|err| format!("failed to set service running status: {err}"))?;

        log_state_transition(engine.bootstrap(&current_config));
        drive_service_cycle(&mut engine, &current_config);

        let mut tick_interval = engine.next_tick_delay(&current_config);
        loop {
            match shutdown_rx.recv_timeout(tick_interval) {
                Ok(()) => break,
                Err(RecvTimeoutError::Timeout) => {
                    let reloaded_config = config::ServiceConfig::load();
                    if reloaded_config != current_config {
                        log_config_snapshot("reload", &reloaded_config);
                        current_config = reloaded_config;
                        log_state_transition(engine.bootstrap(&current_config));
                    }

                    drive_service_cycle(&mut engine, &current_config);
                    tick_interval = engine.next_tick_delay(&current_config);
                }
                Err(err) => return Err(format!("service control channel failed: {err}")),
            }
        }

        status_handle
            .set_service_status(ServiceStatus {
                service_type: ServiceType::OWN_PROCESS,
                current_state: ServiceState::Stopped,
                controls_accepted: ServiceControlAccept::empty(),
                exit_code: ServiceExitCode::Win32(0),
                checkpoint: 0,
                wait_hint: Duration::default(),
                process_id: None,
            })
            .map_err(|err| format!("failed to set service stopped status: {err}"))?;
    }

    #[cfg(not(windows))]
    {
        log_state_transition(engine.bootstrap(&current_config));
        drive_service_cycle(&mut engine, &current_config);
        thread::sleep(Duration::from_millis(100));
    }

    #[allow(unreachable_code)]
    Ok(())
}

fn drive_service_cycle(engine: &mut state::ServiceEngine, config: &config::ServiceConfig) {
    const MAX_TRANSITIONS_PER_CYCLE: usize = 4;

    for _ in 0..MAX_TRANSITIONS_PER_CYCLE {
        let transition = engine.tick(config);
        let current = transition.current;
        let changed = transition.changed;
        log_state_transition(transition);

        if !changed
            || !matches!(
                current,
                state::ServicePhase::WaitingForEnrollment
                    | state::ServicePhase::GeneratingKey
                    | state::ServicePhase::SubmittingCsr
                    | state::ServicePhase::RenewalDue
            )
        {
            break;
        }
    }
}

fn log_config_snapshot(context: &str, config: &config::ServiceConfig) {
    info!(
        context = %context,
        sources = %config.source_summary(),
        has_server_url = config.server_url.is_some(),
        server_url = %config.server_url.as_deref().unwrap_or("<missing>"),
        has_client_uid = config.client_uid.is_some(),
        client_uid = %config.client_uid.as_deref().unwrap_or("<missing>"),
        has_device_id = config.device_id.is_some(),
        device_id = %config.device_id.as_deref().unwrap_or("<missing>"),
        has_enrollment_secret = config.has_bootstrap_secret(),
        poll_interval_secs = config.effective_poll_interval().as_secs(),
        renew_before_secs = config.renew_before.as_secs(),
        log_level = %config.log_level,
        "service configuration snapshot"
    );

    for warning in &config.warnings {
        warn!(context = %context, warning = %warning, "service configuration warning");
    }
}

fn log_state_transition(transition: state::StateTransition) {
    if transition.current == state::ServicePhase::ErrorBackoff {
        if transition.changed {
            warn!(
                previous = transition.previous.as_str(),
                current = transition.current.as_str(),
                changed = transition.changed,
                detail = %transition.detail,
                "service state backoff"
            );
        } else {
            info!(
                state = transition.current.as_str(),
                detail = %transition.detail,
                "service state backoff pending"
            );
        }
        return;
    }

    if transition.changed {
        info!(
            previous = transition.previous.as_str(),
            current = transition.current.as_str(),
            detail = %transition.detail,
            "service state updated"
        );
    } else {
        info!(
            state = transition.current.as_str(),
            detail = %transition.detail,
            "service state unchanged"
        );
    }
}
