## catalog.gd - the robot list the menus show: who is in the field, sorted and
## filtered, and a one-glance spec card per robot.
##
## Pure logic: registry in, plain dictionaries out.
class_name Catalog

const LEAGUE_ORDER := ["world", "elite", "pro", "rookie"]
const LEAGUE_NAMES := {"world": "World Championship", "elite": "Elite", "pro": "Pro", "rookie": "Rookie", "exhibition": "Exhibition"}

const WEAPON_NAMES := {
	"spinner_h": "Horizontal spinner", "spinner_v": "Vertical spinner", "drum": "Drum",
	"hammer": "Hammer", "flipper": "Flipper", "lifter": "Lifter", "crusher": "Crusher",
	"static": "Wedge", "none": "No weapon",
}
const ARCHETYPE_NAMES := {
	"spinner_h": "Horizontal spinner", "spinner_v": "Vertical spinner", "drum": "Drum",
	"hammer": "Hammer", "flipper": "Flipper", "lifter": "Lifter", "crusher": "Crusher",
	"static": "Wedge", "none": "No weapon", "wedge": "Wedge", "multibot": "Multibot",
}

static func _in_roster(reg: Registry) -> Dictionary:
	var s := {}
	for r in reg.roster(): s[r.id] = true
	# Robots that joined during a career (field.gd) are part of the field too.
	for r in reg.all_robots():
		if J.truthy(r.get("newcomer")) and not J.truthy(r.get("retired")): s[r.id] = true
	return s

## Every robot the player can pick, A to Z. Roster bots carry their league;
## the house and test bots outside the field are "exhibition".
static func catalog(reg: Registry) -> Array:
	var in_roster := _in_roster(reg)
	var out := []
	for r in reg.all_robots():
		if J.truthy(r.get("retired")): continue      # a career's retired robots are only names now
		out.append({
			"id": r.id,
			"name": r.name,
			"league": r.get("league") if in_roster.has(r.id) else "exhibition",
			"origin": r.get("origin"),
			"archetype": r.get("archetype"),
			"team": J.g(r, "team", ""),
			"inspiredBy": r.get("inspiredBy"),
			"rating": r.get("rating"),
			"number": r.get("number"),
			"livery": J.g(r, "livery", {}),
			"multibot": r.get("partner") != null,
			"isPlayer": r.id == reg.playerId,
			"sortKey": str(r.name).to_lower(),
		})
	return J.sorted(out, func(a, b): return J.strcmp(a.sortKey, b.sortKey))

## Narrow the list: `league` is a league id, "all", or "exhibition"; `query`
## matches the name, team or archetype, case-insensitively.
static func filter_catalog(entries: Array, league: String = "all", query: String = "") -> Array:
	var q := query.strip_edges().to_lower()
	return entries.filter(func(e):
		if league != "all" and e.league != league: return false
		if q == "": return true
		return e.sortKey.contains(q) or str(e.team).to_lower().contains(q) or str(ARCHETYPE_NAMES.get(e.archetype, "")).to_lower().contains(q))

## The spec card: what a fan wants to know before the fight, all derived from
## the build (never stated in the robot file).
static func spec_card(reg: Registry, id, def = null) -> Dictionary:
	if def == null: def = reg.robot(id)
	var a := Build.assemble_robot(reg, def)
	var partner = Build.assemble_partner(reg, def) if def.get("partner") != null else null
	var w: Dictionary = a.stats.weapon
	var shape := Shape.build_shape(a)
	var energy: float = J.g(w, "energyJ", 0.0)
	var in_field := false
	for r in reg.roster():
		if r.id == id:
			in_field = true
			break
	var wp = a.parts.get("weapon")
	var pcard = null
	if partner != null:
		var pw = partner.parts.get("weapon")
		pcard = {"name": partner.name, "weapon": pw.name if pw != null else "None"}
	return {
		"id": id,
		"name": def.get("name"),
		"team": J.g(def, "team", ""),
		"league": LEAGUE_NAMES.get(def.get("league") if (in_field or J.truthy(def.get("newcomer"))) else "exhibition"),
		"archetype": ARCHETYPE_NAMES.get(def.get("archetype"), def.get("archetype")),
		"inspiredBy": def.get("inspiredBy"),
		"origin": def.get("origin"),
		"rating": def.get("rating"),
		"personality": def.get("personality"),
		"weightLb": J.rnd((a.weightLb + (partner.weightLb if partner != null else 0.0)) * 10.0) / 10.0,
		"topSpeedMph": J.rnd(a.stats.topSpeedMph * 10.0) / 10.0,
		"pushRatio": J.rnd(a.stats.pushRatio * 100.0) / 100.0,
		"weapon": wp.name if wp != null else "None",
		"weaponClass": WEAPON_NAMES.get(w["class"], w["class"]),
		"weaponEnergyKJ": J.rnd(energy / 100.0) / 10.0,
		"armourHp": J.rnd(a.stats.armorHp),
		"invertible": shape.invertible,
		"selfRights": a.stats.selfRight.via != "none",
		"partner": pcard,
	}

## A scouting card for the career's next opponent: the spec card plus what to
## watch for and where it is weak, read off the build.
static func scouting(reg: Registry, def: Dictionary) -> Dictionary:
	var card := spec_card(reg, def.id, def)
	var a := Build.assemble_robot(reg, def)
	var s: Dictionary = a.stats
	var w: Dictionary = s.weapon
	var cls: String = w["class"]
	var shape := Shape.build_shape(a)
	var notes := []
	var weak := []

	if cls == "spinner_h" or cls == "spinner_v" or cls == "drum":
		notes.append("Stores %s kJ and needs %s s to spin back up after a hit." % [J.fixed(w.energyJ / 1000.0, 1), J.fixed(w.spinUpS, 1)])
		weak.append("Hit it while the weapon is still spinning up.")
	elif cls == "hammer": notes.append("Overhead strikes: keep moving, it has to line you up.")
	elif cls == "flipper" or cls == "lifter":
		var ch: float = J.g(w, "charges", INF)
		notes.append("%s from the front: don't give it your nose%s." % ["Flips" if cls == "flipper" else "Lifts", " (%s shots of gas)" % J.num(ch) if (ch != 0.0 and is_finite(ch)) else ""])
	elif cls == "crusher": notes.append("Grabs and crushes: once held, it bites again and again.")
	elif cls == "static": notes.append("A pusher: it wants you off your wheels or into the hazards.")

	if not shape.invertible and s.selfRight.via == "none": weak.append("Cannot run upside down or right itself: a flip ends its fight.")
	elif shape.invertible: notes.append("Runs upside down: flipping it does nothing.")
	elif s.selfRight.via == "gyro": notes.append("Can sometimes right itself on its rotor's gyro kick - a flip is a scramble, not a KO.")
	else: notes.append("Rights itself with its %s." % ("self-righting arm" if s.selfRight.via == "srimech" else "weapon"))

	var slots := {}
	for f in a.fittings:
		if f.part.category == "armor": slots[f.part.spec.slot] = true
	for sl in [["side", "sides"], ["rear", "back"], ["top", "top"]]:
		if not slots.has(sl[0]): weak.append("No armour on the %s." % sl[1])
	if s.topSpeedMph < 12: weak.append("Slow (%s mph): you can out-drive it." % J.fixed(s.topSpeedMph, 1))
	elif s.topSpeedMph > 18: notes.append("Fast (%s mph)." % J.fixed(s.topSpeedMph, 1))
	if s.pushRatio < 0.8: weak.append("Weak pusher (%sx its weight)." % J.fixed(s.pushRatio, 2))
	elif s.pushRatio > 1.1: notes.append("Strong pusher (%sx): don't get into a shoving match." % J.fixed(s.pushRatio, 2))
	card.notes = notes
	card.weak = weak
	card.driver = {"rating": def.get("rating"), "personality": def.get("personality"), "league": def.get("league")}
	return card
