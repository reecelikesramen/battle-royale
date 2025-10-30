use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

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
    encode = |packet| {
        let mut data = Vec::with_capacity(packet.username.len() + packet.message.len() + 2);
        data.extend_from_slice(packet.username.as_bytes());
        data.push(0);
        data.extend_from_slice(packet.message.as_bytes());
        data.push(0);
        data
    },
    decode = |data| -> Result<Self> {
        let null_pos = data
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| Error::new(ErrorKind::InvalidData, "Missing null terminator for username"))?;
        let username = String::from_utf8(data[..null_pos].to_vec())
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Invalid UTF-8 for username: {}", e)))?;

        let remaining = &data[null_pos + 1..];
        let null_pos = remaining
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| Error::new(ErrorKind::InvalidData, "Missing null terminator for message"))?;
        let message = String::from_utf8(remaining[..null_pos].to_vec())
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Invalid UTF-8 for message: {}", e)))?;

        Ok(Self { username, message })
    }
}
