//! gamepulse-cli.exe — console probe. The GUI is a separate exe (main.rs, gamepulse.exe)
//! Checks every game in `GAMES` at once; the exit code covers all clients.
//! Separate because the GUI must use the windows subsystem (no console popping up), which can't print stdout or return exit codes to a console.
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--help"] || args == ["-h"] {
        println!("GamePulse API probe (Windows 11 x64). The GUI is gamepulse.exe.\nChecks every supported game: {}.\n\n  --once       Print process/TCP/window snapshot as JSON\n  --capture    Capture the complete virtual desktop and print metadata\n  --capture-preview DIR  Also save one full-desktop BMP in DIR\n\nNo monitoring, internet check, configuration import or notifications.\nExit: 0 sockets present / capture succeeded, 1 missing socket / capture unavailable,\n      2 no clients, 3 observation or argument error. Socket presence is not proof of gameplay.", gamepulse::GAMES.iter().map(|g| format!("{} ({})", g.name, g.exe)).collect::<Vec<_>>().join(", "));
        return ExitCode::SUCCESS;
    }
    let preview = args.len() == 2 && args[0] == "--capture-preview" && !args[1].is_empty();
    if args != ["--once"] && args != ["--capture"] && !preview {
        eprintln!("Use --once, --capture, --capture-preview DIR or --help. No action performed.");
        return ExitCode::from(3);
    }
    #[cfg(windows)]
    {
        let snapshot = gamepulse::windows::snapshot(gamepulse::GAMES);
        if args == ["--capture"] || preview {
            let directory = if preview {
                Some(std::path::Path::new(&args[1]))
            } else {
                None
            };
            return gamepulse::windows::capture::run(&snapshot, directory);
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
