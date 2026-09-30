use std::process::Command;

#[test]
fn help_does_not_observe_or_capture() {
    let output = Command::new(env!("CARGO_BIN_EXE_rooc-monitor-probe"))
        .arg("--help")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("No monitoring"));
}

#[test]
fn invalid_arguments_do_not_start_observation() {
    for args in [
        vec![],
        vec!["--capture", "--once"],
        vec!["--unknown"],
        vec!["--capture-preview"],
        vec!["--capture-preview", ""],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_rooc-monitor-probe"))
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(3));
        assert!(output.stdout.is_empty());
    }
}

#[cfg(not(windows))]
#[test]
fn unsupported_platform_never_reports_online() {
    for arg in ["--once", "--capture"] {
        let output = Command::new(env!("CARGO_BIN_EXE_rooc-monitor-probe"))
            .arg(arg)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(3));
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("requires Windows"));
    }
}
