class_name MovementState
extends State

@onready var player: PlayerController = owner
var animation_player: AnimationPlayer:
	get: return player.animation_player
var animation_tree: AnimationTree:
	get: return player.animation_tree
var camera_animation_player: AnimationPlayer:
	get: return player.camera_animation_player
var ctx: Enums.IntegrationContext:
	get: return player.context
var is_remote_player: bool:
	get: return !player.is_authority and !NetworkTransport.is_server
