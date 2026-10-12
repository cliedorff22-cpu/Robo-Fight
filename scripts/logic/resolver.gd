## resolver.gd - a whole fight in a couple of milliseconds, with no physics.
##
## A season is hundreds of AI-vs-AI fights, and an off-season is thousands of
## trial fights. The resolver plays a fight at the level of EXCHANGES: every
## half second the robots may engage, and when they do each one gets a chance
## to land its weapon, ram, flip or drive the other into a hazard. What a
## landed hit does is the real damage model (damage.gd) on the real assembled
## robots, damaged parts slow them down as condition.gd says, and a fight
## that goes the distance is scored by the real judges (judging.gd). So a
## resolved fight leaves the same kind of record a physics fight does -
## winner, method, cards, and part-level damage that carries out of the match.
##
## Every tunable number is in rules.json `resolver`. Pure logic, seeded: the
## same seed always resolves the same fight - and, draw for draw, the same
## fight the JavaScript game resolved (tests/run_tests.gd holds it to that).
##
## Multibots: a side is one or more units; a side is knocked out when more
## than half its weight is disabled - the show's rule.
##
## This is the hottest code in the game, so the fight itself runs on typed
## objects (RUnit, RSide, RCtx) with the damage arithmetic written out
## (_hit, _ram, _dmg mirror Damage.resolve_hit / resolve_ram / damage_fitting
## without building the reports a physics fight needs).
class_name Resolver

const DEFAULTS := {
	"tickS": 0.5,
	"engageRate": 0.34,            # chance per tick of an exchange, at average aggression
	"hitBase": 0.36,               # chance a ready weapon lands, per exchange, at skill 0.5
	"skillSpread": 0.9,            # how much skill moves the hit chance
	"agilityWeight": 0.35,         # a faster, nimbler target is harder to hit
	"ramChance": 0.45,             # a weaponless (or unready) unit rams instead
	"ramSpeedFrac": [0.35, 0.8],   # of top speed, on a ram
	"flipChance": 0.55,            # a landed flipper/lifter hit turns the target over
	"hammerFlipChance": 0.1,
	"selfRightChance": {"srimech": 0.92, "weapon": 0.75, "gyro": 0.45},   # per attempt
	"hazardChance": 0.05,          # per exchange, the stronger pusher shoves the other into a hazard
	"hazardHp": 70,
	"squareness": [0.15, 0.95],    # range, centred higher with skill
	"crusherBiteFrac": 0.6,        # of a bite's energy delivered when held
	"driveFloor": 0.18,            # tractive force below this share of rated = cannot move
	"countS": 10,
	# How well each weapon class lands its hits in practice, relative to 1.
	"classEdge": {"spinner_h": 1.5, "spinner_v": 1.0, "drum": 1.0, "hammer": 0.5, "flipper": 0.8, "lifter": 0.5, "crusher": 0.6, "static": 1.0, "none": 0.6},
	# Beaching: getting under a robot and leaving it on top of you.
	"beachChance": {"static": 0.12, "flipper": 0.06, "lifter": 0.06, "spinner_h": 0.04, "drum": 0.02, "spinner_v": 0.02, "hammer": 0.01, "crusher": 0.03, "none": 0.02},
	"forksBeachBonus": 0.04,
	# Each unit of a multibot is a smaller robot with less of everything.
	"multibotEdge": 0.6,
	"multibotExposure": 1.4,       # ...and is easier to hit, beach and flip
	"adaptCap": 0.15,              # the most a driver learns to dodge in one fight
	"beachEscape": 0.12,
	"wedgePushS": 1.0,             # extra control a wedge earns per exchange
}

## Resolver config: rules.json `resolver` over the defaults.
static func resolver_config(rules: Dictionary) -> Dictionary:
	return J.merge(DEFAULTS, rules.get("resolver", {}))

## Assemble a side's units from a robot def (a multibot brings its partner).
static func side_units(reg: Registry, def: Dictionary, conditions = null) -> Array:
	var units := [Build.assemble_robot(reg, def)]
	if def.get("partner") != null: units.append(Build.assemble_partner(reg, def))
	if conditions != null:
		for i in units.size():
			var c = conditions[i] if i < conditions.size() else null
			if c is Dictionary:
				for k in c: units[i].condition[k] = c[k]
	return units

## Whether a design can drive upside down (Shape.build_shape's `invertible`),
## kept per distinct body and build.
static func invertible_of(reg: Registry, a: Dictionary) -> bool:
	var def: Dictionary = a.def
	var key := "inv:" + JSON.stringify([def.get("body"), def.build])
	var v = reg.cache_get(key)
	if v == null:
		v = Shape.build_shape(a).invertible
		reg.cache_set(key, v)
	return v

# ---------------------------------------------------------------- the fight's objects

# Everything about the rules a fight reads, as plain numbers: read from
# rules.json once per registry, shared by every fight (and every thread).
class RRules:
	var cfg: Dictionary
	var jcfg: Dictionary
	var rules: Dictionary
	var duration := 180.0
	var tick := 0.5
	var count_s := 10.0
	var engage_rate := 0.34
	var hit_base := 0.36
	var skill_spread := 0.9
	var agility_weight := 0.35
	var ram_chance := 0.45
	var ram_lo := 0.35
	var ram_hi := 0.8
	var flip_by_class = null       # a per-class table, when the rules give one
	var flip_chance := 0.55
	var hammer_flip := 0.1
	var self_right: Dictionary
	var hazard_chance := 0.05
	var hazard_hp := 70.0
	var sq_lo := 0.15
	var sq_hi := 0.95
	var crusher_frac := 0.6
	var drive_floor := 0.18
	var class_edge: Dictionary
	var beach_chance: Dictionary
	var forks_bonus := 0.04
	var multibot_edge := 0.6
	var multibot_exposure := 1.4
	var adapt_cap := 0.15
	var beach_escape := 0.12
	var wedge_push := 1.0
	var wedge_face_chance := 0.5
	var glance: Dictionary        # weapons.wedgeDeflect.transfer by class
	var rotor_spend: Dictionary   # weapons.rotorSpend by class
	var failure_bonus := 35.0
	# rules.json `damage`
	var d_motor := 0.0
	var d_drive := 0.0
	var d_batt := 0.0
	var d_weapon := 0.0
	var th_failed := 0.0
	var chassis_kills := true
	var hp_per_kj := 0.0
	var ram_hp_per_kj := 0.0
	var min_ram_j := 0.0
	var tr_min := 0.0
	var tr_max := 1.0
	var tr_bonus := 1.0
	var armor_pass := 0.0
	var pierce := 0.0
	var vuln: Dictionary
	var vuln_weapon := 1.0
	var vuln_chassis := 1.0
	var self_damage := false
	var class_scale: Dictionary

	func _init(r: Dictionary) -> void:
		rules = r
		cfg = Resolver.resolver_config(r)
		jcfg = Judging.judging_config(r)
		duration = J.path(r, ["match", "durationS"], 180.0)
		tick = cfg.tickS
		count_s = cfg.countS
		engage_rate = cfg.engageRate
		hit_base = cfg.hitBase
		skill_spread = cfg.skillSpread
		agility_weight = cfg.agilityWeight
		ram_chance = cfg.ramChance
		ram_lo = cfg.ramSpeedFrac[0]
		ram_hi = cfg.ramSpeedFrac[1]
		if cfg.flipChance is Dictionary: flip_by_class = cfg.flipChance
		else: flip_chance = cfg.flipChance
		hammer_flip = cfg.hammerFlipChance
		self_right = cfg.selfRightChance
		hazard_chance = cfg.hazardChance
		hazard_hp = cfg.hazardHp
		sq_lo = cfg.squareness[0]
		sq_hi = cfg.squareness[1]
		crusher_frac = cfg.crusherBiteFrac
		drive_floor = cfg.driveFloor
		class_edge = cfg.classEdge
		beach_chance = cfg.beachChance
		forks_bonus = cfg.forksBeachBonus
		multibot_edge = cfg.multibotEdge
		multibot_exposure = cfg.multibotExposure
		adapt_cap = cfg.adaptCap
		beach_escape = cfg.beachEscape
		wedge_push = cfg.wedgePushS
		wedge_face_chance = J.g(cfg, "wedgeFaceChance", 0.5)
		var wpn: Dictionary = r.get("weapons", {})
		glance = J.path(wpn, ["wedgeDeflect", "transfer"], {})
		rotor_spend = J.g(wpn, "rotorSpend", {})
		failure_bonus = jcfg.failureBonusHp
		var d: Dictionary = r.damage
		d_motor = d.degrade.motorTorque
		d_drive = d.degrade.driveTorque
		d_batt = d.degrade.batteryPower
		d_weapon = d.degrade.weaponOutput
		th_failed = d.thresholds.failed
		chassis_kills = J.truthy(d.get("chassisKillsBot"))
		hp_per_kj = d.hpPerKilojoule
		ram_hp_per_kj = d.rammingHpPerKilojoule
		min_ram_j = d.minRamEnergyJ
		tr_min = d.transfer.min
		tr_max = d.transfer.max
		tr_bonus = d.transfer.squareHitBonus
		armor_pass = d.armorPassThrough
		pierce = J.g(d, "pierce", 0.0)
		vuln = d.vulnerability
		vuln_weapon = J.g(vuln, "weapon", 1.0)
		vuln_chassis = J.g(vuln, "chassis", 1.0)
		self_damage = J.truthy(d.get("selfDamageOnHit"))
		class_scale = J.g(d, "classScale", {})

static func rules_of(reg: Registry) -> RRules:
	var r = reg.cache_get("resolverRules")
	if r == null:
		r = RRules.new(reg.rules)
		reg.cache_set("resolverRules", r)
	return r

# One fight's moving parts.
class RCtx:
	var k: RRules
	var rng: Rng
	var t := 0.0
	var any_disabled := false     # nobody down yet: the count has nothing to do
	var last_failed := false      # set by _dmg: did that blow finish the part off

# One robot in the fight.
class RUnit:
	var a: Dictionary
	var prof: Dictionary
	var skill := 0.5
	var aggression := 1.0
	var invertible := false
	var family := "none"
	var kinetic := false
	var cls := "none"
	var via := "none"
	var spool := 0.4              # spinners have spun up in the opening seconds
	var adapt := 0.0              # learned this fight: how much harder it is to hit
	var learn := 0.0
	var reload := 0.0
	var flipped := false
	var flip_t := 0.0
	var beached := false
	var beach_t := 0.0
	var forks := false
	var disabled := false
	var disabled_at := 0.0
	var cause = null
	var weight := 0.0
	var mass := 0.0
	var pivot_base := 0.0
	var drive_rated := 1.0
	var dirty := false            # hit since its numbers were last worked out
	# What it can do in its present condition - the few figures of
	# Condition.effective_stats() a resolved fight reads (see refresh()).
	var e_energy := 0.0
	var e_spin_up := 0.0
	var e_tractive := 0.0
	var e_top := 0.0
	var e_dead := false
	var e_immobile := false
	var e_cause := "drive"
	# Rated figures and per-class numbers, read once.
	var b_wheels := 4.0
	var b_driven := 4.0
	var b_force := 0.0
	var b_top := 0.0
	var b_energy := 0.0
	var b_motor_w := 0.0
	var b_powered := false
	var has_weapon := false
	var has_wmotor := false
	var w_conc := 1.0
	var w_self := 0.1
	var w_scale := 1.0
	var w_bite := 0.7
	var w_cycle := 1.5
	var edge := 1.0
	var beach_p := 0.02
	var flip_p := 0.0
	var glance = null
	var rotor_spend := 0.25
	var self_right_p := 0.7
	# Where a hit on it can land (_pick_target), by what is hitting it:
	# [keys, weights, total] for an overhead blow, a horizontal bar, anything else.
	var tg_top: Array
	var tg_spin: Array
	var tg_other: Array

	func setup(k: RRules) -> void:
		var st: Dictionary = a.stats
		var w: Dictionary = st.weapon
		cls = w["class"]
		family = Weapon.family_of(cls)
		kinetic = family == Weapon.KINETIC
		via = st.selfRight.via
		weight = a.weightLb
		mass = a.massKg
		pivot_base = st.pivotAuthority
		drive_rated = maxf(1.0, st.forcePerWheelN * st.drivenWheels)
		b_wheels = st.wheelCount
		b_driven = st.drivenWheels
		b_force = st.forcePerWheelN
		b_top = st.topSpeedMps
		b_energy = w.energyJ
		b_motor_w = J.g(w, "motorPowerW", 0.0)
		b_powered = w.powered
		has_weapon = a.parts.get("weapon") != null
		has_wmotor = a.parts.get("weaponMotor") != null
		w_conc = w.concentration
		w_self = J.g(w, "selfDamageFraction", 0.1)
		w_scale = J.g(k.class_scale, cls, 1.0)
		w_bite = Resolver._or(w.get("biteIntervalS"), 0.7)
		w_cycle = Resolver._or(w.get("cycleS"), 1.5)
		edge = J.g(k.class_edge, cls, 1.0)
		beach_p = J.g(k.beach_chance, cls, 0.02)
		if k.flip_by_class != null: flip_p = J.g(k.flip_by_class, cls, 0.0)
		elif cls == "flipper": flip_p = k.flip_chance
		elif cls == "lifter": flip_p = k.flip_chance * 0.7
		elif cls == "hammer": flip_p = k.hammer_flip
		glance = k.glance.get(cls)
		rotor_spend = J.g(k.rotor_spend, cls, 0.25)
		self_right_p = J.g(k.self_right, via, 0.7)
		tg_top = _targets(true, false)
		tg_spin = _targets(false, true)
		tg_other = _targets(false, false)
		refresh(k)

	# Mostly armour, sometimes the wheels, the weapon or bare chassis.
	func _targets(top: bool, spinner_h: bool) -> Array:
		var keys: Array[String] = []
		var wts: Array[float] = []
		for ks in a.armorSlots:
			var slot: String = ks[1]
			var wt := 0.4
			if slot == "front": wt = 2.2
			elif slot == "side": wt = 1.0
			elif slot == "top": wt = 2.2 if top else 0.5
			keys.append(ks[0])
			wts.append(wt)
		keys.append("wheel")
		wts.append(0.7 if spinner_h else 0.35)
		if has_weapon:
			keys.append("weapon")
			wts.append(0.35)
		wts.append(1.5 if keys.size() <= 3 else 0.3)
		keys.append("chassis")
		var tot := 0.0
		for x in wts: tot += x
		return [keys, wts, tot]

	static func _c(c: Dictionary, key: String) -> float:
		var v = c.get(key)
		if v == null: return 1.0
		return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)

	## Condition.effective_stats(), cut down to what the fight needs.
	func refresh(k: RRules) -> void:
		dirty = false
		var c: Dictionary = a.condition
		var wheel_c := _c(c, "wheel")
		var motor_c := _c(c, "motor")
		var drive_c := _c(c, "drive")
		var batt_c := _c(c, "battery")
		var elec_c := _c(c, "electronics")
		var chassis_c := _c(c, "chassis")
		var weapon_c := _c(c, "weapon") if has_weapon else 0.0
		var wmotor_c := _c(c, "weaponMotor") if has_wmotor else 0.0
		var motor_factor := k.d_motor + (1.0 - k.d_motor) * motor_c
		var drive_factor := k.d_drive + (1.0 - k.d_drive) * drive_c
		var batt_factor := k.d_batt + (1.0 - k.d_batt) * batt_c
		var wheels_remaining: float = ceil(wheel_c * b_wheels)
		var driven_remaining := minf(b_driven, wheels_remaining)
		var force_per_wheel := b_force * motor_factor * drive_factor * batt_factor
		e_tractive = force_per_wheel * driven_remaining
		e_top = b_top * batt_factor
		var weapon_energy := b_energy * (k.d_weapon + (1.0 - k.d_weapon) * weapon_c)
		var motor_power := b_motor_w * (k.d_motor + (1.0 - k.d_motor) * wmotor_c)
		e_dead = (not has_weapon) or weapon_c <= k.th_failed or (b_powered and wmotor_c <= k.th_failed)
		e_spin_up = weapon_energy / motor_power if motor_power > 0 else INF
		e_energy = 0.0 if e_dead else weapon_energy
		var chassis_gone := k.chassis_kills and chassis_c <= k.th_failed
		var electronics_gone := elec_c <= k.th_failed
		e_immobile = chassis_gone or electronics_gone or wheels_remaining <= 0
		e_cause = "chassis" if chassis_gone else ("electronics" if electronics_gone else ("wheels" if wheels_remaining <= 0 else "drive"))

class RSide:
	var id
	var def: Dictionary
	var units: Array[RUnit] = []
	var multi := false
	var weight := 0.0
	var hp_taken := 0.0
	var damage := 0.0
	var hp_dealt := 0.0
	var failures := 0
	var hazard_hp := 0.0
	var advancing_s := 0.0
	var attacks := 0.0
	var pushing_s := 0.0
	var opp_disabled_s := 0.0
	var own_disabled_s := 0.0
	var self_hazard := 0
	var hits_landed := 0
	var flips := 0

static func _make_side(reg: Registry, def: Dictionary, conds, k: RRules) -> RSide:
	var s := RSide.new()
	s.id = def.id
	s.def = def
	var prof := AI.ai_profile(def)
	var aggression: float = {"aggressive": 1.25, "opportunistic": 1.0, "defensive": 0.78}.get(prof.personality, 1.0)
	var learn: float = J.g(def, "learnRate", 0.7) * 0.012 * (0.5 + prof.skill)
	for a in side_units(reg, def, conds):
		var u := RUnit.new()
		u.a = a
		u.prof = prof
		u.skill = prof.skill
		u.aggression = aggression
		u.learn = learn
		u.invertible = invertible_of(reg, a)
		for e in J.path(a, ["def", "body", "extras"], []):
			if e.type == "forks" or e.type == "plow":
				u.forks = true
				break
		u.setup(k)
		s.units.append(u)
		s.weight += u.weight
	s.multi = s.units.size() > 1
	return s

# ---------------------------------------------------------------- who is in it
# (The original built lists of the live and the free units each time; these
# walk the same units in the same order without the lists.)

# The keenest free unit's aggression, or -1 with nobody free to fight.
static func _aggr_free(s: RSide) -> float:
	var m := -1.0
	for u in s.units:
		if not u.disabled and not u.flipped and not u.beached and u.aggression > m: m = u.aggression
	return maxf(m, 0.0) if m >= 0.0 else -1.0

static func _speed_free(s: RSide) -> float:
	var m := 0.0
	for u in s.units:
		if not u.disabled and not u.flipped and not u.beached: m = maxf(m, u.e_top)
	return m

static func _skill_free(s: RSide) -> float:
	var m := 0.0
	for u in s.units:
		if not u.disabled and not u.flipped and not u.beached: m = maxf(m, u.skill)
	return m

static func _push_free(s: RSide) -> float:
	var t := 0.0
	for u in s.units:
		if not u.disabled and not u.flipped and not u.beached: t += u.e_tractive * (0.6 + u.skill * 0.4)
	return t + 1.0

static func _skill_live(s: RSide) -> float:
	var m := 0.0
	for u in s.units:
		if not u.disabled: m = maxf(m, u.skill)
	return m

static func _any_live(s: RSide) -> bool:
	for u in s.units:
		if not u.disabled: return true
	return false

static func _has_free(s: RSide) -> bool:
	for u in s.units:
		if not u.disabled and not u.flipped and not u.beached: return true
	return false

# A unit by its share of the weight, from the free units (`free_only`) or the
# live ones. With nobody to pick it still draws, as the original did, so the
# stream stays in step; then it answers null.
static func _pick_by_weight(s: RSide, rng: Rng, free_only: bool) -> RUnit:
	var tot := 0.0
	var last: RUnit = null
	for u in s.units:
		if u.disabled or (free_only and (u.flipped or u.beached)): continue
		tot += u.weight
		last = u
	var r := rng.next() * tot
	for u in s.units:
		if u.disabled or (free_only and (u.flipped or u.beached)): continue
		r -= u.weight
		if r <= 0: return u
	return last

## Where a hit lands on `u`, by what is hitting it.
static func _pick_target(u: RUnit, rng: Rng, kind: String) -> String:
	var tg: Array
	if kind == "hammer" or kind == "crusher" or kind == "hazard": tg = u.tg_top
	elif kind == "spinner_h": tg = u.tg_spin
	else: tg = u.tg_other
	var keys: Array[String] = tg[0]
	var wts: Array[float] = tg[1]
	var tot: float = tg[2]
	var r := rng.next() * tot
	for i in keys.size():
		r -= wts[i]
		if r <= 0: return keys[i]
	return "chassis"

# ---------------------------------------------------------------- the fight

## Resolve one fight.
##   a, b    robot DEFS (ratings, leagues and personalities as fielded)
##   opts    { seed = 1, conditionA, conditionB } - per-unit condition maps to
##           start from (a robot that shows up damaged)
## Returns { winnerId, loserId, method, cause, elapsedS, decision, cards, votes,
##   sides: { id: { hpDealt, hpTaken, damageScore, hitsLanded, flips, ko,
##   condition: [per unit] } } }
static func resolve_fight(reg: Registry, a: Dictionary, b: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var seed_v = opts.get("seed", 1)
	var k := rules_of(reg)
	var rng := Rng.new(Rng.hash_seed("resolve:%s:%s:%s" % [J.s(seed_v), a.id, b.id]))
	var x := RCtx.new()
	x.k = k
	x.rng = rng

	var A := _make_side(reg, a, opts.get("conditionA"), k)
	var B := _make_side(reg, b, opts.get("conditionB"), k)

	var duration := k.duration
	var tick := k.tick
	var count_s := k.count_s
	var beach_escape := k.beach_escape
	var engage_rate := k.engage_rate
	var t := 0.0
	var ended := false
	var end_winner: RSide = null
	var end_loser: RSide = null
	var end_cause = null
	var sides: Array[RSide] = [A, B]

	while t < duration and not ended:
		x.t = t
		for s in sides:
			for u in s.units:
				if u.disabled: continue
				# Kinetic weapons spool between exchanges.
				if u.kinetic and u.e_energy > 0 and is_finite(u.e_spin_up):
					u.spool = minf(1.0, u.spool + tick / maxf(0.3, u.e_spin_up))
				u.reload = maxf(0.0, u.reload - tick)
				# Beached: try to drive off whatever it is stranded on.
				if u.beached:
					u.beach_t += tick
					if rng.next() < beach_escape * minf(1.5, 0.5 + u.e_tractive / maxf(1.0, u.mass * 9.81)):
						u.beached = false; u.beach_t = 0.0
					elif u.beach_t >= count_s + 1:
						u.disabled = true; u.cause = "beached"; u.disabled_at = t; x.any_disabled = true
				# Flipped and trying to get back over.
				if u.flipped:
					u.flip_t += tick
					if u.via != "none" and u.flip_t >= 1 and rng.next() < u.self_right_p:
						u.flipped = false; u.flip_t = 0.0
					elif u.flip_t >= count_s + 1:
						u.disabled = true; u.cause = "flipped"; u.disabled_at = t; x.any_disabled = true

		# Is a side out? More than half its weight disabled, counted out.
		if x.any_disabled:
			for i in 2:
				var s: RSide = sides[i]
				var o: RSide = sides[1 - i]
				var dis := 0.0
				var since := -INF
				var first_cause = null
				var any := false
				for u in s.units:
					if u.disabled:
						dis += u.weight
						since = maxf(since, u.disabled_at)
						if not any:
							first_cause = u.cause
							any = true
				if dis / s.weight > 0.5:
					s.own_disabled_s += tick
					o.opp_disabled_s += tick
					if t - since >= count_s and not ended:
						ended = true
						end_winner = o
						end_loser = s
						end_cause = first_cause
			if ended: break

		# (No lists built on a quiet tick: most ticks are.)
		var aggr_a := _aggr_free(A)
		var aggr_b := _aggr_free(B)
		if aggr_a < 0.0 or aggr_b < 0.0:
			t += tick
			continue

		# An exchange this tick? Aggressive drivers start more of them.
		if not (rng.next() < engage_rate * (aggr_a + aggr_b) / 2.0):
			t += tick
			continue

		# Who drove it: initiative goes to the keener, quicker driver.
		var init_a := aggr_a * (0.7 + _speed_free(A) * 0.06) * (0.6 + _skill_free(A))
		var init_b := aggr_b * (0.7 + _speed_free(B) * 0.06) * (0.6 + _skill_free(B))
		var leader: RSide = A if rng.next() < init_a / (init_a + init_b) else B
		leader.advancing_s += tick * 2.0

		# Pushing: the stronger pusher controls where it goes.
		var push_a := _push_free(A)
		var push_b := _push_free(B)
		var pusher: RSide = A if rng.next() < push_a / (push_a + push_b) else B
		pusher.pushing_s += tick * 2.0

		# Both sides swing, the leader first.
		for i in 2:
			var s: RSide = leader if i == 0 else (B if leader == A else A)
			var o: RSide = B if s == A else A
			var atk := _pick_by_weight(s, rng, true)
			if atk == null or not _has_free(o): continue
			var dfn := _pick_by_weight(o, rng, true)
			_attack(atk, dfn, s, o, x)
			_check_disabled(dfn, x)
			_check_disabled(atk, x)

		# The arena bites: the pusher drives the other into a hazard.
		var victim_side: RSide = B if pusher == A else A
		if rng.next() < k.hazard_chance * (0.5 + _skill_live(pusher)) and _any_live(victim_side):
			var v := _pick_by_weight(victim_side, rng, false)
			var key := _pick_target(v, rng, "hazard")
			var got := _dmg(v, key, k.hazard_hp * rng.float_range(0.6, 1.4), x)
			if got >= 0.0: _credit_hit(pusher, victim_side, got, 1 if x.last_failed else 0, "hazard", k)
			_check_disabled(v, x)
		t += tick

	var elapsed_s := minf(t, duration)
	var result: Dictionary
	if ended:
		result = {"method": "ko", "cause": end_cause, "winnerId": end_winner.id, "loserId": end_loser.id, "decision": null, "cards": null, "votes": null}
	else:
		var raw := {}
		for i in 2:
			var s: RSide = sides[i]
			var o: RSide = sides[1 - i]
			raw[s.id] = {
				"damage": s.damage,
				"aggression": s.advancing_s + s.attacks * 1.5,
				"control": maxf(0.0, s.pushing_s + s.opp_disabled_s * 0.8 + s.hazard_hp * 0.03 +
					o.self_hazard * 0.6 - s.own_disabled_s * 0.5),
			}
		var j := Judging.judge_cards(raw, [A.id, B.id], k.jcfg, seed_v)
		result = {"method": "decision", "cause": null, "winnerId": j.winnerId, "loserId": j.loserId, "decision": j.decision, "cards": j.cards, "votes": j.votes, "raw": raw}
	var out_sides := {}
	for s in sides:
		var conds := []
		for u in s.units: conds.append(u.a.condition.duplicate())
		out_sides[s.id] = {
			"hpDealt": J.rnd(s.hp_dealt), "hpTaken": J.rnd(s.hp_taken),
			"damageScore": J.rnd(s.damage),
			"hitsLanded": s.hits_landed, "flips": s.flips,
			"ko": result.method == "ko" and result.loserId == s.id,
			"condition": conds,
		}
	result.elapsedS = elapsed_s
	result.sides = out_sides
	return result

static func _credit_hit(atk: RSide, def: RSide, hp: float, failures: int, kind: String, k: RRules) -> void:
	atk.damage += hp + failures * k.failure_bonus
	atk.hp_dealt += hp
	atk.failures += failures
	if kind == "hazard": atk.hazard_hp += hp
	else:
		atk.hits_landed += 1
		atk.attacks += 1.0 if kind == "weapon" else 0.5
	def.hp_taken += hp

# A unit whose drive is gone, or that is upside down with no way back, is
# disabled for good; the count runs from then.
static func _check_disabled(u: RUnit, x: RCtx) -> void:
	if u.disabled: return
	if u.dirty: u.refresh(x.k)
	if u.e_immobile or u.e_tractive / u.drive_rated < x.k.drive_floor:
		u.disabled = true
		x.any_disabled = true
		u.cause = u.e_cause
		u.disabled_at = x.t

static func _attack(atk: RUnit, def: RUnit, s: RSide, o: RSide, x: RCtx) -> void:
	var k := x.k
	var rng := x.rng
	var tick := k.tick
	var cls := atk.cls
	var skill := atk.skill
	var top_speed := def.e_top
	if top_speed == 0.0: top_speed = 1.0
	var agility := minf(2.0, top_speed / 6.0 + (0.2 if def.pivot_base > 1.5 else 0.0))
	var edge := atk.edge * (k.multibot_edge if s.multi else 1.0)
	var exposed := k.multibot_exposure if o.multi else 1.0
	# `def.adapt`: what the defending driver has learned this fight about
	# keeping out of this weapon's way.
	var p_hit := clampf(k.hit_base * edge * exposed * (1.0 + (skill - 0.5) * k.skill_spread) * (1.0 - k.agility_weight * (agility - 0.8)) * (1.0 - def.adapt), 0.03, 0.92)
	# Getting underneath: the defender is left stranded on the attacker.
	if not def.invertible and rng.next() < (atk.beach_p + (k.forks_bonus if atk.forks else 0.0)) * exposed:
		def.beached = true; def.beach_t = 0.0
		s.pushing_s += tick * 2.0
		s.attacks += 0.5
		return
	var sq := k.sq_lo + (k.sq_hi - k.sq_lo) * clampf(rng.next() * 0.6 + skill * 0.4, 0.0, 1.0)
	var ready := false
	if not atk.e_dead:
		if atk.kinetic: ready = atk.spool > 0.35
		elif atk.family != Weapon.NONE: ready = atk.reload <= 0

	if ready and rng.next() < p_hit:
		var key := _pick_target(def, rng, cls)
		var stored := atk.e_energy
		if atk.kinetic: stored *= atk.spool
		elif atk.family == Weapon.CRUSHER: stored *= k.crusher_frac
		# A rotor that meets a wedge face-on glances off it (weapons.wedgeDeflect).
		if atk.kinetic and atk.glance != null and def.cls == "static" and rng.next() < k.wedge_face_chance:
			stored *= atk.glance
		var consumed := _hit(atk, def, s, o, key, stored, sq, x)
		# Learning in the fight: every hit taken teaches the driver a little
		# more about how this weapon comes in.
		def.adapt = minf(k.adapt_cap, def.adapt + def.learn)
		# Every landed hit costs a rotor at least its class's share of spin.
		if atk.kinetic:
			atk.spool = maxf(0.0, atk.spool - maxf(consumed / maxf(1.0, atk.e_energy), atk.rotor_spend))
		elif atk.family == Weapon.CRUSHER:
			atk.reload = atk.w_bite * 2.0
		else:
			atk.reload = maxf(tick, atk.w_cycle)
		# Flippers throw, lifters tip, verticals launch, hammers occasionally
		# turn a bot over: a chance per landed hit, by class.
		if atk.flip_p != 0.0 and not def.invertible and rng.next() < atk.flip_p:
			def.flipped = true; def.flip_t = 0.0
			s.flips += 1
			s.attacks += 0.5
		return
	# No weapon ready: drive into them instead.
	if rng.next() < k.ram_chance * (1.6 if (cls == "static" or cls == "none") else 1.0):
		var v := atk.e_top * rng.float_range(k.ram_lo, k.ram_hi)
		_ram(atk, def, s, o, _pick_target(def, rng, "ram"), v, x)
		# A good wedge gets under and shoves for control.
		if cls == "static": s.pushing_s += k.wedge_push

# Damage.damage_fitting without the record: hp off one fitting. Returns the
# hp it lost (-1 if the robot has no such fitting) and sets x.last_failed.
static func _dmg(u: RUnit, key: String, hp: float, x: RCtx) -> float:
	x.last_failed = false
	var a := u.a
	var f = a.fittingMap.get(key)
	if f == null: return -1.0
	var cond: Dictionary = a.condition
	var part_hp: float = f.part.hp
	var bv = cond.get(key)
	var before: float = 1.0 if bv == null else bv
	var hp_available := part_hp * before
	var hp_lost := minf(hp, hp_available)
	var after := 0.0
	if part_hp > 0:
		after = before - hp_lost / part_hp
		after = 0.0 if after < 0.0 else (1.0 if after > 1.0 else after)
	cond[key] = after
	u.dirty = true
	var th := x.k.th_failed
	x.last_failed = after <= th and before > th
	return hp_lost

# One weapon hit: Damage.resolve_hit, credited straight to the scorebook
# (the same arithmetic and the same draws). Returns the energy that went in.
static func _hit(atk: RUnit, def: RUnit, s: RSide, o: RSide, key: String, stored: float, squareness: float, x: RCtx) -> float:
	var k := x.k
	var sq := 0.0 if squareness < 0.0 else (1.0 if squareness > 1.0 else squareness)
	var frac := k.tr_min + (k.tr_max - k.tr_min) * sq
	if sq > 0.9: frac *= k.tr_bonus
	frac *= 0.85 + x.rng.next() * 0.3
	var transfer := clampf(frac, k.tr_min * 0.6, 1.0)
	var delivered := maxf(0.0, stored) * transfer
	var raw_hp := (delivered / 1000.0) * k.hp_per_kj * atk.w_conc * atk.w_scale
	var hp := 0.0
	var failures := 0
	var landed := delivered > 0 and raw_hp > 0
	if landed:
		var da := def.a
		var struck = da.fittingMap.get(key)
		var pass_through := 0.0
		if struck != null and struck.part.category == "armor":
			var pv = da.condition.get(key)
			var panel_condition: float = 1.0 if pv == null else pv
			# Hard armour resists; an intact panel keeps most of the blow out.
			var got := _dmg(def, key, raw_hp / maxf(0.2, struck.part.spec.hardness), x)
			if got >= 0.0:
				hp += got
				if x.last_failed: failures += 1
			var pierce := 1.0 + k.pierce * maxf(0.0, atk.w_conc - 1.5)
			pass_through = raw_hp * (minf(0.9, k.armor_pass * pierce) if panel_condition > 0 else 1.0)
		else:
			# A bare face, or a direct hit on the weapon or the chassis.
			var vuln: float = J.g(k.vuln, struck.part.category, 1.0) if struck != null else k.vuln_chassis
			var got := _dmg(def, key, raw_hp * vuln, x)
			if got >= 0.0:
				hp += got
				if x.last_failed: failures += 1
		# Blow through the armour into something that matters.
		if pass_through > 0.5:
			var internal = _pick_internal(da, x)
			if internal != null:
				var got := _dmg(def, internal.key, pass_through * J.g(k.vuln, internal.part.category, 1.0), x)
				if got >= 0.0:
					hp += got
					if x.last_failed: failures += 1
		# Hitting things breaks your own weapon too.
		if k.self_damage and atk.has_weapon:
			_dmg(atk, "weapon", raw_hp * atk.w_self * k.vuln_weapon, x)
	_credit_hit(s, o, hp, failures, "weapon", k)
	return delivered if landed else 0.0

# Damage.pick_internal: which internal part a pass-through blow finds.
static func _pick_internal(a: Dictionary, x: RCtx):
	var cond: Dictionary = a.condition
	var vuln := x.k.vuln
	var cands := []
	var total := 0.0
	var wts: Array[float] = []
	for f in a.internals:
		var cv = cond.get(f.key)
		if cv == null or cv > 0:
			var wv: float = J.g(vuln, f.part.category, 1.0)
			cands.append(f)
			wts.append(wv)
			total += wv
	if cands.is_empty(): return null
	var roll := x.rng.next() * total
	for i in cands.size():
		roll -= wts[i]
		if roll <= 0: return cands[i]
	return cands[cands.size() - 1]

# One ram: Damage.resolve_ram, credited the same way.
static func _ram(atk: RUnit, def: RUnit, s: RSide, o: RSide, key: String, speed: float, x: RCtx) -> void:
	var k := x.k
	var mass := minf(atk.mass, def.mass)
	var energy := 0.5 * mass * speed * speed
	if energy < k.min_ram_j: return
	# A wedge rams better than a flat face.
	var conc := atk.w_conc if atk.w_conc != 0.0 else 0.4
	var raw_hp := (energy / 1000.0) * k.ram_hp_per_kj * conc
	var struck = def.a.fittingMap.get(key)
	var vuln: float = J.g(k.vuln, struck.part.category, 1.0) if struck != null else k.vuln_chassis
	var got := _dmg(def, key, raw_hp * vuln, x)
	var failures := 1 if (got >= 0.0 and x.last_failed) else 0
	_credit_hit(s, o, maxf(got, 0.0), failures, "ram", k)

# `x || def` for numbers.
static func _or(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if (f == 0.0 or is_nan(f)) else f
