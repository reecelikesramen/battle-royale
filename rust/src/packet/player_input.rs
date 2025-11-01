use crate::packet::prelude::*;

define_packet! {
    name: PlayerInputPacket,
    variant: PlayerInput,
    reliable: false,
    fields: {
        id: {
            godot: i64,
            wire: u8,
            default: -1,
        },
        sequence_id: {
            godot: i64,
            wire: u16,
        },
        timestamp_ms: {
            godot: i64,
            wire: u32,
        },
        move_forward: {
            godot: f64,
            wire: f32,
        },
        move_backward: {
            godot: f64,
            wire: f32,
        },
        move_left: {
            godot: f64,
            wire: f32,
        },
        move_right: {
            godot: f64,
            wire: f32,
        },
        look_delta: {
            godot: Vector2,
        },
        jump_pressed: {
            godot: bool,
        },
        crouch_pressed: {
            godot: bool,
        },
        crouch_released: {
            godot: bool,
        },
        look_abs: {
            godot: Vector2,
        },
        velocity: {
            godot: Vector3,
        },
        crouch_held: {
            godot: bool,
        },
        was_on_floor: {
            godot: bool,
        },
    },
    codec: postcard
}