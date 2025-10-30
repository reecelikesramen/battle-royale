use crate::packet::prelude::*;
use godot::prelude::*;
use std::io::{Error, ErrorKind, Result};

define_packet! {
    name: IdAssignmentPacket,
    variant: IdAssignment,
    reliable: true,
    fields: {
        id: {
            godot: i64,
            wire: u8,
            default: 0,
            to_wire: |value: &i64| (*value).try_into().unwrap(),
            to_gd: |value: &u8| i64::from(*value),
        },
        remote_ids: {
            godot: Array<i64>,
            wire: Vec<u8>,
            default: array![],
            to_wire: |value: &Array<i64>| {
                value
                    .iter_shared()
                    .map(|id| id.try_into().unwrap())
                    .collect::<Vec<u8>>()
            },
            to_gd: |value: &Vec<u8>| {
                value
                    .iter()
                    .map(|&id| id as i64)
                    .collect::<Array<i64>>()
            },
        },
    },
    encode = |packet| {
        let mut data = Vec::with_capacity(1 + packet.remote_ids.len());
        data.extend_from_slice(&packet.id.to_le_bytes());
        data.extend_from_slice(packet.remote_ids.as_slice());
        data
    },
    decode = |data| -> Result<Self> {
        if data.len() < 1 {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "Invalid id assignment packet data length",
            ));
        }

        let id = data[0];
        let remote_ids = data[1..].to_vec();

        Ok(Self { id, remote_ids })
    }
}
