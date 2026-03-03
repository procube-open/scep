use std::fs;
use std::io;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;

const LOG_DIR: &str = r"C:\ProgramData\MyTunnelApp\logs";
const LOG_FILE_PREFIX: &str = "service.log";
#[cfg(windows)]
const EVENTLOG_SOURCE: &str = "MyTunnelService";

pub fn init_logging() -> Result<WorkerGuard, io::Error> {
    fs::create_dir_all(LOG_DIR)?;

    let appender = tracing_appender::rolling::daily(LOG_DIR, LOG_FILE_PREFIX);
    let (non_blocking, guard) = tracing_appender::non_blocking(appender);
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,service=info"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(non_blocking)
        .try_init()
        .map_err(|err| {
            io::Error::other(format!("failed to initialize tracing subscriber: {err}"))
        })?;

    Ok(guard)
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
