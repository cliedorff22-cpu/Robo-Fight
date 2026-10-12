## referee.gd - watches the physics and tells the match what happened.
##
## The match (logic/match.gd) and the judges (logic/judging.gd) are pure logic
## and never see the physics engine. Each step this works out, for each robot:
##
##   - can it drive?        upright, wheels on the floor, drive alive
##   - is it trying / moving under its own power?
##   - is it advancing on the opponent, or pushing it around?
##   - is one robot pinning the other?
##
## and routes every hit to the scorebook - crediting hazard damage to whoever
## drove the victim into the hazard.
class_name Referee
extends RefCounted

# Fallback only. Robots touch when the engine says their colliders touch; this
# body-box gap misses wedge noses and armour, which stick out past the
# chassis dims.
const CONTACT_GAP_M := 0.05

var facts = null               # the last step's facts, for the HUD and tests

var _match: Match
var _bus: Bus
var _sides := []               # [{ id, units: [{ id, sim, weapon }] }]
var _A: Dictionary
var _B: Dictionary
var _side_of_unit := {}
var _arena = null              # { halfX, halfZ }
var _t := 0.0
var _last_contact_t := -INF
var _locked_s := 0.0
var _lock_s := 6.0
var _off_hit: Callable

## `sides`: exactly two - { id, sim, weapon } for a single robot, or
## { id, units: [{ id, sim, weapon }] } for a multibot. Hits arrive with UNIT
## ids and are scored to the side. `arena_dims`: { halfX, halfZ }.
func _init(match_state: Match, event_bus: Bus, sides: Array, arena_dims = null) -> void:
	_match = match_state
	_bus = event_bus
	_arena = arena_dims
	for s in sides:
		var units: Array = s.units if s.get("units") != null else [{"id": s.id, "sim": s.sim, "weapon": s.get("weapon")}]
		var side := {"id": s.id, "units": units}
		_sides.append(side)
		for u in units: _side_of_unit[u.id] = side
	_A = _sides[0]
	_B = _sides[1]
	# Two robots locked together - weapons hooked, one wedged on the other -
	# both trying to get away and neither moving. On the show the referee
	# stops the fight and pulls them apart; so does this one.
	_lock_s = J.g(_match.config, "separateAfterS", 6.0)
	_off_hit = _bus.on(Bus.HIT, _on_hit)

func _other(id) -> Dictionary:
	return _B if id == _A.id else _A

func _on_hit(e: Dictionary) -> void:
	if _match.phase != Match.LIVE: return       # test drives before the bell do not score
	var hp := 0.0
	for h in e.get("hits", []): hp += J.g(h, "hpLost", 0.0)
	var failures: int = e.get("failures", []).size()
	var attacker = e.get("attackerId")
	if _side_of_unit.has(attacker): attacker = _side_of_unit[attacker].id
	var defender = e.get("defenderId")
	if _side_of_unit.has(defender): defender = _side_of_unit[defender].id
	var credit_to = null
	# Driven into a hazard: the damage is the pusher's, if they were just in
	# contact.
	if e.kind == "hazard" and _t - _last_contact_t <= _match.scorebook.cfg.hazardCreditS:
		credit_to = _other(defender).id
	_match.scorebook.record_hit({"kind": e.kind, "attackerId": attacker, "defenderId": defender, "hp": hp, "failures": failures, "creditTo": credit_to})

# The yaw the referee reads off a body (the rotation about the vertical).
static func _yaw_of(sim: RobotSim) -> float:
	var q := sim.global_transform.basis.get_rotation_quaternion()
	return atan2(2.0 * (q.w * q.y + q.x * q.z), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))

# How far a robot's body reaches along a world direction, from its centre.
static func _extent_along(unit: Dictionary, dir: Vector2) -> float:
	var d: Dictionary = unit.sim.assembled.dims
	var yaw := _yaw_of(unit.sim)
	var c := absf(cos(yaw) * dir.x - sin(yaw) * dir.y)       # forward is local +X
	var s := sqrt(maxf(0.0, 1.0 - c * c))
	return c * d.lengthM / 2.0 + s * d.widthM / 2.0

# Do any of unit a's colliders have live contact with unit b's body?
static func _touching(a: Dictionary, b: Dictionary) -> bool:
	for c in (a.sim as RobotSim).contacts():
		if is_same(c.other, b.sim): return true
	return false

func _mobility(unit: Dictionary, drive) -> Dictionary:
	var sim: RobotSim = unit.sim
	var v := sim.linear_velocity
	var w := sim.angular_velocity
	var eff := sim.effective()
	var wheels_down := 0
	for x in sim.telemetry:
		if x.grounded: wheels_down += 1
	var upright := sim.uprightness()
	# An invertible robot running on its back is driving, not flipped.
	var on_its_wheels := upright > 0.45 or sim.inverted
	# Below the deck can only mean down a pit (the floor is y = 0 everywhere
	# else): out on the spot, as on Robot Wars.
	var pitted := sim.global_position.y < -0.25
	var immobile: bool = J.truthy(eff.get("immobile"))
	var no_wheels: bool = eff.get("wheelCount", 0) <= 0
	var throttle: float = drive.get("throttle", 0.0) if drive is Dictionary else 0.0
	var steer: float = drive.get("steer", 0.0) if drive is Dictionary else 0.0
	var speed := Vector2(v.x, v.z).length()
	var cause := "stuck"
	if pitted: cause = "pitted"
	elif immobile or no_wheels: cause = "disabled"
	elif not on_its_wheels: cause = "flipped"
	elif wheels_down < 2: cause = "beached"
	return {
		"able": not pitted and not immobile and not no_wheels and on_its_wheels and wheels_down >= 2,
		"out": pitted,
		# Why not, for the referee's call and the results screen.
		"cause": cause,
		"trying": absf(throttle) > 0.25 or absf(steer) > 0.35,
		"moving": speed > 0.2 or absf(w.y) > 0.6,
		"vel": Vector2(v.x, v.z),
		"speed": speed,
		"throttle": throttle,
		"yaw": _yaw_of(sim),
	}

# A side's mobility. One robot: its own. A multibot is out when more than half
# its weight cannot drive (the show's rule); it is trying and moving if any
# working unit is. The `lead` unit - the one doing the fighting - is the
# working unit nearest the other side.
func _side_mobility(side: Dictionary, per: Dictionary, lead: Dictionary) -> Dictionary:
	if side.units.size() == 1: return per[side.units[0].id]
	var total := 0.0
	var down_w := 0.0
	var pitted_w := 0.0
	var heaviest_down = null
	var trying := false
	var moving := false
	for u in side.units:
		var wt: float = u.sim.assembled.weightLb
		var m: Dictionary = per[u.id]
		total += wt
		if not m.able:
			down_w += wt
			if m.out: pitted_w += wt
			if heaviest_down == null or wt > heaviest_down.sim.assembled.weightLb: heaviest_down = u
		else:
			trying = trying or m.trying
			moving = moving or m.moving
	var out: Dictionary = per[lead.id].duplicate()
	out.able = down_w / total <= 0.5
	# A multibot is out on the spot only if more than half of it is down the pit.
	out.out = pitted_w / total > 0.5
	out.cause = per[heaviest_down.id].cause if heaviest_down != null else "stuck"
	out.trying = trying
	out.moving = moving
	return out

# The closest pair of opposing units, preferring ones that still work.
func _closest_pair(per: Dictionary) -> Dictionary:
	var best := {}
	var best_d := INF
	for a in _pool(_A, per):
		for b in _pool(_B, per):
			var pa: Vector3 = a.sim.global_position
			var pb: Vector3 = b.sim.global_position
			var d := Vector2(pb.x - pa.x, pb.z - pa.z).length()
			if d < best_d:
				best_d = d
				best = {"a": a, "b": b, "d": d, "pa": pa, "pb": pb}
	return best

static func _pool(side: Dictionary, per: Dictionary) -> Array:
	var w := []
	for u in side.units:
		if per[u.id].able: w.append(u)
	return w if not w.is_empty() else side.units

# Pull two locked robots apart along the line between them, and stop them.
static func _separate(ua: Dictionary, ub: Dictionary, ab: Vector2) -> void:
	var push := 0.35
	for pair in [[ua, -1.0], [ub, 1.0]]:
		var b: RobotSim = pair[0].sim
		var k: float = pair[1]
		var xf := b.global_transform
		xf.origin += Vector3(ab.x * push * k, 0.05, ab.y * push * k)
		b.global_transform = xf
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO

static func _facing(m: Dictionary, dir: Vector2) -> float:
	return cos(m.yaw) * dir.x - sin(m.yaw) * dir.y

static func _driving_at(m: Dictionary, dir: Vector2) -> bool:
	return m.throttle * _facing(m, dir) > 0.3

func _against_wall(unit: Dictionary, pos: Vector3, dir: Vector2) -> bool:
	if _arena == null: return false
	var reach := _extent_along(unit, dir) + 0.45
	return (dir.x > 0.5 and _arena.halfX - pos.x < reach) or (dir.x < -0.5 and pos.x + _arena.halfX < reach) or \
		(dir.y > 0.5 and _arena.halfZ - pos.z < reach) or (dir.y < -0.5 and pos.z + _arena.halfZ < reach)

# Pinning: holding the other robot in place while it tries to get away -
# shoved against a wall, or held while it tries to drive somewhere else. Two
# robots shoving nose to nose in the open is a fight, not a pin.
func _pinning(contact: bool, me: Dictionary, them: Dictionary, dir: Vector2, them_unit: Dictionary, them_pos: Vector3) -> bool:
	return contact and me.able and _driving_at(me, dir) and them.speed < 0.3 and them.trying and \
		(_against_wall(them_unit, them_pos, dir) or not _driving_at(them, -dir))

func _by_wall(p: Vector3) -> bool:
	return _arena != null and (absf(p.x) > _arena.halfX - 0.9 or absf(p.z) > _arena.halfZ - 0.9)

## Call once per physics step, after the engine has stepped and combat has
## resolved. `drives`: { [botId]: drive input } - what each driver asked for.
func step(dt: float, drives: Dictionary) -> void:
	_t += dt
	var per := {}
	for s in _sides:
		for u in s.units: per[u.id] = _mobility(u, drives.get(u.id))
	var cp := _closest_pair(per)
	var ua: Dictionary = cp.a
	var ub: Dictionary = cp.b
	var pa: Vector3 = cp.pa
	var pb: Vector3 = cp.pb
	var dx := pb.x - pa.x
	var dz := pb.z - pa.z
	var dist := Vector2(dx, dz).length()
	if dist == 0.0: dist = 1e-6
	var ab := Vector2(dx / dist, dz / dist)
	var gap := dist - _extent_along(ua, ab) - _extent_along(ub, ab)
	var contact := gap < CONTACT_GAP_M or _touching(ua, ub)
	if contact: _last_contact_t = _t

	var mA := _side_mobility(_A, per, ua)
	var mB := _side_mobility(_B, per, ub)

	# Closing speed of each robot toward the other, and how fast each is being
	# carried along the line between them.
	var toward_a: float = mA.vel.x * ab.x + mA.vel.y * ab.y            # A toward B
	var toward_b: float = -(mB.vel.x * ab.x + mB.vel.y * ab.y)         # B toward A
	var ba := -ab
	var f := {}
	f[_A.id] = {
		"advancing": mA.trying and gap < 4.0 and toward_a > 0.35,
		"pushing": contact and _driving_at(mA, ab) and toward_a > 0.15 and -toward_b > 0.05,
		"disabled": not mA.able,
	}
	f[_B.id] = {
		"advancing": mB.trying and gap < 4.0 and toward_b > 0.35,
		"pushing": contact and _driving_at(mB, ba) and toward_b > 0.15 and -toward_a > 0.05,
		"disabled": not mB.able,
	}

	var pinner = null
	var pinned = null
	if _pinning(contact, mA, mB, ab, ub, pb):
		pinner = _A.id; pinned = _B.id
	elif _pinning(contact, mB, mA, ba, ua, pa):
		pinner = _B.id; pinned = _A.id
	_match.report_pin(pinner, pinned, dt)

	# A pin is one robot holding the other against a WALL (the pin rule covers
	# it). Two robots both driving and getting nowhere in open floor are
	# locked - the pin read flickers between them, so ignore it there. Against
	# a wall it IS a pin - until the pinner has had its warning and its
	# release window and still cannot (or will not) let go.
	var wall_pin: bool = pinner != null and (_by_wall(pa) or _by_wall(pb))
	var stuck_together: bool = contact and _match.phase == Match.LIVE and mA.trying and mB.trying and mA.speed < 0.08 and mB.speed < 0.08 and mA.able and mB.able
	_locked_s = _locked_s + dt if stuck_together else 0.0
	var cfg: Dictionary = _match.config
	var limit: float = J.g(cfg, "pinLimitS", 10.0) + J.g(cfg, "pinReleaseS", 3.0) + _lock_s if wall_pin else _lock_s
	if _locked_s >= limit:
		_locked_s = 0.0
		_separate(ua, ub, ab)
		_bus.emit(Bus.SEPARATE, {"a": _A.id, "b": _B.id})

	var ra := mA.duplicate()
	ra.pinned = pinned == _A.id
	ra.engaged = contact
	_match.report_mobility(_A.id, ra, dt)
	var rb := mB.duplicate()
	rb.pinned = pinned == _B.id
	rb.engaged = contact
	_match.report_mobility(_B.id, rb, dt)
	if _match.phase == Match.LIVE:
		_match.scorebook.record_step(_A.id, f[_A.id], dt)
		_match.scorebook.record_step(_B.id, f[_B.id], dt)
	facts = {"gap": gap, "contact": contact, "pinner": pinner, "pinned": pinned, "mobility": {_A.id: mA, _B.id: mB}}
	facts.merge(f)

func reset() -> void:
	_t = 0.0
	_last_contact_t = -INF
	facts = null
	_locked_s = 0.0

func dispose() -> void:
	if _off_hit.is_valid(): _off_hit.call()

func side(id):
	for s in _sides:
		if s.id == id: return s
	return null
