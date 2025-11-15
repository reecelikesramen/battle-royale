class_name MovementState

extends State

@onready var player: FPSController = owner
var animation_player: AnimationPlayer:
	get: return player.animation_player
var ctx: Enums.IntegrationContext:
	get: return player.context
var is_remote_player: bool:
	get: return !player.is_authority and !LowLevelNetworkHandler.is_server