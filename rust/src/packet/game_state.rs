use crate::packet::prelude::*;
use godot::prelude::*;

define_packet! {
    name: GameStatePacket,
    variant: GameState,
    reliable: false,
    fields: {
        id: {
            godot: i64,
            wire: u8,
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
    codec: postcard
}
