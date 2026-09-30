use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--help"] || args == ["-h"] {
        println!("ROOC Monitor API probe (Windows 11 x64)\n\n  --once       Print process/TCP/window snapshot as JSON\n  --capture    Probe a fresh WGC frame per game window (5s timeout each)\n  --capture-preview DIR  Also save BMP previews in DIR (explicit disk output)\n\nNo monitoring, internet check, configuration import or notifications.\nExit: 0 sockets present / capture succeeded, 1 missing socket / capture unavailable,\n      2 no clients, 3 observation or argument error. Socket presence is not proof of gameplay.");
        return ExitCode::SUCCESS;
    }
    let preview = args.len() == 2 && args[0] == "--capture-preview" && !args[1].is_empty();
    if args != ["--once"] && args != ["--capture"] && !preview {
        eprintln!("Use --once, --capture, --capture-preview DIR or --help. No action performed.");
        return ExitCode::from(3);
    }
    #[cfg(windows)]
    {
        let snapshot = rooc_monitor_probe::windows::snapshot();
        if args == ["--capture"] || preview {
            let directory = if preview {
                Some(std::path::Path::new(&args[1]))
            } else {
                None
            };
            return rooc_monitor_probe::windows::capture::run(&snapshot, directory);
        }
        match serde_json::to_string_pretty(&snapshot) {
            Ok(json) => println!("{json}"),
            Err(error) => {
                eprintln!("Cannot serialize snapshot: {error}");
                return ExitCode::from(3);
            }
        }
        ExitCode::from(snapshot.exit_code())
    }
    #[cfg(not(windows))]
    {
        eprintln!("This probe requires Windows 11 x64. No observation performed.");
        ExitCode::from(3)
    }
}
