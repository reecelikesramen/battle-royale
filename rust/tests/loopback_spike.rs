//! Phase 0.1 spike — same-thread GNS loopback feasibility.
//!
//! Verifies a single thread can own both `GnsSocket<IsServer>` and
//! `GnsSocket<IsClient>` simultaneously, drive their polls sequentially, and
//! round-trip messages between them on localhost. If this hangs or fails, the
//! listen-server transport plan needs to fall back to in-memory channels.

use gns::sys::{
    ESteamNetworkingConnectionState, k_nSteamNetworkingSend_Reliable,
};
use gns::{GnsConnection, GnsGlobal, GnsSocket};
use std::net::{IpAddr, Ipv4Addr};
use std::time::{Duration, Instant};

const TEST_PORT: u16 = 47876;
const TEST_IP: IpAddr = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
const MAX_ITERS: u32 = 400;

#[test]
fn same_thread_loopback_handshake_and_roundtrip() {
    let gns_global = GnsGlobal::get().expect("get GnsGlobal");

    let server = GnsSocket::new(gns_global.clone())
        .listen(TEST_IP, TEST_PORT)
        .expect("server listen");
    let client = GnsSocket::new(gns_global.clone())
        .connect(TEST_IP, TEST_PORT)
        .expect("client connect");

    let mut server_peer_conn: Option<GnsConnection> = None;
    let mut client_connected = false;
    let mut server_received: Vec<Vec<u8>> = Vec::new();
    let mut client_received: Vec<Vec<u8>> = Vec::new();
    let mut sent_c2s = false;
    let mut sent_s2c = false;

    let start = Instant::now();

    for iter in 0..MAX_ITERS {
        gns_global.poll_callbacks();

        // Server connection events: accept new, capture connected peer.
        let _ = server.poll_event::<128>(|event| {
            let old = event.old_state();
            let new = event.info().state();
            if old == ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None
                && new == ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting
            {
                let _ = server.accept(event.connection());
            } else if old == ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting
                && new == ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected
            {
                server_peer_conn = Some(event.connection());
            }
        });

        // Client connection state.
        let _ = client.poll_event::<128>(|event| {
            if event.info().state()
                == ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected
            {
                client_connected = true;
            }
        });

        // Once handshake complete, send one packet each direction.
        if client_connected && server_peer_conn.is_some() {
            if !sent_c2s {
                client.send_messages(vec![gns_global.utils().allocate_message(
                    client.connection(),
                    k_nSteamNetworkingSend_Reliable,
                    b"ping",
                )]);
                sent_c2s = true;
            }
            if !sent_s2c {
                if let Some(conn) = server_peer_conn {
                    server.send_messages(vec![gns_global.utils().allocate_message(
                        conn,
                        k_nSteamNetworkingSend_Reliable,
                        b"pong",
                    )]);
                    sent_s2c = true;
                }
            }
        }

        // Drain inbound messages.
        let _ = server.poll_messages::<128>(|msg| {
            server_received.push(msg.payload().to_vec());
        });
        let _ = client.poll_messages::<128>(|msg| {
            client_received.push(msg.payload().to_vec());
        });

        if !server_received.is_empty() && !client_received.is_empty() {
            eprintln!(
                "[spike] handshake + roundtrip done after {} iters ({}ms)",
                iter + 1,
                start.elapsed().as_millis()
            );
            break;
        }

        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(
        client_connected,
        "client did not reach Connected within {} iters",
        MAX_ITERS
    );
    assert!(
        server_peer_conn.is_some(),
        "server did not see Connected peer within {} iters",
        MAX_ITERS
    );
    assert!(
        server_received.iter().any(|p| p == b"ping"),
        "server did not receive ping. payloads: {:?}",
        server_received
    );
    assert!(
        client_received.iter().any(|p| p == b"pong"),
        "client did not receive pong. payloads: {:?}",
        client_received
    );
}
