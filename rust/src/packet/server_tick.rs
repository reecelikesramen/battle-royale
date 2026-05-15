use crate::packet::prelude::*;

define_packet! {
    name: ServerTickPacket,
    variant: ServerTick,
    reliable: false,
    fields: {
        server_tick: {
            godot: i64,
            wire: u32,
            default: 0,
        },
        server_tick_us: {
            godot: i64,
            wire: u32,
            default: 0,
        },
    },
    codec: postcard
}
