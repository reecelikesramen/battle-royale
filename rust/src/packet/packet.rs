use crate::packet::prelude::*;
use godot::prelude::*;
use num_derive::{FromPrimitive, ToPrimitive};
use num_traits::{FromPrimitive, ToPrimitive};
use std::io::{Error, ErrorKind, Result};

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromPrimitive, ToPrimitive)]
pub(crate) enum PacketId {
    IdAssignment,
    Chat,
    PlayerInput,
    PlayerDisconnected,
    ServerTick,
    NetState,
    NetReliable,
    Null,
}

pub(crate) enum Packet {
    IdAssignment(IdAssignmentPacketWire),
    PlayerInput(PlayerInputPacketWire),
    Chat(ChatPacketWire),
    PlayerDisconnected(PlayerDisconnectedPacketWire),
    ServerTick(ServerTickPacketWire),
    NetState(NetStatePacketWire),
    NetReliable(NetReliablePacketWire),
    Null(NullPacketWire),
}

impl Packet {
    fn id(&self) -> PacketId {
        match self {
            Packet::IdAssignment(_) => PacketId::IdAssignment,
            Packet::PlayerInput(_) => PacketId::PlayerInput,
            Packet::Chat(_) => PacketId::Chat,
            Packet::PlayerDisconnected(_) => PacketId::PlayerDisconnected,
            Packet::ServerTick(_) => PacketId::ServerTick,
            Packet::NetState(_) => PacketId::NetState,
            Packet::NetReliable(_) => PacketId::NetReliable,
            Packet::Null(_) => PacketId::Null,
        }
    }

    pub(crate) fn is_reliable(&self) -> bool {
        match self {
            Packet::IdAssignment(_) => IdAssignmentPacketWire::IS_RELIABLE,
            Packet::PlayerInput(_) => PlayerInputPacketWire::IS_RELIABLE,
            Packet::Chat(_) => ChatPacketWire::IS_RELIABLE,
            Packet::PlayerDisconnected(_) => PlayerDisconnectedPacketWire::IS_RELIABLE,
            Packet::ServerTick(_) => ServerTickPacketWire::IS_RELIABLE,
            Packet::NetState(_) => NetStatePacketWire::IS_RELIABLE,
            Packet::NetReliable(_) => NetReliablePacketWire::IS_RELIABLE,
            Packet::Null(_) => NullPacketWire::IS_RELIABLE,
        }
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut bytes = vec![self.id().to_u8().unwrap()];
        bytes.extend(match self {
            Packet::IdAssignment(packet) => packet.encode(),
            Packet::PlayerInput(packet) => packet.encode(),
            Packet::Chat(packet) => packet.encode(),
            Packet::PlayerDisconnected(packet) => packet.encode(),
            Packet::ServerTick(packet) => packet.encode(),
            Packet::NetState(packet) => packet.encode(),
            Packet::NetReliable(packet) => packet.encode(),
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
            PacketId::PlayerInput => Ok(Packet::PlayerInput(PlayerInputPacketWire::decode(packet_data)?)),
            PacketId::Chat => Ok(Packet::Chat(ChatPacketWire::decode(packet_data)?)),
            PacketId::PlayerDisconnected => Ok(Packet::PlayerDisconnected(
                PlayerDisconnectedPacketWire::decode(packet_data)?,
            )),
            PacketId::ServerTick => Ok(Packet::ServerTick(ServerTickPacketWire::decode(packet_data)?)),
            PacketId::NetState => Ok(Packet::NetState(NetStatePacketWire::decode(packet_data)?)),
            PacketId::NetReliable => Ok(Packet::NetReliable(NetReliablePacketWire::decode(packet_data)?)),
            PacketId::Null => Ok(Packet::Null(NullPacketWire::decode(packet_data)?)),
        }
    }

    pub(crate) fn as_gd(&self) -> Gd<Object> {
        match self {
            Packet::IdAssignment(packet) => packet.as_gd(),
            Packet::PlayerInput(packet) => packet.as_gd(),
            Packet::Chat(packet) => packet.as_gd(),
            Packet::PlayerDisconnected(packet) => packet.as_gd(),
            Packet::ServerTick(packet) => packet.as_gd(),
            Packet::NetState(packet) => packet.as_gd(),
            Packet::NetReliable(packet) => packet.as_gd(),
            Packet::Null(packet) => packet.as_gd(),
        }
    }
}
