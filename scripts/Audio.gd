class_name GameAudio
extends Node
## Sound manager built in code (no autoload): two looping ambient beds crossfaded by where the
## player is looking (surface vs nest), a small pool of one-shot players with per-sound
## throttling, a master volume and a mute switch (stored in user://settings.cfg).
## Every file access is guarded: a missing / unloadable file just means that sound is silent.
## Headless runs (dummy audio driver, self-test) leave it disabled unless --forcesound is given.

const DIR := "res://assets/audio/"
const SETTINGS_PATH := "user://settings.cfg"
const POOL_SIZE := 6

# name -> [volume_db, min seconds between plays (real time), max copies playing at once, pitch variation]
const SFX := {
	"dig": [-6.0, 0.40, 2, 0.08],
	"fight": [-6.0, 0.45, 2, 0.10],
	"alarm": [-9.0, 6.0, 1, 0.0],
	"threat_warning": [-9.0, 4.0, 1, 0.0],
	"ui_click": [-6.0, 0.05, 2, 0.04],
	"ant_death": [-10.0, 1.5, 1, 0.10],
	"egg_hatch": [-12.0, 2.0, 1, 0.08],
	"food_deposit": [-14.0, 1.2, 1, 0.10],
	"chamber_complete": [-6.0, 2.0, 1, 0.0],
}
const AMBIENT_SURFACE_DB := -6.0
const AMBIENT_NEST_DB := -4.0

var enabled := false             # sound output active (false in headless runs)
var master := 0.6                # 0..1 linear
var muted := false
var played := {}                 # name -> times actually started (diagnostics / tests)
var throttled := {}              # name -> times skipped by throttling / pool limits
var missing: Array[String] = []  # files that could not be loaded

var _streams := {}
var _pool: Array[AudioStreamPlayer] = []
var _last := {}                  # name -> last start time (msec)
var _amb_surface: AudioStreamPlayer
var _amb_nest: AudioStreamPlayer
var _mix := 0.5                  # current surface(0) .. nest(1) blend
var _mix_target := 0.5

func _init(force_enable := false) -> void:
	name = "Audio"
	enabled = force_enable or DisplayServer.get_name() != "headless"
	_load_settings()

func _ready() -> void:
	_apply_master()
	if not enabled:
		return
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	for n in SFX:
		_stream(n)
	_amb_surface = _make_loop("ambient_surface", AMBIENT_SURFACE_DB)
	_amb_nest = _make_loop("ambient_nest", AMBIENT_NEST_DB)
	_update_mix()

func _exit_tree() -> void:
	# release playbacks so the engine does not report leaked resources at exit
	for p in _pool:
		p.stop()
		p.stream = null
	for p in [_amb_surface, _amb_nest]:
		if p != null:
			p.stop()
			p.stream = null
	_streams.clear()

func _stream(n: String) -> AudioStream:
	if _streams.has(n):
		return _streams[n]
	# prefer the small OGG (web download size), fall back to WAV
	var s: AudioStream = null
	var path := ""
	for ext in ["ogg", "wav"]:
		path = "%s%s.%s" % [DIR, n, ext]
		if ResourceLoader.exists(path):
			s = load(path) as AudioStream
			if s != null:
				break
	if s == null:
		missing.append(path)
		push_warning("Audio: cannot load " + path)
	_streams[n] = s
	return s

func _make_loop(n: String, db: float) -> AudioStreamPlayer:
	var base := _stream(n)
	if base == null:
		return null
	var s: AudioStream
	if base is AudioStreamOggVorbis:
		var o := (base as AudioStreamOggVorbis).duplicate() as AudioStreamOggVorbis
		o.loop = true
		s = o
	elif base is AudioStreamWAV:
		var w := (base as AudioStreamWAV).duplicate() as AudioStreamWAV
		# WAVs do not loop by default in Godot 4: loop over the whole sample data
		var bytes_per := 2 * (2 if w.stereo else 1)
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = w.data.size() / bytes_per
		s = w
	else:
		return null
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = db
	add_child(p)
	p.play()
	return p

# ------------------------------------------------------------------ one-shots
## Returns true if the sound was started.
func play(n: String, extra_db := 0.0) -> bool:
	if not enabled or not SFX.has(n):
		return false
	var s := _stream(n)
	if s == null:
		return false
	var cfg: Array = SFX[n]
	var now := Time.get_ticks_msec()
	if now - int(_last.get(n, -100000)) < int(float(cfg[1]) * 1000.0):
		throttled[n] = int(throttled.get(n, 0)) + 1
		return false
	var copies := 0
	var free: AudioStreamPlayer = null
	for p in _pool:
		if p.playing:
			if p.stream == s:
				copies += 1
		elif free == null:
			free = p
	if free == null or copies >= int(cfg[2]):
		throttled[n] = int(throttled.get(n, 0)) + 1
		return false
	_last[n] = now
	free.stream = s
	free.volume_db = float(cfg[0]) + extra_db
	free.pitch_scale = 1.0 + randf_range(-float(cfg[3]), float(cfg[3]))
	free.play()
	played[n] = int(played.get(n, 0)) + 1
	return true

func playing_count() -> int:
	var n := 0
	for p in _pool:
		if p.playing:
			n += 1
	return n

# ------------------------------------------------------------------ ambience
## t: 0 = surface, 1 = underground.
func set_depth_mix(t: float) -> void:
	_mix_target = clampf(t, 0.0, 1.0)

func _process(delta: float) -> void:
	if _mix != _mix_target:
		_mix = move_toward(_mix, _mix_target, delta * 0.8)
		_update_mix()

func _update_mix() -> void:
	if _amb_surface != null:
		_amb_surface.volume_db = linear_to_db(maxf(1.0 - _mix, 0.0001)) + AMBIENT_SURFACE_DB
	if _amb_nest != null:
		_amb_nest.volume_db = linear_to_db(maxf(_mix, 0.0001)) + AMBIENT_NEST_DB

func ambient_playing() -> bool:
	return (_amb_surface != null and _amb_surface.playing) and (_amb_nest != null and _amb_nest.playing)

# ------------------------------------------------------------------ master volume / mute
func set_master(v: float) -> void:
	master = clampf(snappedf(v, 0.05), 0.0, 1.0)
	_apply_master()
	_save_settings()

func change_master(delta: float) -> void:
	set_master(master + delta)

func toggle_mute() -> void:
	muted = not muted
	_apply_master()
	_save_settings()

func _apply_master() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, 0.0001)))
	AudioServer.set_bus_mute(0, muted)

func label() -> String:
	if not enabled:
		return "Sound off (no audio)"
	if muted:
		return "MUTED [M]"
	return "Sound %d%% [M]" % roundi(master * 100.0)

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		master = clampf(float(cf.get_value("audio", "master", master)), 0.0, 1.0)
		muted = bool(cf.get_value("audio", "muted", false))

func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("audio", "master", master)
	cf.set_value("audio", "muted", muted)
	cf.save(SETTINGS_PATH)
