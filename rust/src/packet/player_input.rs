use crate::packet::prelude::*;

// TODO: quantization of inputs
// TODO: use connection id to identify player
// TODO: wrap timestamp_us to save bytes
define_packet! {
    name: PlayerInputPacket,
    variant: PlayerInput,
    reliable: false,
    fields: {
        sequence_id: {
            godot: i64,
            wire: u16,
        },
        timestamp_us: {
            godot: i64,
            wire: u32,
        },
        move_forward_backward: {
            godot: f64,
            wire: i8,
        },
        move_left_right: {
            godot: f64,
            wire: i8,
        },
        look_abs: {
            godot: Vector2,
        },
        jump: {
            godot: bool,
        },
        crouch: {
            godot: bool,
        },
        sprint: {
            godot: bool,
        },
    },
    codec: postcard
}