extends Node

# Server tick clock + render-time computation for interpolation.
#
# Phase 1: server broadcasts ServerTickPacket every physics tick. Client EMAs
# the offset between server timestamp and local timestamp at packet arrival.
# render_time_us() = local_us + offset - interp_window_us. Proxy entities
# render against this clock; predicted entities ignore it.

@export var tick_hz: int = 120         ## engine physics rate; future schemas may override
@export var snapshot_hz: int = 30      ## server -> client state broadcast rate
@export var interp_window_ratio: float = 1.0  ## multiplier on (1/snapshot_hz) interval

var server_tick: int = 0               ## latest known server tick
var server_tick_us: int = 0            ## server-reported timestamp when last tick received
var local_us_at_last_sync: int = 0     ## local clock when last tick received

# EMA-smoothed offset: server_us - local_us. Used to convert local time into
# server time for interp/render computations.
var offset_us: float = 0.0
var synced: bool = false

const _EMA_ALPHA: float = 0.1


func _ready() -> void:
	if NetClient.has_signal("handle_server_tick"):
		NetClient.handle_server_tick.connect(_on_server_tick)


func _on_server_tick(packet) -> void:
	var local_us := Time.get_ticks_usec()
	server_tick = packet.server_tick
	server_tick_us = packet.server_tick_us
	local_us_at_last_sync = local_us

	var sample := float(packet.server_tick_us) - float(local_us)
	if not synced:
		offset_us = sample
		synced = true
	else:
		offset_us = lerpf(offset_us, sample, _EMA_ALPHA)


## Server-clock time for "now" on the local machine.
func server_now_us() -> int:
	return Time.get_ticks_usec() + int(offset_us)


## The server-clock time to sample for proxy rendering. Subtracts the interp
## window so we render slightly in the past, giving snapshots room to arrive.
func render_time_us() -> int:
	var window_us := int(interp_window_ratio * 1_000_000.0 / float(snapshot_hz))
	return server_now_us() - window_us


## Seconds-per-tick. Convenience for replacing
## `1.0 / Engine.get_physics_ticks_per_second()`.
func tick_delta() -> float:
	return 1.0 / float(tick_hz)
