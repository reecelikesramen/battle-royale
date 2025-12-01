use godot::prelude::*;

mod network_driver;
mod packet;
mod data_structures;
mod math;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}
