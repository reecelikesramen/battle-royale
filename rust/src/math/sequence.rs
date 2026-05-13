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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diff_simple_forward() {
        assert_eq!(seq_diff(10, 5), 5);
        assert_eq!(seq_diff(0, 0), 0);
    }

    #[test]
    fn diff_simple_backward() {
        assert_eq!(seq_diff(5, 10), -5);
    }

    #[test]
    fn diff_wraparound_forward() {
        // 5 is "newer" than 65530 across the wrap boundary
        assert!(seq_diff(5, 65530) > 0);
        assert_eq!(seq_diff(5, 65530), 11);
    }

    #[test]
    fn diff_wraparound_backward() {
        // 65530 is "older" than 5 across the wrap boundary
        assert!(seq_diff(65530, 5) < 0);
        assert_eq!(seq_diff(65530, 5), -11);
    }

    #[test]
    fn is_newer_around_wrap() {
        assert!(seq_is_newer(5, 65530));
        assert!(!seq_is_newer(65530, 5));
    }

    #[test]
    fn is_newer_equal_returns_false() {
        assert!(!seq_is_newer(42, 42));
    }

    #[test]
    fn diff_max_half_range_split() {
        // At exactly half-range, behavior should be symmetric (one is positive,
        // the other negative); we just guard the wraparound branches don't
        // double-fire.
        let d = seq_diff(0, SEQUENCE_HALF_RANGE as u16);
        assert!(d == -SEQUENCE_HALF_RANGE || d == SEQUENCE_HALF_RANGE);
    }
}