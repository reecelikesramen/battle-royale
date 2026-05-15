use crate::packet::prelude::*;
use godot::prelude::*;

// Phase 6 generic predicted-entity command packet. Counterpart to NetStatePacket
// for the client->server direction. payload is the schema-driven, quantized
// command field bytes; sequence_id / timestamp_us / last_received_tick are
// infrastructure fields the predictor stamps directly (kept out of payload so
// they aren't quantized). Routing on the server is via (schema_id, entity_id);
// the receiving NetPredictor must also verify peer_id matches its owner_id.
define_packet! {
    name: NetCommandPacket,
    variant: NetCommand,
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
        sequence_id: {
            godot: i64,
            wire: u16,
        },
        timestamp_us: {
            godot: i64,
            wire: u32,
        },
        last_received_tick: {
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
        let wire = NetCommandPacketWire {
            schema_id: 1,
            entity_id: 42,
            sequence_id: 1234,
            timestamp_us: 9_999_999,
            last_received_tick: 4242,
            payload: vec![0x01, 0x02, 0x03, 0x04, 0x05],
        };
        let bytes = wire.encode();
        let decoded = NetCommandPacketWire::decode(&bytes).unwrap();
        assert_eq!(decoded.schema_id, 1);
        assert_eq!(decoded.entity_id, 42);
        assert_eq!(decoded.sequence_id, 1234);
        assert_eq!(decoded.timestamp_us, 9_999_999);
        assert_eq!(decoded.last_received_tick, 4242);
        assert_eq!(decoded.payload, vec![0x01, 0x02, 0x03, 0x04, 0x05]);
    }

    #[test]
    fn postcard_roundtrip_empty_payload() {
        let wire = NetCommandPacketWire {
            schema_id: 7,
            entity_id: 0,
            sequence_id: 0,
            timestamp_us: 0,
            last_received_tick: 0,
            payload: vec![],
        };
        let bytes = wire.encode();
        let decoded = NetCommandPacketWire::decode(&bytes).unwrap();
        assert!(decoded.payload.is_empty());
    }
}
