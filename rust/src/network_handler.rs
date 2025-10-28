use std::collections::HashMap;
use godot::prelude::*;
use godot::classes::Node;
use godot::classes::INode;
use gns::{GnsGlobal, GnsSocket, IsCreated, GnsListenSocket};
use std::sync::Arc;

const DEFAULT_IP_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: i64 = 45876;

/* TODO: unwrap must be banned */

#[derive(GodotClass)]
#[class(base=Node)]
struct NetworkHandler {
    base: Base<Node>,

    /* common vars */
    is_server: bool,
    gns_global: Arc<GnsGlobal>,
    socket: Option<GnsSocket<IsCreated>>,

    /* server-side vars */
    available_peer_ids: Vec<i64>,
    client_peers: HashMap<i64, String>, /* string for now */

    /* client-side vars */
    server_peer: String, /* string for now */
}

#[godot_api]
impl INode for NetworkHandler {
    fn init(base: Base<Node>) -> Self {
        godot_print!("NetworkHandler initialized");

        Self {
            base,
            is_server: false,
            gns_global: GnsGlobal::get().unwrap(),
            socket: None,
            available_peer_ids: (0..256).rev().collect(),
            client_peers: HashMap::new(),
            server_peer: "".into(),
        }
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

    #[func]
    fn start_server(&mut self, ip_address: String, port: i64) {
        self.is_server = true;
        self.available_peer_ids = (0..256).rev().collect();
    }

    #[func]
    fn start_server_with_port(&mut self, port: i64) {
        self.start_server(DEFAULT_IP_ADDRESS.into(), port);
    }

    #[func]
    fn start_server_default(&mut self) {
        self.start_server(DEFAULT_IP_ADDRESS.into(), DEFAULT_PORT);
    }

    #[func]
    fn start_client(&mut self, ip_address: String, port: i64) {
        self.is_server = false;
        let socket = GnsSocket::<IsCreated>::new(self.gns_global.clone());
        let client = socket.connect(ip_address.parse().unwrap(), port as u16).unwrap();
        self.server_peer = ip_address;
    }

    #[func]
    fn start_client_with_port(&mut self, port: i64) {
        self.start_client(DEFAULT_IP_ADDRESS.into(), port);
    }

    #[func]
    fn start_client_default(&mut self) {
        self.start_client(DEFAULT_IP_ADDRESS.into(), DEFAULT_PORT);
    }
}