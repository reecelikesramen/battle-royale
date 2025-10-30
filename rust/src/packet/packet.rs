use crate::packet::prelude::*;
use godot::prelude::*;
use num_derive::{FromPrimitive, ToPrimitive};
use num_traits::{FromPrimitive, ToPrimitive};
use std::io::{Error, ErrorKind, Result};

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromPrimitive, ToPrimitive)]
pub(crate) enum PacketId {
    IdAssignment,
    GameState,
    Chat,
    PlayerDisconnected,
}

pub(crate) enum Packet {
    IdAssignment(IdAssignmentPacket),
    GameState(GameStatePacket),
    Chat(ChatPacket),
    PlayerDisconnected(PlayerDisconnectedPacket),
}

impl Packet {
    fn id(&self) -> PacketId {
        match self {
            Packet::IdAssignment(_) => PacketId::IdAssignment,
            Packet::GameState(_) => PacketId::GameState,
            Packet::Chat(_) => PacketId::Chat,
            Packet::PlayerDisconnected(_) => PacketId::PlayerDisconnected,
        }
    }

    pub(crate) fn is_reliable(&self) -> bool {
        match self {
            Packet::IdAssignment(_) => IdAssignmentPacket::IS_RELIABLE,
            Packet::GameState(_) => GameStatePacket::IS_RELIABLE,
            Packet::Chat(_) => ChatPacket::IS_RELIABLE,
            Packet::PlayerDisconnected(_) => PlayerDisconnectedPacket::IS_RELIABLE,
        }
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut bytes = vec![self.id().to_u8().unwrap()];
        bytes.extend(match self {
            Packet::IdAssignment(packet) => packet.encode(),
            Packet::GameState(packet) => packet.encode(),
            Packet::Chat(packet) => packet.encode(),
            Packet::PlayerDisconnected(packet) => packet.encode(),
        });
        bytes
    }

    pub(crate) fn decode(data: &[u8]) -> Result<Self> {
        if data.is_empty() {
            return Err(Error::new(ErrorKind::InvalidData, "Empty packet data"));
        }

        // 2. Get the ID byte and the rest of the data
        let id_byte = data[0];
        let packet_data = &data[1..];

        // 3. Use FromPrimitive to convert the u8 byte back to a PacketId
        let packet_id = PacketId::from_u8(id_byte)
            .ok_or_else(|| Error::new(ErrorKind::InvalidData, "Unknown packet ID"))?;

        match packet_id {
            PacketId::IdAssignment => Ok(Packet::IdAssignment(IdAssignmentPacket::decode(
                packet_data,
            )?)),
            PacketId::GameState => Ok(Packet::GameState(GameStatePacket::decode(packet_data)?)),
            PacketId::Chat => Ok(Packet::Chat(ChatPacket::decode(packet_data)?)),
            PacketId::PlayerDisconnected => Ok(Packet::PlayerDisconnected(PlayerDisconnectedPacket::decode(packet_data)?)),
        }
    }

    pub(crate) fn as_gd(&self) -> Gd<Object> {
        match self {
            Packet::IdAssignment(packet) => packet.as_gd(),
            Packet::GameState(packet) => packet.as_gd(),
            Packet::Chat(packet) => packet.as_gd(),
            Packet::PlayerDisconnected(packet) => packet.as_gd(),
        }
    }
}
