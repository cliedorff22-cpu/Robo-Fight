## damage.gd - resolving one impact into part-level damage.
##
## Pure logic. The simulation tells it "this weapon, with this much stored
## energy, hit that fitting, this squarely"; it decides what broke. All
## variance comes from a seeded Rng so a replay or a saved season reproduces.
##
## Routing is geometric: every collider maps to a fitting key, so a hit on the
## left side panel damages `armor.1`. Armour then passes a fraction of the
## blow through to ONE internal part.
class_name Damage

const SEVERITY_ORDER := {"scratch": 0, "glance": 1, "hit": 2, "heavy": 3, "catastrophic": 4}

## Internal parts that a blow through the armour can find.
const INTERNALS := ["electronics", "battery", "motor", "drive", "weaponMotor", "srimech", "chassis"]

## Energy a moving mass carries, for ram damage.
static func kinetic_energy_j(mass_kg: float, speed_mps: float) -> float:
	return 0.5 * mass_kg * speed_mps * speed_mps

## Convert delivered energy into raw hit points.
static func energy_to_hp(delivered_j: float, concentration: float, rules: Dictionary) -> float:
	return (delivered_j / 1000.0) * rules.damage.hpPerKilojoule * concentration

## How much of a weapon's stored energy a given hit actually delivers.
## `squareness` is 0 for a glancing graze and 1 for a dead-square hit.
static func energy_transfer(squareness: float, rules: Dictionary, rng: Rng) -> float:
	var t: Dictionary = rules.damage.transfer
	var sq := J.clamp01(squareness)
	var frac: float = t.min + (t.max - t.min) * sq
	if sq > 0.9: frac *= t.squareHitBonus
	# +/-15% so identical-looking hits are not identical.
	frac *= 0.85 + (rng.next() if rng != null else 0.5) * 0.3
	return clampf(frac, t.min * 0.6, 1.0)

## Label a hit by how much of the struck part it took.
static func severity_of(hp_lost: float, part_hp: float, rules: Dictionary) -> String:
	var s: Dictionary = rules.damage.severity
	var frac := hp_lost / part_hp if part_hp > 0 else 0.0
	if frac >= s.catastrophic: return "catastrophic"
	if frac >= s.heavy: return "heavy"
	if frac >= s.hit: return "hit"
	if frac >= s.glance: return "glance"
	return "scratch"

static func find_fitting(assembled: Dictionary, key):
	if key == null: return null
	var m = assembled.get("fittingMap")
	if m != null: return m.get(key)
	for f in assembled.fittings:
		if f.key == key: return f
	return null

## Apply hp of damage to one fitting. Mutates `assembled.condition`.
## Returns a record of what happened, or null if the fitting does not exist.
static func damage_fitting(assembled: Dictionary, key, hp: float, rules: Dictionary):
	var fitting = find_fitting(assembled, key)
	if fitting == null: return null

	var th: Dictionary = rules.damage.thresholds
	var part_hp: float = fitting.part.hp
	var before: float = J.g(assembled.condition, key, 1.0)
	var status_before := Condition.part_status(before, th)

	# Damage beyond what the part has left is wasted on it, not carried over.
	var hp_available := part_hp * before
	var hp_lost := minf(hp, hp_available)
	var after := J.clamp01(before - hp_lost / part_hp) if part_hp > 0 else 0.0

	assembled.condition[key] = after
	var status_after := Condition.part_status(after, th)

	return {
		"key": key,
		"partId": fitting.part.id,
		"name": fitting.part.name,
		"category": fitting.part.category,
		"hpLost": hp_lost,
		"hpOverkill": maxf(0.0, hp - hp_available),
		"conditionBefore": before,
		"conditionAfter": after,
		"statusBefore": status_before,
		"statusAfter": status_after,
		"failed": status_after == Condition.FAILED and status_before != Condition.FAILED,
		"degraded": status_after != status_before,
		"severity": severity_of(hp_lost, part_hp, rules),
	}

## Pick which internal part a pass-through blow damages, weighted by how
## vulnerable each is.
static func pick_internal(assembled: Dictionary, rules: Dictionary, rng: Rng):
	var vuln: Dictionary = rules.damage.vulnerability
	var candidates := []
	var cond: Dictionary = assembled.condition
	var pool = assembled.get("internals")
	if pool != null:
		for f in pool:
			var cv = cond.get(f.key)
			if cv == null or cv > 0: candidates.append(f)
	else:
		for f in assembled.fittings:
			if INTERNALS.has(f.part.category) and J.g(cond, f.key, 1.0) > 0:
				candidates.append(f)
	if candidates.is_empty(): return null

	var weights := []
	var total := 0.0
	for f in candidates:
		var wv: float = J.g(vuln, f.part.category, 1.0)
		weights.append(wv)
		total += wv
	var roll := (rng.next() if rng != null else 0.5) * total
	for i in candidates.size():
		roll -= weights[i]
		if roll <= 0: return candidates[i].key
	return candidates[candidates.size() - 1].key

## Resolve one weapon impact.
##   o.attacker / o.defender  assembled robots (defender's condition mutated)
##   o.targetKey      fitting struck, from the collider map
##   o.storedEnergyJ  energy the weapon has RIGHT NOW
##   o.squareness     0..1
##   o.rules, o.rng
## Returns every part affected, plus the impulse and the energy the attacker's
## weapon lost - the simulation needs both.
static func resolve_hit(o: Dictionary) -> Dictionary:
	var attacker: Dictionary = o.attacker
	var defender: Dictionary = o.defender
	var target_key = o.get("targetKey")
	var stored_energy_j: float = o.storedEnergyJ
	var squareness: float = o.get("squareness", 0.5)
	var rules: Dictionary = o.rules
	var rng: Rng = o.get("rng")

	var d: Dictionary = rules.damage
	var w: Dictionary = attacker.stats.weapon

	var transfer := energy_transfer(squareness, rules, rng)
	var delivered_j := maxf(0.0, stored_energy_j) * transfer
	# The balance pass's per-class lever (rules.json damage.classScale).
	var raw_hp: float = energy_to_hp(delivered_j, w.concentration, rules) * J.path(d, ["classScale", w["class"]], 1.0)

	var result := {
		"deliveredJ": delivered_j,
		"transfer": transfer,
		"rawHp": raw_hp,
		"squareness": squareness,
		"hits": [],
		"selfHit": null,
		"impulseNs": 0.0,
		"severity": "scratch",
		"failures": [],
		"defenderImmobilised": false,
	}
	if delivered_j <= 0 or raw_hp <= 0: return result

	var struck = find_fitting(defender, target_key)
	var target_is_armor: bool = struck != null and struck.part.category == "armor"
	var pass_through_hp := 0.0

	if target_is_armor:
		var spec: Dictionary = struck.part.spec
		var panel_condition: float = J.g(defender.condition, target_key, 1.0)
		# Hard armour resists; springy armour deflects energy back out as impulse.
		var absorbed_hp: float = raw_hp / maxf(0.2, spec.hardness)
		var rec = damage_fitting(defender, target_key, absorbed_hp, rules)
		if rec != null: result.hits.append(rec)
		result.impulseNs += delivered_j * d.deflectionImpulseFraction * J.g(spec, "deflection", 1.0) * 0.01
		# An intact panel keeps most of the blow out. A destroyed one keeps
		# none. A concentrated blow punches more of itself through.
		var pierce: float = 1.0 + J.g(d, "pierce", 0.0) * maxf(0.0, J.g(w, "concentration", 1.0) - 1.5)
		var through: float = minf(0.9, d.armorPassThrough * pierce) if panel_condition > 0 else 1.0
		pass_through_hp = raw_hp * through
	else:
		# A bare face, or a direct hit on the weapon or the chassis.
		var vuln: float = J.g(d.vulnerability, struck.part.category if struck != null else "chassis", 1.0)
		var rec = damage_fitting(defender, target_key, raw_hp * vuln, rules)
		if rec != null: result.hits.append(rec)
		result.impulseNs += delivered_j * 0.004
		pass_through_hp = 0.0

	# Blow through the armour into something that matters.
	if pass_through_hp > 0.5:
		var internal_key = pick_internal(defender, rules, rng)
		if internal_key != null:
			var f = find_fitting(defender, internal_key)
			var vuln: float = J.g(d.vulnerability, f.part.category, 1.0)
			var rec = damage_fitting(defender, internal_key, pass_through_hp * vuln, rules)
			if rec != null:
				rec.throughArmor = true
				result.hits.append(rec)

	# Hitting things breaks your own weapon too. Spinners pay the most for it.
	if J.truthy(d.get("selfDamageOnHit")) and attacker.parts.get("weapon") != null:
		var self_hp: float = raw_hp * J.g(w, "selfDamageFraction", 0.1) * J.g(d.vulnerability, "weapon", 1.0)
		var rec = damage_fitting(attacker, "weapon", self_hp, rules)
		if rec != null: result.selfHit = rec

	# Summarise.
	var worst := "scratch"
	var failures := []
	for h in result.hits:
		if SEVERITY_ORDER[h.severity] > SEVERITY_ORDER[worst]: worst = h.severity
		if h.failed: failures.append(h)
	result.severity = worst
	result.failures = failures
	result.energyConsumedJ = delivered_j
	return result

## Resolve a ram - two bots colliding with no weapon involved. Deliberately
## much weaker per joule than a weapon hit; below `minRamEnergyJ` nothing
## happens at all.
static func resolve_ram(o: Dictionary) -> Dictionary:
	var attacker: Dictionary = o.attacker
	var defender: Dictionary = o.defender
	var target_key = o.get("targetKey")
	var rules: Dictionary = o.rules
	var d: Dictionary = rules.damage
	var mass_kg: float = minf(attacker.massKg, defender.massKg)
	var energy_j := kinetic_energy_j(mass_kg, o.relativeSpeedMps)

	if energy_j < d.minRamEnergyJ:
		return {"deliveredJ": 0.0, "hits": [], "severity": "none", "failures": [], "impulseNs": 0.0, "ignored": true}

	# A wedge rams better than a flat face.
	var concentration: float = attacker.stats.weapon.concentration
	if concentration == 0.0: concentration = 0.4
	var raw_hp: float = (energy_j / 1000.0) * d.rammingHpPerKilojoule * concentration

	var result := {"deliveredJ": energy_j, "rawHp": raw_hp, "hits": [], "selfHit": null, "failures": [], "impulseNs": energy_j * 0.002}
	var struck = find_fitting(defender, target_key)
	var vuln: float = J.g(d.vulnerability, struck.part.category if struck != null else "chassis", 1.0)

	var rec = damage_fitting(defender, target_key if J.truthy(target_key) else "chassis", raw_hp * vuln, rules)
	if rec != null: result.hits.append(rec)

	result.severity = rec.severity if rec != null else "none"
	result.failures = result.hits.filter(func(h): return h.failed)
	return result

## Restore everything to factory condition - used by the pit and by tests.
static func repair_all(assembled: Dictionary) -> void:
	for f in assembled.fittings: assembled.condition[f.key] = 1.0
