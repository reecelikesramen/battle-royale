use crate::packet::prelude::*;
use godot::prelude::*;

define_packet! {
    name: IdAssignmentPacket,
    variant: IdAssignment,
    reliable: true,
    fields: {
        id: {
            godot: i64,
            wire: u8,
            default: 0,
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
    codec: postcard
}
