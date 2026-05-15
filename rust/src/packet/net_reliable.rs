use crate::packet::prelude::*;
use godot::prelude::*;

// Phase 9 reliable RPC carrier. Travels over the GNS reliable lane (reliable
// = true), addressed by `topic` so multiple subsystems can multiplex on one
// packet kind. idempotency_key dedupes: the receiver remembers the last K
// seen keys per topic and silently drops repeats. payload is the topic-
// specific serialized body, opaque to the framework.
define_packet! {
    name: NetReliablePacket,
    variant: NetReliable,
    reliable: true,
    fields: {
        topic: {
            godot: i64,
            wire: u16,
        },
        idempotency_key: {
            godot: i64,
            wire: u32,
        },
        payload: {
            godot: PackedByteArray,
            wire: Vec<u8>,
        },
    },
    codec: postcard
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::packet::packet_data::PacketData;

    #[test]
    fn postcard_roundtrip() {
        let wire = NetReliablePacketWire {
            topic: 7,
            idempotency_key: 42,
            payload: vec![1, 2, 3, 4, 5],
        };
        let bytes = wire.encode();
        let back = NetReliablePacketWire::decode(&bytes).unwrap();
        assert_eq!(back.topic, 7);
        assert_eq!(back.idempotency_key, 42);
        assert_eq!(back.payload, vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn empty_payload_roundtrip() {
        let wire = NetReliablePacketWire {
            topic: 0,
            idempotency_key: 0,
            payload: vec![],
        };
        let bytes = wire.encode();
        let back = NetReliablePacketWire::decode(&bytes).unwrap();
        assert!(back.payload.is_empty());
    }

    #[test]
    fn is_reliable_flag_set() {
        assert!(NetReliablePacketWire::IS_RELIABLE);
    }
}
