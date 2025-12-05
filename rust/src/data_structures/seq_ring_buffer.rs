use godot::prelude::*;
use num_traits::FromPrimitive;
use crate::math::sequence::{seq_is_newer, seq_diff};

const BUFFER_SIZE: usize = 128;
const MAX_DELAY_US: i64 = 150_000i64; // 150ms
const MIN_DELAY_US: i64 = 33_000i64; // 33ms

#[derive(Clone)]
struct BufferEntry {
    arrival_timestamp_us: i64,  // when this client received the packet
    // server_timestamp_us: i64,
    value: Variant,
}

#[derive(GodotClass)]
#[class(init, base=RefCounted)]
struct InterpolationPair {
    base: Base<RefCounted>,
    #[var]
    from: Variant,
    #[var]
    to: Variant,
    #[var]
    alpha: f64,
    #[var]
    extrapolation_s: f64,
    #[var]
    is_valid: bool,
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SequenceRingBuffer {
    base: Base<RefCounted>,
    buffer: Vec<Option<BufferEntry>>,
    size: usize, // must be power of 2
    mask: u16,
    oldest_sequence_id: u16,
    newest_sequence_id: u16,
    count: usize,
    buffer_delay_us: i64,
}

#[godot_api]
impl IRefCounted for SequenceRingBuffer {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            buffer: vec![None; BUFFER_SIZE],
            size: BUFFER_SIZE,
            mask: (BUFFER_SIZE - 1) as u16,
            oldest_sequence_id: 65535,
            newest_sequence_id: 65535,
            count: 0,
            buffer_delay_us: 0,
        }
    }
}

#[godot_api]
impl SequenceRingBuffer {
    #[func]
    fn insert(&mut self, sequence_id: i64, arrival_timestamp_us: i64, server_timestamp_us: i64, value: Variant) -> bool {
        let Some(seq_id) = u16::from_i64(sequence_id) else {
            godot_warn!("Invalid sequence id: {sequence_id}");
            return false;
        };

        let window = seq_diff(self.newest_sequence_id, seq_id);
        if self.count > 0 && window > self.size as i32 {
            godot_warn!(
                "Sequence {} dropped: newer end of buffer is {}",
                seq_id,
                self.newest_sequence_id,
            );
            return false;
        }

        let index = (seq_id & self.mask) as usize;
        let was_empty = self.buffer[index].is_none();
        let extends_front = self.count == 0 || seq_is_newer(seq_id, self.newest_sequence_id);

        // adaptive delay
        let mut prev_arrival_timestamp_us = None;
        if self.count > 0 && extends_front {
            let prev_index = (self.newest_sequence_id & self.mask) as usize;

            if let Some(ref prev_entry) = self.buffer[prev_index] {
                prev_arrival_timestamp_us = Some(prev_entry.arrival_timestamp_us);
            }
        }

        self.buffer[index] = Some(BufferEntry { arrival_timestamp_us, /*server_timestamp_us,*/ value });

        if was_empty {
            self.count += 1;
        }

        if self.count == 1 {
            self.oldest_sequence_id = seq_id;
            self.newest_sequence_id = seq_id;
            return true;
        }

        if extends_front {
            if let Some(prev_arrival_timestamp_us) = prev_arrival_timestamp_us {
                let delta_us = arrival_timestamp_us - prev_arrival_timestamp_us;
                if delta_us > 0 {
                    self.buffer_delay_us = delta_us.clamp(MIN_DELAY_US, MAX_DELAY_US);
                } else if arrival_timestamp_us != -1 || prev_arrival_timestamp_us != -1 {
                    // not -1 and not -1 supresses insert from unacked inputs since its not needed for this
                    godot_warn!("Timestamp is older than previous entry: {} < {}", arrival_timestamp_us, prev_arrival_timestamp_us);
                }
            }
            self.newest_sequence_id = seq_id;
        } else if seq_is_newer(self.oldest_sequence_id, seq_id) {
            self.oldest_sequence_id = seq_id;
        }

        true
    }

    #[func]
    fn prune_up_to(&mut self, sequence_id: i64) -> i64 {
        let Some(prune_seq_id) = u16::from_i64(sequence_id) else {
            godot_warn!("Invalid sequence id: {sequence_id}");
            return 0;
        };

        let mut pruned = 0;
        let mut current = self.oldest_sequence_id;

        loop {
            let index = (current & self.mask) as usize;
            if self.buffer[index].is_some() && !seq_is_newer(current, prune_seq_id) {
                self.buffer[index] = None;
                self.count -= 1;
                pruned += 1;
            }

            if current == self.newest_sequence_id {
                break;
            }

            current = current.wrapping_add(1);

            if seq_diff(current, self.oldest_sequence_id) > self.size as i32 {
                break;
            }
        }

        pruned
    }

    #[func]
    fn get_starting_at(&mut self, sequence_id: i64) -> Array<Variant> {
        let Some(start_seq_id) = u16::from_i64(sequence_id) else {
            godot_warn!("Invalid sequence id: {sequence_id}");
            return Array::new();
        };

        let mut result = Array::new();
        let mut current = start_seq_id;

        loop {
            let index = (current & self.mask) as usize;
            if let Some(ref value) = self.buffer[index] {
                result.push(&value.value);
            }

            if current == self.newest_sequence_id {
                break;
            }

            current = current.wrapping_add(1);

            if seq_diff(current, start_seq_id) > self.size as i32 {
                break;
            }
        }

        result
    }

    #[func]
    fn get_interpolation_pair(&mut self, now_us: i64) -> Gd<InterpolationPair> {
        if self.count >= 3 {
            let target_time = now_us - self.buffer_delay_us;

            loop {
                if self.count < 3 {
                    break;
                }

                let mut candidate = self.oldest_sequence_id.wrapping_add(1);
                let mut next_entry = None;
                while candidate != self.newest_sequence_id.wrapping_add(1) {
                    let index = (candidate & self.mask) as usize;
                    if let Some(ref entry) = self.buffer[index] {
                        next_entry = Some((candidate, entry.arrival_timestamp_us));
                        break;
                    }
                    candidate = candidate.wrapping_add(1);
                }

                let Some((next_seq, next_arrival_timestamp_us)) = next_entry else { break; };

                if target_time > next_arrival_timestamp_us {
                    let old_index = (self.oldest_sequence_id & self.mask) as usize;
                    if self.buffer[old_index].is_some() {
                        self.buffer[old_index] = None;
                        self.count -= 1;
                    }
                    self.oldest_sequence_id = next_seq;
                    continue;
                }

                break;

                // let next_seq = self.oldest_sequence_id.wrapping_add(1);
                // let next_index = (next_seq & self.mask) as usize;

                // if let Some(ref next_entry) = self.buffer[next_index] {
                //     if target_time > next_entry.timestamp_us {
                //         let old_index = (self.oldest_sequence_id & self.mask) as usize;
                //         self.buffer[old_index] = None;
                //         self.count -= 1;
                //         self.oldest_sequence_id = next_seq;
                //         continue;
                //     }
                // }

                // break;
            }
        }

        let mut pair = Gd::from_init_fn(|base| InterpolationPair {
            base,
            from: Variant::nil(),
            to: Variant::nil(),
            alpha: 0.0,
            extrapolation_s: 0.0,
            is_valid: false,
        });

        if self.count == 0 {
            return pair;
        }

        if self.count == 1 {
            let index = (self.oldest_sequence_id & self.mask) as usize;
            if let Some(ref entry) = self.buffer[index] {
                pair.bind_mut().from = entry.value.clone();
                pair.bind_mut().is_valid = true;
            }
            return pair;
        }

        let target_time = now_us - self.buffer_delay_us;
        let mut current = self.oldest_sequence_id;
        let mut from: Option<&BufferEntry> = None;
        let mut to: Option<&BufferEntry> = None;

        loop {
            let index = (current & self.mask) as usize;

            if let Some(ref entry) = self.buffer[index] {
                if entry.arrival_timestamp_us <= target_time {
                    from = Some(entry)
                } else if to.is_none() {
                    to = Some(entry);
                    break;
                }
            }

            if current == self.newest_sequence_id {
                break;
            }

            current = current.wrapping_add(1);

            if seq_diff(current, self.oldest_sequence_id) > self.size as i32 {
                break;
            }
        }

        if let (Some(from), Some(to)) = (from, to) {
            let mut span = to.arrival_timestamp_us - from.arrival_timestamp_us;
            if span < 0 {
                godot_warn!("Timestamp is older than previous entry: {} < {}", to.arrival_timestamp_us, from.arrival_timestamp_us);
            }
            span = span.max(1);
            let alpha = ((target_time - from.arrival_timestamp_us) as f64 / span as f64).clamp(0.0, 1.0);
            let extrapolation_us = (target_time - to.arrival_timestamp_us).max(0);
            pair.bind_mut().from = from.value.clone();
            pair.bind_mut().to = to.value.clone();
            pair.bind_mut().alpha = alpha;
            pair.bind_mut().extrapolation_s = extrapolation_us as f64 / 1_000_000.0;
            pair.bind_mut().is_valid = true;
        } else if let Some(from) = from {
            pair.bind_mut().from = from.value.clone();
            pair.bind_mut().is_valid = true;
        }
            
        pair
    }

    #[func]
    fn size(&self) -> i64 {
        self.count as i64
    }

    #[func]
    fn oldest_sequence_id(&self) -> i64 {
        self.oldest_sequence_id as i64
    }

    #[func]
    fn newest_sequence_id(&self) -> i64 {
        self.newest_sequence_id as i64
    }

    #[func]
    fn buffer_delay_us(&self) -> i64 {
        self.buffer_delay_us
    }
}