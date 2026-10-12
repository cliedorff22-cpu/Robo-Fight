## build.gd - assemble a robot from part ids into derived stats, and judge it
## against the rulebook.
##
## The heart of the data-driven design: a robot JSON file names parts, and
## everything the simulation needs (mass, inertia, top speed, tractive force,
## armour rating) is COMPUTED here from part specs. No robot file ever states
## its own top speed.
##
## Pure logic: no nodes, no physics. An assembled robot is a Dictionary.
class_name Build

const GRAVITY := 9.81

# Armour and structure sit on the perimeter, so a battlebot's real rotational
# inertia runs above the uniform-solid-box figure.
const INERTIA_PERIMETER_FACTOR := 1.18

## Internal parts that a blow through the armour can find (damage.gd).
const INTERNAL_PARTS := ["electronics", "battery", "motor", "drive", "weaponMotor", "srimech", "chassis"]

const SINGLE_SLOTS := ["chassis", "drive", "wheel", "motor", "battery", "electronics", "weaponMotor", "weapon", "srimech"]

static func round2(n: float) -> float:
	return J.rnd(n * 100.0) / 100.0

## Assemble a robot definition into a full, simulation-ready description.
##
## Everything derived from the parts alone (stats, fittings, the legality
## check) is worked out once per distinct build and shared between the robots
## assembled from it: treat `parts`, `fittings`, `stats`, `dims`, `inertia`
## and `legality` as read-only. `condition` is each robot's own.
static func assemble_robot(reg: Registry, robot_def: Dictionary) -> Dictionary:
	var b: Dictionary = robot_def.build
	var key := "asm:" + JSON.stringify(b)
	var core = reg.cache_get(key)
	if core == null:
		core = _assemble_core(reg, robot_def)
		reg.cache_set(key, core)
	return {
		"id": robot_def.id,
		"name": robot_def.get("name"),
		"number": robot_def.get("number"),
		"livery": robot_def.get("livery"),
		"archetype": robot_def.get("archetype"),
		"personality": robot_def.get("personality"),
		"def": robot_def,
		"parts": core.parts,
		# Fitting list drives condition, damage routing and the pit report.
		"fittings": core.fittings,
		"weightLb": core.weightLb,
		"massKg": core.massKg,
		"dims": core.dims,
		"comLocalM": core.comLocalM,
		"inertia": core.inertia,
		"stats": core.stats,
		"fittingMap": core.fittingMap,
		"armorSlots": core.armorSlots,
		"internals": core.internals,
		# Persistent part condition, 1.0 = factory fresh. It lives on the
		# robot, not the match, so it survives between fights.
		"condition": core.condition.duplicate(),
		"legality": core.legality,
	}

## Will this build assemble at all (every part known and in its right slot)?
static func can_assemble(reg: Registry, robot_def: Dictionary) -> bool:
	var b = robot_def.get("build")
	if not (b is Dictionary): return false
	for slot in ["chassis", "drive", "wheel", "motor", "battery", "electronics"]:
		if not J.truthy(b.get(slot)): return false
	for slot in SINGLE_SLOTS:
		var id = b.get(slot)
		if not J.truthy(id): continue
		if not reg.has_part(id) or reg.part(id).category != slot: return false
	for id in b.get("armor", []):
		if not reg.has_part(id) or reg.part(id).category != "armor": return false
	return true

static func _assemble_core(reg: Registry, robot_def: Dictionary) -> Dictionary:
	var b: Dictionary = robot_def.build
	var parts := {}
	for slot in SINGLE_SLOTS:
		var id = b.get(slot)
		if id == null or (id is String and id == ""):
			parts[slot] = null
			continue
		var p := reg.part(id)
		assert(p.category == slot, "%s: part \"%s\" is category \"%s\", expected \"%s\"" % [robot_def.id, id, p.category, slot])
		parts[slot] = p
	var armor := []
	for id in b.get("armor", []):
		var p := reg.part(id)
		assert(p.category == "armor", "%s: armour slot holds \"%s\" of category \"%s\"" % [robot_def.id, id, p.category])
		armor.append(p)
	parts.armor = armor

	var weight_lb := total_weight_lb(parts)
	var mass_kg := U.lb_to_kg(weight_lb)
	var dims := chassis_dims(parts.chassis)
	var core := {
		"parts": parts,
		"fittings": fittings(parts),
		"weightLb": weight_lb,
		"massKg": mass_kg,
		"dims": dims,
		"comLocalM": chassis_com(parts.chassis),
		"inertia": box_inertia(mass_kg, dims),
		"stats": derive_stats(parts, mass_kg, dims),
		"condition": fresh_condition(parts),
	}
	# Lookups the fight code leans on: a fitting by its key, and the armour
	# panels with the face each covers.
	var fmap := {}
	var armour := []
	for f in core.fittings:
		fmap[f.key] = f
		if f.part.category == "armor": armour.append([f.key, f.part.spec.slot])
	core.fittingMap = fmap
	core.armorSlots = armour
	var internals := []
	for f in core.fittings:
		if INTERNAL_PARTS.has(f.part.category): internals.append(f)
	core.internals = internals
	core.legality = check_legality(reg, core)
	return core

## The second robot of a multibot, assembled as a robot in its own right.
static func assemble_partner(reg: Registry, robot_def: Dictionary):
	var p = robot_def.get("partner")
	if p == null: return null
	var d := robot_def.duplicate()
	var pname = p.get("name")
	d.id = "%s__%s" % [robot_def.id, _partner_slug(pname if pname else "b")]
	d.name = pname if pname else "%s B" % robot_def.name
	d.body = p.get("body")
	d.build = p.build
	d.erase("partner")
	d.unitOf = robot_def.id
	return assemble_robot(reg, d)

# toLowerCase().replace(/[^a-z0-9]+/g, "_")
static func _partner_slug(s: String) -> String:
	return J.slug(s)

## A multibot's units together must make weight, like any single robot.
static func check_multibot_weight(reg: Registry, a: Dictionary, b: Dictionary) -> Array:
	var cap: float = reg.rules.weightClass.cap
	var tolerance: float = reg.rules.weightClass.tolerance
	var total := round2(a.weightLb + b.weightLb)
	if total > cap + tolerance:
		return ["Multibot overweight: %s + %s = %s lb exceeds the %s lb cap." % [J.num(a.weightLb), J.num(b.weightLb), J.num(total), J.num(cap)]]
	return []

## Every part in the loadout as {key, part} pairs. `key` identifies the
## FITTING, not the part type: twin side panels are "armor.0" and "armor.1".
static func fittings(parts: Dictionary) -> Array:
	var out := []
	for slot in SINGLE_SLOTS:
		if parts.get(slot) != null:
			out.append({"key": slot, "part": parts[slot]})
	var i := 0
	for p in parts.armor:
		out.append({"key": "armor.%d" % i, "part": p})
		i += 1
	return out

## Just the parts, for sums that do not care which fitting they came from.
static func part_list(parts: Dictionary) -> Array:
	return fittings(parts).map(func(f): return f.part)

static func total_weight_lb(parts: Dictionary) -> float:
	var sum := 0.0
	for f in fittings(parts): sum += f.part.weight
	return round2(sum)

static func fresh_condition(parts: Dictionary) -> Dictionary:
	var c := {}
	for f in fittings(parts): c[f.key] = 1.0
	return c

static func chassis_dims(chassis: Dictionary) -> Dictionary:
	var s: Array = chassis.spec.sizeIn
	return {"lengthM": U.in_to_m(s[0]), "heightM": U.in_to_m(s[1]), "widthM": U.in_to_m(s[2])}

static func chassis_com(chassis: Dictionary) -> Dictionary:
	var c: Array = chassis.spec.get("comLocalIn", [0, 0, 0])
	return {"x": U.in_to_m(c[0]), "y": U.in_to_m(c[1]), "z": U.in_to_m(c[2])}

## Principal inertia of a box about its centre of mass, scaled for perimeter mass.
static func box_inertia(mass_kg: float, dims: Dictionary) -> Dictionary:
	var L: float = dims.lengthM
	var H: float = dims.heightM
	var W: float = dims.widthM
	var k := (mass_kg / 12.0) * INERTIA_PERIMETER_FACTOR
	return {
		"x": k * (H * H + W * W),   # roll
		"y": k * (L * L + W * W),   # yaw - the one skid steering fights
		"z": k * (L * L + H * H),   # pitch
	}

## Drivetrain and protection numbers, all computed from part specs.
static func derive_stats(parts: Dictionary, mass_kg: float, dims: Dictionary) -> Dictionary:
	var drive: Dictionary = parts.drive.spec
	var wheel: Dictionary = parts.wheel.spec
	var motor: Dictionary = parts.motor.spec
	var chassis_clearance_in: float = J.g(parts.chassis.spec, "groundClearanceIn", 0.75)

	var wheel_radius_m := U.in_to_m(wheel.diameterIn / 2.0)
	var driven_wheels: float = minf(drive.wheelCount, wheel.count)

	# Free-running top speed: motor rpm through the reduction, at the rim.
	var wheel_rpm: float = motor.maxRpm / drive.gearRatio
	var top_speed_mps := (wheel_rpm / 60.0) * 2.0 * PI * wheel_radius_m

	# Torque at one wheel, and the force that puts on the floor.
	var wheel_torque_nm: float = motor.maxTorqueNm * drive.gearRatio * drive.efficiency
	var force_per_wheel_n := wheel_torque_nm / wheel_radius_m
	var tractive_force_n := force_per_wheel_n * driven_wheels

	# Real acceleration is whichever runs out first: torque or grip.
	var grip_limit_n: float = wheel.grip * mass_kg * GRAVITY
	var usable_force_n := minf(tractive_force_n, grip_limit_n)

	var armor_hp := 0.0
	var armor_rating := 0.0
	for a in parts.armor:
		armor_hp += a.hp
		armor_rating += a.hp * a.spec.hardness

	var stats := {
		"wheelRadiusM": wheel_radius_m,
		"wheelWidthM": U.in_to_m(wheel.widthIn),
		"wheelCount": wheel.count,
		"drivenWheels": driven_wheels,
		"grip": wheel.grip,
		"gearRatio": drive.gearRatio,
		"steering": drive.steering,

		"topSpeedMps": top_speed_mps,
		"topSpeedMph": U.mps_to_mph(top_speed_mps),
		"wheelTorqueNm": wheel_torque_nm,
		"forcePerWheelN": force_per_wheel_n,
		"tractiveForceN": tractive_force_n,
		"gripLimitN": grip_limit_n,
		"accelMps2": usable_force_n / mass_kg,
		# Push-vs-weight, the number drivers actually care about in a shoving match.
		"pushRatio": usable_force_n / (mass_kg * GRAVITY),

		"armorHp": armor_hp,
		"armorRating": armor_rating,
		"chassisHp": parts.chassis.hp,
		"reliability": parts.electronics.spec.reliability,
		"powerWh": parts.battery.spec.capacityWh,
		"weapon": derive_weapon(parts.get("weapon"), parts.get("weaponMotor")),
		"selfRight": derive_self_right(parts),

		# Ride height is a PROPERTY OF THE CHASSIS, declared in parts.json.
		"groundClearanceM": U.in_to_m(chassis_clearance_in),
		# Suspension travel is mostly tyre squish, so it is a wheel property.
		"suspensionTravelM": U.in_to_m(J.g(wheel, "suspensionTravelIn", 0.5)),
		"lateralGripFraction": J.g(wheel, "lateralGripFactor", 0.85),

		# Wheel layout, derived here so the physics and these figures cannot disagree.
		"trackHalfM": dims.widthM / 2.0 + U.in_to_m(wheel.widthIn) * 0.45,
		"wheelbaseHalfM": dims.lengthM * 0.30,
		"maxYawRateRadS": U.deg_to_rad(J.g(drive, "maxYawRateDegS", 420)),
	}

	# Can this build actually turn? Pivoting a skid-steer bot pits the drive
	# torque about the yaw axis against the lateral grip of every wheel
	# resisting the scrub.
	var pivot_drive: float = stats.drivenWheels * stats.forcePerWheelN * stats.trackHalfM
	var pivot_resist: float = stats.grip * stats.lateralGripFraction * mass_kg * GRAVITY * stats.wheelbaseHalfM
	stats.pivotDriveTorqueNm = pivot_drive
	stats.pivotResistTorqueNm = pivot_resist
	stats.pivotAuthority = pivot_drive / pivot_resist if pivot_resist > 0 else INF
	return stats

## What a weapon actually does, derived from its physical spec. A spinner's
## energy comes from its rotor inertia and tip speed; how long it takes to
## reach it comes from the weapon motor's power.
static func derive_weapon(weapon, weapon_motor) -> Dictionary:
	if weapon == null:
		return {"class": "none", "powered": false, "energyJ": 0.0, "concentration": 0.0, "spinUpS": 0.0}
	var w: Dictionary = weapon.spec
	var cls: String = w["class"]
	var out := {
		"class": cls,
		"powered": J.truthy(w.get("powered")),
		"concentration": J.g(w, "concentration", 1.0),
		"selfDamageFraction": J.g(w, "selfDamageFraction", 0.1),
		"gyroEffect": J.g(w, "gyroEffect", 0.0),
		"energyJ": 0.0,
		"tipSpeedMps": 0.0,
		"maxOmegaRadS": 0.0,
		"rotorInertiaKgM2": J.g(w, "rotorInertiaKgM2", 0.0),
		"spinUpS": 0.0,
		"spinDownS": 0.0,
		"cycleS": J.g(w, "cycleS", 0.0),
		"charges": J.g(w, "charges", INF),
		"impulseNs": J.g(w, "impulseNs", 0.0),
	}

	if cls == "spinner_h" or cls == "spinner_v" or cls == "drum":
		# Kinetic store: E = 1/2 I omega^2, with omega set by tip speed at the rim.
		var radius_m := U.in_to_m(w.radiusIn)
		var omega: float = w.maxTipSpeedMps / radius_m if radius_m > 0 else 0.0
		out.maxOmegaRadS = omega
		out.tipSpeedMps = w.maxTipSpeedMps
		out.energyJ = 0.5 * w.rotorInertiaKgM2 * omega * omega
		out.radiusM = radius_m
		# Spin-up is energy divided by the power the motor can actually put in.
		var power_w: float = weapon_motor.spec.powerW * weapon_motor.spec.efficiency if weapon_motor != null else 0.0
		out.motorPowerW = power_w
		out.spinUpS = out.energyJ / power_w if power_w > 0 else INF
		# Coasting down takes longer than spinning up - nothing is braking it.
		out.spinDownS = out.spinUpS * 2.2
	elif cls == "hammer" or cls == "flipper" or cls == "lifter":
		# Discrete strike: the energy is whatever the actuator delivers per swing.
		out.energyJ = J.g(w, "impactEnergyJ", 0.0)
		out.reachM = U.in_to_m(J.g(w, "reachIn", 0.0))
		out.spinUpS = 0.0
	elif cls == "crusher":
		# A crusher applies force over a stroke: energy per bite = force x stroke.
		var stroke_m := U.in_to_m(J.g(w, "strokeIn", 1.0))
		out.energyJ = J.g(w, "crushForceN", 0.0) * stroke_m
		out.crushForceN = J.g(w, "crushForceN", 0.0)
		# How far ahead of the nose the jaw takes hold.
		out.reachM = U.in_to_m(J.g(w, "reachIn", 18.0)) * 0.45
		out.strokeM = stroke_m
		out.biteIntervalS = J.g(w, "biteIntervalS", 0.7)
		out.spinUpS = 0.0
	else:
		# Static: no stored energy. It damages only through ram energy.
		out.energyJ = 0.0
	return out

## Can this robot get itself back onto its wheels once flipped, and how hard
## does it push?
static func derive_self_right(parts: Dictionary) -> Dictionary:
	var sr = parts.get("srimech")
	if sr != null:
		return {"via": "srimech", "impulseNs": J.g(sr.spec, "impulseNs", 420.0), "cooldownS": J.g(sr.spec, "cooldownS", 2.5), "fitting": "srimech"}
	var wp = parts.get("weapon")
	var w = wp.spec if wp != null else null
	if w != null:
		var cls: String = w["class"]
		if cls == "flipper" or cls == "hammer" or cls == "lifter" or cls == "crusher":
			var impulse := 400.0
			if cls == "flipper": impulse = minf(560.0, J.g(w, "impulseNs", 600.0) * 0.6)
			elif cls == "hammer": impulse = 460.0
			elif cls == "crusher": impulse = 380.0
			return {"via": "weapon", "impulseNs": impulse, "cooldownS": maxf(1.2, J.g(w, "cycleS", 2.0)), "fitting": "weapon"}
		# A vertical disc or drum can throw itself back over on its rotor's
		# gyroscopic kick - but it is a scramble, not a sure thing.
		if J.truthy(w.get("powered")) and (cls == "spinner_v" or cls == "drum"):
			return {"via": "gyro", "impulseNs": 380.0, "cooldownS": 3.5, "chance": 0.55, "fitting": "weapon"}
	return {"via": "none", "impulseNs": 0.0, "cooldownS": 0.0, "fitting": null}

## Rulebook check. `errors` make a build illegal (cannot fight); `warnings`
## are legal but worth telling the player about.
static func check_legality(reg: Registry, a: Dictionary) -> Dictionary:
	var errors := []
	var warnings := []
	var weight_class: Dictionary = reg.rules.weightClass
	var legality: Dictionary = reg.rules.legality
	var cap_lb: float = weight_class.cap
	var limit_lb: float = cap_lb + weight_class.tolerance

	if a.weightLb > limit_lb:
		errors.append("Overweight: %s lb exceeds the %s lb cap." % [J.fixed(a.weightLb, 1), J.num(cap_lb)])
	elif a.weightLb > cap_lb - 2:
		warnings.append("Only %s lb under the cap - no room for repairs." % J.fixed(cap_lb - a.weightLb, 1))

	# Weapon legality, against the DERIVED output rather than a stated number.
	var weapon = a.parts.get("weapon")
	var wm = a.parts.get("weaponMotor")
	var wstats: Dictionary = a.stats.weapon
	if weapon != null:
		if legality.bannedWeaponClasses.has(wstats["class"]):
			errors.append("Banned weapon class: \"%s\"." % wstats["class"])
		if J.g(wstats, "tipSpeedMps", 0.0) > legality.maxWeaponTipSpeedMps:
			errors.append("Weapon tip speed %s m/s exceeds the %s m/s limit." % [J.fixed(wstats.tipSpeedMps, 0), J.num(legality.maxWeaponTipSpeedMps)])
		if wstats.energyJ > legality.maxWeaponEnergyJ:
			errors.append("Weapon energy %s kJ exceeds the %s kJ limit." % [J.fixed(wstats.energyJ / 1000.0, 1), J.fixed(legality.maxWeaponEnergyJ / 1000.0, 0)])
		# A powered weapon needs a motor, and the motor has to be up to the rotor.
		if wstats.powered and wm == null:
			errors.append("\"%s\" is a powered weapon but no weapon motor is fitted." % weapon.name)
		if wstats.powered and wm != null:
			var cap: float = wm.spec.maxEnergyJ
			if wstats.energyJ > cap:
				errors.append("\"%s\" is rated to %s kJ but \"%s\" stores %s kJ." % [wm.name, J.fixed(cap / 1000.0, 0), weapon.name, J.fixed(wstats.energyJ / 1000.0, 1)])
			if wstats.spinUpS > 20:
				warnings.append("Weapon takes %s s to reach full speed - most of the match." % J.fixed(wstats.spinUpS, 0))
		if not wstats.powered and wm != null:
			warnings.append("Weapon motor fitted but \"%s\" is unpowered - that is %s lb wasted." % [weapon.name, J.num(wm.weight)])
	else:
		warnings.append("No weapon fitted - this build can only push.")

	# Safety hardware.
	var ecu: Dictionary = a.parts.electronics.spec
	if J.truthy(legality.get("requireRemovableLink")) and not J.truthy(ecu.get("hasRemovableLink")):
		errors.append("Electronics lack a removable power link.")
	if J.truthy(legality.get("requirePowerSwitch")) and not J.truthy(ecu.get("hasPowerSwitch")):
		errors.append("Electronics lack a master power switch.")
	if a.parts.battery.spec.nominalV > legality.maxBatteryVoltageNominal:
		errors.append("Battery %s V exceeds the %s V limit." % [J.num(a.parts.battery.spec.nominalV), J.num(legality.maxBatteryVoltageNominal)])

	# Mechanical coherence.
	if a.parts.wheel.spec.count < a.parts.drive.spec.wheelCount:
		errors.append("Drive wants %s wheels but the wheel set has %s." % [J.num(a.parts.drive.spec.wheelCount), J.num(a.parts.wheel.spec.count)])
	if a.parts.motor.spec.count < a.parts.drive.spec.motorSlots:
		errors.append("Drive has %s motor slots but only %s motors are fitted." % [J.num(a.parts.drive.spec.motorSlots), J.num(a.parts.motor.spec.count)])
	if a.parts.motor.spec.role != "drive":
		errors.append("Motor \"%s\" is not a drive motor." % a.parts.motor.id)

	# Armour must fit the chassis' available slots.
	var allowed: Dictionary = J.g(a.parts.chassis.spec, "armorSlots", {})
	var used := {}
	for panel in a.parts.armor:
		var slot: String = panel.spec.slot
		used[slot] = used.get(slot, 0) + 1
	for slot in used:
		var mx: float = J.g(allowed, slot, 0)
		if used[slot] > mx:
			errors.append("Chassis takes %s \"%s\" armour panel(s) but %s are fitted." % [J.num(mx), slot, J.num(used[slot])])
	# A build that physically cannot pivot is legal but unusable.
	if a.stats.pivotAuthority < 1.0:
		errors.append("This build cannot turn: drive torque about the yaw axis (%s Nm) is below the grip resisting it (%s Nm). Drive more wheels, fit stronger motors, or use a narrower wheelbase." % [J.fixed(a.stats.pivotDriveTorqueNm, 0), J.fixed(a.stats.pivotResistTorqueNm, 0)])
	elif a.stats.pivotAuthority < 1.3:
		warnings.append("Turns poorly - only %sx the grip resisting a pivot." % J.fixed(a.stats.pivotAuthority, 2))

	if not used.has("front"): warnings.append("No front armour - the most-hit face is bare.")
	if not used.has("top"): warnings.append("No top armour - vulnerable to vertical spinners and hammers.")

	return {
		"legal": errors.size() == 0,
		"errors": errors,
		"warnings": warnings,
		"weightLb": a.weightLb,
		"capLb": cap_lb,
		"marginLb": round2(cap_lb - a.weightLb),
	}
