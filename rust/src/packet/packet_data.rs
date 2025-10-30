use std::io::Result;


pub(crate) trait PacketData: Sized {
    const IS_RELIABLE: bool;
    fn encode(&self) -> Vec<u8>;
    fn decode(data: &[u8]) -> Result<Self>;
}
