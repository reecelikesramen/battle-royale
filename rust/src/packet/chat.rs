use crate::packet::prelude::*;
use godot::prelude::*;

define_packet! {
    name: ChatPacket,
    variant: Chat,
    reliable: true,
    fields: {
        username: {
            godot: GString,
            wire: String,
            to_wire: |value: &GString| value.to_string(),
            to_gd: |value: &String| GString::from(value.as_str()),
        },
        message: {
            godot: GString,
            wire: String,
            to_wire: |value: &GString| value.to_string(),
            to_gd: |value: &String| GString::from(value.as_str()),
        },
    },
    codec: postcard
}
