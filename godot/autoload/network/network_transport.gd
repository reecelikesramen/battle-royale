extends NetworkDriver

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

enum LoadTestingPreset {
	OFF,
	BROADBAND,
	WIFI_LIGHT,
	WIFI_CONGESTED,
	MOBILE_AVERAGE,
	MOBILE_BUFFERBLOAT,
}

func _apply_load_testing_preset(preset: LoadTestingPreset) -> void:
	match preset:
		LoadTestingPreset.OFF:
			print("Applying load testing preset: OFF")
			fake_ping_lag_send = 0
			fake_ping_lag_recv = 0
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 0
			fake_jitter_recv = 0
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 0
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 0
		LoadTestingPreset.BROADBAND:
			print("Applying load testing preset: BROADBAND")
			fake_ping_lag_send = 25
			fake_ping_lag_recv = 25
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 5
			fake_jitter_recv = 5
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 60
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 30
		LoadTestingPreset.WIFI_LIGHT:
			print("Applying load testing preset: WIFI_LIGHT")
			fake_ping_lag_send = 40
			fake_ping_lag_recv = 40
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 12
			fake_jitter_recv = 12
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 0
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 0
		LoadTestingPreset.WIFI_CONGESTED:
			print("Applying load testing preset: WIFI_CONGESTED")
			fake_ping_lag_send = 65
			fake_ping_lag_recv = 65
			fake_loss_send = 1
			fake_loss_recv = 1
			fake_jitter_send = 20
			fake_jitter_recv = 20
			fake_dup_send = 1
			fake_dup_recv = 1
			fake_dup_ms_max = 110
			fake_reorder_send = 2
			fake_reorder_recv = 2
			fake_reorder_ms = 70
		LoadTestingPreset.MOBILE_AVERAGE:
			print("Applying load testing preset: MOBILE_AVERAGE")
			fake_ping_lag_send = 100
			fake_ping_lag_recv = 100
			fake_loss_send = 2
			fake_loss_recv = 2
			fake_jitter_send = 30
			fake_jitter_recv = 30
			fake_dup_send = 1
			fake_dup_recv = 1
			fake_dup_ms_max = 150
			fake_reorder_send = 3
			fake_reorder_recv = 3
			fake_reorder_ms = 110
		LoadTestingPreset.MOBILE_BUFFERBLOAT:
			print("Applying load testing preset: MOBILE_BUFFERBLOAT")
			fake_ping_lag_send = 140
			fake_ping_lag_recv = 140
			fake_loss_send = 3
			fake_loss_recv = 3
			fake_jitter_send = 45
			fake_jitter_recv = 45
			fake_dup_send = 2
			fake_dup_recv = 2
			fake_dup_ms_max = 190
			fake_reorder_send = 5
			fake_reorder_recv = 5
			fake_reorder_ms = 150


@export var load_testing_off: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.OFF)
		set_deferred("load_testing_off", false)

@export var load_testing_broadband: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.BROADBAND)
		set_deferred("load_testing_broadband", false)

@export var load_testing_wifi_light: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.WIFI_LIGHT)
		set_deferred("load_testing_wifi_light", false)

@export var load_testing_wifi_congested: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.WIFI_CONGESTED)
		set_deferred("load_testing_wifi_congested", false)

@export var load_testing_mobile_average: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.MOBILE_AVERAGE)
		set_deferred("load_testing_mobile_average", false)

@export var load_testing_mobile_bufferbloat: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.MOBILE_BUFFERBLOAT)
		set_deferred("load_testing_mobile_bufferbloat", false)


var is_dedicated_server: bool:
	get: return "--server" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
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
