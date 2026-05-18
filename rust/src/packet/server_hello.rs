use crate::packet::prelude::*;
use godot::prelude::*;

// Sent by the server to a new peer immediately on connect, before any
// other server-originated packet. Carries the server's BUILD_SHA so the
// client can compare against its own and disconnect locally with a clear
// reason on mismatch.
define_packet! {
    name: ServerHelloPacket,
    variant: ServerHello,
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
