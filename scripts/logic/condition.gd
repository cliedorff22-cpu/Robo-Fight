## condition.gd - what a damaged robot can actually still do.
##
## Every part carries a persistent condition from 1.0 (factory fresh) to 0.0
## (destroyed), keyed by FITTING so twin panels degrade independently. This
## turns those numbers back into drive torque, grip, top speed, armour and
## weapon output. Pure logic; degradation floors all come from rules.json.
class_name Condition

const OK := "ok"
const IMPAIRED := "impaired"
const CRITICAL := "critical"
const FAILED := "failed"

## Which band a condition value falls into.
static func part_status(condition: float, thresholds: Dictionary) -> String:
	if condition <= thresholds.failed: return FAILED
	if condition < thresholds.critical: return CRITICAL
	if condition < thresholds.impaired: return IMPAIRED
	return OK

## Linear fade from a floor at zero condition up to full at 1.0.
static func degrade(condition: float, floor_v: float) -> float:
	return floor_v + (1.0 - floor_v) * J.clamp01(condition)

static func cond_of(c: Dictionary, key: String) -> float:
	var v = c.get(key)
	return 1.0 if v == null else J.clamp01(v)

## Effective stats for a robot in its current condition. Returns a NEW
## dictionary; `assembled.stats` stays the pristine rated figures.
static func effective_stats(assembled: Dictionary, rules: Dictionary) -> Dictionary:
	var d: Dictionary = rules.damage
	var th: Dictionary = d.thresholds
	var c: Dictionary = assembled.condition
	var base: Dictionary = assembled.stats
	var dg: Dictionary = d.degrade

	var wheel_c := cond_of(c, "wheel")
	var motor_c := cond_of(c, "motor")
	var drive_c := cond_of(c, "drive")
	var batt_c := cond_of(c, "battery")
	var elec_c := cond_of(c, "electronics")
	var chassis_c := cond_of(c, "chassis")
	var has_weapon: bool = assembled.parts.get("weapon") != null
	var has_wmotor: bool = assembled.parts.get("weaponMotor") != null
	var weapon_c := cond_of(c, "weapon") if has_weapon else 0.0
	var wmotor_c := cond_of(c, "weaponMotor") if has_wmotor else 0.0

	# --- drivetrain
	var motor_factor := degrade(motor_c, dg.motorTorque)
	var drive_factor := degrade(drive_c, dg.driveTorque)
	var batt_factor := degrade(batt_c, dg.batteryPower)

	# Wheels are a SET, so condition thins the set out, rounding up.
	var wheels_remaining: float = ceil(wheel_c * base.wheelCount)
	var driven_remaining: float = minf(base.drivenWheels, wheels_remaining)

	var grip_factor := degrade(wheel_c, dg.wheelGrip)
	var force_per_wheel_n: float = base.forcePerWheelN * motor_factor * drive_factor * batt_factor

	# Top speed is voltage-limited, so only the battery drags it down.
	var top_speed_mps: float = base.topSpeedMps * batt_factor

	# --- armour, per fitting
	var armor_remaining := {}
	var armor_hp := 0.0
	for f in assembled.fittings:
		if f.part.category != "armor": continue
		var hp: float = f.part.hp * degrade(cond_of(c, f.key), dg.armorProtection)
		armor_remaining[f.key] = hp
		armor_hp += hp

	# --- weapon. A bent rotor stores less; a dead weapon motor never spins it.
	var w: Dictionary = base.weapon
	var weapon_energy_j: float = w.energyJ * degrade(weapon_c, dg.weaponOutput)
	var weapon_motor_power_w: float = J.g(w, "motorPowerW", 0.0) * degrade(wmotor_c, dg.motorTorque)
	var weapon_dead: bool = (not has_weapon) or weapon_c <= th.failed or (w.powered and wmotor_c <= th.failed)
	var spin_up_s: float = weapon_energy_j / weapon_motor_power_w if weapon_motor_power_w > 0 else INF

	# --- electronics. A dying radio stutters before it quits.
	var control_reliability := J.clamp01(elec_c)
	var dropout_hz: float = d.electronicsDropoutHz * (1.0 - control_reliability)

	# --- is this bot still a going concern?
	var chassis_gone: bool = J.truthy(d.get("chassisKillsBot")) and chassis_c <= th.failed
	var electronics_gone: bool = elec_c <= th.failed
	var no_wheels := wheels_remaining <= 0
	var immobile := chassis_gone or electronics_gone or no_wheels

	var out := base.duplicate()
	out.forcePerWheelN = force_per_wheel_n
	out.tractiveForceN = force_per_wheel_n * driven_remaining
	out.topSpeedMps = top_speed_mps
	out.grip = base.grip * grip_factor
	out.gripLimitN = base.gripLimitN * grip_factor
	out.wheelCount = wheels_remaining
	out.drivenWheels = driven_remaining
	out.wheelsLost = base.wheelCount - wheels_remaining
	out.accelMps2 = minf(force_per_wheel_n * driven_remaining, base.gripLimitN * grip_factor) / assembled.massKg
	out.armorHp = armor_hp
	out.armorRemainingHp = armor_remaining

	var ew := w.duplicate()
	ew.energyJ = 0.0 if weapon_dead else weapon_energy_j
	ew.motorPowerW = weapon_motor_power_w
	ew.spinUpS = spin_up_s
	ew.dead = weapon_dead
	out.weapon = ew

	out.controlReliability = control_reliability
	out.dropoutHz = dropout_hz
	out.dropoutS = d.electronicsDropoutS
	out.immobile = immobile
	out.chassisGone = chassis_gone
	out.electronicsGone = electronics_gone
	# Pivot authority has to be recomputed: fewer driven wheels and less grip
	# move both sides of that balance.
	out.pivotAuthority = _pivot_authority(assembled, force_per_wheel_n, driven_remaining, grip_factor)
	return out

static func _pivot_authority(assembled: Dictionary, force_per_wheel_n: float, driven_wheels: float, grip_factor: float) -> float:
	var s: Dictionary = assembled.stats
	var drive: float = driven_wheels * force_per_wheel_n * s.trackHalfM
	var resist: float = s.grip * grip_factor * s.lateralGripFraction * assembled.massKg * 9.81 * s.wheelbaseHalfM
	return drive / resist if resist > 0 else INF

## Per-fitting condition report - what the pit screen shows, and what the HUD
## damage panel reads from.
static func condition_report(assembled: Dictionary, rules: Dictionary) -> Array:
	var th: Dictionary = rules.damage.thresholds
	var out := []
	for f in assembled.fittings:
		var condition: float = J.g(assembled.condition, f.key, 1.0)
		out.append({
			"key": f.key,
			"partId": f.part.id,
			"name": f.part.name,
			"category": f.part.category,
			"condition": condition,
			"status": part_status(condition, th),
			"hpRemaining": f.part.hp * condition,
			"hpFull": f.part.hp,
			"repairCost": J.rnd(f.part.hp * (1.0 - condition) * f.part.repairCostPerHp),
			"repairMinutes": J.rnd(f.part.hp * (1.0 - condition) * f.part.repairMinPerHp),
		})
	return out

## Worst-affected fittings first - for a damage report that leads with the news.
static func worst_first(report: Array) -> Array:
	return J.sorted(report, func(a, b): return a.condition - b.condition)

## Total value of the damage on a robot, in repair currency.
static func repair_bill(report: Array) -> float:
	var sum := 0.0
	for r in report: sum += r.repairCost
	return sum
