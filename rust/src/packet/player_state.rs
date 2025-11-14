use crate::packet::prelude::*;

// TODO: wrap timestamp_us to save bytes
define_packet! {
    name: PlayerStatePacket,
    variant: PlayerState,
    reliable: false,
    fields: {
        player_id: {
            godot: i64,
            wire: u8,
            default: -1,
        },
        last_input_sequence_id: {
            godot: i64,
            wire: u16,
        },
        timestamp_us: {
            godot: i64,
            wire: u32,
        },
        position: {
            godot: Vector3,
        },
        look_abs: {
            godot: Vector2,
        },
        velocity: {
            godot: Vector3,
        },
        movement_state: {
            godot: i64,
            wire: u8
        }
    },
    codec: postcard
}