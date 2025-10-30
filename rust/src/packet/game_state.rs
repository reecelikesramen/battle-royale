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
        camera_rotation: {
            godot: f32,
        },
        player_rotation: {
            godot: f32,
        },
        is_crouching: {
            godot: bool,
        },
    },
    codec: postcard
}
