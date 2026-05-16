use crate::packet::prelude::*;
use godot::prelude::*;
use num_derive::{FromPrimitive, ToPrimitive};
use num_traits::{FromPrimitive, ToPrimitive};
use std::io::{Error, ErrorKind, Result};

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromPrimitive, ToPrimitive)]
pub(crate) enum PacketId {
    IdAssignment,
    PlayerDisconnected,
    ServerTick,
    NetState,
    NetCommand,
    NetReliable,
    Null,
    // Append-only. Wire ids are persisted in saved replays + cross-version
    // peers; inserting a new variant in the middle would silently shift every
    // packet id above it and break decode against older clients.
    ServerHello,
    ClientHello,
}

pub(crate) enum Packet {
    IdAssignment(IdAssignmentPacketWire),
    PlayerDisconnected(PlayerDisconnectedPacketWire),
    ServerTick(ServerTickPacketWire),
    NetState(NetStatePacketWire),
    NetCommand(NetCommandPacketWire),
    NetReliable(NetReliablePacketWire),
    Null(NullPacketWire),
    ServerHello(ServerHelloPacketWire),
    ClientHello(ClientHelloPacketWire),
}

impl Packet {
    fn id(&self) -> PacketId {
        match self {
            Packet::IdAssignment(_) => PacketId::IdAssignment,
            Packet::PlayerDisconnected(_) => PacketId::PlayerDisconnected,
            Packet::ServerTick(_) => PacketId::ServerTick,
            Packet::NetState(_) => PacketId::NetState,
            Packet::NetCommand(_) => PacketId::NetCommand,
            Packet::NetReliable(_) => PacketId::NetReliable,
            Packet::Null(_) => PacketId::Null,
            Packet::ServerHello(_) => PacketId::ServerHello,
            Packet::ClientHello(_) => PacketId::ClientHello,
        }
    }

    pub(crate) fn is_reliable(&self) -> bool {
        match self {
            Packet::IdAssignment(_) => IdAssignmentPacketWire::IS_RELIABLE,
            Packet::PlayerDisconnected(_) => PlayerDisconnectedPacketWire::IS_RELIABLE,
            Packet::ServerTick(_) => ServerTickPacketWire::IS_RELIABLE,
            Packet::NetState(_) => NetStatePacketWire::IS_RELIABLE,
            Packet::NetCommand(_) => NetCommandPacketWire::IS_RELIABLE,
            Packet::NetReliable(_) => NetReliablePacketWire::IS_RELIABLE,
            Packet::Null(_) => NullPacketWire::IS_RELIABLE,
            Packet::ServerHello(_) => ServerHelloPacketWire::IS_RELIABLE,
            Packet::ClientHello(_) => ClientHelloPacketWire::IS_RELIABLE,
        }
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut bytes = vec![self.id().to_u8().unwrap()];
        bytes.extend(match self {
            Packet::IdAssignment(packet) => packet.encode(),
            Packet::PlayerDisconnected(packet) => packet.encode(),
            Packet::ServerTick(packet) => packet.encode(),
            Packet::NetState(packet) => packet.encode(),
            Packet::NetCommand(packet) => packet.encode(),
            Packet::NetReliable(packet) => packet.encode(),
            Packet::Null(packet) => packet.encode(),
            Packet::ServerHello(packet) => packet.encode(),
            Packet::ClientHello(packet) => packet.encode(),
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
            PacketId::PlayerDisconnected => Ok(Packet::PlayerDisconnected(
                PlayerDisconnectedPacketWire::decode(packet_data)?,
            )),
            PacketId::ServerTick => Ok(Packet::ServerTick(ServerTickPacketWire::decode(packet_data)?)),
            PacketId::NetState => Ok(Packet::NetState(NetStatePacketWire::decode(packet_data)?)),
            PacketId::NetCommand => Ok(Packet::NetCommand(NetCommandPacketWire::decode(packet_data)?)),
            PacketId::NetReliable => Ok(Packet::NetReliable(NetReliablePacketWire::decode(packet_data)?)),
            PacketId::Null => Ok(Packet::Null(NullPacketWire::decode(packet_data)?)),
            PacketId::ServerHello => Ok(Packet::ServerHello(ServerHelloPacketWire::decode(packet_data)?)),
            PacketId::ClientHello => Ok(Packet::ClientHello(ClientHelloPacketWire::decode(packet_data)?)),
        }
    }

    pub(crate) fn as_gd(&self) -> Gd<Object> {
        match self {
            Packet::IdAssignment(packet) => packet.as_gd(),
            Packet::PlayerDisconnected(packet) => packet.as_gd(),
            Packet::ServerTick(packet) => packet.as_gd(),
            Packet::NetState(packet) => packet.as_gd(),
            Packet::NetCommand(packet) => packet.as_gd(),
            Packet::NetReliable(packet) => packet.as_gd(),
            Packet::Null(packet) => packet.as_gd(),
            Packet::ServerHello(packet) => packet.as_gd(),
            Packet::ClientHello(packet) => packet.as_gd(),
        }
    }
}
