use crate::packet::prelude::*;
use godot::prelude::*;

define_packet! {
    name: PlayerDisconnectedPacket,
    variant: PlayerDisconnected,
    reliable: true,
    fields: {
        player_id: {
            godot: i64,
            wire: u8,
        },
    },
    codec: postcard
}
