use crate::packet::prelude::*;
use godot::prelude::*;

// Phase 6 generic predicted/replicated state packet. payload is the schema-
// driven, quantized, optionally delta-encoded field bytes; baseline_tick = 0
// means full snapshot, otherwise it's a delta against the per-client baseline
// the server recorded as acked at that tick. last_input_seq lets predictors
// prune their unacked input buffer. Routing to a specific entity is via
// (schema_id, entity_id) pair so multiple entity types share one packet kind.
define_packet! {
    name: NetStatePacket,
    variant: NetState,
    reliable: false,
    fields: {
        schema_id: {
            godot: i64,
            wire: u16,
        },
        entity_id: {
            godot: i64,
            wire: u32,
        },
        last_input_seq: {
            godot: i64,
            wire: u16,
        },
        baseline_tick: {
            godot: i64,
            wire: u32,
        },
        new_tick: {
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
    fn postcard_roundtrip_full_snapshot() {
        let wire = NetStatePacketWire {
            schema_id: 1,
            entity_id: 42,
            last_input_seq: 1234,
            baseline_tick: 0,
            new_tick: 99_999,
            payload: vec![0xDE, 0xAD, 0xBE, 0xEF],
        };
        let bytes = wire.encode();
        let decoded = NetStatePacketWire::decode(&bytes).unwrap();
        assert_eq!(decoded.schema_id, 1);
        assert_eq!(decoded.entity_id, 42);
        assert_eq!(decoded.last_input_seq, 1234);
        assert_eq!(decoded.baseline_tick, 0);
        assert_eq!(decoded.new_tick, 99_999);
        assert_eq!(decoded.payload, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn postcard_roundtrip_empty_payload() {
        let wire = NetStatePacketWire {
            schema_id: 7,
            entity_id: 0,
            last_input_seq: 0,
            baseline_tick: 12,
            new_tick: 13,
            payload: vec![],
        };
        let bytes = wire.encode();
        let decoded = NetStatePacketWire::decode(&bytes).unwrap();
        assert_eq!(decoded.schema_id, 7);
        assert_eq!(decoded.baseline_tick, 12);
        assert_eq!(decoded.new_tick, 13);
        assert!(decoded.payload.is_empty());
    }

    #[test]
    fn decode_garbage_errors() {
        let bad = vec![0xFFu8; 4];
        // Garbage bytes don't necessarily fail (postcard varint can accept many
        // inputs), but the result MUST be either a decoded value or an Err. We
        // primarily test that decode doesn't panic.
        let _ = NetStatePacketWire::decode(&bad);
    }
}
