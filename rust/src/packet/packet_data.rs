use std::io::Result;
use godot::prelude::*;


pub(crate) trait PacketData: Sized {
    const IS_RELIABLE: bool;
    fn encode(&self) -> Vec<u8>;
    fn decode(data: &[u8]) -> Result<Self>;
}
