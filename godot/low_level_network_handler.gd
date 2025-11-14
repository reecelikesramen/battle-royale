extends NetworkHandler

@export_range(0, 1000) var fake_ping_lag_send: int:
	set(value):
		print("Setting fake ping lag send to %d" % value)
		fake_ping_lag_send = value
		set_fake_ping_lag_send(value)

@export_range(0, 1000) var fake_ping_lag_recv: int:
	set(value):
		print("Setting fake ping lag recv to %d" % value)
		fake_ping_lag_recv = value
		set_fake_ping_lag_recv(value)

@export_range(0, 1000) var fake_loss_send: int:
	set(value):
		print("Setting fake loss send to %d" % value)
		fake_loss_send = value
		set_fake_loss_send(value)

@export_range(0, 1000) var fake_loss_recv: int:
	set(value):
		print("Setting fake loss recv to %d" % value)
		fake_loss_recv = value
		set_fake_loss_recv(value)

@export_range(0, 1000) var fake_jitter_send: int:
	set(value):
		print("Setting fake jitter send to %d" % value)
		fake_jitter_send = value
		set_fake_jitter_send(value)

@export_range(0, 1000) var fake_jitter_recv: int:
	set(value):
		print("Setting fake jitter recv to %d" % value)
		fake_jitter_recv = value
		set_fake_jitter_recv(value)

@export_range(0, 1000) var fake_dup_send: int:
	set(value):
		print("Setting fake dup send to %d" % value)
		fake_dup_send = value
		set_fake_dup_send(value)

@export_range(0, 1000) var fake_dup_recv: int:
	set(value):
		print("Setting fake dup recv to %d" % value)
		fake_dup_recv = value
		set_fake_dup_recv(value)

@export_range(0, 1000) var fake_dup_ms_max: int:
	set(value):
		print("Setting fake dup ms max to %d" % value)
		fake_dup_ms_max = value
		set_fake_dup_ms_max(value)

@export_range(0, 1000) var fake_reorder_send: int:
	set(value):
		print("Setting fake reorder send to %d" % value)
		fake_reorder_send = value
		set_fake_reorder_send(value)

@export_range(0, 1000) var fake_reorder_recv: int:
	set(value):
		print("Setting fake reorder recv to %d" % value)
		fake_reorder_recv = value
		set_fake_reorder_recv(value)

@export_range(0, 1000) var fake_reorder_ms: int:
	set(value):
		print("Setting fake reorder ms to %d" % value)
		fake_reorder_ms = value
		set_fake_reorder_ms(value)

var is_dedicated_server: bool:
	get: return "--server" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	print("I'm a server" if is_dedicated_server else "I'm a client")
	if is_dedicated_server:
		start_server_default()
		set_fake_ping_lag_send(fake_ping_lag_send)
		set_fake_ping_lag_recv(fake_ping_lag_recv)
		set_fake_loss_send(fake_loss_send)
		set_fake_loss_recv(fake_loss_recv)
		set_fake_jitter_send(fake_jitter_send)
		set_fake_jitter_recv(fake_jitter_recv)
		set_fake_dup_send(fake_dup_send)
		set_fake_dup_recv(fake_dup_recv)
		set_fake_dup_ms_max(fake_dup_ms_max)
		set_fake_reorder_send(fake_reorder_send)
		set_fake_reorder_recv(fake_reorder_recv)
		set_fake_reorder_ms(fake_reorder_ms)


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_server:
			destroy_server()
		else:
			disconnect_client()
