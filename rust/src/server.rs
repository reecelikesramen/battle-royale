use godot::prelude::*;
use godot::classes::Node3D;
use godot::classes::INode3D;

#[derive(GodotClass)]
#[class(base=Node3D)]
struct Server {
    base: Base<Node3D>
}

#[godot_api]
impl INode3D for Server {
    fn init(base: Base<Node3D>) -> Self {
        godot_print!("Server initialized");

        Self { base }
    }
}