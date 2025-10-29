use godot::prelude::*;

mod network_handler;
mod packet;
mod player;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}
