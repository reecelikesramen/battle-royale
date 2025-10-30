use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

define_packet! {
    name: GameStatePacket,
    variant: GameState,
    reliable: false,
    fields: {
        id: {
            godot: i64,
            default: -1,
        },
        player_position: {
            godot: Vector3,
        },
        player_sight_direction: {
            godot: Vector3,
        },
        is_crouching: {
            godot: bool,
        },
    },
    encode = |packet| {
        let mut data = Vec::with_capacity(26);
        let id: u8 = packet.id.try_into().unwrap();
        data.extend_from_slice(&[id]);
        data.extend_from_slice(&packet.player_position.x.to_le_bytes());
        data.extend_from_slice(&packet.player_position.y.to_le_bytes());
        data.extend_from_slice(&packet.player_position.z.to_le_bytes());
        data.extend_from_slice(&packet.player_sight_direction.x.to_le_bytes());
        data.extend_from_slice(&packet.player_sight_direction.y.to_le_bytes());
        data.extend_from_slice(&packet.player_sight_direction.z.to_le_bytes());
        data.extend_from_slice(&[packet.is_crouching as u8]);
        data
    },
    decode = |data| -> Result<Self> {
        if data.len() != 26 {
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
        let player_sight_direction = Vector3::new(
            f32::from_le_bytes([data[13], data[14], data[15], data[16]]),
            f32::from_le_bytes([data[17], data[18], data[19], data[20]]),
            f32::from_le_bytes([data[21], data[22], data[23], data[24]]),
        );
        let is_crouching = data[25] != 0;

        Ok(Self { id: id as i64, player_position, player_sight_direction, is_crouching })
    }
}
