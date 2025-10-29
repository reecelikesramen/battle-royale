use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

#[derive(GodotClass)]
#[class(base=Object)]
pub(crate) struct GdIdAssignmentPacket {
    base: Base<Object>,
    #[var]
    id: u8,
    #[var]
    remote_ids: Array<i64>,
}

#[godot_api]
impl GdIdAssignmentPacket {
    #[func]
    pub(crate) fn new(id: u8, remote_ids: Array<i64>) -> Gd<Self> {
        Gd::from_init_fn(|base| Self { base, id, remote_ids })
    }

    #[func]
    fn create(id: u8, remote_ids: Array<i64>) -> Gd<GdPacket> {
        Gd::from_init_fn(|base| GdPacket {
            base,
            packet: Packet::IdAssignment(IdAssignmentPacket { id, remote_ids: remote_ids.iter_shared().map(|id| id.try_into().unwrap()).collect() }),
        })
    }
}

#[godot_api]
impl IObject for GdIdAssignmentPacket {
    fn init(base: Base<Object>) -> Self {
        Self { base, id: 0, remote_ids: array![] }
    }
}

pub(crate) struct IdAssignmentPacket {
    pub(crate) id: u8,
    pub(crate) remote_ids: Vec<u8>,
}

impl IdAssignmentPacket {
    pub(crate) fn as_gd(&self) -> Gd<Object> {
        let array: Array<i64> = self.remote_ids.iter()
            .map(|&id| id as i64)
            .collect();
        GdIdAssignmentPacket::new(self.id, array).upcast::<Object>()
    }
}

impl PacketData for IdAssignmentPacket {
    const IS_RELIABLE: bool = true;

    fn encode(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(12);
        data.extend_from_slice(&self.id.to_le_bytes());
        for remote_id in &self.remote_ids {
            data.extend_from_slice(&remote_id.to_le_bytes());
        }
        data
    }

    fn decode(data: &[u8]) -> Result<Self> {
        if data.len() < 2 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "Invalid id assignment packet data length",
            ));
        }
        let id = data[0];
        let remote_ids = data[1..].to_vec();
        Ok(IdAssignmentPacket { id, remote_ids })
    }
}
