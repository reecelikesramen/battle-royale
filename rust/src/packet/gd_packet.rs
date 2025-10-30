use crate::packet::prelude::*;
use godot::prelude::*;

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub(crate) struct GdPacket {
    pub(crate) base: Base<RefCounted>,
    pub(crate) packet: Packet,
}

#[godot_api]
impl IRefCounted for GdPacket {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            packet: Packet::Null(NullPacketWire),
        }
    }
}
