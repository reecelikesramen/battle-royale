use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

define_packet! {
    name: PlayerDisconnectedPacket,
    variant: PlayerDisconnected,
    reliable: true,
    fields: {
        player_id: {
            godot: i64,
            wire: u8,
            to_wire: |value: &i64| (*value).try_into().unwrap(),
            to_gd: |value: &u8| i64::from(*value),
        },
    },
    encode = |packet| {
        vec![packet.player_id]
    },
    decode = |data| -> Result<Self> {
        if data.len() != 1 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "Invalid player disconnected packet data length",
            ));
        }

        Ok(Self { player_id: data[0] })
    }
}
