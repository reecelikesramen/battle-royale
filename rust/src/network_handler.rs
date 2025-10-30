use crate::packet::prelude::*;
use gns::sys::{
    ESteamNetworkingConfigValue, ESteamNetworkingConnectionState,
    ESteamNetworkingSocketsDebugOutputType, k_nSteamNetworkingSend_Reliable,
};
use gns::{
    GnsConfig, GnsConnection, GnsGlobal, GnsSocket, IsClient, IsServer,
    sys::k_nSteamNetworkingSend_Unreliable,
};
use godot::classes::INode;
use godot::classes::Node;
use godot::prelude::*;
use std::sync::{Arc, Mutex, OnceLock};
use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, Ipv4Addr},
    time::Instant,
};

const DEFAULT_IP_ADDRESS: IpAddr = IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0));
const DEFAULT_PORT: i64 = 45876;

/* TODO: unwrap must be banned */

// Global debug message queue accessible from GNS callbacks
static DEBUG_QUEUE: OnceLock<Arc<Mutex<VecDeque<String>>>> = OnceLock::new();

// Helper function to queue debug messages from GNS callbacks
fn queue_debug_message(prefix: &str, ty: ESteamNetworkingSocketsDebugOutputType, message: String) {
    if let Some(queue) = DEBUG_QUEUE.get() {
        if let Ok(mut q) = queue.lock() {
            q.push_back(format!("[{}] {ty:#?}: {message}", prefix));
            // Limit queue size to prevent memory issues
            if q.len() > 1000 {
                q.pop_front();
            }
        }
    }
}

// Function pointer compatible callbacks for GNS
fn server_debug_callback(ty: ESteamNetworkingSocketsDebugOutputType, message: String) {
    queue_debug_message("GNS Server", ty, message);
}

fn client_debug_callback(ty: ESteamNetworkingSocketsDebugOutputType, message: String) {
    queue_debug_message("GNS Client", ty, message);
}

#[derive(GodotClass)]
#[class(base=Node)]
struct NetworkHandler {
    base: Base<Node>,

    /* common vars */
    #[var]
    is_connected: bool,
    #[var]
    is_server: bool,
    gns_global: Arc<GnsGlobal>,
    last_update: Instant,

    /* server-side vars */
    server: Option<GnsSocket<IsServer>>,
    available_peer_ids: Vec<i64>,
    connected_clients: HashMap<GnsConnection, u8>,

    /* client-side vars */
    client: Option<GnsSocket<IsClient>>,

    /* thread-safe debug message queue */
    debug_messages: Arc<Mutex<VecDeque<String>>>,
}

#[godot_api]
impl INode for NetworkHandler {
    fn init(base: Base<Node>) -> Self {
        godot_print!("NetworkHandler initialized");

        let gns_global = GnsGlobal::get().unwrap_or_else(|_| {
            godot_print!("ERROR: Failed to get GnsGlobal instance");
            panic!("GnsGlobal initialization failed");
        });

        // Initialize global debug queue
        let debug_queue = Arc::new(Mutex::new(VecDeque::new()));
        let _ = DEBUG_QUEUE.set(debug_queue.clone());

        Self {
            base,
            is_connected: false,
            is_server: false,
            gns_global,
            server: None,
            last_update: Instant::now(),
            available_peer_ids: vec![],
            connected_clients: HashMap::new(),
            client: None,
            debug_messages: debug_queue,
        }
    }

    fn physics_process(&mut self, _delta: f64) {
        self.handle_events();
        self.process_debug_messages();
    }
}

#[godot_api]
impl NetworkHandler {
    /* server-side signals */
    #[signal]
    fn on_peer_connect(peer_id: i64);
    #[signal]
    fn on_peer_disconnect(peer_id: i64);
    #[signal]
    fn on_server_packet(peer_id: i64, packet: Gd<Object>);

    /* client-side signals */
    #[signal]
    fn on_connect_to_server();
    #[signal]
    fn on_disconnect_from_server();
    #[signal]
    fn on_client_packet(packet: Gd<Object>);

    fn _start_server(&mut self, ip_address: IpAddr, port: i64) {
        self.is_server = true;
        self.available_peer_ids = (0..100).rev().collect();

        // Setup debugging to log everything.
        // Use function pointer to safely queue messages from GNS thread
        self.gns_global.utils().enable_debug_output(
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Everything,
            server_debug_callback,
        );

        // // Add fake 1000ms ping to everyone connecting.
        // self.gns_global.utils().set_global_config_value(
        //     ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLag_Recv,
        //     GnsConfig::Int32(1000),
        // ).unwrap_or_else(|e| {
        //     godot_print!("ERROR: Failed to set global config value: {:#?}", e);
        //     panic!("Failed to configure fake ping");
        // });

        self.server = GnsSocket::new(self.gns_global.clone())
            .listen(ip_address, port.try_into().unwrap())
            .ok();

        self.is_connected = true;
    }

    #[func]
    fn start_server(&mut self, ip_address: String, port: i64) {
        let addr = ip_address.parse().unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to parse IP address '{}': {}", ip_address, e);
            panic!("Invalid IP address");
        });
        self._start_server(addr, port);
    }

    #[func]
    fn start_server_with_port(&mut self, port: i64) {
        self._start_server(DEFAULT_IP_ADDRESS, port);
    }

    #[func]
    fn start_server_default(&mut self) {
        self._start_server(DEFAULT_IP_ADDRESS, DEFAULT_PORT);
    }

    fn _start_client(&mut self, ip_address: IpAddr, port: i64) {
        self.is_server = false;

        // Setup debugging using function pointer to safely queue messages from GNS thread
        self.gns_global.utils().enable_debug_output(
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Everything,
            client_debug_callback,
        );

        self.client = GnsSocket::new(self.gns_global.clone())
            .connect(ip_address, port.try_into().unwrap())
            .ok();

        self.is_connected = true;
    }

    #[func]
    fn start_client(&mut self, ip_address: String, port: i64) {
        godot_print!("Starting client to {}:{}", ip_address, port);
        let addr = ip_address.parse().unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to parse IP address '{}': {}", ip_address, e);
            panic!("Invalid IP address");
        });
        self._start_client(addr, port);
    }

    #[func]
    fn start_client_with_port(&mut self, port: i64) {
        self._start_client(DEFAULT_IP_ADDRESS, port);
    }

    #[func]
    fn start_client_default(&mut self) {
        self._start_client(DEFAULT_IP_ADDRESS, DEFAULT_PORT);
    }

    #[func]
    fn disconnect_client(&mut self) {
        self.client = None;
        self.is_connected = false;
        self.signals().on_disconnect_from_server().emit();
    }

    #[func]
    fn destroy_server(&mut self) {
        self.server = None;
        self.is_connected = false;
    }

    fn _send_packet(&self, packet: &Packet) {
        if self.is_server {
            return;
        }

        let client = self.client.as_ref().unwrap_or_else(|| {
            godot_print!("ERROR: Client not initialized");
            panic!("Client socket not initialized");
        });

        client.send_messages(vec![self.gns_global.utils().allocate_message(
            client.connection(),
            if packet.is_reliable() {
                k_nSteamNetworkingSend_Reliable
            } else {
                k_nSteamNetworkingSend_Unreliable
            },
            packet.encode().as_slice(),
        )]);
    }

    #[func]
    fn send_packet(&self, packet: Gd<GdPacket>) {
        self._send_packet(&packet.bind().packet);
    }

    fn _broadcast_packet(&self, packet: &Packet) {
        if !self.is_server {
            return;
        }

        let server = self.server.as_ref().unwrap_or_else(|| {
            godot_print!("ERROR: Server not initialized");
            panic!("Server socket not initialized");
        });

        let messages = self
            .connected_clients
            .keys()
            .clone()
            .into_iter()
            .map(|client| {
                self.gns_global.utils().allocate_message(
                    *client,
                    if packet.is_reliable() {
                        k_nSteamNetworkingSend_Reliable
                    } else {
                        k_nSteamNetworkingSend_Unreliable
                    },
                    packet.encode().as_slice(),
                )
            })
            .collect::<Vec<_>>();

        server.send_messages(messages);
    }

    #[func]
    fn broadcast_packet(&self, packet: Gd<GdPacket>) {
        self._broadcast_packet(&packet.bind().packet);
    }

    fn process_debug_messages(&mut self) {
        if let Ok(mut queue) = self.debug_messages.lock() {
            // Process up to 10 messages per frame to avoid blocking
            for _ in 0..10 {
                if let Some(message) = queue.pop_front() {
                    godot_print!("{}", message);
                } else {
                    break;
                }
            }
        }
    }

    fn queue_debug(&self, message: String) {
        if let Ok(mut queue) = self.debug_messages.lock() {
            queue.push_back(message);
            if queue.len() > 1000 {
                queue.pop_front();
            }
        }
    }

    fn handle_events(&mut self) {
        if !self.is_connected {
            return;
        }

        if self.is_server {
            self.handle_server_events();
        } else {
            self.handle_client_events();
        }
    }

    fn handle_client_events(&mut self) {
        self.gns_global.poll_callbacks();

        let client = self.client.as_ref().unwrap_or_else(|| {
            godot_print!("ERROR: Client not initialized");
            panic!("Client socket not initialized");
        });

        let mut packets_to_emit = Vec::new();

        // Process some messages, we arbitrary define 100 as being the max number of messages we can handle per iteration.
        let _messages_processed = client.poll_messages::<100>(|message| {
            let packet = Packet::decode(message.payload());

            match packet {
                Ok(packet) => {
                    packets_to_emit.push(packet.as_gd());
                }
                Err(e) => {
                    self.queue_debug(format!(
                        "ERROR: Failed to decode packet: {}, raw data {:x?}",
                        e,
                        &message.payload()
                    ));
                }
            }
        });

        let mut emit_disconnect = false;
        let mut emit_connect = false;
        client.poll_event::<100>(|event| match (event.old_state(), event.info().state()) {
            (
                ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None,
                ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
            ) => {
                self.queue_debug("GnsSocket<Client>: connecting to server.".to_string());
            }
            (
                ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
                ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected,
            ) => {
                self.queue_debug("GnsSocket<Client>: connected to server.".to_string());
                emit_connect = true;
            }
            (_, ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ClosedByPeer | ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ProblemDetectedLocally) => {
                // We got disconnected or lost the connection.
                self.queue_debug("GnsSocket<Client>: ET phone home.".to_string());
                emit_disconnect = true;
            }
            (previous, current) => {
                self.queue_debug(format!("GnsSocket<Client>: {:#?} => {:#?}.", previous, current));
            }
        });

        if emit_disconnect {
            self.is_connected = false;
            self.signals().on_disconnect_from_server().emit();
            self.client = None;
        }

        if emit_connect {
            self.signals().on_connect_to_server().emit();
        }

        for packet in packets_to_emit {
            self.signals().on_client_packet().emit(&packet);
        }
    }

    fn handle_server_events(&mut self) {
        let server = self.server.take().unwrap_or_else(|| {
            godot_print!("ERROR: Server not initialized");
            panic!("Server socket not initialized");
        });

        let now = Instant::now();
        let elapsed = now - self.last_update;
        if elapsed.as_secs() > 10 {
            self.last_update = now;
            for (client, nick) in self.connected_clients.clone().into_iter() {
                let info = server.get_connection_info(client).unwrap_or_else(|| {
                    self.queue_debug(format!("ERROR: Failed to get connection info for {nick}"));
                    panic!()
                });
                let (status, _) = server
                    .get_connection_real_time_status(client, 0)
                    .unwrap_or_else(|_| {
                        self.queue_debug(format!(
                            "ERROR: Failed to get real time status for {nick}"
                        ));
                        panic!()
                    });
                self.queue_debug(format!(
                  "== Client {:#?}\n\tIP: {:#?}\n\tPing: {:#?}\n\tOut/sec: {:#?}\n\tIn/sec: {:#?}",
                    nick,
                    info.remote_address(),
                    status.ping(),
                    status.out_bytes_per_sec(),
                    status.in_bytes_per_sec(),
                ));
            }
        }

        // Poll internal callbacks
        self.gns_global.poll_callbacks();

        let mut packets_to_emit: Vec<(i64, Gd<Object>)> = Vec::new();
        let mut peer_connects_to_emit: Vec<i64> = Vec::new();
        let mut peer_disconnects_to_emit: Vec<i64> = Vec::new();

        // Process connections events.
        let _events_processed = server.poll_event::<100>(|event| {
          match (event.old_state(), event.info().state()) {
            // A client is about to connect, accept it.
            (
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None,
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
            ) => {
                if self.available_peer_ids.is_empty() {
                    self.queue_debug(format!("GnsSocket<Server>: no available peer ids"));
                    server.close_connection(event.connection(), 0, "Server is full", false);
                } else {
                    let result = server.accept(event.connection());
                    self.queue_debug(format!("GnsSocket<Server>: accepted new client: {:#?}.", result));
                    self.queue_debug(format!("GnsSocket<Server>: number of clients: {:#?}.", self.connected_clients.len()));
                }
            }

            // A client is connected, we previously accepted it and don't do anything here.
            // In a more sophisticated scenario we could initial sending some messages.
            (
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected,
            ) => {
                match self.available_peer_ids.pop() {
                    Some(peer_id) => {
                        self.connected_clients.insert(event.connection(), peer_id.try_into().unwrap());
                        self.queue_debug(format!("GnsSocket<Server>: new client connected with peer id: {:#?}.", peer_id));
                        peer_connects_to_emit.push(peer_id);
                    }
                    None => {
                        self.queue_debug(format!("GnsSocket<Server>: no available peer ids, this should not happen"));
                        server.close_connection(event.connection(), 0, "Server is full", false);
                    },
                }
            }

            (_, ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ClosedByPeer | ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ProblemDetectedLocally) => {
              // Remove the client from the list and close the connection.
              let conn = event.connection();
              match self.connected_clients.remove(&conn) {
                Some(peer_id) => {
                  self.queue_debug(format!("GnsSocket<Server>: {:#?} disconnected with peer id: {:#?}.", conn, peer_id));
                  peer_disconnects_to_emit.push(peer_id.try_into().unwrap());
                }
                None => {
                  self.queue_debug(format!("GnsSocket<Server>: {:#?} disconnected, but not found in connected clients", conn));
                }
              }
              // Make sure we cleanup the connection, mandatory as per GNS doc.
              self.queue_debug(format!("GnsSocket<Server>: closing connection for {:#?}.", conn));
              server.close_connection(conn, 0, "", false);
            }

            // A client state is changing, perhaps disconnecting
            // If a client disconnected and it's connection get cleaned up, its state goes back to `ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None`
            (previous, current) => {
              self.queue_debug(format!("GnsSocket<Server>: {:#?} => {:#?}.", previous, current));
            }
          }
        });

        // Process some messages, we arbitrary define 100 as being the max number of messages we can handle per iteration.
        let _messages_processed = server.poll_messages::<100>(|message| {
            let packet = Packet::decode(message.payload());

            let peer_id: i64 = match self.connected_clients.get(&message.connection()) {
                Some(peer_id) => (*peer_id).try_into().unwrap(),
                None => {
                    self.queue_debug(format!(
                        "ERROR: Failed to get peer id for connection: {:#?}",
                        message.connection()
                    ));
                    return;
                }
            };

            match packet {
                Ok(packet) => {
                    packets_to_emit.push((peer_id, packet.as_gd()));
                }
                Err(e) => {
                    self.queue_debug(format!(
                        "ERROR: Failed to decode packet: {}, raw data {:x?}",
                        e,
                        &message.payload()
                    ));
                }
            }
        });

        self.server = Some(server);

        for peer_id in peer_connects_to_emit {
            self.signals().on_peer_connect().emit(peer_id);
        }

        for peer_id in peer_disconnects_to_emit {
            self.signals().on_peer_disconnect().emit(peer_id);
        }

        for (peer_id, packet) in packets_to_emit {
            self.signals().on_server_packet().emit(peer_id, &packet);
        }
    }
}
