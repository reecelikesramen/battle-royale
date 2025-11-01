use crate::packet::prelude::*;

define_packet! {
    name: PlayerStatePacket,
    variant: PlayerState,
    reliable: false,
    fields: {
        id: {
            godot: i64,
            wire: u8,
            default: -1,
        },
        last_input_sequence_id: {
            godot: i64,
            wire: u16,
        },
        timestamp_ms: {
            godot: i64,
            wire: u32,
        },
        position: {
            godot: Vector3,
        },
        rotation: {
            godot: Vector2,
        },
        is_crouching: {
            godot: bool,
        },
        velocity: {
            godot: Vector3,
        },
    },
    codec: postcard
}