/*
Future enhancements and notes for define_packet! macro

- Fallible field conversions (recommended):
  Allow per-field `to_wire` (and optionally `to_gd`) closures to return
  `Result<T, E>`. The macro can handle this by logging and returning an empty
  payload or by switching the Godot API to propagate `Option`/`Result`.

- Packet enum/ID registration (optional):
  Provide a separate `register_packets!(...)` macro that generates
  `PacketId`, `Packet`, and all match arms. This eliminates the manual
  edits to `packet.rs` when adding new packets.

- Tradeoffs and considerations:
  * Macro debuggability: compile errors can be less obvious; keep expansions
    small and focused. Prefer clear error messages inside conversions.
  * Clone requirements: `to_payload()` clones Godot field values. If heavy
    data shows up, consider adjusting the API to borrow or rebuild from
    references.
  * Symmetry: Godot-facing type stays clean (`PacketName`), wire type is
    auto-suffixed with `Wire` and kept engine-free.
*/

/*
Macro schema: define_packet!

Invocation shape (postcard/serde codec)

    define_packet! {
        name: PacketTypeName,
        variant: PacketEnumVariant,
        reliable: <bool>,
        fields: {
            field_a: {
                godot: <GodotFieldType>
                , wire: <WireFieldType>        // optional; defaults documented below
                , default: <expr>              // optional; defaults to Default::default()
                , to_wire: |value| { ... }     // optional; default conversions provided
                , to_gd: |value| { ... }       // optional; default conversions provided
            },
            field_b: { ... },
        },
        codec: postcard
    }

What gets generated

1) Godot-facing class: `PacketTypeName`
   - `#[derive(GodotClass)] #[class(base=RefCounted)]`
   - Fields are declared with Godot types and `#[var]` for export.
   - API:
     - `fn new(..godot_fields..) -> Gd<Self>`
     - `fn create(..godot_fields..) -> Gd<GdPacket>`: builds the wire struct and wraps into `Packet::<variant>`
     - `fn to_payload(&self) -> Gd<GdPacket>`: convenience wrapper calling `create(..self fields..)`, so GDScript can forward a received packet back out without re-specifying fields.

2) Wire/data struct: `PacketTypeNameWire`
   - `#[derive(serde::Serialize, serde::Deserialize)]`
   - Pure Rust data for network encoding/decoding; never contains Godot types.

3) PacketData impl for `PacketTypeNameWire`
   - `const IS_RELIABLE: bool = reliable`
   - `fn encode(&self) -> Vec<u8>`: uses `postcard::to_allocvec(self)`; logs errors on failure.
   - `fn decode(data: &[u8]) -> std::io::Result<Self>`: uses `postcard::from_bytes(data)`.

4) Conversions
   - Per-field conversion is governed by `to_wire` and `to_gd` closures.
   - Default wiring:
       * `Vector3` → `[f32; 3]` (and vice versa)
       * `Vector2` → `[f32; 2]` (and vice versa)
       * `i64` ↔ `u8` conversions with range checking
       * Otherwise, clone the value.
   - You can override both the wire type and conversions per field.

5) Defaults
   - If `default:` is omitted for a field, the macro expands to `<GodotFieldType as Default>::default()`.
   - If the Godot type does not implement `Default` and no `default:` is provided, compilation fails in `init`, forcing an explicit default.

Notes
   - The macro does not modify `PacketId` or the `Packet` enum; add new variants in `packet.rs` (or introduce a separate registration macro later).
*/

use godot::prelude::*;

pub(crate) trait ToWire<W> { fn to_wire(&self) -> W; }
pub(crate) trait ToGodot<G> { fn to_godot(&self) -> G; }

impl<T: Clone> ToWire<T> for T { fn to_wire(&self) -> T { self.clone() } }
impl<T: Clone> ToGodot<T> for T { fn to_godot(&self) -> T { self.clone() } }
impl ToWire<[f32; 3]> for Vector3 { fn to_wire(&self) -> [f32; 3] { [self.x, self.y, self.z] } }
impl ToGodot<Vector3> for [f32; 3] { fn to_godot(&self) -> Vector3 { Vector3::new(self[0], self[1], self[2]) } }
impl ToWire<[f32; 2]> for Vector2 { fn to_wire(&self) -> [f32; 2] { [self.x, self.y] } }
impl ToGodot<Vector2> for [f32; 2] { fn to_godot(&self) -> Vector2 { Vector2::new(self[0], self[1]) } }
impl ToWire<u8> for i64 { fn to_wire(&self) -> u8 { u8::try_from(*self).unwrap_or_else(|_| panic!("i64 value out of range for u8: {}", self)) } }
impl ToGodot<i64> for u8 { fn to_godot(&self) -> i64 { i64::from(*self) } }

#[inline]
pub(crate) fn convert_to_wire<G, W>(v: &G) -> W where G: ToWire<W> { <G as ToWire<W>>::to_wire(v) }
#[inline]
pub(crate) fn convert_to_godot<W, G>(v: &W) -> G where W: ToGodot<G> { <W as ToGodot<G>>::to_godot(v) }

macro_rules! define_packet_wire_ty_default {
    (Vector3) => {
        [f32; 3]
    };
    (Vector2) => {
        [f32; 2]
    };
    ($ty:ty) => {
        $ty
    };
}

macro_rules! define_packet_field_wire_ty {
    ($godot_ty:ty, $wire_ty:ty) => { $wire_ty };
    (Vector3) => { [f32; 3] };
    (Vector2) => { [f32; 2] };
    ($godot_ty:ty) => { $godot_ty };
}

macro_rules! define_packet_field_default {
    ($godot_ty:ty, $default:expr) => {
        $default
    };
    ($godot_ty:ty) => {
        <$godot_ty as Default>::default()
    };
}

macro_rules! define_packet_to_wire_default {
    ($value:expr, Vector3, [f32; 3]) => {
        [$value.x, $value.y, $value.z]
    };
    ($value:expr, Vector2, [f32; 2]) => {
        [$value.x, $value.y]
    };
    ($value:expr, i64, u8) => {
        u8::try_from($value).unwrap_or_else(|_| panic!("i64 value out of range for u8: {}", $value))
    };
    ($value:expr, $godot_ty:ty, $wire_ty:ty) => {
        $value.clone()
    };
}

macro_rules! define_packet_field_to_wire {
    ($value:expr, $godot_ty:ty, $wire_ty:ty, $to_wire:expr) => {
        ($to_wire)(&$value)
    };
    ($value:expr, $godot_ty:ty, $wire_ty:ty) => {
        crate::packet::macros::convert_to_wire::<$godot_ty, $wire_ty>(&$value)
    };
    ($value:expr, $godot_ty:ty, $to_wire:expr) => {
        ($to_wire)(&$value)
    };
    ($value:expr, Vector3) => {
        crate::packet::macros::convert_to_wire::<Vector3, [f32; 3]>(&$value)
    };
    ($value:expr, Vector2) => {
        crate::packet::macros::convert_to_wire::<Vector2, [f32; 2]>(&$value)
    };
    ($value:expr, $godot_ty:ty) => {
        crate::packet::macros::convert_to_wire::<$godot_ty, $godot_ty>(&$value)
    };
}

macro_rules! define_packet_to_gd_default {
    ($value:expr, Vector3, [f32; 3]) => {
        Vector3::new($value[0], $value[1], $value[2])
    };
    ($value:expr, Vector2, [f32; 2]) => {
        Vector2::new($value[0], $value[1])
    };
    ($value:expr, i64, u8) => {
        i64::from($value)
    };
    ($value:expr, $godot_ty:ty, $wire_ty:ty) => {
        $value.clone()
    };
}

macro_rules! define_packet_field_to_gd {
    ($value:expr, $godot_ty:ty, $wire_ty:ty, $to_gd:expr) => {
        ($to_gd)(&$value)
    };
    ($value:expr, $godot_ty:ty, $wire_ty:ty) => {
        crate::packet::macros::convert_to_godot::<$wire_ty, $godot_ty>(&$value)
    };
    ($value:expr, $godot_ty:ty, $to_gd:expr) => {
        ($to_gd)(&$value)
    };
    ($value:expr, Vector3) => {
        crate::packet::macros::convert_to_godot::<[f32; 3], Vector3>(&$value)
    };
    ($value:expr, Vector2) => {
        crate::packet::macros::convert_to_godot::<[f32; 2], Vector2>(&$value)
    };
    ($value:expr, $godot_ty:ty) => {
        crate::packet::macros::convert_to_godot::<$godot_ty, $godot_ty>(&$value)
    };
}

macro_rules! define_packet {
    (
        name: $name:ident,
        variant: $variant:ident,
        reliable: $reliable:expr,
        fields: {
            $( $field:ident : {
                godot: $godot_ty:ty
                $(, wire: $wire_ty:ty)?
                $(, default: $default:expr)?
                $(, to_wire: $to_wire:expr)?
                $(, to_gd: $to_gd:expr)?
                $(,)?
            } ),+ $(,)?
        },
        codec: postcard
    ) => {
        paste::paste! {
            #[derive(GodotClass)]
            #[class(base=RefCounted)]
            pub(crate) struct $name {
                base: Base<RefCounted>,
                $( #[var] $field: $godot_ty ),+
            }

            #[godot_api]
            impl $name {
                #[func]
                pub(crate) fn new($( $field: $godot_ty ),+) -> Gd<Self> {
                    Gd::from_init_fn(|base| Self { base, $( $field ),+ })
                }

                #[func]
                pub(crate) fn create($( $field: $godot_ty ),+) -> Gd<GdPacket> {
                    Gd::from_init_fn(|base| GdPacket {
                        base,
                        packet: Packet::$variant([<$name Wire>] {
                            $( $field: define_packet_field_to_wire!(
                                $field,
                                $godot_ty
                                $(, $wire_ty)?
                                $(, $to_wire)?
                            ) ),+
                        }),
                    })
                }

                #[func]
                pub(crate) fn to_payload(&self) -> Gd<GdPacket> {
                    Self::create($( self.$field.clone() ),+)
                }
            }

            #[godot_api]
            impl IRefCounted for $name {
                fn init(base: Base<RefCounted>) -> Self {
                    Self {
                        base,
                        $( $field: define_packet_field_default!(
                            $godot_ty
                            $(, $default)?
                        ) ),+
                    }
                }
            }

            #[derive(serde::Serialize, serde::Deserialize)]
            pub(crate) struct [<$name Wire>] {
                $( pub(crate) $field: define_packet_field_wire_ty!(
                    $godot_ty
                    $(, $wire_ty)?
                ) ),+
            }

            impl [<$name Wire>] {
                pub(crate) fn as_gd(&self) -> Gd<Object> {
                    $name::new(
                        $( define_packet_field_to_gd!(
                            self.$field,
                            $godot_ty
                            $(, $wire_ty)?
                            $(, $to_gd)?
                        ) ),+
                    ).upcast::<Object>()
                }
            }

            impl PacketData for [<$name Wire>] {
                const IS_RELIABLE: bool = $reliable;

                fn encode(&self) -> Vec<u8> {
                    match postcard::to_allocvec(self) {
                        Ok(bytes) => bytes,
                        Err(err) => {
                            godot_print!(
                                "ERROR: Failed to encode {}: {}",
                                concat!(stringify!($name), "Wire"),
                                err
                            );
                            Vec::new()
                        }
                    }
                }

                fn decode(data: &[u8]) -> std::io::Result<Self> {
                    postcard::from_bytes(data).map_err(|err| {
                        std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            format!("postcard decode failed: {}", err)
                        )
                    })
                }
            }
        }
    };
}

// A specialized macro for packets with no fields ("null"/"empty" payload)
// Generates a Godot-facing class `<Name>` and a unit wire struct `<Name>Wire`.
// Example:
// define_null_packet! { name: NullPacket, variant: Null, reliable: false }
macro_rules! define_null_packet {
    (
        name: $name:ident,
        variant: $variant:ident,
        reliable: $reliable:expr $(,)?
    ) => {
        paste::paste! {
            #[derive(GodotClass)]
            #[class(base=RefCounted)]
            pub(crate) struct $name {
                base: Base<RefCounted>,
            }

            #[godot_api]
            impl $name {
                #[func]
                pub(crate) fn new() -> Gd<Self> {
                    Gd::from_init_fn(|base| Self { base })
                }

                #[func]
                pub(crate) fn create() -> Gd<GdPacket> {
                    Gd::from_init_fn(|base| GdPacket { base, packet: Packet::$variant([<$name Wire>]) })
                }

                #[func]
                pub(crate) fn to_payload(&self) -> Gd<GdPacket> {
                    Self::create()
                }
            }

            #[godot_api]
            impl IRefCounted for $name {
                fn init(base: Base<RefCounted>) -> Self {
                    Self { base }
                }
            }

            // Unit-like wire struct for an empty payload
            pub(crate) struct [<$name Wire>];

            impl [<$name Wire>] {
                pub(crate) fn as_gd(&self) -> Gd<Object> {
                    $name::new().upcast::<Object>()
                }
            }

            impl PacketData for [<$name Wire>] {
                const IS_RELIABLE: bool = $reliable;

                fn encode(&self) -> Vec<u8> {
                    Vec::new()
                }

                fn decode(data: &[u8]) -> std::io::Result<Self> {
                    if data.is_empty() {
                        Ok(Self)
                    } else {
                        Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "Null packet should have empty payload",
                        ))
                    }
                }
            }
        }
    };
}
