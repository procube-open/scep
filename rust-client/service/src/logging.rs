use std::fs;
use std::io;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;

const LOG_DIR: &str = r"C:\ProgramData\MyTunnelApp\logs";
const LOG_FILE_PREFIX: &str = "service.log";
#[cfg(windows)]
const EVENTLOG_SOURCE: &str = "MyTunnelService";
const FALLBACK_LOG_FILTER: &str = "info,service=info";

pub fn init_logging(default_level: &str) -> Result<WorkerGuard, io::Error> {
    fs::create_dir_all(LOG_DIR)?;

    let appender = tracing_appender::rolling::daily(LOG_DIR, LOG_FILE_PREFIX);
    let (non_blocking, guard) = tracing_appender::non_blocking(appender);
    let filter = build_env_filter(default_level);

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(non_blocking)
        .try_init()
        .map_err(|err| {
            io::Error::other(format!("failed to initialize tracing subscriber: {err}"))
        })?;

    Ok(guard)
}

fn build_env_filter(default_level: &str) -> EnvFilter {
    if std::env::var_os("RUST_LOG").is_some() {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(FALLBACK_LOG_FILTER))
    } else {
        let directive = format!("{default_level},service={default_level}");
        EnvFilter::try_new(directive).unwrap_or_else(|_| EnvFilter::new(FALLBACK_LOG_FILTER))
    }
}

#[cfg(windows)]
pub fn write_fatal_eventlog(message: &str) {
    use eventlog::EventLog;
    use log::{Level, Log, Record};

    let _ = eventlog::register(EVENTLOG_SOURCE);

    let logger = match EventLog::new(EVENTLOG_SOURCE, Level::Error) {
        Ok(logger) => logger,
        Err(err) => {
            eprintln!(
                "failed to initialize Windows eventlog writer: {err}; original error: {message}"
            );
            return;
        }
    };

    let args = format_args!("{message}");
    let record = Record::builder()
        .level(Level::Error)
        .target(EVENTLOG_SOURCE)
        .args(args)
        .build();
    logger.log(&record);
}

#[cfg(not(windows))]
pub fn write_fatal_eventlog(message: &str) {
    eprintln!("FATAL EVENTLOG: {message}");
}
