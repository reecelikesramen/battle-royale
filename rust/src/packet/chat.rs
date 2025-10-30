use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub(crate) struct GdChatPacket {
    base: Base<RefCounted>,
    #[var]
    username: GString,
    #[var]
    message: GString,
}

#[godot_api]
impl GdChatPacket {
    #[func]
    pub(crate) fn new(username: GString, message: GString) -> Gd<Self> {
        Gd::from_init_fn(|base| Self { base, username, message })
    }

    #[func]
    fn create(username: GString, message: GString) -> Gd<GdPacket> {
        Gd::from_init_fn(|base| GdPacket {
            base,
            packet: Packet::Chat(ChatPacket { username: username.to_string(), message: message.to_string() }),
        })
    }
}

#[godot_api]
impl IRefCounted for GdChatPacket {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, username: GString::new(), message: GString::new() }
    }
}

pub(crate) struct ChatPacket {
    pub(crate) username: String,
    pub(crate) message: String,
}

impl ChatPacket {
    pub(crate) fn as_gd(&self) -> Gd<Object> {
        GdChatPacket::new(GString::from(&self.username), GString::from(&self.message)).upcast::<Object>()
    }
}

impl PacketData for ChatPacket {
    const IS_RELIABLE: bool = true;

    fn encode(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(self.username.len() + self.message.len() + 2);
        data.extend_from_slice(self.username.as_bytes());
        data.push(0); // null terminator
        data.extend_from_slice(self.message.as_bytes());
        data.push(0); // null terminator
        data
    }

    fn decode(data: &[u8]) -> Result<Self> {
        let null_pos = data.iter().position(|&b| b == 0)
            .ok_or_else(|| Error::new(ErrorKind::InvalidData, "Missing null terminator for username"))?;
        let username = String::from_utf8(data[..null_pos].to_vec())
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Invalid UTF-8 for username: {}", e)))?;
        
        let remaining = &data[null_pos + 1..];
        let null_pos = remaining.iter().position(|&b| b == 0)
            .ok_or_else(|| Error::new(ErrorKind::InvalidData, "Missing null terminator for message"))?;
        let message = String::from_utf8(remaining[..null_pos].to_vec())
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Invalid UTF-8 for message: {}", e)))?;
        
        Ok(ChatPacket { username, message })
    }
}
