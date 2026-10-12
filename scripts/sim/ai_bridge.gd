## ai_bridge.gd - physics state -> the plain perception logic/ai.gd reads.
##
## The AI lives in logic and so may not touch the physics engine or the
## hazard objects. This is the one place that looks at them on its behalf and
## flattens them into numbers. Positions are Vector2 on the floor: (x, z).
class_name AIBridge

## Front-mounted weapons: the end of the bot you do not want to meet.
const FRONT_WEAPONS := ["spinner_v", "drum", "hammer", "flipper", "lifter", "crusher", "static"]
const VITAL := ["chassis", "electronics", "motor", "battery", "drive", "wheel"]

## One bot as the AI sees it.
static func perceive_bot(sim: RobotSim, weapon: Weapon) -> Dictionary:
	var a: Dictionary = sim.assembled
	var t := sim.global_position
	var v := sim.linear_velocity
	var eff := sim.effective()
	var ws: Dictionary = a.stats.weapon
	var wheels_down := 0
	for w in sim.telemetry:
		if w.grounded: wheels_down += 1
	return {
		"id": a.id,
		"pos": Vector2(t.x, t.z),
		"vel": Vector2(v.x, v.z),
		# Heading of the robot's nose, read off its forward axis so it stays
		# right when an invertible bot is running on its back.
		"yaw": sim.heading(),
		"speed": Vector2(v.x, v.z).length(),
		"yawRate": sim.angular_velocity.y,
		"wheelsDown": wheels_down,
		"upright": sim.uprightness(),
		"inverted": sim.inverted,
		"canSelfRight": sim.can_self_right(),
		"archetype": a.get("archetype"),
		"family": weapon.family if weapon != null else "none",
		"weaponReady": weapon != null and weapon.ready,
		"weaponPhase": weapon.phase if weapon != null else "idle",
		"weaponDead": J.truthy(J.path(eff, ["weapon", "dead"])),
		"spinPct": weapon.spinPct if weapon != null else 0.0,
		"energyJ": weapon.energyJ if weapon != null else 0.0,
		# Horizontal spinners hit across their whole front arc and much of
		# their sides; everything else only matters from straight ahead.
		"frontWeapon": FRONT_WEAPONS.has(ws["class"]) or ws["class"] == "spinner_h",
		"reachM": J.g(ws, "reachM", 0.15),
		"halfLenM": a.dims.lengthM / 2.0,
		"health": health_of(a),
		"topSpeed": J.g(eff, "topSpeedMps", a.stats.topSpeedMps),
	}

## Hazards as danger zones: { kind, center, radius, danger 0..1, segment? }.
## `remaining_s` lets the AI see killsaws that are ABOUT to come up.
static func perceive_hazards(hazards: Hazards, remaining_s: float) -> Array:
	var out := []
	var up_next := hazards.killsaw_active_at(remaining_s - 0.6)
	for h in hazards.all:
		if h.type == "pulverizer" or h.type == "hammer":
			var danger := 0.15
			if h.state == Hazards.ARMED or h.state == Hazards.SWINGING: danger = 1.0
			elif h.state == Hazards.RETRACTING: danger = 0.5
			out.append({"kind": "pulverizer", "center": Vector2(U.ft_to_m(h.def.pos[0]), U.ft_to_m(h.def.pos[2])),
				"radius": U.ft_to_m(h.def.headSize[0]) * 0.6, "danger": danger})
		elif h.type == "killsaw":
			var p: Dictionary = h.pieces[0]
			var danger: float = maxf(h.travel, 0.9 if up_next.has(h.id) else 0.0)
			if danger < 0.05: continue
			out.append({"kind": "killsaw", "center": Vector2(p.pos.x, p.pos.z), "radius": p.slotLength / 2.0, "danger": danger})
		elif h.type == "pit":
			# Nothing to fear until the lights start flashing; once it is
			# going down, the most dangerous thing in the box - and the best
			# place to shove the other robot.
			var danger: float = 1.0 if h.travel > 0.0 else (0.4 + 0.5 * h.warning if h.warning > 0.0 else 0.0)
			if danger < 0.05: continue
			var r: Dictionary = h.rect
			out.append({"kind": "pit", "center": Vector2(r.cx, r.cz), "radius": maxf(r.hw, r.hl) * 1.05, "danger": danger})
		elif h.type == "screw":
			var p: Dictionary = h.pieces[0]
			var half: float = p.length / 2.0
			var d := Vector2(sin(p.yaw) * half, cos(p.yaw) * half)
			var c := Vector2(p.pos.x, p.pos.z)
			out.append({"kind": "screw", "center": c, "segment": [c - d, c + d], "radius": p.spacing / 2.0 + p.radius, "danger": 0.6})
	return out

## How much robot is left, 0..1: the hp-weighted average of every part,
## pulled down hard by the worst of the parts that keep it in the fight. A bot
## with perfect armour and a dying battery is not healthy.
static func health_of(assembled: Dictionary) -> float:
	var have := 0.0
	var full := 0.0
	var worst_vital := 1.0
	for f in assembled.fittings:
		var c: float = J.g(assembled.condition, f.key, 1.0)
		have += f.part.hp * c
		full += f.part.hp
		if VITAL.has(f.part.category): worst_vital = minf(worst_vital, c)
	var avg := have / full if full > 0.0 else 1.0
	return 0.6 * avg + 0.4 * worst_vital

## Everything one AI needs for one decision. `lead`: -1..1, who the judges
## would favour right now (scorebook.lead).
static func perceive(self_sim: RobotSim, self_weapon: Weapon, opp_sim: RobotSim, opp_weapon: Weapon, hazards: Hazards,
		arena_dims: Dictionary, remaining_s = null, lead := 0.0) -> Dictionary:
	return {
		"me": perceive_bot(self_sim, self_weapon),
		"opponent": perceive_bot(opp_sim, opp_weapon),
		"hazards": perceive_hazards(hazards, remaining_s if remaining_s != null else 999.0),
		"arena": {"halfX": arena_dims.halfX, "halfZ": arena_dims.halfZ},
		"remainingS": remaining_s,
		"lead": lead,
	}
