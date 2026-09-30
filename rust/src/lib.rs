use serde::Serialize;
use std::net::IpAddr;

pub mod preview;

#[cfg(windows)]
pub mod windows;

/// FILETIME ticks (100 ns since 1601-01-01 UTC), preserved without rounding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Identity {
    pub pid: u32,
    pub started_filetime: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Connection {
    pub local: String,
    pub remote: String,
    pub created_filetime: i64,
}

#[derive(Debug, Serialize)]
pub struct Client {
    pub identity: Identity,
    pub connections: Vec<Connection>,
    pub windows: Vec<Window>,
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub hwnd: usize,
    pub minimized: bool,
}

#[derive(Debug, Serialize)]
pub struct Snapshot {
    pub schema_version: u32,
    pub sampled_unix_ms: u128,
    pub clients: Vec<Client>,
    pub errors: Vec<String>,
}

impl Snapshot {
    /// Incomplete observations must never become an online / no-process verdict.
    pub fn exit_code(&self) -> u8 {
        if !self.errors.is_empty() {
            3
        } else if self.clients.is_empty() {
            2
        } else if self.clients.iter().any(|c| c.connections.is_empty()) {
            1
        } else {
            0
        }
    }
}

pub const IGNORED_PORTS: [u16; 3] = [80, 443, 8080];

/// Match the legacy address filter, with explicit unspecified/mapped IPv6 handling.
pub fn is_game_connection(established: bool, address: IpAddr, port: u16) -> bool {
    let address = match address {
        IpAddr::V6(ip) => ip.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(address),
        _ => address,
    };
    established
        && !address.is_loopback()
        && !address.is_unspecified()
        && !IGNORED_PORTS.contains(&port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_only_established_non_web_non_loopback_connections() {
        for address in [
            "127.0.0.1",
            "127.2.3.4",
            "0.0.0.0",
            "::1",
            "::",
            "::ffff:127.0.0.1",
            "::ffff:0.0.0.0",
        ] {
            assert!(!is_game_connection(true, address.parse().unwrap(), 10011));
        }
        for address in [
            "192.0.2.12",
            "2001:db8::12",
            "::ffff:192.0.2.12",
            "10.0.0.2",
        ] {
            let ip = address.parse().unwrap();
            assert!(is_game_connection(true, ip, 10011));
            assert!(!is_game_connection(false, ip, 10011));
            for port in IGNORED_PORTS {
                assert!(!is_game_connection(true, ip, port));
            }
        }
    }

    #[test]
    fn once_verdict_includes_all_clients_and_preserves_unknown() {
        let mut s = Snapshot {
            schema_version: 1,
            sampled_unix_ms: 0,
            clients: vec![],
            errors: vec![],
        };
        assert_eq!(s.exit_code(), 2);
        s.clients.push(Client {
            identity: Identity {
                pid: 10,
                started_filetime: 1,
            },
            connections: vec![],
            windows: vec![],
        });
        assert_eq!(s.exit_code(), 1);
        s.clients[0].connections.push(Connection {
            local: "local".into(),
            remote: "remote".into(),
            created_filetime: 1,
        });
        assert_eq!(s.exit_code(), 0);
        s.clients.push(Client {
            identity: Identity {
                pid: 20,
                started_filetime: 2,
            },
            connections: vec![],
            windows: vec![],
        });
        assert_eq!(s.exit_code(), 1);
        s.errors.push("TCP query failed".into());
        assert_eq!(s.exit_code(), 3);
        s.clients.clear();
        assert_eq!(s.exit_code(), 3);
    }
}
