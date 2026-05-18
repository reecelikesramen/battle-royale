extends Node

# Client-local persisted settings. Today: just the Network Quality preset,
# which scales reconcile smoothing / snap / deadband / proxy buffer-segments
# on NetPredictor so high-ping players can trade visual accuracy for input
# feel.
#
# Anti-cheat note: every setting here is presentation-layer. Server policy
# (hit detection, damage, lag-comp clamp, grenade physics) doesn't read
# anything from this store — clients lying about their preset just changes
# what their own screen does.

enum QualityPreset {
	LOW = 0,       # <40ms RTT: tight reconcile, max responsiveness
	BALANCED = 1,  # 40-100ms RTT: current defaults (no-op multipliers)
	HIGH = 2,      # >100ms RTT: smoother reconcile, looser snap, longer interp
	AUTO = 3,      # Sample ping (NetClient EMA), pick LOW/BALANCED/HIGH per bucket
}

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "network"
const SETTINGS_KEY_PRESET := "quality_preset"

# Preset → multiplier table. Lookup-only; flip to constants if hot.
# smooth_rate_mul:    higher = corrects faster (tighter feel, more visible jitter)
# snap_mul:           higher = tolerates larger errors before hard-snapping
# deadband_mul:       higher = ignores more sub-threshold jitter (smoother)
# buffer_segments_mul: higher = more interp lag on remote proxies (smoother)
const PRESET_MULTIPLIERS: Dictionary = {
	QualityPreset.LOW: {
		"smooth_rate_mul": 1.5,
		"snap_mul": 0.5,
		"deadband_mul": 0.7,
		"buffer_segments_mul": 0.6,
	},
	QualityPreset.BALANCED: {
		"smooth_rate_mul": 1.0,
		"snap_mul": 1.0,
		"deadband_mul": 1.0,
		"buffer_segments_mul": 1.0,
	},
	QualityPreset.HIGH: {
		"smooth_rate_mul": 0.6,
		"snap_mul": 1.5,
		"deadband_mul": 1.5,
		"buffer_segments_mul": 1.4,
	},
	# AUTO uses BALANCED multipliers initially; NetClient.gd's ping sampler
	# overrides the *effective* preset at runtime (sprint 4) by calling
	# set_quality_preset directly with LOW/BALANCED/HIGH. AUTO itself never
	# selects multipliers — it's a flag on which preset to follow live.
}

# Persisted user choice. May be AUTO; the effective preset (LOW/BALANCED/HIGH)
# can differ and lives in `effective_preset` below.
var current_preset: int = QualityPreset.BALANCED

# What multipliers are actually applied right now. NetPredictor reads from
# this dict every correction tick. Always populated; never null.
var quality_multipliers: Dictionary = PRESET_MULTIPLIERS[QualityPreset.BALANCED]

# When current_preset == AUTO, this is what AUTO has resolved to. Otherwise
# it tracks current_preset. NetClient's sprint-4 ping sampler writes this.
var effective_preset: int = QualityPreset.BALANCED

signal quality_preset_changed(new_effective_preset: int)


func _ready() -> void:
	_load_from_disk()


func _load_from_disk() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_PATH)
	if err != OK:
		# First run / missing file — keep defaults.
		return
	var saved: int = cfg.get_value(SETTINGS_SECTION, SETTINGS_KEY_PRESET, QualityPreset.BALANCED)
	if saved < 0 or saved > QualityPreset.AUTO:
		return
	current_preset = saved
	# AUTO defers to NetClient's ping sampler; otherwise the user's pick is
	# also the effective preset.
	if current_preset != QualityPreset.AUTO:
		_apply_effective(current_preset)
	# AUTO case: leave effective at BALANCED until NetClient picks. Sprint 4
	# will wire the ping sampler; until then AUTO behaves like BALANCED.


# Called by main-menu / escape-menu UI when the user changes their preset.
# Writes through to disk and updates the effective preset (unless AUTO, which
# defers to the ping sampler).
func set_quality_preset(preset: int) -> void:
	if preset < 0 or preset > QualityPreset.AUTO:
		return
	current_preset = preset
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # ignore err; we'll write either way
	cfg.set_value(SETTINGS_SECTION, SETTINGS_KEY_PRESET, preset)
	cfg.save(SETTINGS_PATH)
	if preset == QualityPreset.AUTO:
		# Don't change the live multipliers — the sampler controls effective.
		return
	_apply_effective(preset)


# Called by NetClient's ping sampler (sprint 4) when AUTO is active and the
# RTT bucket changes. Direct user picks go through set_quality_preset which
# also writes to disk; this entry point doesn't persist (the user's choice
# remains AUTO across sessions).
func apply_auto_preset(preset: int) -> void:
	if preset == QualityPreset.AUTO:
		return
	if preset < 0 or preset > QualityPreset.HIGH:
		return
	if current_preset != QualityPreset.AUTO:
		return
	_apply_effective(preset)


func _apply_effective(preset: int) -> void:
	if preset < 0 or preset > QualityPreset.HIGH:
		return
	if preset == effective_preset and quality_multipliers == PRESET_MULTIPLIERS[preset]:
		return
	effective_preset = preset
	quality_multipliers = PRESET_MULTIPLIERS[preset]
	print("[SETTINGS] quality preset → %s (mul=%s)" % [_preset_name(preset), quality_multipliers])
	quality_preset_changed.emit(preset)


static func _preset_name(p: int) -> String:
	match p:
		QualityPreset.LOW: return "LOW"
		QualityPreset.BALANCED: return "BALANCED"
		QualityPreset.HIGH: return "HIGH"
		QualityPreset.AUTO: return "AUTO"
	return "?"
