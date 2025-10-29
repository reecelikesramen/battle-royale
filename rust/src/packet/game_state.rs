use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub(crate) struct GdGameStatePacket {
    base: Base<RefCounted>,
    #[var]
    id: i64,
    #[var]
    player_position: Vector3,
}

#[godot_api]
impl GdGameStatePacket {
    #[func]
    pub(crate) fn new(id: i64, player_position: Vector3) -> Gd<Self> {
        Gd::from_init_fn(|base| Self { base, id, player_position })
    }

    #[func]
    fn create(id: i64, player_position: Vector3) -> Gd<GdPacket> {
        Gd::from_init_fn(|base| GdPacket {
            base,
            packet: Packet::GameState(GameStatePacket { id, player_position }),
        })
    }
}

#[godot_api]
impl IRefCounted for GdGameStatePacket {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, id: -1, player_position: Vector3::ZERO }
    }
}

pub(crate) struct GameStatePacket {
    pub(crate) id: i64,
    pub(crate) player_position: Vector3,
}

impl GameStatePacket {
    pub(crate) fn as_gd(&self) -> Gd<Object> {
        GdGameStatePacket::new(self.id, self.player_position).upcast::<Object>()
    }
}

impl PacketData for GameStatePacket {
    const IS_RELIABLE: bool = false;

    fn encode(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(13);
        let id: u8 = self.id.try_into().unwrap();
        data.extend_from_slice(&id.to_le_bytes());
        data.extend_from_slice(&self.player_position.x.to_le_bytes());
        data.extend_from_slice(&self.player_position.y.to_le_bytes());
        data.extend_from_slice(&self.player_position.z.to_le_bytes());
        data
    }

    fn decode(data: &[u8]) -> Result<Self> {
        if data.len() != 13 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "Invalid game state packet data length",
            ));
        }
        let id = u8::from_le_bytes([data[0]]);
        let player_position = Vector3::new(
            f32::from_le_bytes([data[1], data[2], data[3], data[4]]),
            f32::from_le_bytes([data[5], data[6], data[7], data[8]]),
            f32::from_le_bytes([data[9], data[10], data[11], data[12]]),
        );
        Ok(GameStatePacket { id: id as i64, player_position })
    }
}
