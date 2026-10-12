## game_audio.gd - the fight's sound.
##
## It listens to the same bus as the effects and the crowd (impacts, broken
## parts, hazards, the referee, the bell) and is told, once a frame, how fast
## each robot is driving and what its weapon is doing. Nothing in it touches
## game state. The sounds themselves are synthesised (synth.gd); a robot's
## motor and weapon are heard from where the robot is, as the camera hears it.
class_name GameAudio
extends Node3D

const SEV := {"scratch": 0.0, "glance": 0.25, "hit": 0.5, "heavy": 0.8, "catastrophic": 1.0}
const BUS := "Game"
const CROWD_BUS := "Crowd"

static var _streams := {}          # name -> AudioStreamWAV (shared by every fight)
static var _thread: Thread = null
static var _pcm = null
static var _mutex := Mutex.new()

var enabled := true
var volume := 0.75
var crowd_volume := 1.0

var _offs := []
var _shots: Array[AudioStreamPlayer3D] = []
var _flat: Array[AudioStreamPlayer] = []
var _voices := {}                  # robot id -> { drive, whine, whoosh }
var _crowd := {}                   # low / high / voice -> AudioStreamPlayer
var _excitement := 0.0
var _alarm := 0.0
var _ooh_t := -1.0
var _clock := 0.0
var _delayed := []                 # [[time, Callable]]
var _rng := RandomNumberGenerator.new()

## Start making the sounds now (off the main thread), so they are ready by
## the time a fight wants them. Safe to call more than once.
static func warm_up() -> void:
	if not _streams.is_empty() or _thread != null: return
	if DisplayServer.get_name() == "headless": return      # nothing to hear
	_thread = Thread.new()
	_thread.start(func():
		var made := Synth.build_all()
		_mutex.lock()
		_pcm = made
		_mutex.unlock())

## Let the sound-making thread finish (the game is closing).
static func shut_down() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

static func _collect() -> bool:
	if not _streams.is_empty(): return true
	if _thread == null:
		warm_up()
		return false
	_mutex.lock()
	var made = _pcm
	_mutex.unlock()
	if made == null: return false
	_thread.wait_to_finish()
	_thread = null
	for k in made: _streams[k] = Synth.stream(made[k], (k as String).ends_with("_loop"))
	_pcm = null
	return true

static func _ensure_buses() -> void:
	if AudioServer.get_bus_index(BUS) < 0:
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, BUS)
		AudioServer.set_bus_send(i, "Master")
		var comp := AudioEffectCompressor.new()
		comp.threshold = -14.0
		comp.ratio = 4.0
		AudioServer.add_bus_effect(i, comp)
	if AudioServer.get_bus_index(CROWD_BUS) < 0:
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, CROWD_BUS)
		AudioServer.set_bus_send(i, BUS)

func _init(bus: Bus = null, settings: Dictionary = {}) -> void:
	name = "GameAudio"
	_ensure_buses()
	warm_up()
	_rng.randomize()
	for i in 10:
		var p := AudioStreamPlayer3D.new()
		p.bus = BUS
		p.unit_size = 9.0
		p.max_db = 3.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_shots.append(p)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.bus = BUS
		add_child(p)
		_flat.append(p)
	apply_settings(settings)
	if bus == null: return
	_offs.append(bus.on(Bus.HIT, func(e):
		var s: float = SEV.get(e.severity, 0.3)
		if s <= 0.0: return
		impact(minf(1.0, 0.25 + s * 0.8), "ram" if e.kind == "ram" else "weapon", e.get("at"))
		if e.kind == "hazard" and e.get("hazardType") == "screw": _play_at("grind", e.get("at"), 0.8)
		if s >= 0.8: cheer(1.2 if s >= 1.0 else 0.9)
		elif s >= 0.5: cheer(0.5)))
	_offs.append(bus.on(Bus.PART_FAILED, func(e):
		impact(0.9, "weapon", e.get("at"))
		_play_at("break_battery" if e.get("category") == "battery" else "break", e.get("at"), 1.0)
		cheer(0.9)))
	_offs.append(bus.on(Bus.HAZARD_FIRE, _on_hazard))
	_offs.append(bus.on(Bus.REF_COUNT, func(e):
		beep(1320.0 if e.count >= e.of - 2 else 990.0, false, 0.7)
		if e.count == 1: cheer(0.6)))
	_offs.append(bus.on(Bus.KO, func(_e): cheer(1.5)))
	_offs.append(bus.on(Bus.TAP_OUT, func(_e): cheer(1.0)))
	_offs.append(bus.on(Bus.PIN_WARNING, func(_e): beep(520.0, true, 0.7)))
	_offs.append(bus.on(Bus.MATCH_END, func(_e):
		_play("bell", 1.0)
		cheer(1.3)))

# The arena's hazards.
func _on_hazard(e: Dictionary) -> void:
	match e.type:
		"pulverizer", "hammer": _play("pulverizer", 1.0)
		"killsaw": _play("killsaw", 0.9)
		"pit": _play("pit", 1.0)
		"screw": _play("grind", 0.4)

func _exit_tree() -> void:
	for off in _offs:
		if (off as Callable).is_valid(): off.call()

func is_ready() -> bool:
	return _collect()

static func _db(gain: float) -> float:
	return linear_to_db(maxf(gain, 0.00005))

func _play(sound: String, gain: float, pitch := 1.0) -> void:
	if not _collect(): return
	for p in _flat:
		if p.playing: continue
		p.stream = _streams[sound]
		p.volume_db = _db(gain)
		p.pitch_scale = pitch
		p.play()
		return

func _play_at(sound: String, at, gain: float, pitch := 1.0) -> void:
	if at == null:
		_play(sound, gain, pitch)
		return
	if not _collect(): return
	var pick: AudioStreamPlayer3D = null
	for p in _shots:
		if not p.playing:
			pick = p
			break
	if pick == null: pick = _shots[_rng.randi() % _shots.size()]
	pick.stream = _streams[sound]
	pick.position = at
	pick.volume_db = _db(gain)
	pick.pitch_scale = pitch
	pick.play()

# ---------------------------------------------------------------- one-shots

## Steel on steel, at a point in the arena (or everywhere, with no point).
func impact(strength := 0.5, kind := "weapon", at = null) -> void:
	var sound := "impact_r%d" % (_rng.randi() % 2) if kind == "ram" else "impact_w%d" % (_rng.randi() % 4)
	_play_at(sound, at, strength / 0.85 * 1.6, _rng.randf_range(0.92, 1.08))

func beep(freq := 880.0, long := false, gain := 1.0) -> void:
	_play("beep_long" if long else "beep", gain, freq / 880.0)

func countdown_beep(n: int) -> void:
	beep(660.0 if n > 0 else 1320.0, n <= 0, 0.95)

func start_horn() -> void:
	_play("horn", 1.0)
	cheer(1.0)

## A flipper or hammer firing.
func weapon_fired(at = null) -> void:
	_play_at("pneumatic", at, 1.2)

## Lift the crowd: 0.3 a murmur of interest, 1 on their feet.
func cheer(level := 0.6) -> void:
	_excitement = minf(1.6, maxf(_excitement, level))
	# An "ooh": the voice band sweeping up and settling.
	if level >= 0.8: _ooh_t = 0.0

# ---------------------------------------------------------------- settings

func set_enabled(on: bool) -> void:
	enabled = on
	_apply_volume()

func set_volume(v: float) -> void:
	volume = v
	_apply_volume()

func set_crowd(v: float) -> void:
	crowd_volume = v
	_apply_volume()

func _apply_volume() -> void:
	var i := AudioServer.get_bus_index(BUS)
	AudioServer.set_bus_mute(i, not enabled or volume <= 0.001)
	AudioServer.set_bus_volume_db(i, _db(volume))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(CROWD_BUS), _db(crowd_volume))

func apply_settings(s: Dictionary) -> void:
	enabled = J.truthy(s.get("sound", true))
	volume = float(s.get("volume", 0.75))
	crowd_volume = float(s.get("crowd", 1.0))
	_apply_volume()

# ---------------------------------------------------------------- per frame

func _loop_player(sound: String, bus_name: String, spatial: bool) -> Node:
	var p: Node
	if spatial:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 7.0
		p3.max_db = 0.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p = p3
	else:
		p = AudioStreamPlayer.new()
	p.set("bus", bus_name)
	p.set("stream", _streams[sound])
	p.set("volume_db", -80.0)
	add_child(p)
	p.call("play")
	return p

# A robot's drive whine and its weapon, created on first use.
func _voice_of(id, family: String) -> Dictionary:
	if _voices.has(id): return _voices[id]
	var v := {"drive": _loop_player("drive_loop", BUS, true)}
	if family == Weapon.KINETIC:
		# A spinner: a rising whine and the whoosh of the blade going past.
		v.whine = _loop_player("whine_loop", BUS, true)
		v.whoosh = _loop_player("whoosh_loop", BUS, true)
	_voices[id] = v
	return v

## Once a frame. `bots`: [{ id, pos: Vector3, speed 0..1, throttle 0..1,
## family, spin 0..1, omega rad/s, out }]; `live`: the match is running;
## `pit_warning`: 0..1 while the pit is about to open; `energy`: how lively
## this venue's crowd is.
func update(dt: float, bots: Array, live := false, pit_warning := 0.0, energy := 0.4) -> void:
	_clock += dt
	if not _collect(): return
	for i in range(_delayed.size() - 1, -1, -1):
		if _clock >= _delayed[i][0]:
			_delayed[i][1].call()
			_delayed.remove_at(i)
	for b in bots:
		var v := _voice_of(b.id, b.get("family", "none"))
		var k := minf(1.0, dt * 14.0)
		var drive: AudioStreamPlayer3D = v.drive
		drive.position = b.pos
		# Drive whine climbs with speed; louder when the driver is on it.
		drive.pitch_scale = lerpf(drive.pitch_scale, (55.0 + b.speed * 260.0) / 55.0, k)
		var dg: float = 0.0 if J.truthy(b.get("out")) else (0.012 + b.throttle * 0.045 + b.speed * 0.03) * 3.2
		drive.volume_db = lerpf(drive.volume_db, _db(dg), k)
		if v.has("whine"):
			var s := clampf(b.get("spin", 0.0), 0.0, 1.0)
			var whine: AudioStreamPlayer3D = v.whine
			whine.position = b.pos
			whine.pitch_scale = lerpf(whine.pitch_scale, (80.0 + s * 620.0) / 80.0, k)
			whine.volume_db = lerpf(whine.volume_db, _db((0.03 + s * 0.08) * 1.6 if s > 0.02 else 0.0), k)
			# Whoosh: the blades passing, as fast as the ear can follow.
			var whoosh: AudioStreamPlayer3D = v.whoosh
			whoosh.position = b.pos
			whoosh.pitch_scale = lerpf(whoosh.pitch_scale, clampf((4.0 + b.get("omega", 0.0) * 0.12) / 8.0, 0.6, 5.0), k)
			whoosh.volume_db = lerpf(whoosh.volume_db, _db(s * 0.12 * 2.0 if s > 0.05 else 0.0), k)
	# The crowd: a bed that rises with the action and settles back.
	if _crowd.is_empty():
		_crowd = {"low": _loop_player("crowd_low_loop", CROWD_BUS, false), "high": _loop_player("crowd_high_loop", CROWD_BUS, false),
			"voice": _loop_player("crowd_voice_loop", CROWD_BUS, false)}
	_excitement = maxf(0.0, _excitement - dt * 0.35)
	var base := 0.05 + energy * 0.07 if live else 0.03 + energy * 0.04
	var lift := _excitement * 0.32
	var kc := minf(1.0, dt * 4.0)
	_crowd.low.volume_db = lerpf(_crowd.low.volume_db, _db((base + lift * 0.6) * 1.4), kc)
	_crowd.high.volume_db = lerpf(_crowd.high.volume_db, _db((base * 0.6 + lift) * 1.4), kc)
	_crowd.voice.volume_db = lerpf(_crowd.voice.volume_db, _db(lift * 0.5 * 1.4), kc)
	if _ooh_t >= 0.0:
		_ooh_t += dt
		var f := lerpf(450.0, 950.0, _ooh_t / 0.6) if _ooh_t < 0.6 else lerpf(950.0, 650.0, minf(1.0, (_ooh_t - 0.6) / 1.0))
		_crowd.voice.pitch_scale = f / 700.0
		if _ooh_t > 1.6: _ooh_t = -1.0
	# The pit's alarm: a slow two-tone while its lamps flash.
	if pit_warning > 0.0 and live:
		_alarm -= dt
		if _alarm <= 0.0:
			beep(740.0 if int(_clock * 2.5) % 2 == 1 else 560.0, true, 0.6)
			_alarm = 0.4
	else:
		_alarm = 0.0

## Everything quiet (a pause, leaving the fight).
func hush() -> void:
	for id in _voices:
		for k in _voices[id]: _voices[id][k].volume_db = -80.0
