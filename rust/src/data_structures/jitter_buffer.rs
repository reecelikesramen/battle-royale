use godot::{classes::Engine, prelude::*};
use crate::math::sequence::{seq_is_newer, seq_diff};
use num_traits::FromPrimitive;
use std::collections::HashMap;

const MAX_FRAMES_PER_TICK: usize = 4;
const PACKET_LOSS_TOLERANCE: i32 = 4;

#[derive(GodotClass)]
#[class(no_init, base=RefCounted)]
struct TimestampedPacket {
    base: Base<RefCounted>,
    #[var]
    delta: f64,
    #[var]
    timestamp_us: i64,
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

        if !seq_is_newer(sequence_id, self.last_sequence_id) {
            return;
        }

        self.last_sequence_id = sequence_id;

        let Some(rs_timestamp_us) = u32::from_i64(timestamp_us) else {
            godot_warn!("Invalid timestamp: {timestamp_us}");
            return;
        };


        let delta = if self.last_received_timestamp_us > 0 {
            (rs_timestamp_us - self.last_received_timestamp_us) as f64 / 1_000_000.0
        } else {
            1.0 / Engine::singleton().get_physics_ticks_per_second() as f64
        };
        self.last_received_timestamp_us = rs_timestamp_us;

        let ts_packet = Gd::from_init_fn(|base| TimestampedPacket {
            base,
            delta,
            timestamp_us,
            packet,
        });

        self.packets.insert(sequence_id, ts_packet);
    }

    #[func]
    fn consume(&mut self) -> Array<Gd<TimestampedPacket>> {
        for _ in 0..MAX_FRAMES_PER_TICK {
            // packet available, stop skipping
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
            if let Some(packet) = self.packets.remove(&self.next_sequence_id) {
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