class_name MovementState

extends State

@onready var player: FPSController = owner
var animation_player: AnimationPlayer:
	get: return player.animation_player
var ctx: Enums.IntegrationContext:
	get: return player.context
