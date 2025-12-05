class_name PeekState
extends State

const MAX_VELOCITY: float = 2.0
const PEEK_SPEED: float = 5.0
const UNPEEK_SPEED: float = 7.0

@onready var player: PlayerController = owner
var animation_player: AnimationPlayer:
	get: return player.animation_player
var ctx: Enums.IntegrationContext:
	get: return player.context
var is_remote_player: bool:
	get: return !player.is_authority and !NetworkTransport.is_server
