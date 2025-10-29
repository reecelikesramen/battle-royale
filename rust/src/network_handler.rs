use std::{collections::{HashMap, VecDeque}, net::{IpAddr, Ipv4Addr}, time::Instant};
use std::sync::{Arc, Mutex, OnceLock};
use gns::{GnsConfig, GnsConnection, GnsGlobal, GnsSocket, IsClient, IsServer};
use gns::sys::{ESteamNetworkingConfigValue, ESteamNetworkingConnectionState, ESteamNetworkingSocketsDebugOutputType, k_nSteamNetworkingSend_Reliable};
use godot::prelude::*;
use godot::classes::Node;
use godot::classes::INode;

const DEFAULT_IP_ADDRESS: IpAddr = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
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
    is_server: bool,
    gns_global: Arc<GnsGlobal>,
    last_update: Instant,
    
    /* server-side vars */
    server: Option<GnsSocket<IsServer>>,
    available_peer_ids: Vec<i64>,
    nonce: i64,
    client_peers: HashMap<GnsConnection, String>,

    /* client-side vars */
    client: Option<GnsSocket<IsClient>>,
    test_user_input_stream: Arc<Mutex<VecDeque<String>>>,

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
            available_peer_ids: (0..256).rev().collect(),
            nonce: 0,
            client_peers: HashMap::new(),
            client: None,
            test_user_input_stream: Arc::new(Mutex::new(VecDeque::new())),
            debug_messages: debug_queue,
        }
    }

    fn physics_process(&mut self, _delta: f64) {
        self.process_debug_messages();
        self.handle_events();
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
    fn on_server_packet(peer_id: i64, packet: PackedByteArray);

    /* client-side signals */
    #[signal]
    fn on_connect_to_server();
    #[signal]
    fn on_disconnect_from_server();
    #[signal]
    fn on_client_packet(packet: PackedByteArray);

    fn _start_server(&mut self, ip_address: IpAddr, port: i64) {
        self.is_connected = true;
        self.is_server = true;
        self.available_peer_ids = (0..256).rev().collect();

        // Setup debugging to log everything.
        // Use function pointer to safely queue messages from GNS thread
        self.gns_global.utils().enable_debug_output(
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Everything,
            server_debug_callback,
        );

        // Add fake 1000ms ping to everyone connecting.
        self.gns_global.utils().set_global_config_value(
            ESteamNetworkingConfigValue::k_ESteamNetworkingConfig_FakePacketLag_Recv,
            GnsConfig::Int32(1000),
        ).unwrap_or_else(|e| {
            godot_print!("ERROR: Failed to set global config value: {:#?}", e);
            panic!("Failed to configure fake ping");
        });

        self.server = GnsSocket::new(self.gns_global.clone())
            .listen(ip_address, port as u16).ok()
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
        self.is_connected = true;
        self.is_server = false;
        
        // Setup debugging using function pointer to safely queue messages from GNS thread
        self.gns_global.utils().enable_debug_output(
            ESteamNetworkingSocketsDebugOutputType::k_ESteamNetworkingSocketsDebugOutputType_Everything,
            client_debug_callback,
        );
    
        self.client = GnsSocket::new(self.gns_global.clone())
            .connect(ip_address, port as u16)
            .ok();
    }

    #[func]
    fn start_client(&mut self, ip_address: String, port: i64) {
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
    fn test_submit_user_input(&mut self, input: String) {
        godot_print!("Submitting input: {}", input);
        if let Ok(mut input_queue) = self.test_user_input_stream.lock() {
            input_queue.push_back(input);
        }
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

        // Process some messages, we arbitrary define 100 as being the max number of messages we can handle per iteration.
        let _messages_processed = client.poll_messages::<100>(|message| {
            let s = core::str::from_utf8(message.payload()).unwrap_or_else(|e| {
                self.queue_debug(format!("ERROR: Failed to decode UTF8 message: {}", e));
                ""
            });
            if !s.is_empty() {
                self.queue_debug(format!("[Client Chat] {}", s));
            }
        });

        let mut quit = false;
        let _ =
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
                }
                (_, ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ClosedByPeer | ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ProblemDetectedLocally) => {
                  // We got disconnected or lost the connection.
                  self.queue_debug("GnsSocket<Client>: ET phone home.".to_string());
                    quit = true;
                }
                (previous, current) => {
                    self.queue_debug(format!("GnsSocket<Client>: {:#?} => {:#?}.", previous, current));
                }

            });
        if quit {
            self.is_connected = false;
            return;
        }

        // Process queued user input messages
        if let Ok(mut input_queue) = self.test_user_input_stream.lock() {
            while let Some(input) = input_queue.pop_front() {
                let input = input.trim();
                if input == "/quit" {
                    self.is_connected = false;
                    return;
                }
                client.send_messages(vec![self.gns_global.utils().allocate_message(
                    client.connection(),
                    k_nSteamNetworkingSend_Reliable,
                    input.as_bytes(),
                )]);
            }
        }
    }

    fn handle_server_events(&mut self) {
        let server = self.server.as_ref().unwrap_or_else(|| {
            godot_print!("ERROR: Server not initialized");
            panic!("Server socket not initialized");
        });
        self.last_update = Instant::now();
        
        // Clone Arc for use in closures
        let debug_queue = self.debug_messages.clone();
        let queue_msg = |msg: String| {
            if let Ok(mut q) = debug_queue.lock() {
                q.push_back(msg);
                if q.len() > 1000 {
                    q.pop_front();
                }
            }
        };

        let now = Instant::now();
        let elapsed = now - self.last_update;
        if elapsed.as_secs() > 10 {
            self.last_update = now;
            for (client, nick) in self.client_peers.clone().into_iter() {
                let info = server.get_connection_info(client).unwrap_or_else(|| {
                    queue_msg(format!("ERROR: Failed to get connection info for {nick}"));
                    panic!()
                });
                let (status, _) = server.get_connection_real_time_status(client, 0).unwrap_or_else(|_| {
                    queue_msg(format!("ERROR: Failed to get real time status for {nick}"));
                    panic!()
                });
                queue_msg(format!(
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

        // Broadcast a message to the provided clients.
        // We first build a list of messages and then send them.
        let broadcast_chat = |clients: Vec<GnsConnection>, title: &str, content: &str| {
            let messages = clients
                .clone()
                .into_iter()
                .map(|client| {
                    self.gns_global.utils().allocate_message(
                        client,
                        k_nSteamNetworkingSend_Reliable,
                        format!("[{}]: {}", title, content).as_bytes(),
                    )
                })
                .collect::<Vec<_>>();
            // Here we should check whether all messages were successfully sent with the result.
            server.send_messages(messages);
        };

        // Process connections events.
        let _events_processed = server.poll_event::<100>(|event| {
          match (event.old_state(), event.info().state()) {
            // A client is about to connect, accept it.
            (
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None,
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
            ) => {
              let result = server.accept(event.connection());
              queue_msg(format!("GnsSocket<Server>: accepted new client: {:#?}.", result));
              if result.is_ok() {
                self.client_peers.insert(event.connection(), self.nonce.to_string());
                broadcast_chat(
                  self.client_peers.keys().copied().collect(),
                  "Server",
                  &format!("A new user joined us, weclome {}", self.nonce),
                );
                self.nonce += 1;
              }
              queue_msg(format!("GnsSocket<Server>: number of clients: {:#?}.", self.client_peers.len()));
            }

            // A client is connected, we previously accepted it and don't do anything here.
            // In a more sophisticated scenario we could initial sending some messages.
            (
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connecting,
              ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_Connected,
            ) => {
            }

            (_, ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ClosedByPeer | ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_ProblemDetectedLocally) => {
              // Remove the client from the list and close the connection.
              let conn = event.connection();
              queue_msg(format!("GnsSocket<Server>: {:#?} disconnected", conn));
              let nickname = &self.client_peers[&conn];
              broadcast_chat(
                self.client_peers.keys().copied().collect(),
                "Server",
                &format!("[{}] lost faith.", nickname),
              );
              self.client_peers.remove(&conn);
              // Make sure we cleanup the connection, mandatory as per GNS doc.
              server.close_connection(conn, 0, "", false);
            }

            // A client state is changing, perhaps disconnecting
            // If a client disconnected and it's connection get cleaned up, its state goes back to `ESteamNetworkingConnectionState::k_ESteamNetworkingConnectionState_None`
            (previous, current) => {
              queue_msg(format!("GnsSocket<Server>: {:#?} => {:#?}.", previous, current));
            }
          }
        });

        // Process some messages, we arbitrary define 100 as being the max number of messages we can handle per iteration.
        let _messages_processed = server.poll_messages::<100>(|message| {
            let chat_message = core::str::from_utf8(message.payload()).unwrap_or_else(|e| {
                queue_msg(format!("ERROR: Failed to decode UTF8 message: {}", e));
                ""
            });
            if !chat_message.is_empty() {
                let sender = message.connection();
                let sender_nickname = &self.client_peers[&sender];
                queue_msg(format!("[Server Received] From {}: {}", sender_nickname, chat_message));
                broadcast_chat(
                    self.client_peers.keys().copied().collect(),
                    &sender_nickname,
                    chat_message,
                );
            }
        });
    }
}