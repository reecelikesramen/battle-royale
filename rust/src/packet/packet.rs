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
    Null,
}

pub(crate) enum Packet {
    IdAssignment(IdAssignmentPacketWire),
    GameState(GameStatePacketWire),
    Chat(ChatPacketWire),
    PlayerDisconnected(PlayerDisconnectedPacketWire),
    Null(NullPacketWire),
}

impl Packet {
    fn id(&self) -> PacketId {
        match self {
            Packet::IdAssignment(_) => PacketId::IdAssignment,
            Packet::GameState(_) => PacketId::GameState,
            Packet::Chat(_) => PacketId::Chat,
            Packet::PlayerDisconnected(_) => PacketId::PlayerDisconnected,
            Packet::Null(_) => PacketId::Null,
        }
    }

    pub(crate) fn is_reliable(&self) -> bool {
        match self {
            Packet::IdAssignment(_) => IdAssignmentPacketWire::IS_RELIABLE,
            Packet::GameState(_) => GameStatePacketWire::IS_RELIABLE,
            Packet::Chat(_) => ChatPacketWire::IS_RELIABLE,
            Packet::PlayerDisconnected(_) => PlayerDisconnectedPacketWire::IS_RELIABLE,
            Packet::Null(_) => NullPacketWire::IS_RELIABLE,
        }
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut bytes = vec![self.id().to_u8().unwrap()];
        bytes.extend(match self {
            Packet::IdAssignment(packet) => packet.encode(),
            Packet::GameState(packet) => packet.encode(),
            Packet::Chat(packet) => packet.encode(),
            Packet::PlayerDisconnected(packet) => packet.encode(),
            Packet::Null(packet) => packet.encode(),
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
            PacketId::IdAssignment => Ok(Packet::IdAssignment(IdAssignmentPacketWire::decode(
                packet_data,
            )?)),
            PacketId::GameState => Ok(Packet::GameState(GameStatePacketWire::decode(packet_data)?)),
            PacketId::Chat => Ok(Packet::Chat(ChatPacketWire::decode(packet_data)?)),
            PacketId::PlayerDisconnected => Ok(Packet::PlayerDisconnected(PlayerDisconnectedPacketWire::decode(packet_data)?)),
            PacketId::Null => Ok(Packet::Null(NullPacketWire::decode(packet_data)?)),
        }
    }

    pub(crate) fn as_gd(&self) -> Gd<Object> {
        match self {
            Packet::IdAssignment(packet) => packet.as_gd(),
            Packet::GameState(packet) => packet.as_gd(),
            Packet::Chat(packet) => packet.as_gd(),
            Packet::PlayerDisconnected(packet) => packet.as_gd(),
            Packet::Null(packet) => packet.as_gd(),
        }
    }
}
