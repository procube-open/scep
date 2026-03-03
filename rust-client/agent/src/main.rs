mod store;

fn main() {
    #[cfg(windows)]
    {
        if let Err(err) = store::run() {
            eprintln!("agent failed: {err}");
            std::process::exit(1);
        }
    }

    #[cfg(not(windows))]
    {
        println!("agent helper is active only on Windows targets");
    }
}
