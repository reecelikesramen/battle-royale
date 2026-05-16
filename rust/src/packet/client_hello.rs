use crate::packet::prelude::*;
use godot::prelude::*;

// Sent by the client in reply to ServerHelloPacket as the first reliable
// message from client → server. Carries the client's BUILD_SHA so the
// server can kick mismatched builds with a clear reason instead of letting
// them stumble through protocol drift.
define_packet! {
    name: ClientHelloPacket,
    variant: ClientHello,
    reliable: true,
    fields: {
        build_sha: {
            godot: GString,
            wire: String,
            default: GString::new(),
            to_wire: |v: &GString| v.to_string(),
            to_gd: |v: &String| GString::from(v),
        },
        version: {
            godot: GString,
            wire: String,
            default: GString::new(),
            to_wire: |v: &GString| v.to_string(),
            to_gd: |v: &String| GString::from(v),
        },
    },
    codec: postcard
}
