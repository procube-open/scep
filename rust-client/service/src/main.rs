mod config;
mod logging;

#[cfg(not(windows))]
use std::thread;
use std::time::Duration;
#[cfg(windows)]
use std::{sync::mpsc, sync::mpsc::RecvTimeoutError};

#[cfg(windows)]
use tracing::error;
use tracing::info;

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
    let _guard =
        logging::init_logging().map_err(|err| format!("failed to initialize logs: {err}"))?;
    let cfg = config::ServiceConfig::load()?;
    info!(config_url = %cfg.config_url, "service configuration loaded");

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

        loop {
            match shutdown_rx.recv_timeout(Duration::from_secs(30)) {
                Ok(()) => break,
                Err(RecvTimeoutError::Timeout) => {}
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
        info!("service_main placeholder loop");
        thread::sleep(Duration::from_millis(100));
    }

    #[allow(unreachable_code)]
    Ok(())
}
