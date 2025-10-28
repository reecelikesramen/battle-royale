use godot::prelude::*;

mod player;
mod network_handler;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}