use godot::{classes::Engine, prelude::*};
use crate::math::sequence::{seq_is_newer, seq_diff};
use num_traits::FromPrimitive;
use std::collections::HashMap;

const MAX_FRAMES_PER_TICK: usize = 4;
const PACKET_LOSS_TOLERANCE: i32 = 4;

// Maximum age window in input frames. Inputs older than (next_sequence_id - this)
// are dropped, inputs further in the future than (next_sequence_id + this) are
// dropped defensively. 26 frames is ~200ms at 128Hz; sized as worst-case for
// Phase 2 and reused as a generic age window until per-schema config arrives.
const MAX_INPUT_AGE_TICKS: i32 = 26;

#[derive(GodotClass)]
#[class(no_init, base=RefCounted)]
struct TimestampedPacket {
    base: Base<RefCounted>,
    #[var]
    delta: f64,
    #[var]
    timestamp_us: i64,
    #[var]
    sequence_id: i64,
    #[var]
    packet: Variant,
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct JitterBuffer {
    base: Base<RefCounted>,
    packets: HashMap<u16, Gd<TimestampedPacket>>,
    next_sequence_id: u16,
    last_received_timestamp_us: u32,
    last_consumed_timestamp_us: u32,
    last_sequence_id: u16,
}

#[godot_api]
impl IRefCounted for JitterBuffer {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            packets: HashMap::with_capacity(64),
            next_sequence_id: 0,
            last_received_timestamp_us: 0,
            last_consumed_timestamp_us: 0,
            last_sequence_id: 65535,
        }
    }
}

#[godot_api]
impl JitterBuffer {
    #[func]
    fn enqueue(&mut self, sequence_id: i64, timestamp_us: i64, packet: Variant) {
        let Some(sequence_id) = u16::from_i64(sequence_id) else {
            godot_warn!("Invalid sequence id: {sequence_id}");
            return;
        };

        // Already consumed -- next_sequence_id moved past it.
        if seq_diff(sequence_id, self.next_sequence_id) < 0 {
            return;
        }

        // Defensive bound: a wildly-future sequence id indicates client drift
        // or attack; refuse rather than buffer thousands of slots.
        if seq_diff(sequence_id, self.next_sequence_id) > MAX_INPUT_AGE_TICKS {
            return;
        }

        // Dedup against in-buffer copy. With input redundancy, the same seq_id
        // can arrive multiple times; first one wins.
        if self.packets.contains_key(&sequence_id) {
            return;
        }

        let Some(rs_timestamp_us) = u32::from_i64(timestamp_us) else {
            godot_warn!("Invalid timestamp: {timestamp_us}");
            return;
        };

        if seq_is_newer(sequence_id, self.last_sequence_id) {
            self.last_sequence_id = sequence_id;
            self.last_received_timestamp_us = rs_timestamp_us;
        }

        // Delta is filled in at consume time from successive packet timestamps,
        // not packet arrival times (which are meaningless with redundancy).
        let ts_packet = Gd::from_init_fn(|base| TimestampedPacket {
            base,
            delta: 0.0,
            timestamp_us,
            sequence_id: sequence_id as i64,
            packet,
        });

        self.packets.insert(sequence_id, ts_packet);
    }

    #[func]
    fn consume(&mut self) -> Array<Gd<TimestampedPacket>> {
        for _ in 0..MAX_FRAMES_PER_TICK {
            if self.packets.contains_key(&self.next_sequence_id) {
                break;
            }

            let diff = seq_diff(self.last_sequence_id, self.next_sequence_id);
            if diff < PACKET_LOSS_TOLERANCE {
                return Array::new();
            }

            self.next_sequence_id = self.next_sequence_id.wrapping_add(1);
        }

        let mut consumed = Array::new();
        for _ in 0..MAX_FRAMES_PER_TICK {
            if let Some(mut packet) = self.packets.remove(&self.next_sequence_id) {
                let pkt_ts = packet.bind().timestamp_us;
                let delta = if self.last_consumed_timestamp_us > 0 {
                    let pkt_ts_u32 = pkt_ts as u32;
                    let gap = pkt_ts_u32.wrapping_sub(self.last_consumed_timestamp_us);
                    (gap as f64) / 1_000_000.0
                } else {
                    1.0 / Engine::singleton().get_physics_ticks_per_second() as f64
                };
                let clamped_delta = if delta > 0.0 && delta < 1.0 {
                    delta
                } else {
                    1.0 / Engine::singleton().get_physics_ticks_per_second() as f64
                };
                packet.bind_mut().delta = clamped_delta;
                self.last_consumed_timestamp_us = pkt_ts as u32;
                consumed.push(&packet);
                self.next_sequence_id = self.next_sequence_id.wrapping_add(1);
            } else {
                break;
            }
        }

        consumed
    }

    #[func]
    fn size(&self) -> i64 {
        self.packets.len() as i64
    }

    #[func]
    fn last_sequence_id(&self) -> i64 {
        self.last_sequence_id as i64
    }

    #[func]
    fn last_received_timestamp_us(&self) -> i64 {
        self.last_received_timestamp_us as i64
    }

    #[func]
    fn next_sequence_id(&self) -> i64 {
        self.next_sequence_id as i64
    }
}
