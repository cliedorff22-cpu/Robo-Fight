## hazards.gd - the arena's moving parts: wall screws, corner pulverizers,
## floor killsaws and the pit.
##
## All are KINEMATIC bodies: their transform is driven each step and the
## engine works out the push they give. That makes them unstoppable (a 250 lb
## bot cannot stall a hammer), which is how the real hazards behave.
##
## Each runs a small state machine - armed -> swinging -> retracting ->
## cooldown - triggered by a bot entering its trigger radius, or off the match
## clock. Geometry and timings all come from arena.json.
class_name Hazards
extends RefCounted

const ARMED := "armed"
const SWINGING := "swinging"
const RETRACTING := "retracting"
const COOLDOWN := "cooldown"
# Killsaw states: below the deck until the last minute of the match.
const STOWED := "stowed"
const RISING := "rising"
const SPINNING := "spinning"
const LOWERING := "lowering"

var all: Array = []
var _rota: SawRotation
var _by_body := {}             # body -> hazard, for the ones with teeth

## `match_seed`: the rotating killsaw draw comes from it, so a replayed match
## brings up the same saws at the same times.
func _init(parent: Node3D, arena: Dictionary, bus: Bus = null, match_seed = 1) -> void:
	_rota = SawRotation.new(arena, match_seed)
	for def in arena.get("hazards", []):
		if def.get("enabled") == false: continue
		var pos_m := U.ft3(def.pos)
		var yaw := deg_to_rad(J.g(def, "yaw", 0.0))
		var h: Hazard
		match def.type:
			"screw": h = Screw.new(parent, def, pos_m, yaw, arena)
			"killsaw": h = Killsaw.new(parent, def, pos_m, yaw, arena.get("killsaw", {}), bus)
			"pit": h = PitTrap.new(parent, def, arena, bus)
			_: h = Swinger.new(parent, def, pos_m, yaw, bus)
		all.append(h)
		for b in h.teeth: _by_body[b] = h

## Advance every hazard. `bot_positions` are Vector3 in metres; `remaining_s`
## is the match clock (or null before the bell) - the killsaws deploy off it.
func update(dt: float, bot_positions: Array, remaining_s = null) -> void:
	var ctx := {"remainingS": remaining_s, "killsawActive": _rota.active_at(remaining_s)}
	for h in all: h.update(dt, bot_positions, ctx)

## Ids of the killsaws that should be up with `remaining_s` on the clock (a
## Dictionary used as a set).
func killsaw_active_at(remaining_s) -> Dictionary:
	return _rota.active_at(remaining_s)

## The hazard whose teeth this body is, or null (furniture, the arena).
func hazard_of(body: Object) -> Hazard:
	return _by_body.get(body)

## Render-facing description, built once.
func pieces() -> Array:
	var out := []
	for h in all: out.append_array(h.pieces)
	return out

## Live transforms for the renderer to copy each frame:
## [{ hazardId, part, xf: Transform3D }]
func transforms() -> Array:
	var out := []
	for h in all: h.add_transforms(out)
	return out

func by_id(id: String) -> Hazard:
	for h in all:
		if h.id == id: return h
	return null

# ---------------------------------------------------------------- base

class Hazard:
	extends RefCounted
	var id: String
	var type: String
	var def: Dictionary
	## A representative body: combat reads its motion for closing speed.
	var body: AnimatableBody3D
	var pieces := []
	## The bodies whose touch is a hit (not the pedestal or the cradle).
	var teeth := []
	var state := Hazards.ARMED
	var travel := 0.0
	var warning := 0.0
	## How fast the body itself is moving (only a rising saw does).
	var lin_vel := Vector3.ZERO

	## Dangerous right now?
	func live() -> bool: return false
	func update(_dt: float, _bots: Array, _ctx: Dictionary) -> void: pass
	func add_transforms(_out: Array) -> void: pass

# ---------------------------------------------------------------- screw
# A PAIR of augers lying side by side along the wall, each a shaft with a
# raised helical flight. Both turn so their upper faces run AWAY from the
# wall: a bot that lands on them gets chewed for a moment and thrown back out
# into the arena.
#
# They stand PROUD of the deck, sitting half-sunk in a solid steel cradle that
# runs back to the kickplate, so a bot can be rammed into them or thrown up
# onto them. The cradle fills the space under and behind the augers, so a
# wedge cannot slide in underneath and a bot thrown over them lands on steel.
#
# Each auger is its own body, because each spins about its OWN axis. The
# flights are VISUAL ONLY - the collider is the smooth outer envelope, which
# drags a bot by friction and is numerically stable.
class Screw:
	extends Hazard
	var _augers := []            # [{ body, dir, hand, part }]
	var _base: Basis
	var _omega := 0.0
	var _spin := 0.0

	func _init(parent: Node3D, d: Dictionary, pos_m: Vector3, yaw: float, arena: Dictionary) -> void:
		id = d.id
		type = "screw"
		def = d
		var length_m := U.ft_to_m(d.length)
		var radius_m := U.ft_to_m(d.radius)
		var count := int(J.g(d, "augerCount", 2))
		_omega = absf(U.rpm_to_radps(d.rpm))
		var spacing_m := U.ft_to_m(J.g(d, "augerSpacing", d.radius * 2.2))
		# Auger axis height above the deck; the cradle comes up to it, so the
		# lower half of each auger is enclosed and the upper half is out in
		# the open.
		var center_y := U.ft_to_m(J.g(d, "axisHeight", d.radius))
		# Cylinders run along local Y, so tilt -90 deg about X to lay it along
		# local Z, then yaw it to run along its wall.
		var yaw_b := Phys.yaw_basis(yaw)
		_base = yaw_b * Basis(Vector3.RIGHT, -PI / 2.0)
		# Spin sign that makes the top of the barrel move toward the arena
		# centre. For a positive spin about the laid axis, the top surface
		# moves along axis x up.
		var axis := _base * Vector3.UP
		var top_x := -axis.z
		var top_z := axis.x
		var outward := 1.0 if top_x * -pos_m.x + top_z * -pos_m.z >= 0.0 else -1.0
		for i in count:
			var lateral := (i - (count - 1) / 2.0) * spacing_m
			var off := yaw_b * Vector3(lateral, 0, 0)
			# Born lying down, or it would stand upright for the first step -
			# a 9 ft pole - and be swung flat, swatting anything near it.
			# High friction, no bounce: it should grab a bot, not punt it.
			var b := Phys.kinematic(parent, Transform3D(_base, Vector3(pos_m.x + off.x, center_y, pos_m.z + off.z)), 0.95, 0.0, true)
			Phys.add_shape(b, Phys.cylinder(radius_m, length_m))
			# `hand` mirrors the flights so the pair reads as a matched set.
			_augers.append({"body": b, "dir": outward, "hand": 1 if i % 2 == 0 else -1, "part": "auger%d" % i})
			teeth.append(b)
		body = _augers[0].body

		# The cradle: a fixed steel box from just in front of the inner auger
		# back to the wall, as tall as the auger axis. Local frame: X across
		# the unit (toward the wall is +X once `toWall` is applied), Z along it.
		var lat := yaw_b * Vector3.RIGHT
		var along := lat.x * pos_m.x + lat.z * pos_m.z
		var to_wall := 1.0 if along >= 0.0 else -1.0
		var wall_half := U.ft_to_m(arena.floor.size[0]) / 2.0 if absf(lat.x) > absf(lat.z) else U.ft_to_m(arena.floor.size[1]) / 2.0
		# The inner auger overhangs the cradle face by a centimetre. Set back
		# even a few centimetres, a flat-nosed bot hits the steel box and
		# never touches the teeth; any more overhang and a wedge can slide in
		# under the auger.
		var overhang := 0.01
		var front := -to_wall * (spacing_m * (count - 1) / 2.0 + radius_m - overhang)    # arena side
		var back := to_wall * (wall_half - absf(along) - 0.005)                           # at the wall
		var cradle_w := absf(back - front)
		var cradle_mid := (front + back) / 2.0
		var cradle_off := yaw_b * Vector3(cradle_mid, 0, 0)
		var cradle_pos := Vector3(pos_m.x + cradle_off.x, center_y / 2.0, pos_m.z + cradle_off.z)
		var cradle_l := length_m + 0.24                 # room for the bearing blocks
		# Furniture: running into it does no damage.
		var cradle := Phys.static_box(parent, Transform3D(yaw_b, cradle_pos), Vector3(cradle_w, center_y, cradle_l), 0.6, 0.05)
		# Bearing blocks the shafts turn in, standing on the cradle at each
		# end, up to the crown. Solid, so the picture and the physics agree.
		var block_h := radius_m * 1.15
		var block_d := 0.1
		for end in [-1.0, 1.0]:
			Phys.add_shape(cradle, Phys.box(Vector3(cradle_w, block_h, block_d)),
				Transform3D(Basis.IDENTITY, Vector3(0, center_y / 2.0 + block_h / 2.0, end * (length_m / 2.0 + block_d / 2.0 + 0.01))))
		var aug := []
		for a in _augers: aug.append({"part": a.part, "hand": a.hand})
		pieces = [{
			"kind": "screw", "hazardId": id, "radius": radius_m, "length": length_m,
			"pos": Vector3(pos_m.x, 0, pos_m.z), "yaw": yaw, "centerY": center_y, "augers": aug, "spacing": spacing_m,
			# Which way the wall is, across the unit (+1 or -1 along local X).
			"toWall": to_wall,
		}, {
			"kind": "screwCradle", "hazardId": id, "size": Vector3(cradle_w, center_y, cradle_l), "pos": cradle_pos, "yaw": yaw,
			"endBlock": {"height": block_h, "depth": block_d, "offset": length_m / 2.0 + block_d / 2.0 + 0.01},
		}]

	# A screw never stops turning, so it is always dangerous.
	func live() -> bool: return true

	func update(dt: float, _bots: Array, _ctx: Dictionary) -> void:
		_spin += _omega * dt
		for a in _augers:
			# Spin about the barrel's own axis: applied before the lay/yaw rotation.
			var b: AnimatableBody3D = a.body
			b.transform = Transform3D(_base * Basis(Vector3.UP, _spin * a.dir), b.position)

	func add_transforms(out: Array) -> void:
		for a in _augers: out.append({"hazardId": id, "part": a.part, "xf": a.body.transform})

# ---------------------------------------------------------------- pulverizer
# Modelled on the real pulverizers: a steel pedestal standing on the deck in
# the corner, with the hammer arm hinged at its top. The arm waits standing
# up (leaning back toward the corner), then whips forward over the top and
# slams the head flat onto the floor in front of it.
#
# `pos` is where the HEAD LANDS. The pivot sits `armLength` behind that,
# toward the corner, at `pivotHeight` above the deck.
#
# Angle convention, about the hinge (local X after yawing): 0 = arm pointing
# straight down, 180 = straight up, 270 = straight out over the floor. Local
# +Z faces into the arena, and the head hangs off the arm toward local -Z,
# which is "down" when the arm lies flat at 270.
#
# headSize = [width across the arm, length along the arm, depth of the face].
class Swinger:
	extends Hazard
	var angle := 0.0
	var _t := 0.0
	var _rest := 0.0
	var _strike := 0.0
	var _trigger_r := 0.0
	var _trigger: Vector3
	var _yaw_b: Basis
	var _pivot: Vector3
	var _head_local: Vector3
	var _bus: Bus

	func _init(parent: Node3D, d: Dictionary, pos_m: Vector3, yaw: float, bus: Bus) -> void:
		id = d.id
		type = d.type
		def = d
		_bus = bus
		var arm_length := U.ft_to_m(d.armLength)
		var hw := U.ft_to_m(d.headSize[0])
		var hl := U.ft_to_m(d.headSize[1])
		var hd := U.ft_to_m(d.headSize[2])
		var pivot_y := U.ft_to_m(d.pivotHeight)
		_rest = deg_to_rad(d.restAngle)
		_strike = deg_to_rad(d.strikeAngle)
		_trigger_r = U.ft_to_m(d.triggerRadius)
		var arm_w := U.ft_to_m(J.g(d, "armWidth", 0.42))
		var arm_t := U.ft_to_m(J.g(d, "armThickness", 0.5))
		_yaw_b = Phys.yaw_basis(yaw)
		var fwd := _yaw_b * Vector3(0, 0, 1)
		_pivot = Vector3(pos_m.x - fwd.x * arm_length, pivot_y, pos_m.z - fwd.z * arm_length)
		# The head is offset toward local -Z so that, with the arm flat, its
		# face sits under the arm and meets the deck.
		_head_local = Vector3(0, -arm_length, -hd * 0.35)
		body = Phys.kinematic(parent, Transform3D(_yaw_b * Basis(Vector3.RIGHT, _rest), _pivot), 0.55, 0.12)
		Phys.add_shape(body, Phys.box(Vector3(arm_w, arm_length, arm_t)), Transform3D(Basis.IDENTITY, Vector3(0, -arm_length / 2.0, 0)))
		Phys.add_shape(body, Phys.box(Vector3(hw, hl, hd)), Transform3D(Basis.IDENTITY, _head_local))
		teeth.append(body)
		angle = _rest
		# The pedestal is solid: a bot driven into the corner hits steel. Not
		# teeth, so touching it is not a hazard hit.
		var bs: Array = d.get("baseSize", [2.2, d.pivotHeight - 0.25, 1.6])
		var base_size := Vector3(U.ft_to_m(bs[0]), U.ft_to_m(bs[1]), U.ft_to_m(bs[2]))
		var base_xf := Transform3D(_yaw_b, Vector3(_pivot.x, base_size.y / 2.0, _pivot.z))
		Phys.static_box(parent, base_xf, base_size, 0.5, 0.05)
		# The trigger watches where the head LANDS (`pos`), not the pivot or
		# the cocked head.
		_trigger = Vector3(pos_m.x, 0, pos_m.z)
		pieces = [
			{"kind": "swingerArm", "hazardId": id, "length": arm_length, "thickness": [arm_w, arm_t]},
			{"kind": "swingerHead", "hazardId": id, "size": Vector3(hw, hl, hd), "local": _head_local, "armLength": arm_length, "headMassKg": U.lb_to_kg(d.headMass)},
			{"kind": "swingerPivot", "hazardId": id, "pos": _pivot, "basis": _yaw_b},
			{"kind": "swingerBase", "hazardId": id, "size": base_size, "xf": base_xf},
		]

	func _set_angle(a: float) -> void:
		angle = a
		body.transform = Transform3D(_yaw_b * Basis(Vector3.RIGHT, a), _pivot)

	## World centre of the head right now - for tests and the camera.
	func head_center() -> Vector3:
		return body.transform * _head_local

	# Deliberately NOT just "swinging". The swing completes and the state
	# flips to retracting inside the same update that puts the head at its
	# lowest point - which is a step BEFORE the contact it causes is reported.
	# The head is still travelling fast early in the retract, so that counts.
	func live() -> bool:
		return state == Hazards.SWINGING or (state == Hazards.RETRACTING and _t < minf(0.2, def.retractTimeS * 0.35))

	func update(dt: float, bots: Array, _ctx: Dictionary) -> void:
		_t += dt
		match state:
			Hazards.ARMED:
				for p in bots:
					var dx: float = p.x - _trigger.x
					var dz: float = p.z - _trigger.z
					if dx * dx + dz * dz < _trigger_r * _trigger_r:
						state = Hazards.SWINGING
						_t = 0.0
						if _bus != null: _bus.emit(Bus.HAZARD_FIRE, {"id": id, "type": type})
						break
			Hazards.SWINGING:
				# Ease-in: a falling hammer accelerates, so t^2 beats linear.
				var u := minf(1.0, _t / def.swingTimeS)
				_set_angle(_rest + (_strike - _rest) * (u * u))
				if u >= 1.0:
					state = Hazards.RETRACTING
					_t = 0.0
			Hazards.RETRACTING:
				var u := minf(1.0, _t / def.retractTimeS)
				var e := 2.0 * u * u if u < 0.5 else 1.0 - 2.0 * (1.0 - u) * (1.0 - u)
				_set_angle(_strike + (_rest - _strike) * e)
				if u >= 1.0:
					state = Hazards.COOLDOWN
					_t = 0.0
			Hazards.COOLDOWN:
				if _t >= def.cooldownS:
					state = Hazards.ARMED
					_t = 0.0

	func add_transforms(out: Array) -> void:
		out.append({"hazardId": id, "part": "arm", "xf": body.transform})

# ---------------------------------------------------------------- killsaw
# Saw blades living in a slot under the deck. They sit below the floor for
# most of the match. In the last minute ("rotating", the default) a random
# handful come up, and every few seconds a fresh handful replaces them - so
# the safe ground keeps moving and the closing stretch is a different fight.
class Killsaw:
	extends Hazard
	var _pos: Vector3
	var _yaw_b: Basis
	var _stowed_y := 0.0
	var _deployed_y := 0.0
	var _rise_s := 0.45
	var _omega := 0.0
	var _trigger_r := 0.0
	var _deploy_at := 60.0
	var _mode := "rotating"
	var _spin := 0.0
	var _bus: Bus

	func _init(parent: Node3D, d: Dictionary, pos_m: Vector3, yaw: float, shared: Dictionary, bus: Bus) -> void:
		var cfg := J.merge(shared, d)
		id = d.id
		type = "killsaw"
		def = cfg
		_bus = bus
		_pos = pos_m
		_yaw_b = Phys.yaw_basis(yaw)
		var blade_r := U.ft_to_m(J.g(cfg, "bladeRadius", 1.1))
		var blade_t := U.ft_to_m(J.g(cfg, "bladeThickness", 0.08))
		var count := int(J.g(cfg, "bladeCount", 2))
		var spacing := U.ft_to_m(J.g(cfg, "bladeSpacing", 1.1))
		_stowed_y = -U.ft_to_m(J.g(cfg, "stowedDepth", 1.3))
		_deployed_y = U.ft_to_m(J.g(cfg, "deployedHeight", 0.55)) - blade_r     # hub below the deck
		_rise_s = J.g(cfg, "riseS", 0.45)
		_omega = U.rpm_to_radps(J.g(cfg, "rpm", 1400))
		_trigger_r = U.ft_to_m(J.g(cfg, "triggerRadius", 4.0))
		_deploy_at = J.g(cfg, "deployAtRemainingS", 60)
		_mode = J.g(cfg, "deploy", "rotating")
		state = Hazards.STOWED
		body = Phys.kinematic(parent, Transform3D(_yaw_b, Vector3(pos_m.x, _stowed_y, pos_m.z)), 0.3, 0.17)
		# Blades are thin discs side by side on one axle running ACROSS the
		# slot (local X), each standing in the plane of the slot and coming up
		# through its own slit in the cover.
		for i in count:
			var offset := (i - (count - 1) / 2.0) * spacing
			Phys.add_shape(body, Phys.cylinder(blade_r, blade_t), Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3(offset, 0, 0)))
		teeth.append(body)
		pieces = [{
			"kind": "killsaw", "hazardId": id, "bladeRadius": blade_r, "bladeThickness": blade_t, "bladeCount": count, "bladeSpacing": spacing,
			"slotLength": U.ft_to_m(J.g(cfg, "slotLength", 3.0)),
			# How far the blade tops stand above the deck when fully up - the
			# drawn cover's slit has to be long enough for that chord.
			"deployedHeight": U.ft_to_m(J.g(cfg, "deployedHeight", 0.55)),
			"pos": Vector3(pos_m.x, 0, pos_m.z), "yaw": yaw,
		}]

	func deployed() -> bool: return travel > 0.5
	# Only dangerous once the blades are actually clear of the deck.
	func live() -> bool: return travel > 0.35

	func update(dt: float, bots: Array, ctx: Dictionary) -> void:
		# The clock decides whether these are live at all.
		var remaining = ctx.get("remainingS")
		var clocked := _mode == "timed" or _mode == "rotating"
		var armed_by_clock: bool = (remaining != null and remaining <= _deploy_at) if clocked else true
		var want := 0.0
		if not armed_by_clock:
			want = 0.0
		elif _mode == "rotating":
			# The draw is made once for all saws - see SawRotation.
			want = 1.0 if ctx.killsawActive.has(id) else 0.0
		elif _mode == "timed":
			want = 1.0                      # up for the rest of the match
		else:
			for b in bots:
				var dx: float = b.x - _pos.x
				var dz: float = b.z - _pos.z
				if dx * dx + dz * dz < _trigger_r * _trigger_r: want = 1.0
		var before := travel
		var rate := dt / maxf(0.01, _rise_s)
		# Must hold still when already where it wants to be.
		if want > travel: travel = minf(1.0, travel + rate)
		elif want < travel: travel = maxf(0.0, travel - rate)
		if travel >= 1.0: state = Hazards.SPINNING
		elif travel <= 0.0: state = Hazards.STOWED
		else: state = Hazards.RISING if want > before else Hazards.LOWERING
		# Only spinning once they are actually out of the floor.
		if travel > 0.05: _spin += _omega * dt
		var y := _stowed_y + (_deployed_y - _stowed_y) * travel
		lin_vel = Vector3(0, (y - body.position.y) / maxf(dt, 1e-6), 0)
		# Turn on the axle (local X), which runs through every blade's centre.
		body.transform = Transform3D(_yaw_b * Basis(Vector3.RIGHT, _spin), Vector3(_pos.x, y, _pos.z))
		if before <= 0.05 and travel > 0.05 and _bus != null:
			_bus.emit(Bus.HAZARD_FIRE, {"id": id, "type": "killsaw"})

	func add_transforms(out: Array) -> void:
		out.append({"hazardId": id, "part": "blades", "xf": body.transform})

# ---------------------------------------------------------------- pit
# A square of deck that sinks out of the floor late in the match and stays
# down: the Robot Wars pit. arena_world.gd has already cut the hole, lined it
# with steel and put a floor in it; this is the panel, a slab flush with the
# deck until `openAtRemainingS`, then lowered over `lowerS` to the bottom. A
# robot on it goes down with it. It does no damage itself - the referee rules
# a robot below the deck out.
class PitTrap:
	extends Hazard
	var rect: Dictionary
	var _lid_t := 0.1
	var _open_at := 90.0
	var _lower_s := 2.5
	var _warn_s := 4.0
	var _fired := false
	var _bus: Bus

	func _init(parent: Node3D, d: Dictionary, arena: Dictionary, bus: Bus) -> void:
		id = d.id
		type = "pit"
		def = d
		_bus = bus
		rect = ArenaWorld.pit_rects({"hazards": [d]})[0]
		_open_at = J.g(d, "openAtRemainingS", 90)
		_lower_s = maxf(0.1, J.g(d, "lowerS", 2.5))
		_warn_s = J.g(d, "warnS", 4)
		state = "closed"
		body = Phys.kinematic(parent, Transform3D(Basis.IDENTITY, Vector3(rect.cx, -_lid_t / 2.0, rect.cz)), J.path(arena, ["floor", "friction"], 1.0), 0.0, false, Phys.ARENA)
		Phys.add_shape(body, Phys.box(Vector3((rect.hw - 0.005) * 2.0, _lid_t, (rect.hl - 0.005) * 2.0)))
		pieces = [{"kind": "pit", "hazardId": id, "pos": Vector3(rect.cx, 0, rect.cz), "hw": rect.hw, "hl": rect.hl, "depth": rect.depth, "lidT": _lid_t}]

	func is_open() -> bool: return travel > 0.3

	func update(dt: float, _bots: Array, ctx: Dictionary) -> void:
		var remaining = ctx.get("remainingS")
		var due: bool = remaining != null and remaining <= _open_at
		warning = 1.0 - (remaining - _open_at) / _warn_s if (not due and remaining != null and remaining <= _open_at + _warn_s) else 0.0
		if due and travel < 1.0:
			travel = minf(1.0, travel + dt / _lower_s)
			if not _fired:
				_fired = true
				if _bus != null: _bus.emit(Bus.HAZARD_FIRE, {"id": id, "type": "pit"})
		elif not due and travel > 0.0:
			# A rematch winds the clock back: the panel comes back up.
			travel = 0.0
			_fired = false
		state = "open" if travel >= 1.0 else ("lowering" if travel > 0.0 else ("warning" if warning > 0.0 else "closed"))
		body.position = Vector3(rect.cx, -_lid_t / 2.0 - travel * (rect.depth - _lid_t / 2.0 - 0.02), rect.cz)

	func add_transforms(out: Array) -> void:
		out.append({"hazardId": id, "part": "lid", "xf": body.transform})

# ---------------------------------------------------------------- killsaw rotation
# Which saws are up, as a pure function of the match clock. From
# `deployAtRemainingS` the last minute is cut into `rotateEveryS` windows;
# each window gets `activeCount` saws drawn from a stream seeded by the match
# seed, and no window repeats the exact set before it.
#
# Deriving it from the clock rather than keeping a timer means pausing,
# scrubbing a replay or restarting the match can never desync it.
class SawRotation:
	extends RefCounted
	var _ids := []
	var _on := false
	var _every := 5.0
	var _k := 3
	var _deploy_at := 60.0
	var _rng: Rng
	var _windows := []
	var _empty := {}

	func _init(arena: Dictionary, match_seed) -> void:
		var cfg: Dictionary = arena.get("killsaw", {})
		for h in arena.get("hazards", []):
			if h.get("type") == "killsaw" and h.get("enabled") != false: _ids.append(h.id)
		_on = J.g(cfg, "deploy", "rotating") == "rotating" and not _ids.is_empty()
		_every = maxf(0.5, J.g(cfg, "rotateEveryS", 5))
		_k = maxi(1, mini(_ids.size(), int(J.g(cfg, "activeCount", 3))))
		_deploy_at = J.g(cfg, "deployAtRemainingS", 60)
		_rng = Rng.new(Rng.hash_seed("%s:killsaws:%s" % [arena.get("id"), J.s(match_seed)]))

	static func _key(set: Dictionary) -> String:
		var k := set.keys()
		k.sort()
		return ",".join(k)

	func _window(i: int) -> Dictionary:
		while _windows.size() <= i:
			var prev = _windows[_windows.size() - 1] if not _windows.is_empty() else null
			var next := {}
			# With k == ids.size() there is only one possible set; do not spin.
			for tries in 8:
				next = {}
				for sid in _rng.shuffle(_ids).slice(0, _k): next[sid] = true
				if prev == null or _k == _ids.size() or _key(next) != _key(prev): break
			_windows.append(next)
		return _windows[i]

	func active_at(remaining_s) -> Dictionary:
		if not _on or remaining_s == null or remaining_s > _deploy_at: return _empty
		return _window(int(floor((_deploy_at - maxf(0.0, remaining_s)) / _every)))
