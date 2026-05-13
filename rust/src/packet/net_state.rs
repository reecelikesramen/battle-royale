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
