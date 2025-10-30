/*
Future enhancements and notes for define_packet! macro

- Fallible field conversions (recommended):
  Allow per-field `to_wire` (and optionally `to_gd`) closures to return
  `Result<T, E>`. The macro can handle this by:
    - Making `create(...)` and `to_payload()` return `Option<Gd<GdPacket>>`
      (or log a Godot error and return null) when a conversion fails.
    - This removes the need for `.unwrap()` in mappings while preserving
      the ergonomic Godot API.

- Packet enum/ID registration (optional):
  Provide a separate `register_packets!(...)` macro that generates
  `PacketId`, `Packet`, and all match arms. This eliminates the manual
  edits to `packet.rs` when adding new packets.

- Tradeoffs and considerations:
  * Macro debuggability: compile errors can be less obvious; keep expansions
    small and focused. Prefer clear error messages inside conversions.
  * Clone requirements: `to_payload()` currently clones Godot field values.
    This is fine for common Godot value types, but if heavy data shows up,
    consider adjusting the API to borrow or rebuild from references.
  * Symmetry: Godot-facing type stays clean (`PacketName`), wire type is
    auto-suffixed with `Wire` and kept engine-free.
*/

/*
Macro schema: define_packet!

Invocation shape

    define_packet! {
        name: PacketTypeName,
        variant: PacketEnumVariant,
        reliable: <bool>,
        fields: {
            field_a: {
                godot: <GodotFieldType>,
                // Optional when Godot and wire types are identical
                wire: <WireFieldType>,
                // Optional: uses <GodotFieldType as Default>::default() if omitted
                default: <expr>,
                // Optional: Godot -> wire conversion; if omitted, clones the value
                to_wire: |value: &<GodotFieldType>| -> <WireFieldType> { ... },
                // Optional: wire -> Godot conversion; if omitted, clones the value
                to_gd: |value: &<WireFieldType>| -> <GodotFieldType> { ... },
            },
            field_b: { ... },
        },
        // Encode/Decode implement PacketData for the generated Wire type
        encode = |packet| { /* build Vec<u8> from `packet` */ },
        decode = |data| -> Result<Self> { /* parse `data` into Self */ }
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
   - Pure Rust data for network encoding/decoding; never contains Godot types or Base.
   - API:
     - `fn as_gd(&self) -> Gd<Object>`: builds `PacketTypeName::new(..)` and upcasts.

3) PacketData impl for `PacketTypeNameWire`
   - `const IS_RELIABLE: bool = reliable`
   - `fn encode(&self) -> Vec<u8>`: body provided by `encode = |packet| { ... }` (the identifier `packet` is bound to `&self`).
   - `fn decode(data: &[u8]) -> Result<Self>`: body provided by `decode = |data| -> Result<Self> { ... }`.

4) Conversions
   - Per-field conversion is governed by `to_wire` and `to_gd` closures.
   - If `wire:` is omitted, the wire type defaults to the Godot type.
   - If a conversion is omitted, the macro clones the value by default.

5) Defaults
   - If `default:` is omitted for a field, the macro expands to `<GodotFieldType as Default>::default()`.
   - If the Godot type does not implement `Default` and no `default:` is provided, compilation fails in `init`, forcing an explicit default.

6) Assumptions
   - Base type is always `RefCounted` (as requested).
   - The crate `paste` is used to derive the `Wire` type name (`<Name>Wire`).
   - `create` and `to_payload` currently clone Godot field values; acceptable for common Godot value types.

Examples

    // 1) Identical Godot and wire types
    define_packet! {
        name: GameStatePacket,
        variant: GameState,
        reliable: false,
        fields: {
            id: { godot: i64, default: -1 },
            player_position: { godot: Vector3, default: Vector3::ZERO },
        },
        encode = |packet| { /* ... */ },
        decode = |data| -> Result<Self> { /* ... */ },
    }

    // 2) Different Godot and wire types with explicit conversions
    define_packet! {
        name: ChatPacket,
        variant: Chat,
        reliable: true,
        fields: {
            username: {
                godot: GString,
                wire: String,
                to_wire: |v: &GString| v.to_string(),
                to_gd: |v: &String| GString::from(v.as_str()),
            },
        },
        encode = |packet| { /* ... */ },
        decode = |data| -> Result<Self> { /* ... */ },
    }

Notes
   - The macro does not modify `PacketId` or the `Packet` enum; add new variants in `packet.rs` (or introduce a separate registration macro later).
   - For range-limited conversions (e.g., `i64` -> `u8`), consider switching to a fallible form for `to_wire` and have `create`/`to_payload` return `Option<Gd<GdPacket>>` or log errors, as described in the header comment.
*/

macro_rules! define_packet {
    (
        name: $name:ident,
        variant: $variant:ident,
        reliable: $reliable:expr,
        fields: {
            $( $field:ident : {
                godot: $godot_ty:ty,
                $( wire: $wire_ty:ty, )?
                $( default: $default:expr, )?
                $( to_wire: $to_wire:expr, )?
                $( to_gd: $to_gd:expr, )?
            } ),+ $(,)?
        },
        encode = |$encode_self:ident| $encode_body:block,
        decode = |$decode_data:ident| -> Result<Self> $decode_body:block
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
                            $( $field: define_packet!(@to_wire $field $(, $to_wire)? ) ),+
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
                        $( $field: define_packet!(@default $godot_ty $(, $default)? ) ),+
                    }
                }
            }

            pub(crate) struct [<$name Wire>] {
                $( pub(crate) $field: define_packet!(@wire_ty $godot_ty $(, $wire_ty)? ) ),+
            }

            impl [<$name Wire>] {
                pub(crate) fn as_gd(&self) -> Gd<Object> {
                    $name::new(
                        $( define_packet!(@to_gd self.$field $(, $to_gd)? ) ),+
                    ).upcast::<Object>()
                }
            }

            impl PacketData for [<$name Wire>] {
                const IS_RELIABLE: bool = $reliable;

                fn encode(&self) -> Vec<u8> {
                    let $encode_self = self;
                    $encode_body
                }

                fn decode($decode_data: &[u8]) -> Result<Self> $decode_body
            }
        }
    };

    (@wire_ty $godot_ty:ty $(, $wire_ty:ty)? ) => {
        define_packet!(@wire_ty_impl $godot_ty $(, $wire_ty)? )
    };
    (@wire_ty_impl $godot_ty:ty) => { $godot_ty };
    (@wire_ty_impl $godot_ty:ty, $wire_ty:ty) => { $wire_ty };

    (@default $godot_ty:ty $(, $default:expr)? ) => {
        define_packet!(@default_impl $godot_ty $(, $default)? )
    };
    (@default_impl $godot_ty:ty) => { <$godot_ty as Default>::default() };
    (@default_impl $godot_ty:ty, $default:expr) => { $default };

    (@to_wire $value:expr $(, $to_wire:expr)? ) => {
        define_packet!(@to_wire_impl $value $(, $to_wire)? )
    };
    (@to_wire_impl $value:expr) => { $value.clone() };
    (@to_wire_impl $value:expr, $to_wire:expr) => { ($to_wire)(&$value) };

    (@to_gd $value:expr $(, $to_gd:expr)? ) => {
        define_packet!(@to_gd_impl $value $(, $to_gd)? )
    };
    (@to_gd_impl $value:expr) => { $value.clone() };
    (@to_gd_impl $value:expr, $to_gd:expr) => { ($to_gd)(&$value) };
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
