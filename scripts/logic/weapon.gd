## weapon.gd - weapon state over time.
##
## Pure logic, advanced by a dt. Three families:
##   kinetic  (spinner_h, spinner_v, drum)  stores energy in a rotor, spools up
##            over seconds, and LOSES that energy when it lands a hit
##   discrete (hammer, flipper, lifter)     a fixed strike per cycle, with a
##            reload, and in the flipper's case a limited number of charges
##   crusher                                closes a jaw and applies damage
##            while held
##
## A kinetic weapon's stored energy is real: spool a bar to 15 kJ, land a hit,
## and you are down to a few kJ and need another eight seconds.
class_name Weapon
extends RefCounted

const IDLE := "idle"
const SPOOLING := "spooling"
const READY := "ready"
const STRIKING := "striking"
const RELOADING := "reloading"
const CLOSED := "closed"
const DEAD := "dead"

const KINETIC := "kinetic"
const DISCRETE := "discrete"
const CRUSHER := "crusher"
const NONE := "none"

static func family_of(weapon_class) -> String:
	if weapon_class == "spinner_h" or weapon_class == "spinner_v" or weapon_class == "drum": return KINETIC
	if weapon_class == "hammer" or weapon_class == "flipper" or weapon_class == "lifter": return DISCRETE
	if weapon_class == "crusher": return CRUSHER
	return NONE

var assembled: Dictionary
var spec = null
var family: String = NONE

var phase: String = IDLE
var energyJ := 0.0          # kinetic: energy stored right now
var omegaRadS := 0.0        # kinetic: implied rotor speed
var chargesLeft: float = INF
var timerS := 0.0           # time in the current phase
var sinceBiteS := 0.0       # crusher: time since it last bit
var spinPct := 0.0          # 0..1 of full energy, for the HUD
var struckThisStep := false
# Discrete: a swing started by the trigger that has not connected yet.
var unspent := false

func _init(assembled_robot: Dictionary, _rules = null) -> void:
	assembled = assembled_robot
	var wp = assembled.parts.get("weapon")
	spec = wp.spec if wp != null else null
	family = family_of(assembled.stats.weapon["class"])
	chargesLeft = J.g(assembled.stats.weapon, "charges", INF)

static func make(assembled_robot: Dictionary, rules = null) -> Weapon:
	return Weapon.new(assembled_robot, rules)

var ready: bool:
	get: return phase == READY or phase == CLOSED

## Would a contact with the weapon right now be a weapon hit? A hammer or
## flipper only has energy mid-swing, so for those it is "a triggered swing
## that has not connected yet".
var armed: bool:
	get:
		if family == DISCRETE:
			return unspent if phase == STRIKING else energyJ > 0
		return energyJ > 0

## Rotor speed implied by stored energy: omega = sqrt(2E/I).
static func omega_for(energy_j: float, inertia: float) -> float:
	return sqrt(maxf(0.0, 2.0 * energy_j) / inertia) if inertia > 0 else 0.0

## Advance the weapon. `demand` 0..1, `effective` = Condition.effective_stats().
func update(dt: float, demand: float, effective: Dictionary) -> void:
	var ew: Dictionary = effective.weapon
	struckThisStep = false

	if family == NONE:
		phase = IDLE
		return

	if ew.dead:
		# Dead weapon: bleed off whatever is still spinning and stay dead.
		phase = DEAD
		energyJ = maxf(0.0, energyJ - energyJ * dt)
		omegaRadS = omega_for(energyJ, ew.rotorInertiaKgM2)
		spinPct = 0.0
		return

	if family == KINETIC:
		var max_e: float = ew.energyJ
		var spin_up: float = maxf(0.0001, ew.spinUpS)
		var sd: float = J.g(ew, "spinDownS", 0.0)
		var spin_down: float = maxf(0.0001, sd if sd != 0.0 else spin_up * 2.2)
		var d := J.clamp01(demand)
		# Under power the motor overcomes bearing and air drag, so spin-up
		# takes exactly the derived spinUpS. Drag only bites as you ease off.
		var power_in_w := (max_e / spin_up) * d
		var drag_w := (energyJ / spin_down) * (1.0 - d)
		energyJ = clampf(energyJ + (power_in_w - drag_w) * dt, 0.0, max_e)
		omegaRadS = omega_for(energyJ, ew.rotorInertiaKgM2)
		spinPct = energyJ / max_e if max_e > 0 else 0.0
		phase = READY if spinPct > 0.98 else (SPOOLING if spinPct > 0.02 else IDLE)
		return

	if family == DISCRETE:
		timerS += dt
		var swing_s: float = J.g(spec, "swingS", J.g(spec, "fireS", 0.2))
		var cycle_s: float = J.g(spec, "cycleS", 2.0)

		# The trigger fires the weapon whether or not anything is there - a
		# whiffed hammer costs its reload just like a real one.
		if demand > 0.5 and phase == READY and chargesLeft > 0:
			phase = STRIKING
			timerS = 0.0
			unspent = true
			if not is_inf(chargesLeft): chargesLeft -= 1

		if phase == STRIKING and timerS >= swing_s:
			phase = RELOADING; timerS = 0.0
		elif phase == RELOADING and timerS >= cycle_s:
			phase = READY; timerS = 0.0
		elif phase == IDLE:
			phase = READY

		if chargesLeft <= 0: phase = DEAD
		energyJ = ew.energyJ if phase == STRIKING else 0.0
		spinPct = 1.0 if phase == READY else (J.clamp01(timerS / cycle_s) if phase == RELOADING else 0.0)
		return

	if family == CRUSHER:
		timerS += dt
		sinceBiteS += dt
		var close_s: float = J.g(spec, "closeS", 1.0)
		var cycle_s: float = J.g(spec, "cycleS", 3.0)
		var holding := demand > 0.5

		if holding and phase != CLOSED and phase != RELOADING:
			if phase != STRIKING:
				phase = STRIKING; timerS = 0.0
			elif timerS >= close_s:
				phase = CLOSED; timerS = 0.0
		elif phase == CLOSED and not holding:
			phase = RELOADING; timerS = 0.0
		elif phase == RELOADING and timerS >= cycle_s:
			phase = READY; timerS = 0.0
		elif phase == IDLE:
			phase = READY

		# A closed jaw keeps working, so it delivers energy per second held.
		energyJ = ew.energyJ if phase == CLOSED else 0.0
		spinPct = 1.0 if phase == CLOSED else J.clamp01(timerS / close_s)
		return

## Try to land a hit. Returns the energy available for Damage.resolve_hit, or 0.
## A kinetic weapon loses its energy in absorb_recoil once the hit is resolved.
func strike(effective: Dictionary) -> float:
	var ew: Dictionary = effective.weapon
	if ew.dead: return 0.0

	if family == KINETIC:
		return energyJ
	if family == DISCRETE:
		# A triggered swing connecting.
		if phase == STRIKING and unspent:
			unspent = false
			struckThisStep = true
			return ew.energyJ
		# Contact with a cocked weapon fires it on the spot.
		if phase != READY or chargesLeft <= 0: return 0.0
		unspent = false
		phase = STRIKING
		timerS = 0.0
		struckThisStep = true
		if not is_inf(chargesLeft): chargesLeft -= 1
		return ew.energyJ
	if family == CRUSHER:
		# A closed jaw keeps working, but it bites at a rate.
		if phase != CLOSED: return 0.0
		var interval: float = J.g(ew, "biteIntervalS", 0.7)
		if sinceBiteS < interval: return 0.0
		sinceBiteS = 0.0
		struckThisStep = true
		return ew.energyJ
	return 0.0

## Energy leaves the rotor when it lands: a big hit costs you your spin-up.
func absorb_recoil(delivered_j: float) -> void:
	if family != KINETIC: return
	energyJ = maxf(0.0, energyJ - delivered_j)
	spinPct = 0.0
	struckThisStep = true

## Called between matches - the rotor is not still spinning in the pit.
func reset() -> void:
	phase = IDLE
	energyJ = 0.0
	omegaRadS = 0.0
	timerS = 0.0
	sinceBiteS = 0.0
	spinPct = 0.0
	unspent = false
	chargesLeft = J.g(assembled.stats.weapon, "charges", INF)
