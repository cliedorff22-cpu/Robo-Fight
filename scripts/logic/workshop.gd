## workshop.gd - editing a robot design: its slots, the parts that fit each
## one, what a swap does to the numbers, and a body that suits the weapon.
##
## Pure logic: the workshop screen draws these, the build advisor searches
## with them, and the tests drive them directly. A design is a robot def's
## look-and-build: { name, body, build, livery, personality }.
## Nothing here spends money - garage.gd prices and fits a finished design.
class_name Workshop

## One part per slot for these; armour is a list of panels by face.
const SINGLE_SLOTS := ["chassis", "drive", "wheel", "motor", "battery", "electronics", "weaponMotor", "weapon", "srimech"]
## Slots a robot can leave empty.
const OPTIONAL := ["weaponMotor", "srimech"]
const SLOT_NAMES := {
	"chassis": "Chassis", "drive": "Drivetrain", "wheel": "Wheels", "motor": "Drive motors", "battery": "Battery",
	"electronics": "Electronics", "weaponMotor": "Weapon motor", "weapon": "Weapon", "srimech": "Self-righter",
	"front": "Front armour", "side": "Side armour", "top": "Top armour", "rear": "Rear armour",
}
const FACES := ["front", "side", "top", "rear"]

## Where each weapon class can be mounted (shape.gd `mount`), best first.
const MOUNTS := {
	"spinner_h": ["front", "low", "overhead"], "spinner_v": ["front"], "drum": ["front"],
	"hammer": ["top"], "flipper": ["front", "lid"], "lifter": ["front"], "crusher": ["front"], "static": ["front"],
}
const MOUNT_NAMES := {
	"front": "Front", "low": "Low (undercutter)", "overhead": "Overhead (on a mast)", "shell": "Full-body shell",
	"top": "Over the top", "lid": "Lid (whole top flips)",
}
## Body templates a player can pick ("classic" and "custom" are not offered).
const TEMPLATES := ["box", "wedge", "slab", "round", "dart", "hex", "bullet", "tent", "cab", "twin"]
const TEMPLATE_NAMES := {
	"box": "Box", "wedge": "Wedge", "slab": "Slab (invertible)", "round": "Round", "dart": "Arrowhead", "hex": "Hex",
	"bullet": "Bullet", "tent": "Tent", "cab": "Deck and cab", "twin": "Twin pods",
}
## Body extras offered in the workshop (shape.gd EXTRA_TYPES has the full list).
const EXTRAS := ["forks", "plow", "wheelGuards", "bumper", "spikes", "horns", "eyes", "fin", "cage", "dome", "spines"]

## The mounts on offer for this build's weapon (a shell spinner has only one).
static func mounts_for(reg: Registry, build: Dictionary) -> Array:
	if J.truthy(build.get("weapon")) and reg.part(build.weapon).spec.get("style") == "shell": return ["shell"]
	return MOUNTS.get(weapon_class_of(reg, build), ["front"])

## The parts a player's robot can fit in a category. The minibot kit
## (spec.minibot) is for the small half of a multibot; drive-motor slots take
## drive motors only.
static func parts_for(reg: Registry, category: String, face = null, minibot := false) -> Array:
	var list := reg.parts_in(category).filter(func(p): return minibot or not J.truthy(p.spec.get("minibot")))
	if category == "armor" and face != null: list = list.filter(func(p): return p.spec.slot == face)
	if category == "motor": list = list.filter(func(p): return p.spec.get("role") == "drive")
	return list

## The weapon class a build carries ("none" without one).
static func weapon_class_of(reg: Registry, build: Dictionary) -> String:
	return reg.part(build.weapon).spec["class"] if J.truthy(build.get("weapon")) else "none"

## Every slot of a design, in workshop order, with what is fitted. Armour
## slots come from the chassis (front 1, side 2, top 1, rear 1 on most).
## Returns [{ key, category, face?, index?, partId, optional, label, fitIndex? }]
static func slots_of(reg: Registry, build: Dictionary) -> Array:
	var out := []
	for cat in SINGLE_SLOTS:
		out.append({"key": cat, "category": cat, "partId": build.get(cat) if J.truthy(build.get(cat)) else null,
			"optional": OPTIONAL.has(cat), "label": SLOT_NAMES[cat]})
	var limits: Dictionary = J.g(reg.part(build.chassis).spec, "armorSlots", {"front": 1, "side": 2, "top": 1, "rear": 1})
	var armour := []
	for face in FACES:
		var n := int(J.g(limits, face, 0))
		for i in n:
			var label: String = SLOT_NAMES[face]
			if n > 1: label = "%s %s" % [SLOT_NAMES[face], "R" if i > 0 else "L"]
			armour.append({"key": "armor:%s:%d" % [face, i], "category": "armor", "face": face, "index": i, "partId": null, "optional": true, "label": label})
	# `fitIndex` is the panel's place in build.armor - its fitting is
	# "armor.<fitIndex>", which is what damage and the 3D view are keyed by.
	var idx := 0
	for id in build.get("armor", []):
		var pface: String = reg.part(id).spec.slot
		for s in armour:
			if s.face == pface and s.partId == null:
				s.partId = id
				s.fitIndex = idx
				break
		idx += 1
	out.append_array(armour)
	return out

## Armour panels in a stable order (front, side L, side R, top, rear).
static func _armour_from_slots(slots: Array) -> Array:
	var out := []
	for s in slots:
		if s.category == "armor" and s.partId != null: out.append(s.partId)
	return out

## A new build with one slot changed (part_id null to empty an optional one).
## Changing the chassis drops panels it has no room for; changing the weapon
## fits or drops a weapon motor to suit.
static func set_slot(reg: Registry, build: Dictionary, key: String, part_id) -> Dictionary:
	var b: Dictionary = J.clone(build)
	if not key.begins_with("armor:"):
		if J.truthy(part_id): b[key] = part_id
		else: b.erase(key)
		# A powered weapon needs a motor (the cheapest, until one is chosen);
		# a wedge or no weapon needs none.
		if key == "weapon":
			var powered: bool = J.truthy(part_id) and J.truthy(reg.part(part_id).spec.get("powered"))
			if not powered: b.erase("weaponMotor")
			elif not J.truthy(b.get("weaponMotor")):
				var motors := J.sorted(parts_for(reg, "weaponMotor"), func(x, y): return x.cost - y.cost)
				if motors.size() > 0: b.weaponMotor = motors[0].id
		if key == "chassis": b.armor = _armour_from_slots(slots_of(reg, b))
		return b
	var slots := slots_of(reg, b)
	for s in slots:
		if s.key == key:
			s.partId = part_id if J.truthy(part_id) else null
			b.armor = _armour_from_slots(slots)
			break
	return b

## A body that works with the build's weapon: keeps the player's template and
## extras where it can, and fixes the mount (and the template, for a shell).
static func fit_body(reg: Registry, body, build: Dictionary) -> Dictionary:
	var b: Dictionary = J.clone(body) if body is Dictionary else {}
	var cls := weapon_class_of(reg, build)
	var mounts := mounts_for(reg, build)
	var tpl = b.get("template")
	if not J.truthy(tpl) or tpl == "classic" or not TEMPLATES.has(tpl): b.template = "wedge" if cls == "static" else "box"
	# A shell spinner IS the body's outside: it needs a round body to wrap.
	var shell: bool = J.truthy(build.get("weapon")) and reg.part(build.weapon).spec.get("style") == "shell"
	if shell:
		b.template = "round"
		b.mount = "shell"
	elif b.get("mount") == "shell": b.mount = mounts[0]
	if not mounts.has(b.get("mount")): b.mount = mounts[0]
	b.extras = b.get("extras", []).filter(func(e): return Shape.EXTRA_TYPES.has(e.type))
	return b

static func _round1(x: float) -> float: return J.rnd(x * 10.0) / 10.0

## The numbers a builder watches, for one design. Null if it will not assemble.
static func summarize(reg: Registry, def: Dictionary):
	if not Build.can_assemble(reg, def): return null
	var a := Build.assemble_robot(reg, def)
	var s: Dictionary = a.stats
	var w: Dictionary = s.weapon
	var shape := Shape.build_shape(a)
	var cap: float = reg.rules.weightClass.cap
	var total_hp := 0.0
	var list_price := 0.0
	for f in a.fittings:
		total_hp += f.part.hp
		list_price += f.part.cost
	var wp = a.parts.get("weapon")
	return {
		"weightLb": J.rnd(a.weightLb * 10.0) / 10.0,
		"capLb": cap,
		"spareLb": J.rnd((cap - a.weightLb) * 10.0) / 10.0,
		"legal": a.legality.errors.size() == 0,
		"errors": a.legality.errors,
		"warnings": a.legality.warnings,
		"topSpeedMph": _round1(s.topSpeedMph),
		"accelMps2": _round1(s.accelMps2),
		"pushRatio": J.rnd(s.pushRatio * 100.0) / 100.0,
		"pivot": J.rnd(s.pivotAuthority * 100.0) / 100.0 if is_finite(s.pivotAuthority) else INF,
		"weaponClass": w["class"],
		"weaponName": wp.name if wp != null else "None",
		"energyKJ": _round1(J.g(w, "energyJ", 0.0) / 1000.0),
		"spinUpS": _round1(w.spinUpS) if is_finite(w.spinUpS) else null,
		"armourHp": J.rnd(s.armorHp),
		"totalHp": J.rnd(total_hp),
		"invertible": shape.invertible,
		"selfRight": s.selfRight.via,
		"clearanceIn": _round1(s.groundClearanceM / 0.0254),
		"listPrice": list_price,
	}

## Just the inspection: the build's legality (Build.check_legality), or null
## if it will not assemble. What fit_within and the AI teams' setups ask
## thousands of times a season - summarize() also sculpts the body.
static func legality_of(reg: Registry, def: Dictionary):
	if not Build.can_assemble(reg, def): return null
	return Build.assemble_robot(reg, def).legality

## b minus a, for the numbers that matter in a swap.
static func delta(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k in ["weightLb", "topSpeedMph", "pushRatio", "energyKJ", "spinUpS", "armourHp", "totalHp"]:
		if a.get(k) != null and b.get(k) != null: out[k] = J.rnd((b[k] - a[k]) * 100.0) / 100.0
	return out

## The parts that could go in a slot, each with what it would do to the design.
## `career` may be null (a sandbox): then nothing is owned, locked or priced.
## Returns [{ part, fitted, owned, spare, price, locked, reason, after, delta, legal }]
static func candidates(reg: Registry, career, design: Dictionary, key: String, minibot := false) -> Array:
	var slot = null
	for s in slots_of(reg, design.build):
		if s.key == key:
			slot = s
			break
	if slot == null: return []
	var before = summarize(reg, def_of(reg, design))
	var owned: Dictionary = Garage.garage_of(reg, career).owned if career != null else {}
	var fitted := Garage.count_parts(design.build)
	var out := []
	for part in parts_for(reg, slot.category, slot.get("face"), minibot):
		var build := set_slot(reg, design.build, key, part.id)
		var d: Dictionary = design.duplicate()
		d.build = build
		d.body = fit_body(reg, design.get("body"), build) if key == "weapon" else design.get("body")
		var after = summarize(reg, def_of(reg, d))
		var buy: Dictionary = Garage.can_buy(reg, career, part.id) if career != null else {"ok": true, "reason": ""}
		var have: float = owned.get(part.id, 0)
		var fit_n: float = fitted.get(part.id, 0)
		out.append({
			"part": part, "fitted": slot.partId == part.id,
			"owned": have, "spare": maxf(0, have - fit_n),
			"price": Garage.price_of(reg, career, part.id) if career != null else part.cost,
			"locked": (not buy.ok) and have <= fit_n, "reason": buy.reason,
			"after": after, "delta": delta(before, after) if (after != null and before != null) else null,
			"legal": after != null and after.legal,
		})
	return J.sorted(out, func(a, b):
		var d: float = J.g(a.part, "tier", 1) - J.g(b.part, "tier", 1)
		return d if d != 0.0 else a.part.cost - b.part.cost)

## A design as a full robot def the build and shape code accept.
static func def_of(reg: Registry, design: Dictionary, base = null) -> Dictionary:
	if base == null: base = reg.robot(reg.playerId)
	var d: Dictionary = base.duplicate()
	d.id = base.id
	d.name = J.g(design, "name", base.get("name"))
	d.body = J.g(design, "body", base.get("body"))
	d.build = design.build
	d.livery = J.g(design, "livery", base.get("livery"))
	d.personality = J.g(design, "personality", base.get("personality"))
	return d

# ---------------------------------------------------------------- shared by the advisor and the AI teams

## Upgrade the panel on `face` to the toughest that fits, trimming other faces if needed.
static func reinforce(reg: Registry, design: Dictionary, face: String, protect: Array):
	var slots := slots_of(reg, design.build).filter(func(s): return s.category == "armor" and s.get("face") == face)
	if slots.is_empty(): return null
	var options := J.sorted(parts_for(reg, "armor", face), func(a, b): return b.hp - a.hp)
	for part in options:
		var build: Dictionary = design.build
		var changed := false
		for s in slots:
			if s.partId != null and reg.part(s.partId).hp >= part.hp: continue
			build = set_slot(reg, build, s.key, part.id)
			changed = true
		if not changed: continue
		var nd: Dictionary = design.duplicate()
		nd.build = build
		var d = fit_within(reg, nd, ["rear", "top", "side", "front"].filter(func(f): return f != face and not protect.has(f)))
		if d != null: return d
	return null

## Make a design legal on weight by stepping down panels on the given faces
## (least important first). Returns null if it cannot.
static func fit_within(reg: Registry, design: Dictionary, faces: Array):
	var d: Dictionary = J.clone(design)
	for i in 8:
		var sum = legality_of(reg, def_of(reg, d))
		if sum == null: return null
		if sum.legal: return d
		var overweight := false
		for e in sum.errors:
			if e.to_lower().contains("overweight"):
				overweight = true
				break
		if not overweight: return null
		var stepped := false
		for face in faces:
			var s = null
			for x in slots_of(reg, d.build):
				if x.category == "armor" and x.get("face") == face and x.partId != null:
					s = x
					break
			if s == null: continue
			var cur := reg.part(s.partId)
			var lighter := J.sorted(parts_for(reg, "armor", face).filter(func(p): return p.weight < cur.weight), func(a, b): return b.weight - a.weight)
			d.build = set_slot(reg, d.build, s.key, lighter[0].id if lighter.size() > 0 else null)
			stepped = true
			break
		if not stepped: return null
	return null

static func uniq_extras(list: Array) -> Array:
	var seen := {}
	var out := []
	for e in list:
		if EXTRAS.has(e.type) and not seen.has(e.type):
			seen[e.type] = true
			out.append(e)
	return out
