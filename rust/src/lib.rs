use godot::prelude::*;

mod player;
mod server;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}