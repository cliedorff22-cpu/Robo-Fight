## fight.gd - one fight, wired up and stepped: the arena, its hazards, the
## robots, their weapons and drivers, combat, the referee and the match.
##
## It knows nothing about the picture. scenes/fight (ui/fight_scene.gd) adds
## the views, cameras, HUD and sound on top and reads what it needs from
## here; the tests run it bare, with no window at all.
##
## Physics runs on the engine's FIXED tick (project setting, 120 Hz), which is
## what keeps the handling identical on a 60 Hz and a 144 Hz monitor. Each
## tick, in _physics_process:
##
##   1. what the step that just ran did: contacts -> damage, the sanity
##      limits, debris, the referee's read of it, the match clock, the replay
##   2. this step's commands: drivers, weapons, wheel forces, hazards
##
## and then the engine steps the bodies.
class_name Fight
extends Node3D

const IDLE_DRIVE := {"throttle": 0.0, "steer": 0.0, "brake": false, "weapon": 0.0}

# Replays wait for the bell - nothing interrupts the fight. Big hits are
# clipped as they happen, a beat after landing so the aftermath is in the
# clip, and the best few play back as a highlight reel once the match ends.
const REEL_MAX := 3            # clips in the reel
const REEL_MIN_HP := 25.0      # a hit has to be worth seeing again
const CLIP_S := 4.0            # length of each clip
const CLIP_TAIL_S := 1.5       # how long after the hit the clip runs on

var reg: Registry
var rules: Dictionary
var match_seed := 1
## Where: { venue, layout } (data/arenas.json), and the arena put together.
var where := {}
var arena: Dictionary
var bus := Bus.new()
## The match: clock, phases, the count, the result (logic/match.gd).
var bout: Match
var world: ArenaWorld
var hazards: Hazards
var combat: Combat
var debris: Debris
var referee: Referee
var rng: Rng
var replay: Replay
## Every robot in the fight: { id, corner, main, tag, def, assembled, sim,
## weapon, brain, drive }. units[0] is red's main unit, units[1] blue's.
var units := []
var red: Dictionary
var blue: Dictionary
var pilot: Pilot
var two_player := false
## Blue is Player 2's until they hand it to the AI.
var p2_human := false
var sim_time := 0.0
## Stopped dead: a pause, or a replay being shown.
var frozen := false
## Scales a human's steering (Settings -> Steering sensitivity).
var steering := 1.0
var arena_dims := {}
## The best hits so far: [{ clip, hp, atS }].
var reel := []

var _start_condition := {}     # unit id -> condition it came in with
var _pending_clip = null
var _stepped := false

## opts:
##   red, blue          robot definitions (already as they should fight)
##   seed               one seed drives every roll: damage, debris, the
##                      judges, both AI drivers and which killsaws come up
##   where              { venue, layout }
##   redAI              the AI drives red too
##   twoPlayer          Player 2 drives blue
##   conditions         { unit id: condition } carried in from a career
##   mats               the material library (for debris; null runs blind)
func _init(registry: Registry, opts: Dictionary) -> void:
	name = "Fight"
	reg = registry
	rules = reg.rules
	match_seed = int(opts.get("seed", 1))
	where = opts.get("where", {"venue": Arenas.DEFAULT_VENUE, "layout": Arenas.DEFAULT_LAYOUT})
	arena = Arenas.compose_arena(reg, where)
	two_player = J.truthy(opts.get("twoPlayer"))
	p2_human = two_player
	rng = Rng.new(match_seed)

	var red_def: Dictionary = opts.red
	var blue_def: Dictionary = opts.blue
	var red_asm := Build.assemble_robot(reg, red_def)
	var blue_asm := Build.assemble_robot(reg, blue_def)
	# Two copies of the same robot would share an id and collide in every map
	# keyed by it.
	var same: bool = blue_asm.id == red_asm.id
	if same: blue_asm.id = "%s_2" % blue_asm.id

	world = ArenaWorld.new(arena)
	add_child(world)
	hazards = Hazards.new(self, arena, bus, match_seed)
	arena_dims = {"halfX": world.dims.halfX, "halfZ": world.dims.halfZ}

	var red_spawn = _spawn("red")
	var blue_spawn = _spawn("blue")
	_add_unit("red", true, "", red_def, red_asm, red_spawn.pos, red_spawn.yaw, match_seed, "%d:player" % match_seed)
	_add_unit("blue", true, "", blue_def, blue_asm, blue_spawn.pos, blue_spawn.yaw, match_seed + 1, "%d:opp" % match_seed)
	red = units[0]
	blue = units[1]
	# Multibots: the second unit of either corner, AI driven, spawned beside
	# its main unit. Each fights its own fight; the corner is out when more
	# than half its weight cannot drive (referee.gd).
	for spec in [["red", red_def, red_spawn, "p2"], ["blue", blue_def, blue_spawn, "o2"]]:
		var def: Dictionary = spec[1]
		if def.get("partner") == null: continue
		var pa = Build.assemble_partner(reg, def)
		if pa == null: continue
		if spec[0] == "blue" and same: pa.id = "%s_2" % pa.id
		var yaw: float = spec[2].yaw
		var at: Vector3 = spec[2].pos + Vector3(sin(yaw) * 1.1, 0, cos(yaw) * 1.1)
		_add_unit(spec[0], false, spec[3], def, pa, at, yaw, Rng.hash_seed("%d:%s" % [match_seed, spec[3]]), "%d:%s:ai" % [match_seed, spec[3]])

	# What each robot carries in from its last fight (a career's pit).
	var conditions: Dictionary = opts.get("conditions", {})
	for u in units:
		if conditions.get(u.id) is Dictionary: u.assembled.condition.merge(conditions[u.id], true)
		# How every robot came in: a rematch starts from this, not from new.
		_start_condition[u.id] = u.assembled.condition.duplicate()

	bout = Match.new(rules, bus, {"botIds": [red.id, blue.id], "seed": match_seed})
	combat = Combat.new(rules, rng, bus)
	for u in units:
		u.weapon = Weapon.new(u.assembled, rules)
		combat.register_bot(u.id, u.sim, u.weapon, u.corner)
	combat.register_hazards(hazards)
	debris = Debris.new(self, rng, opts.get("mats"))
	pilot = Pilot.new(bus, Pilot.AI_DRIVER if J.truthy(opts.get("redAI")) else Pilot.HUMAN, red.brain)
	replay = Replay.new(12.0, 30.0)
	referee = Referee.new(bout, bus, [
		{"id": red.id, "units": _side_units("red")},
		{"id": blue.id, "units": _side_units("blue")},
	], arena_dims)

	# Hits are the AI's cue to back off and reset.
	bus.on(Bus.HIT, _on_hit)
	# The referee told someone to let go of a pin.
	bus.on(Bus.PIN_WARNING, func(e):
		for u in units:
			if e.get("botId") == u.id: u.brain.notify({"type": "pinWarning"}))

func _spawn(id: String) -> Dictionary:
	var s: Dictionary = reg.spawn(id)
	return {"pos": Vector3(U.ft_to_m(s.pos[0]), 0, U.ft_to_m(s.pos[2])), "yaw": deg_to_rad(s.yaw)}

func _add_unit(corner: String, main: bool, tag: String, def: Dictionary, asm: Dictionary, at: Vector3, yaw: float, sim_seed: int, brain_key: String) -> void:
	var sim := RobotSim.new(asm, {"pos": at, "yaw": yaw}, rules, sim_seed)
	add_child(sim)
	# Each driver gets its own seeded stream so one's dice never shift the other's.
	var brain := AI.new({"robot": def, "rng": Rng.new(Rng.hash_seed(brain_key))})
	units.append({"id": asm.id, "corner": corner, "main": main, "tag": tag, "def": def, "assembled": asm, "sim": sim,
		"weapon": null, "brain": brain, "drive": IDLE_DRIVE})

func _side_units(corner: String) -> Array:
	var out := []
	for u in units:
		if u.corner == corner: out.append({"id": u.id, "sim": u.sim, "weapon": u.weapon})
	return out

func unit(id) -> Dictionary:
	for u in units:
		if u.id == id: return u
	return {}

func partners_of(corner: String) -> Array:
	return units.filter(func(u): return u.corner == corner and not u.main)

func _on_hit(e: Dictionary) -> void:
	for u in units:
		if e.get("attackerId") == u.id: u.brain.notify({"type": "hit", "landed": true, "kind": e.kind})
		if e.get("defenderId") == u.id: u.brain.notify({"type": "hit", "took": true, "kind": e.kind})
	if bout.phase != Match.LIVE: return
	var hp := 0.0
	for h in e.get("hits", []): hp += J.g(h, "hpLost", 0.0)
	if hp <= REEL_MIN_HP: return
	if _pending_clip != null:
		# Same exchange: run the clip on to cover this hit's aftermath too,
		# but not so far that the first hit falls off the front of it.
		_pending_clip.hp = maxf(_pending_clip.hp, hp)
		_pending_clip.captureAtS = minf(sim_time + CLIP_TAIL_S, _pending_clip.hitAtS + CLIP_S - 0.5)
	else:
		_pending_clip = {"hp": hp, "hitAtS": sim_time, "captureAtS": sim_time + CLIP_TAIL_S}

# ---------------------------------------------------------------- drivers

# Every unit goes after the nearest opposing unit that can still drive.
func _nearest_foe(u: Dictionary) -> Dictionary:
	var p: Vector3 = u.sim.global_position
	var best := {}
	var bd := INF
	var any_working := false
	for f in units:
		if f.corner != u.corner and not J.truthy(f.sim.effective().get("immobile")): any_working = true
	for f in units:
		if f.corner == u.corner: continue
		if any_working and J.truthy(f.sim.effective().get("immobile")): continue
		var q: Vector3 = f.sim.global_position
		var d := Vector2(q.x - p.x, q.z - p.z).length()
		if d < bd:
			bd = d
			best = f
	return best

func perceive(u: Dictionary) -> Dictionary:
	var f := _nearest_foe(u)
	return AIBridge.perceive(u.sim, u.weapon, f.sim, f.weapon, hazards, arena_dims, bout.clockS,
		bout.scorebook.lead(red.id if u.corner == "red" else blue.id))

func _sens(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out.steer = clampf(d.get("steer", 0.0) * steering, -1.0, 1.0)
	return out

# ---------------------------------------------------------------- the step

func _physics_process(h: float) -> void:
	if frozen: return
	if _stepped: _after_step(h)
	_before_step(h)
	_stepped = true

# This step's commands, before the engine moves anything.
func _before_step(h: float) -> void:
	# Bots hold still until the match is live - the AI does not get a head
	# start on the countdown.
	var live := bout.phase == Match.LIVE
	# Two players split the keyboard; a lone human has all of it.
	var split := p2_human and pilot.mode == Pilot.HUMAN
	var human := DriveInput.read_player(0) if split else DriveInput.read()
	var drive := pilot.read(human, perceive(red) if pilot.mode == Pilot.AI_DRIVER else null, h)
	# Before the match, the human can still drive around to try the bot.
	if pilot.mode == Pilot.HUMAN: red.drive = _sens(drive)
	else: red.drive = drive if live else IDLE_DRIVE
	if p2_human: blue.drive = _sens(DriveInput.read_player(1) if split else DriveInput.read())
	else: blue.drive = blue.brain.drive(perceive(blue), h) if live else IDLE_DRIVE
	for u in units:
		if not u.main: u.drive = u.brain.drive(perceive(u), h) if live else IDLE_DRIVE

	# Weapons first: they need this step's effective stats, and the result
	# feeds the contact resolution after the step.
	for u in units: u.weapon.update(h, u.drive.get("weapon", 0.0), u.sim.effective())

	# The AI concedes through its drive input, like everything else it does.
	if live and not p2_human and J.truthy(blue.drive.get("tapOut")): bout.tap_out(blue.id)
	if live and pilot.mode == Pilot.AI_DRIVER and J.truthy(red.drive.get("tapOut")): bout.tap_out(red.id)

	var positions := []
	for u in units:
		u.sim.step(u.drive, h)
		positions.append(u.sim.global_position)
	# The killsaws deploy off the match clock, so they need it.
	hazards.update(h, positions, bout.clockS)

# What the engine's step did.
func _after_step(h: float) -> void:
	combat.resolve(h)
	for u in units: u.sim.clamp_motion()
	debris.update(h)
	var drives := {}
	for u in units: drives[u.id] = u.drive
	referee.step(h, drives)
	bout.update(h)
	sim_time += h
	if _pending_clip != null and sim_time >= _pending_clip.captureAtS: _capture_clip()
	var poses := []
	for u in units: poses.append(u.sim.global_transform)
	replay.record(h, poses)

func _capture_clip() -> void:
	var clip = replay.capture(CLIP_S)
	if clip != null:
		reel.append({"clip": clip, "hp": _pending_clip.hp, "atS": _pending_clip.hitAtS})
		reel = J.sorted(reel, func(a, b): return b.hp - a.hp).slice(0, REEL_MAX)
	_pending_clip = null

# ---------------------------------------------------------------- control

## Stop everything where it is (a pause, a replay), or let it go again.
func set_frozen(on: bool) -> void:
	if frozen == on: return
	frozen = on
	PhysicsServer3D.set_active(not on)

## Start (or restart) the match: robots back in their squares, as they came
## in - fresh in a Quick Fight, carrying what the pit did not fix in a career.
func start_match(countdown := true) -> void:
	set_frozen(false)
	bout.start(countdown)
	for u in units:
		u.sim.reset()
		var c: Dictionary = u.assembled.condition
		for k in c.keys(): c[k] = 1.0
		c.merge(_start_condition.get(u.id, {}), true)
		u.sim.invalidate()
		u.weapon.reset()
		u.brain.reset()
	referee.reset()
	replay.clear()
	reel = []
	_pending_clip = null
	combat.reset()
	debris.clear()

## Put red back on its wheels in its square (a driving aid before the bell).
func reset_red() -> void:
	for u in units:
		if u.corner == "red": u.sim.reset()

## The opponent drives at a new difficulty from now on.
func set_difficulty(level: String) -> void:
	var diff := Settings.difficulty_of(reg, level)
	for u in units:
		if u.corner != "blue": continue
		var def: Dictionary = u.def.duplicate()
		def.skillBonus = diff.skillBonus
		def.learnRate = diff.learnRate
		u.def = def
		u.brain = AI.new({"robot": def, "rng": Rng.new(Rng.hash_seed("%d:%s:%s" % [match_seed, "opp" if u.main else u.tag + ":ai", level]))})

func _exit_tree() -> void:
	# Never leave the engine's physics switched off behind us.
	PhysicsServer3D.set_active(true)
	if referee != null: referee.dispose()
