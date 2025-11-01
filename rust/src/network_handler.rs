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
    time::{Duration, Instant},
};

const DEFAULT_IP_ADDRESS: IpAddr = IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0));
const DEFAULT_PORT: i64 = 45876;
const PLAYER_COUNT: u8 = 100;
const MAX_MESSAGES_PER_POLL: usize = 256;
const MAX_EVENTS_PER_POLL: usize = 128;
const POLL_TIME_BUDGET_MS: u64 = 2;

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

fn i64_to_u32(value: i64) -> u32 {
    value.try_into().map_err(|e| {
        godot_print!("ERROR: Failed to convert {value} to u32: {:#?}", e);
    }).unwrap_or(0)
}

#[derive(GodotClass)]
#[class(base=Node)]
struct NetworkHandler {
    base: Base<Node>,

    /* server-side vars */
    server: Option<GnsSocket<IsServer>>,
    available_peer_ids: Vec<u8>,
    connected_clients: HashMap<GnsConnection, u8>,

    /* client-side vars */
    client: Option<GnsSocket<IsClient>>,
    #[var]
    client_ping: i64,

    /* common vars */
    #[var]
    is_connected: bool,
    #[var]
    is_server: bool,
    gns_global: Arc<GnsGlobal>,
    last_update: Instant,

    /* config/debug exports */
    #[export]
    #[var(get=get_fake_ping_lag_send, set=set_fake_ping_lag_send)]
    fake_ping_lag_send: i64,
    #[export]
    #[var(get=get_fake_ping_lag_recv, set=set_fake_ping_lag_recv)]
    fake_ping_lag_recv: i64,
    #[export]
    #[var(get=get_fake_loss_send, set=set_fake_loss_send)]
    fake_loss_send: i64,
    #[export]
    #[var(get=get_fake_loss_recv, set=set_fake_loss_recv)]
    fake_loss_recv: i64,
    #[export]
    #[var(get=get_fake_jitter_send, set=set_fake_jitter_send)]
    fake_jitter_send: i64,
    #[export]
    #[var(get=get_fake_jitter_recv, set=set_fake_jitter_recv)]
    fake_jitter_recv: i64,
    #[export]
    #[var(get=get_fake_dup_send, set=set_fake_dup_send)]
    fake_dup_send: i64,
    #[export]
    #[var(get=get_fake_dup_recv, set=set_fake_dup_recv)]
    fake_dup_recv: i64,
    #[export]
    #[var(get=get_fake_dup_ms_max, set=set_fake_dup_ms_max)]
    fake_dup_ms_max: i64,
    #[export]
    #[var(get=get_fake_reorder_send, set=set_fake_reorder_send)]
    fake_reorder_send: i64,
    #[export]
    #[var(get=get_fake_reorder_recv, set=set_fake_reorder_recv)]
    fake_reorder_recv: i64,
    #[export]
    #[var(get=get_fake_reorder_ms, set=set_fake_reorder_ms)]
    fake_reorder_ms: i64,

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
            available_peer_ids: (0..PLAYER_COUNT).rev().collect(),
            connected_clients: HashMap::new(),
            client: None,
            client_ping: 0,
            fake_ping_lag_send: 0,
            fake_ping_lag_recv: 0,
            fake_loss_send: 0,
            fake_loss_recv: 0,
            fake_jitter_send: 0,
            fake_jitter_recv: 0,
            fake_dup_send: 0,
            fake_dup_recv: 0,
            fake_dup_ms_max: 0,
            fake_reorder_send: 0,
            fake_reorder_recv: 0,
            fake_reorder_ms: 0,
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
    fn on_disconnect_from_server(end_reason: i64);
    #[signal]
    fn on_client_packet(packet: Gd<Object>);

    fn _start_server(&mut self, ip_address: IpAddr, port: i64) {
        self.is_server = true;

        // Setup debugging to log everything.
        // Use function pointer to safely queue messages from GNS thread
        self.gns_global.utils().enable_debug_output(
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_None,
            server_debug_callback,
        );

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
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_None,
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
        self.signals().on_disconnect_from_server().emit(1000);
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

        self.client_ping = client.get_connection_real_time_status(client.connection(), 0).and_then(|(status, _)| Ok(status.ping())).unwrap_or(0) as i64;

        let mut packets_to_emit = Vec::new();

        let poll_deadline = Instant::now() + Duration::from_millis(POLL_TIME_BUDGET_MS);
        loop {
            let processed = client.poll_messages::<MAX_MESSAGES_PER_POLL>(|message| {
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
            let processed_count = processed.unwrap_or(0);

            if processed_count == 0 || Instant::now() >= poll_deadline {
                break;
            }
        }

        let mut emit_disconnect = -1;
        let mut emit_connect = false;
        loop {
            let processed = client.poll_event::<MAX_EVENTS_PER_POLL>(|event| match (event.old_state(), event.info().state()) {
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
                emit_disconnect = event.info().end_reason() as i64;
            }
            (previous, current) => {
                self.queue_debug(format!("GnsSocket<Client>: {:#?} => {:#?}.", previous, current));
            }
        });

            if processed == 0 || Instant::now() >= poll_deadline {
                break;
            }
        }

        if emit_disconnect != -1 {
            self.is_connected = false;
            self.signals().on_disconnect_from_server().emit(emit_disconnect);
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
        let mut peer_connects_to_emit: Vec<u8> = Vec::new();
        let mut peer_disconnects_to_emit: Vec<u8> = Vec::new();
        let poll_deadline = Instant::now() + Duration::from_millis(POLL_TIME_BUDGET_MS);

        // Process connections events.
        loop {
            let processed = server
                .poll_event::<MAX_EVENTS_PER_POLL>(|event| {
                    match (event.old_state(), event.info().state()) {
                        (
                            ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None,
                            ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
                        ) => {
                            if self.available_peer_ids.is_empty() {
                                self.queue_debug(format!("GnsSocket<Server>: no available peer ids"));
                                server.close_connection(event.connection(), 1001, "Server is full", false);
                            } else {
                                let result = server.accept(event.connection());
                                self.queue_debug(format!("GnsSocket<Server>: accepted new client: {:#?}.", result));
                                self.queue_debug(format!(
                                    "GnsSocket<Server>: number of clients: {:#?}.",
                                    self.connected_clients.len()
                                ));
                            }
                        }
                        (
                            ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
                            ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected,
                        ) => {
                            match self.available_peer_ids.pop() {
                                Some(peer_id) => {
                                    self.connected_clients.insert(event.connection(), peer_id.try_into().unwrap());
                                    self.queue_debug(format!(
                                        "GnsSocket<Server>: new client connected with peer id: {:#?}.",
                                        peer_id
                                    ));
                                    peer_connects_to_emit.push(peer_id);
                                }
                                None => {
                                    self.queue_debug(format!(
                                        "GnsSocket<Server>: no available peer ids, this should not happen"
                                    ));
                                    server.close_connection(event.connection(), 2000, "Server is full", false);
                                }
                            }
                        }
                        (
                            _,
                            ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ClosedByPeer
                                | ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                        ) => {
                            let conn = event.connection();
                            match self.connected_clients.remove(&conn) {
                                Some(peer_id) => {
                                    self.queue_debug(format!(
                                        "GnsSocket<Server>: {:#?} disconnected with peer id: {:#?}.",
                                        conn,
                                        peer_id
                                    ));
                                    peer_disconnects_to_emit.push(peer_id);
                                }
                                None => {
                                    self.queue_debug(format!(
                                        "GnsSocket<Server>: {:#?} disconnected, but not found in connected clients",
                                        conn
                                    ));
                                }
                            }
                            self.queue_debug(format!("GnsSocket<Server>: closing connection for {:#?}.", conn));
                            server.close_connection(conn, 1002, "Closing connection ended by client", false);
                        }
                        (previous, current) => {
                            self.queue_debug(format!("GnsSocket<Server>: {:#?} => {:#?}.", previous, current));
                        }
                    }
                });

            if processed == 0 || Instant::now() >= poll_deadline {
                break;
            }
        }

        // Process messages with bounded batches and time budget.
        loop {
            let processed = server
                .poll_messages::<MAX_MESSAGES_PER_POLL>(|message| {
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
            let processed_count = processed.unwrap_or(0);

            if processed_count == 0 || Instant::now() >= poll_deadline {
                break;
            }
        }

        self.server = Some(server);

        for peer_id in peer_connects_to_emit {
            self.signals().on_peer_connect().emit(peer_id as i64);
        }

        for peer_id in peer_disconnects_to_emit {
            self.signals().on_peer_disconnect().emit(peer_id as i64);
            self.available_peer_ids.push(peer_id);
        }

        for (peer_id, packet) in packets_to_emit {
            self.signals().on_server_packet().emit(peer_id, &packet);
        }
    }

    #[func]
    fn get_fake_ping_lag_send(&self) -> i64 {
        self.fake_ping_lag_send
    }

    #[func]
    fn set_fake_ping_lag_send(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLag_Send,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_ping_lag_send = 0;
        });
        self.fake_ping_lag_send = value;
    }
    
    #[func]
    fn get_fake_ping_lag_recv(&self) -> i64 {
        self.fake_ping_lag_recv
    }

    #[func]
    fn set_fake_ping_lag_recv(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLag_Recv,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_ping_lag_recv = 0;
        });
        self.fake_ping_lag_recv = value;
    }

    #[func]
    fn get_fake_loss_send(&self) -> i64 {
        self.fake_loss_send
    }

    #[func]
    fn set_fake_loss_send(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLoss_Send,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_loss_send = 0;
        });
        self.fake_loss_send = value;
    }

    #[func]
    fn get_fake_loss_recv(&self) -> i64 {
        self.fake_loss_recv
    }

    #[func]
    fn set_fake_loss_recv(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLoss_Recv,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_loss_recv = 0;
        });
        self.fake_loss_recv = value;
    }

    #[func]
    fn get_fake_jitter_send(&self) -> i64 {
        self.fake_jitter_send
    }

    #[func]
    fn set_fake_jitter_send(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketJitter_Send_Avg,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_jitter_send = 0;
        });
        self.fake_jitter_send = value;
    }

    #[func]
    fn get_fake_jitter_recv(&self) -> i64 {
        self.fake_jitter_recv
    }

    #[func]
    fn set_fake_jitter_recv(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketJitter_Recv_Avg,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_jitter_recv = 0;
        });
        self.fake_jitter_recv = value;
    }

    #[func]
    fn get_fake_dup_send(&self) -> i64 {
        self.fake_dup_send
    }

    #[func]
    fn set_fake_dup_send(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketDup_Send,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_dup_send = 0;
        });
        self.fake_dup_send = value;
    }
    
    #[func]
    fn get_fake_dup_recv(&self) -> i64 {
        self.fake_dup_recv
    }

    #[func]
    fn set_fake_dup_recv(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketDup_Recv,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_dup_recv = 0;
        });
        self.fake_dup_recv = value;
    }

    #[func]
    fn get_fake_dup_ms_max(&self) -> i64 {
        self.fake_dup_ms_max
    }

    #[func]
    fn set_fake_dup_ms_max(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketDup_TimeMax,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_dup_ms_max = 0;
        });
        self.fake_dup_ms_max = value;
    }

    #[func]
    fn get_fake_reorder_send(&self) -> i64 {
        self.fake_reorder_send
    }

    #[func]
    fn set_fake_reorder_send(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketReorder_Send,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_reorder_send = 0;
        });
        self.fake_reorder_send = value;
    }

    #[func]
    fn get_fake_reorder_recv(&self) -> i64 {
        self.fake_reorder_recv
    }

    #[func]
    fn set_fake_reorder_recv(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketReorder_Recv,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_reorder_recv = 0;
        });
        self.fake_reorder_recv = value;
    }

    #[func]
    fn get_fake_reorder_ms(&self) -> i64 {
        self.fake_reorder_ms
    }

    #[func]
    fn set_fake_reorder_ms(&mut self, value: i64) {
        if !self.is_server {
            return;
        }
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketReorder_Time,
            GnsConfig::Int32(i64_to_u32(value)),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            self.fake_reorder_ms = 0;
        });
        self.fake_reorder_ms = value;
    }
}
