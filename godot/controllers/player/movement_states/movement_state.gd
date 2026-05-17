class_name MovementState
extends State

@onready var player: PlayerController = owner
var animation_player: AnimationPlayer:
	get: return player.animation_player
var animation_tree: AnimationTree:
	get: return player.animation_tree
var camera_animation_player: AnimationPlayer:
	get: return player.camera_animation_player
var is_remote_player: bool:
	get: return !player.is_authority and !player._net.is_authoritative_instance
