use crate::packet::macros::{ToGodot, ToWire};
use godot::prelude::*;
use num_traits::FromPrimitive;

impl ToWire<[f32; 3]> for Vector3 {
    fn to_wire(&self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }
}
impl ToGodot<Vector3> for [f32; 3] {
    fn to_godot(&self) -> Vector3 {
        Vector3::new(self[0], self[1], self[2])
    }
}
impl ToWire<[f32; 2]> for Vector2 {
    fn to_wire(&self) -> [f32; 2] {
        [self.x, self.y]
    }
}
impl ToGodot<Vector2> for [f32; 2] {
    fn to_godot(&self) -> Vector2 {
        Vector2::new(self[0], self[1])
    }
}

impl ToWire<u8> for i64 {
    fn to_wire(&self) -> u8 {
        FromPrimitive::from_i64(*self).unwrap_or_else(|| {
            godot_print!("ERROR: Failed to convert i64 to u8: {}", self);
            0
        })
    }
}

impl ToGodot<i64> for u8 {
    fn to_godot(&self) -> i64 {
        i64::from(*self)
    }
}

impl ToWire<f32> for f64 {
    fn to_wire(&self) -> f32 {
        FromPrimitive::from_f64(*self).unwrap_or_else(|| {
            godot_print!("ERROR: Failed to convert f64 to f32: {}", self);
            0.0
        })
    }
}

impl ToGodot<f64> for f32 {
    fn to_godot(&self) -> f64 {
        f64::from(*self)
    }
}

impl ToWire<u16> for i64 {
    fn to_wire(&self) -> u16 {
        FromPrimitive::from_i64(*self).unwrap_or_else(|| {
            godot_print!("ERROR: Failed to convert i64 to u16: {}", self);
            0
        })
    }
}

impl ToGodot<i64> for u16 {
    fn to_godot(&self) -> i64 {
        i64::from(*self)
    }
}

impl ToWire<u32> for i64 {
    fn to_wire(&self) -> u32 {
        FromPrimitive::from_i64(*self).unwrap_or_else(|| {
            godot_print!("ERROR: Failed to convert i64 to u32: {}", self);
            0
        })
    }
}

impl ToGodot<i64> for u32 {
    fn to_godot(&self) -> i64 {
        i64::from(*self)
    }
}

impl ToWire<i8> for f64 {
    fn to_wire(&self) -> i8 {
        (*self as i8).clamp(-1, 1)
    }
}

impl ToGodot<f64> for i8 {
    fn to_godot(&self) -> f64 {
        f64::from(*self)
    }
}