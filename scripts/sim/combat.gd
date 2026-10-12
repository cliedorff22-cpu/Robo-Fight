## combat.gd - turning physics contacts into damage.
##
## The bridge between the simulation and the pure damage model. It owns no
## damage rules of its own: it works out WHO hit WHAT, HOW SQUARELY and WITH
## HOW MUCH ENERGY, then hands that to logic/damage.gd and applies whatever
## impulse comes back.
##
## Routing is geometric throughout: every collider of a robot knows the
## fitting it stands for, so a hit is attributed to the exact panel that was
## struck rather than guessed at from a bounding box.
class_name Combat
extends RefCounted

# Two bodies in contact report it constantly. One exchange per pair per this
# interval keeps a scrape from being resolved as forty separate hits.
const PAIR_COOLDOWN_S := 0.22
# A pair of colliders that was touching within this many steps is still the
# same touch, not a new one (contact reports can blink for a step).
const SAME_TOUCH_STEPS := 3

var rules: Dictionary
var rng: Rng
var bus: Bus
## How each weapon class acts on what it hits, beyond hp: the throw, the
## flip, the lift, the grip. All data (rules.json `weapons`).
var W: Dictionary
var hazards: Hazards = null
var log := []
# Counters, for working out WHERE a contact got dropped. Cheap, and the only
# practical way to debug "the hazard clearly hit it but nothing happened".
var stats := {"rawStarted": 0, "unindexed": 0, "botVsBot": 0, "hazardVsBot": 0, "notLive": 0, "noEnergy": 0, "cooldown": 0, "resolved": 0}

var _bots := {}                # botId -> { id, sim, assembled, weapon, team, hull, radius, zone }
var _order := []
var _cooldowns := {}           # "a|b" -> clock time it ends
var _seen := {}                # collider pair -> step last touching
var _clock := 0.0
var _tick := 0

func _init(rulebook: Dictionary, random: Rng, event_bus: Bus = null) -> void:
	rules = rulebook
	rng = random
	bus = event_bus
	W = rules.get("weapons", {})

## `team`: robots on the same team (a multibot's units) can bump into each
## other but never damage each other. Default: its own.
func register_bot(bot_id: String, sim: RobotSim, weapon: Weapon, team = null) -> void:
	var hull := []
	var radius := 0.0
	for piece in sim.shape.get("pieces", []):
		var key = sim.routes.get(piece.id)
		if key == null: key = "chassis"
		for q in piece.points:
			hull.append([q, key])
			radius = maxf(radius, (q as Vector3).length())
	sim.bot_id = bot_id
	_bots[bot_id] = {"id": bot_id, "sim": sim, "assembled": sim.assembled, "weapon": weapon, "team": team if team != null else bot_id,
		"hull": hull, "radius": radius, "zone": _strike_zone(sim)}
	_order.append(bot_id)

func register_hazards(hazard_set: Hazards) -> void:
	hazards = hazard_set

# ---- strike zones. A hammer, flipper, lifter or crusher acts on whatever is
# in front of it when it fires - its parked collider is somewhere else
# entirely (a hammer head waits up over the nose, above most robots). So
# while one is swinging or closed, each step looks for the opponent's hull in
# the volume the weapon sweeps, in the attacker's own frame.
func _strike_zone(sim: RobotSim):
	var w = sim.shape.get("weapon")
	if not (w is Dictionary): return null
	var v = w.get("visual")
	if not (v is Dictionary): return null
	var m: float = J.g(W, "zoneMarginM", 0.06)
	if w["class"] == "hammer" and v.kind == "arm":
		var hx: float = v.pivot.x + v.reach
		return {"kind": "hammer", "x0": v.pivot.x + v.reach * 0.3, "x1": hx + maxf(0.04, v.head.l / 2.0) + m,
			"z": maxf(0.06, v.head.w / 2.0) + m, "y1": v.pivot.y + 0.05}
	if v.kind == "plate" or v.kind == "jaw":
		return {"kind": w["class"], "x0": v.center.x - v.size.l * 0.5 - 0.03, "x1": v.center.x + v.size.l * 0.5 + m * 2.0,
			"z": v.size.w / 2.0 + m, "y1": v.center.y + v.size.h / 2.0 + 0.12}
	return null

# The point of Y the weapon of X finds in its zone, or null.
func _in_zone(X: Dictionary, Y: Dictionary):
	var z: Dictionary = X.zone
	var xs: RobotSim = X.sim
	var ys: RobotSim = Y.sim
	var px := xs.global_position
	var py := ys.global_position
	if Vector2(px.x - py.x, px.z - py.z).length() > maxf(absf(z.x0), absf(z.x1)) + z.z + Y.radius: return null
	var to_local := xs.global_transform.affine_inverse() * ys.global_transform
	var hammer: bool = z.kind == "hammer"
	var x0: float = z.x0
	var x1: float = z.x1
	var zz: float = z.z
	var y1: float = z.y1
	var best = null
	var best_score := -INF
	for h in Y.hull:
		var l: Vector3 = to_local * (h[0] as Vector3)
		if l.x < x0 or l.x > x1 or absf(l.z) > zz or l.y > y1 or l.y < -0.6: continue
		# A hammer finds the highest point under it; the rest the nearest.
		var score := l.y if hammer else -l.x
		if best == null or score > best_score:
			best_score = score
			best = {"key": h[1], "at": ys.global_transform * (h[0] as Vector3), "local": l}
	return best

# Output left in a damaged weapon, 0..1.
func _output_of(X: Dictionary) -> float:
	var rated: float = J.g(X.assembled.stats.weapon, "energyJ", 0.0)
	var ew: Dictionary = X.sim.effective().weapon
	if J.truthy(ew.get("dead")): return 0.0
	return minf(1.0, ew.energyJ / rated) if rated > 0.0 else 1.0

# Land one strike from a zone: damage, then the class's own effect.
func _zone_strike(X: Dictionary, Y: Dictionary, hit: Dictionary, squareness: float) -> bool:
	var stored: float = X.weapon.strike(X.sim.effective())
	if not (stored > 0.0): return false
	var r := Damage.resolve_hit({"attacker": X.assembled, "defender": Y.assembled, "targetKey": hit.key,
		"storedEnergyJ": stored, "squareness": squareness, "rules": rules, "rng": rng})
	Y.sim.invalidate()
	X.sim.invalidate()
	var fwd: Vector3 = X.sim.global_transform.basis.x
	var spec: Dictionary = X.assembled.parts.weapon.spec
	if X.zone.kind == "flipper":
		# The launch: the rated impulse through the point the plate caught,
		# so an off-centre catch turns the robot over as it goes up.
		var j: float = J.g(spec, "impulseNs", 0.0) * J.g(W, "flipperLaunch", 1.0) * _output_of(X) * (0.6 + 0.4 * squareness)
		var ff: float = J.g(W, "flipperForward", 0.35)
		var dir := Vector3(fwd.x * ff, 1.0, fwd.z * ff).normalized()
		_impulse_at(Y.sim, dir * j, hit.at)
	elif X.zone.kind != "lifter":
		_push_away(Y.sim, X.sim.global_position, r.impulseNs)
	_emit(r, {"kind": "weapon", "attackerId": X.id, "defenderId": Y.id, "targetKey": hit.key, "at": hit.at, "normal": Vector3.UP})
	return true

func _zones(dt: float) -> void:
	for xid in _order:
		var X: Dictionary = _bots[xid]
		if X.zone == null or X.weapon == null: continue
		var weapon: Weapon = X.weapon
		var phase := weapon.phase
		if phase != Weapon.STRIKING and phase != Weapon.CLOSED: continue
		for yid in _order:
			var Y: Dictionary = _bots[yid]
			if Y.team == X.team: continue
			var hit = _in_zone(X, Y)
			if hit == null: continue
			var kind: String = X.zone.kind
			var spec: Dictionary = X.assembled.parts.weapon.spec
			if kind == "lifter" and phase == Weapon.STRIKING:
				# A lifter does not throw: it raises the near edge over the
				# stroke, tipping the robot or taking its wheels off the floor.
				var f: float = J.g(spec, "liftForceN", 0.0) * J.g(W, "lifterLift", 1.0) * _output_of(X)
				var fwd: Vector3 = X.sim.global_transform.basis.x
				var dir := Vector3(fwd.x * 0.25, 1.0, fwd.z * 0.25).normalized()
				_impulse_at(Y.sim, dir * (f * dt), hit.at)
			if kind == "crusher" and phase == Weapon.CLOSED: _grip(X, Y, hit, dt)
			# Discrete weapons land once per swing; a closed jaw bites at its rate.
			if (phase == Weapon.STRIKING and weapon.unspent) or phase == Weapon.CLOSED:
				var sq: float = J.g(W, "hammerSquareness", 0.85) * (0.9 + rng.next() * 0.2) if kind == "hammer" else 0.7
				_zone_strike(X, Y, hit, minf(1.0, sq))

# A closed jaw holds what it bit: the victim is carried with the crusher (its
# velocity pulled toward the jaw's) and its near end lifted, so its wheels
# lose the floor and it cannot drive out.
func _grip(X: Dictionary, Y: Dictionary, hit: Dictionary, dt: float) -> void:
	var bx: RobotSim = X.sim
	var by: RobotSim = Y.sim
	var at: Vector3 = hit.at
	var v_jaw := bx.linear_velocity + bx.angular_velocity.cross(at - bx.global_position)
	var v_y := by.linear_velocity
	var k: float = J.g(W, "crusherHold", 0.25)
	var m_y: float = Y.assembled.massKg
	_impulse_at(by, Vector3((v_jaw.x - v_y.x) * m_y * k, 0, (v_jaw.z - v_y.z) * m_y * k), at)
	_impulse_at(by, Vector3(0, m_y * Phys.GRAVITY * J.g(W, "crusherLift", 0.35) * dt, 0), at)

static func _impulse_at(sim: RobotSim, impulse: Vector3, world_point: Vector3) -> void:
	sim.apply_impulse(impulse, world_point - sim.global_position)

# How square a hit was, 0..1: the contact normal against the closing
# velocity. A head-on collision scores 1, a graze along the surface near 0.
# This is the single biggest source of variance between two otherwise
# identical hits.
static func _squareness(v_a: Vector3, v_b: Vector3, normal: Vector3) -> float:
	var rel := v_a - v_b
	var speed := rel.length()
	if speed < 0.05: return 0.25          # barely moving: a lean, not a hit
	return minf(1.0, absf((rel / speed).dot(normal.normalized())))

static func _pair_key(a: String, b: String) -> String:
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]

func _on_cooldown(a: String, b: String) -> bool:
	return _cooldowns.get(_pair_key(a, b), 0.0) > _clock

func _set_cooldown(a: String, b: String) -> void:
	_cooldowns[_pair_key(a, b)] = _clock + PAIR_COOLDOWN_S

# A rotor's hit throws what it hits - through the point it struck, so the
# robot tumbles - and kicks the spinner back the other way. A vertical throws
# up; a horizontal sideways, and it takes the bigger kick itself. Off a
# wedge, the spinner is the one thrown, up and back.
func _throw_from(atk: Dictionary, def: Dictionary, cls: String, delivered_j: float, at, wedge: bool) -> void:
	var j: float = (delivered_j / 1000.0) * J.g(W, "kineticImpulsePerKJ", 0.0)
	if not (j > 0.0): return
	var pa: Vector3 = atk.sim.global_position
	var pd: Vector3 = def.sim.global_position
	var away := Vector3(pd.x - pa.x, 0, pd.z - pa.z).normalized()
	var lift: float = J.path(W, ["kineticLift", cls], 0.3)
	_impulse_at(def.sim, Vector3(away.x, lift, away.z).normalized() * j, at if at != null else pd)
	var recoil: float = J.path(W, ["recoil", cls], 0.4)
	var back := Vector3(-away.x, 0, -away.z) * (j * recoil)
	if wedge: back.y = j * J.path(W, ["wedgeDeflect", "liftAttacker"], 0.5) * (1.0 if cls == "spinner_h" else 0.4)
	atk.sim.apply_central_impulse(back)

# Push the defender away from the attacker after a hit lands.
static func _push_away(defender: RobotSim, attacker_pos: Vector3, impulse_ns: float) -> void:
	if not (impulse_ns > 0.0): return
	var away := (defender.global_position - attacker_pos).normalized()
	# A little upward component, because big hits pitch bots into the air.
	defender.apply_central_impulse(Vector3(away.x, away.y + 0.45, away.z).normalized() * impulse_ns)

func _emit(result: Dictionary, meta: Dictionary) -> Dictionary:
	stats.resolved += 1
	var hits := []
	for h in result.get("hits", []):
		hits.append({"key": h.key, "category": h.category, "hpLost": h.hpLost, "conditionAfter": h.conditionAfter,
			"failed": h.failed, "throughArmor": J.truthy(h.get("throughArmor"))})
	var failures := []
	for f in result.get("failures", []):
		failures.append({"key": f.key, "name": f.get("name"), "category": f.category})
	var entry := {"t": _clock}
	entry.merge(meta)
	entry.deliveredJ = result.deliveredJ
	entry.severity = result.severity
	entry.hits = hits
	entry.failures = failures
	log.append(entry)
	if bus != null:
		bus.emit(Bus.HIT, entry)
		for f in result.get("failures", []):
			var e := {"t": _clock, "botId": meta.defenderId, "at": meta.get("at"), "normal": meta.get("normal")}
			e.merge(f)
			bus.emit(Bus.PART_FAILED, e)
	return entry

# Weapon on weapon: who wins the exchange? More stored energy wins. Near a
# tie - two identical spinners both at full speed are EXACTLY equal - the one
# driving into the hit wins, then a seeded coin.
func _a_wins_clash(A: Dictionary, B: Dictionary) -> bool:
	var e_a: float = A.weapon.energyJ
	var e_b: float = B.weapon.energyJ
	if absf(e_a - e_b) > 0.03 * maxf(e_a, e_b): return e_a > e_b
	var pa: Vector3 = A.sim.global_position
	var pb: Vector3 = B.sim.global_position
	var ab := Vector3(pb.x - pa.x, 0, pb.z - pa.z).normalized()
	var into_a: float = (A.sim.linear_velocity as Vector3).dot(ab)
	var into_b: float = -(B.sim.linear_velocity as Vector3).dot(ab)
	if absf(into_a - into_b) > 0.3: return into_a > into_b
	return rng.next() < 0.5

# Resolve one bot-on-bot contact. `a_key`/`b_key` are the fittings touched,
# `a_slot`/`b_slot` the shape slots.
func _bot_vs_bot(A: Dictionary, a_key: String, a_slot, B: Dictionary, b_key: String, b_slot, normal: Vector3, at) -> void:
	if is_same(A, B) or A.team == B.team: return     # teammates: physics only
	if _on_cooldown(A.id, B.id): return
	var sa: RobotSim = A.sim
	var sb: RobotSim = B.sim
	var sq := _squareness(sa.linear_velocity, sb.linear_velocity, normal)

	# Whoever landed their WEAPON on the other is the attacker. If both did,
	# the one with more stored energy wins the exchange.
	var a_armed: bool = a_key == "weapon" and A.weapon != null and A.weapon.armed
	var b_armed: bool = b_key == "weapon" and B.weapon != null and B.weapon.armed
	var atk = null
	var def = null
	var target_key := ""
	var def_slot = null
	if a_armed and (not b_armed or _a_wins_clash(A, B)):
		atk = A; def = B; target_key = b_key; def_slot = b_slot
	elif b_armed:
		atk = B; def = A; target_key = a_key; def_slot = a_slot

	if atk != null:
		var weapon: Weapon = atk.weapon
		var stored := weapon.strike(atk.sim.effective())
		if stored > 0.0:
			var kinetic := weapon.family == Weapon.KINETIC
			var cls: String = atk.assembled.stats.weapon["class"]
			# A horizontal rotor striking a wedge glances up off it: wedges
			# are what horizontal spinners fear. How hard it glances depends
			# on the rotor: a vertical's tooth bites a wedge's lip, a
			# horizontal bar rides straight up it.
			var wd: Dictionary = W.get("wedgeDeflect", {})
			var transfer = J.path(wd, ["transfer", cls])
			var wedge: bool = kinetic and transfer != null and (def_slot == "wedge" or
				(def_slot == "weapon" and def.assembled.stats.weapon["class"] == "static"))
			var r := Damage.resolve_hit({"attacker": atk.assembled, "defender": def.assembled, "targetKey": target_key,
				"storedEnergyJ": stored * transfer if wedge else stored, "squareness": sq, "rules": rules, "rng": rng})
			# A landed hit costs a rotor most of its spin, not just what went
			# in: the respool is the price of a spinner (weapons.rotorSpend).
			if kinetic: weapon.absorb_recoil(maxf(r.deliveredJ, stored * J.path(W, ["rotorSpend", cls], 0.0)))
			else: weapon.absorb_recoil(r.deliveredJ)
			def.sim.invalidate()
			atk.sim.invalidate()
			if kinetic: _throw_from(atk, def, cls, r.deliveredJ, at, wedge)
			else: _push_away(def.sim, atk.sim.global_position, r.impulseNs)
			_set_cooldown(A.id, B.id)
			_emit(r, {"kind": "weapon", "attackerId": atk.id, "defenderId": def.id, "targetKey": target_key, "at": at, "normal": normal})
			return

	# No live weapon involved: it is a shove. Worth far less damage, but it is
	# what aggression and control points are made of.
	var speed := (sa.linear_velocity - sb.linear_velocity).length()
	var a_faster := sa.linear_velocity.length() >= sb.linear_velocity.length()
	var ram_atk: Dictionary = A if a_faster else B
	var ram_def: Dictionary = B if a_faster else A
	var ram_key := b_key if a_faster else a_key
	var r := Damage.resolve_ram({"attacker": ram_atk.assembled, "defender": ram_def.assembled, "targetKey": ram_key,
		"relativeSpeedMps": speed, "rules": rules, "rng": rng})
	if J.truthy(r.get("ignored")): return
	ram_def.sim.invalidate()
	_set_cooldown(A.id, B.id)
	_emit(r, {"kind": "ram", "attackerId": ram_atk.id, "defenderId": ram_def.id, "targetKey": ram_key, "at": at, "normal": normal})

# Resolve a hazard striking a bot.
func _hazard_vs_bot(haz: Hazards.Hazard, B: Dictionary, b_key: String, normal: Vector3, at) -> void:
	if _on_cooldown(haz.id, B.id):
		stats.cooldown += 1
		return
	# Each hazard decides for itself whether it is dangerous right now.
	if not haz.live():
		stats.notLive += 1
		return
	var energy_j: float = J.g(haz.def, "impactEnergyJ", 0.0)
	if energy_j <= 0.0:
		stats.noEnergy += 1
		return
	var sim: RobotSim = B.sim
	var sq := _squareness(haz.lin_vel, sim.linear_velocity, normal)
	# Hazards are modelled as an attacker with no robot of their own, so a
	# minimal stand-in carries just the fields the damage model reads.
	var pseudo := {"massKg": 500.0, "parts": {"weapon": null}, "condition": {}, "fittings": [],
		"stats": {"weapon": {"class": "hazard", "concentration": J.g(haz.def, "concentration", 2.0), "selfDamageFraction": 0.0}}}
	var r := Damage.resolve_hit({"attacker": pseudo, "defender": B.assembled, "targetKey": b_key, "storedEnergyJ": energy_j,
		"squareness": maxf(0.5, sq), "rules": rules, "rng": rng})
	sim.invalidate()
	_push_away(sim, haz.body.global_position, r.impulseNs * 2.0)
	_set_cooldown(haz.id, B.id)
	_emit(r, {"kind": "hazard", "hazardId": haz.id, "hazardType": haz.type, "defenderId": B.id, "targetKey": b_key, "at": at, "normal": normal})

## Call once per physics step, after the engine has stepped.
func resolve(dt: float) -> void:
	_clock += dt
	_tick += 1
	_zones(dt)

	for xid in _order:
		var X: Dictionary = _bots[xid]
		var xs: RobotSim = X.sim
		var x_iid := xs.get_instance_id()
		for c in xs.contacts():
			var other: Object = c.other
			if other == null: continue
			var o_iid := other.get_instance_id()
			# A touch between two robots is reported by both; take it once.
			var pair: Array = [x_iid, c.local_shape, o_iid, c.other_shape] if x_iid < o_iid else [o_iid, c.other_shape, x_iid, c.local_shape]
			var last: int = _seen.get(pair, -1000)
			_seen[pair] = _tick
			if last == _tick or _tick - last <= SAME_TOUCH_STEPS: continue
			stats.rawStarted += 1
			if other is RobotSim:
				var Y = _bots.get((other as RobotSim).bot_id)
				if Y == null:
					stats.unindexed += 1
					continue
				stats.botVsBot += 1
				_bot_vs_bot(X, xs.fitting_for_shape(c.local_shape), xs.slot_for_shape(c.local_shape),
					Y, Y.sim.fitting_for_shape(c.other_shape), Y.sim.slot_for_shape(c.other_shape), c.normal, c.at)
			else:
				var haz: Hazards.Hazard = hazards.hazard_of(other) if hazards != null else null
				if haz == null:
					stats.unindexed += 1          # arena geometry: ignore
					continue
				stats.hazardVsBot += 1
				_hazard_vs_bot(haz, X, xs.fitting_for_shape(c.local_shape), c.normal, c.at)

	# Forget old touches and cooldowns so the maps do not grow without bound.
	if _seen.size() > 512:
		for k in _seen.keys():
			if _tick - _seen[k] > 240: _seen.erase(k)
	if _cooldowns.size() > 64:
		for k in _cooldowns.keys():
			if _cooldowns[k] < _clock: _cooldowns.erase(k)

func reset() -> void:
	_clock = 0.0
	log.clear()
	_cooldowns.clear()
	_seen.clear()
	for k in stats: stats[k] = 0
