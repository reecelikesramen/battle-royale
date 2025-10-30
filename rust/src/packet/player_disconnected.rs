use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

#[derive(GodotClass)]
#[class(init, base=Object)]
pub(crate) struct GdPlayerDisconnectedPacket {
    base: Base<Object>,
    #[var]
    player_id: i64,
}

#[godot_api]
impl GdPlayerDisconnectedPacket {
    #[func]
    pub(crate) fn new(player_id: i64) -> Gd<Self> {
        Gd::from_init_fn(|base| Self { base, player_id })
    }

    #[func]
    fn create(player_id: i64) -> Gd<GdPacket> {
        Gd::from_init_fn(|base| GdPacket {
            base,
            packet: Packet::PlayerDisconnected(PlayerDisconnectedPacket { player_id: player_id.try_into().unwrap() }),
        })
    }
}

pub(crate) struct PlayerDisconnectedPacket {
    pub(crate) player_id: u8,
}

impl PlayerDisconnectedPacket {
    pub(crate) fn as_gd(&self) -> Gd<Object> {
        GdPlayerDisconnectedPacket::new(self.player_id as i64).upcast::<Object>()
    }
}

impl PacketData for PlayerDisconnectedPacket {
    const IS_RELIABLE: bool = true;

    fn encode(&self) -> Vec<u8> {
        vec![self.player_id]
    }

    fn decode(data: &[u8]) -> Result<Self> {
        if data.len() != 1 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "Invalid player disconnected packet data length",
            ));
        }
        let id = data[0];
        Ok(PlayerDisconnectedPacket { player_id: id })
    }
}
