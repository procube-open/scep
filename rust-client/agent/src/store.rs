#[cfg(windows)]
pub fn run() -> Result<(), String> {
    // Initial release scope is LocalMachine\My only. CURRENT_USER write support is deferred.
    Ok(())
}
