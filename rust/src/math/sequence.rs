use godot::prelude::*;
use num_traits::FromPrimitive;

pub const SEQUENCE_MODULO: i32 = 65536;
pub const SEQUENCE_HALF_RANGE: i32 = SEQUENCE_MODULO / 2;

pub fn seq_is_newer(a: u16, b: u16) -> bool {
    seq_diff(a, b) > 0
}

pub fn seq_diff(a: u16, b: u16) -> i32 {
    let mut diff = (a as i32) - (b as i32);

    if diff > SEQUENCE_HALF_RANGE {
        diff -= SEQUENCE_MODULO;
    } else if diff < -SEQUENCE_HALF_RANGE {
        diff += SEQUENCE_MODULO;
    }
    diff
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct PacketSequence {
    base: Base<RefCounted>,
    sequence: i64,
}

#[godot_api]
impl IRefCounted for PacketSequence {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            sequence: -1,
        }
    }
}

#[godot_api]
impl PacketSequence {
    #[func]
    fn current(&self) -> i64 {
        self.sequence
    }

    #[func]
    fn next(&mut self) -> i64 {
        self.sequence = (self.sequence + 1) % SEQUENCE_MODULO as i64;
        self.sequence
    }

    fn valid_sequences(a: i64, b: i64) -> Option<(u16, u16)> {
        let Some(a) = u16::from_i64(a) else {
            godot_warn!("Invalid sequence id: {a}");
            return None;
        };
        let Some(b) = u16::from_i64(b) else {
            godot_warn!("Invalid sequence id: {b}");
            return None;
        };
        Some((a, b))
    }
    
    #[func]
    fn diff(a: i64, b: i64) -> i64 {
        let Some((a, b)) = Self::valid_sequences(a, b) else {
            return -1;
        };

        seq_diff(a, b) as i64
    }

    #[func]
    fn is_newer(a: i64, b: i64) -> bool {
        let Some((a, b)) = Self::valid_sequences(a, b) else {
            return false;
        };

        seq_is_newer(a, b)
    }

    #[func]
    fn is_newer_or_equal(a: i64, b: i64) -> bool {
        let Some((a, b)) = Self::valid_sequences(a, b) else {
            return false;
        };
        
        seq_is_newer(a, b) || a == b
    }
}