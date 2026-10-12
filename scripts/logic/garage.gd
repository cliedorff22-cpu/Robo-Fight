## garage.gd - the player's robot and the parts they own, inside the career.
##
## The robot (name, body, build, paint, driver style) lives in `career.garage`,
## every part they own is counted there, and the shop sells more.
##
##   garage = { name, body, build, livery, personality,
##              owned: { partId: count },   # fitted parts included
##              version: "1.0", log: [{ season, text }] }
##
## Rules of the shop (data/economy.json `shop`):
##  - a part's tier unlocks with the best league the player has reached;
##  - prices carry the career's parts discount (sponsors, Giant Nut deals);
##  - fitting a part you do not own buys it; spares sell back at `resale`.
class_name Garage

const SINGLE := ["chassis", "drive", "wheel", "motor", "battery", "electronics", "weaponMotor", "weapon", "srimech"]

## The second unit a robot becomes a multibot with, until the player changes
## it: a minibot wedge, as the field's multibots run.
const DEFAULT_PARTNER := {
	"name": "Minibot",
	"body": {"template": "wedge", "params": {"slope": 0.8}, "mount": "front", "extras": []},
	"build": {"chassis": "chassis_mini", "drive": "drive_2wd_belt", "wheel": "wheel_4_mini", "motor": "motor_drive_mini",
		"battery": "batt_4s_lipo", "electronics": "ecu_mini", "weapon": "wedge_mini", "armor": ["armor_uhmw_front"]},
}

## Every part id a build fits, armour panels each counted.
static func parts_of(build: Dictionary) -> Array:
	var out := []
	for k in SINGLE:
		if J.truthy(build.get(k)): out.append(build[k])
	for id in build.get("armor", []): out.append(id)
	return out

## { partId: count } for a build.
static func count_parts(build: Dictionary) -> Dictionary:
	var c := {}
	for id in parts_of(build): c[id] = c.get(id, 0) + 1
	return c

## Parts fitted across both units of a (possibly multibot) design.
static func fitted_counts(build: Dictionary, partner_build = null) -> Dictionary:
	var c := count_parts(build)
	if partner_build is Dictionary:
		var pc := count_parts(partner_build)
		for id in pc: c[id] = c.get(id, 0) + pc[id]
	return c

## The archetype a build is, from its weapon - what the AI and the menus call it.
static func archetype_of(reg: Registry, build: Dictionary) -> String:
	var cls: String = reg.part(build.weapon).spec["class"] if J.truthy(build.get("weapon")) else "none"
	return "wedge" if cls == "static" else cls

## A fresh garage: the robot file's robot, and its parts, owned.
static func new_garage(reg: Registry) -> Dictionary:
	var base := reg.robot(reg.playerId)
	# The test bots' plain "classic" box is not a workshop body: a career
	# robot starts sculpted, so the workshop can reshape it.
	var body: Dictionary
	var tpl = J.path(base, ["body", "template"])
	if J.truthy(tpl) and tpl != "classic":
		body = J.clone(base.body)
	else:
		var hammer: bool = J.truthy(base.build.get("weapon")) and reg.part(base.build.weapon).spec["class"] == "hammer"
		body = {"template": "wedge" if archetype_of(reg, base.build) == "wedge" else "box", "mount": "top" if hammer else "front", "extras": []}
	var livery = J.clone(base.get("livery"))
	return {
		"name": base.name,
		"body": body,
		"build": J.clone(base.build),
		"livery": livery if livery != null else {},
		"personality": J.g(base, "personality", "opportunistic"),
		"owned": count_parts(base.build),
		"version": "1.0",
		"log": [],
	}

## The career's garage, made on first use (saves from before Stage 6 have none).
static func garage_of(reg: Registry, career: Dictionary) -> Dictionary:
	if career.get("garage") == null: career.garage = new_garage(reg)
	# Garages made before the body rule above: sculpt the classic box once.
	var tpl = J.path(career.garage, ["body", "template"])
	if not J.truthy(tpl) or tpl == "classic": career.garage.body = new_garage(reg).body
	return career.garage

## The player's robot as a robot def - what fights, everywhere.
static func player_def(reg: Registry, career: Dictionary) -> Dictionary:
	var base := reg.robot(career.playerId)
	var g := garage_of(reg, career)
	var d := base.duplicate()
	d.name = g.name
	d.body = J.clone(g.body)
	d.build = J.clone(g.build)
	d.livery = J.clone(g.get("livery"))
	d.personality = g.get("personality")
	d.archetype = archetype_of(reg, g.build)
	d.version = g.get("version")
	# A multibot's second unit: it fights beside the main one, AI driven.
	if g.get("partner") != null: d.partner = J.clone(g.partner)
	else: d.erase("partner")
	return d

## The best league the player has ever been in (it unlocks the shop's tiers).
static func best_league(reg: Registry, career: Dictionary) -> String:
	var order: Array = reg.league.leagues
	var best: int = order.find(career.membership[career.playerId])
	for h in career.get("history", []):
		for lg in [h.get("league"), h.get("nextLeague")]:
			if J.truthy(lg): best = maxi(best, order.find(lg))
	return order[maxi(0, best)]

static func shop_cfg(reg: Registry) -> Dictionary:
	return J.merge({"tierFromLeague": {"rookie": 1, "pro": 2, "elite": 3, "world": 3}, "resale": 0.5}, J.g(reg.economy, "shop", {}))

## The highest part tier the shop will sell the player now.
static func shop_tier(reg: Registry, career: Dictionary) -> int:
	var cfg := shop_cfg(reg)
	var tier := int(J.g(cfg.tierFromLeague, best_league(reg, career), 1))
	# A Giant Nut deal can open the top shelf early.
	if career.get("unlocks", []).has("tier3"): tier = maxi(tier, 3)
	return tier

## The career's parts discount (sponsors and Giant Nut deals), 0..1.
static func discount_of(reg: Registry, career: Dictionary) -> float:
	var d := 0.0
	for id in career.get("sponsors", []):
		for s in reg.economy.sponsors:
			if s.id == id:
				d = maxf(d, J.g(s, "partsDiscount", 0.0))
				break
	for p in career.get("perks", []): d = maxf(d, J.g(p, "partsDiscount", 0.0))
	return d

## What one part costs the player now.
static func price_of(reg: Registry, career: Dictionary, part_id) -> float:
	return J.rnd(reg.part(part_id).cost * (1.0 - discount_of(reg, career)))

## What a spare part sells back for (list price x resale, no discount).
static func resale_of(reg: Registry, part_id) -> float:
	return J.rnd(reg.part(part_id).cost * shop_cfg(reg).resale)

## Owned parts not fitted to the robot right now.
static func spares(reg: Registry, career: Dictionary) -> Dictionary:
	var g := garage_of(reg, career)
	var fitted := fitted_counts(g.build, J.path(g, ["partner", "build"]))
	var out := {}
	for id in g.owned:
		var spare: float = g.owned[id] - fitted.get(id, 0)
		if spare > 0: out[id] = spare
	return out

## Whether the player could buy this part now: { ok, reason }.
static func can_buy(reg: Registry, career: Dictionary, part_id) -> Dictionary:
	var part := reg.part(part_id)
	var tier := shop_tier(reg, career)
	var pt: float = J.g(part, "tier", 1)
	if pt > tier:
		var need = null
		var tfl: Dictionary = shop_cfg(reg).tierFromLeague
		for lg in tfl:
			if tfl[lg] >= pt:
				need = lg
				break
		return {"ok": false, "reason": "Tier %s - unlocks when you reach the %s league." % [J.num(pt), need if need != null else "top"]}
	return {"ok": true, "reason": ""}

## What it would take to fit `build`: the parts to buy (beyond what is owned),
## what they cost, and anything the shop will not sell yet.
static func quote(reg: Registry, career: Dictionary, build: Dictionary, partner_build = null) -> Dictionary:
	var g := garage_of(reg, career)
	var need := fitted_counts(build, partner_build)
	var buy := []
	var locked := []
	var total := 0.0
	for id in need:
		var short: float = need[id] - g.owned.get(id, 0)
		if short <= 0: continue
		var price := price_of(reg, career, id)
		buy.append({"id": id, "n": short, "price": price, "name": reg.part(id).name})
		total += price * short
		var c := can_buy(reg, career, id)
		if not c.ok: locked.append({"id": id, "name": reg.part(id).name, "reason": c.reason})
	return {"buy": buy, "total": total, "locked": locked, "affordable": total <= career.cash}

static func _salvage_fraction(reg: Registry) -> float:
	return J.path(reg.rules, ["pit", "salvageCreditFraction"], 0.4)

## Fit a new design: buy whatever it needs that is not owned, then make it the
## robot. `draft` is { name?, body?, build, livery?, personality?, partner? }
## (partner present and null takes the second unit off).
## Returns { ok, errors: [text], bought, cost }
static func apply_design(reg: Registry, career: Dictionary, draft: Dictionary) -> Dictionary:
	var g := garage_of(reg, career)
	var def := player_def(reg, career)
	def.merge(_pick(draft), true)
	def.id = career.playerId
	if draft.has("partner") and draft.partner == null: def.erase("partner")
	var has_partner: bool = def.get("partner") != null
	if not Build.can_assemble(reg, def) or (has_partner and not Build.can_assemble(reg, def.partner)):
		return {"ok": false, "errors": ["That design has a part missing or in the wrong slot."], "bought": [], "cost": 0}
	var a := Build.assemble_robot(reg, def)
	var pa = Build.assemble_partner(reg, def) if has_partner else null
	# A multibot's units each pass inspection, and together make the weight.
	var errors: Array = a.legality.errors.duplicate()
	if pa != null:
		for e in pa.legality.errors: errors.append("%s: %s" % [def.partner.name, e])
		errors.append_array(Build.check_multibot_weight(reg, a, pa))
	var q := quote(reg, career, def.build, def.partner.build if has_partner else null)
	for l in q.locked: errors.append("%s: %s" % [l.name, l.reason])
	if not q.affordable: errors.append("The new parts cost $%s; you have $%s." % [J.commas(q.total), J.commas(J.rnd(career.cash))])
	if errors.size() > 0: return {"ok": false, "errors": errors, "bought": q.buy, "cost": q.total}

	for b in q.buy:
		g.owned[b.id] = g.owned.get(b.id, 0) + b.n
		Ledger.pay(career, -b.price * b.n, "Workshop: %s%s" % ["%sx " % J.num(b.n) if b.n > 1 else "", b.name])
	# Damage goes where the part goes: a damaged part that stays on the robot
	# keeps its damage, wherever it is fitted now; a damaged part taken off is
	# scrapped for salvage rather than kept as a spare.
	var carried := carry_condition(reg, g, def.build)
	_scrap(reg, career, g, carried)
	g.condition = carried.condition
	# The second unit's damage the same way.
	var old_pb = J.path(g, ["partner", "build"], {})
	var pc := carry_condition(reg, {"build": old_pb, "condition": J.g(g, "partnerCondition", {})}, def.partner.build if has_partner else {})
	_scrap(reg, career, g, pc)
	g.partnerCondition = pc.condition
	var changed := describe_change(reg, g.build, def.build)
	var had_partner: bool = g.get("partner") != null
	if had_partner != has_partner:
		changed.append("became a multibot with %s" % def.partner.name if has_partner else "no longer a multibot")
	elif has_partner and def.partner.build != g.partner.build:
		changed.append("%s refitted" % def.partner.name)
	g.name = def.name
	g.body = J.clone(def.get("body"))
	g.build = J.clone(def.build)
	g.livery = J.clone(def.get("livery"))
	g.personality = def.get("personality")
	g.partner = J.clone(def.partner) if has_partner else null
	if changed.size() > 0:
		var major := false
		for c in changed:
			if c.begins_with("weapon") or c.contains("multibot"): major = true
		g.version = _bump_version(g.get("version"), major)
		g.log.append({"season": career.seasonIndex, "version": g.version, "text": "; ".join(changed)})
		if g.log.size() > 40: g.log = g.log.slice(g.log.size() - 40)
	return {"ok": true, "errors": [], "bought": q.buy, "cost": q.total}

static func _scrap(reg: Registry, career: Dictionary, g: Dictionary, carried: Dictionary) -> void:
	for id in carried.scrapped:
		g.owned[id] = maxf(0, g.owned.get(id, 0) - 1)
		var c: float = carried.scrapCondition[id].pop_front()
		var credit := J.rnd(_salvage_fraction(reg) * reg.part(id).cost * c)
		if credit != 0.0: Ledger.pay(career, credit, "Scrapped a damaged %s" % reg.part(id).name)

static func _keys_of(build: Dictionary) -> Array:
	var out := []
	for k in SINGLE:
		if J.truthy(build.get(k)): out.append({"key": k, "id": build[k]})
	var i := 0
	for id in build.get("armor", []):
		out.append({"key": "armor.%d" % i, "id": id})
		i += 1
	return out

## Map the robot's damage from its old build onto a new one by part: each
## fitting of the new build takes the condition of an unused fitting of the
## same part in the old one (fresh if there is none). Damaged parts left over
## are scrapped.
static func carry_condition(_reg: Registry, g: Dictionary, new_build: Dictionary) -> Dictionary:
	var cond: Dictionary = J.g(g, "condition", {})
	var old := []
	for f in _keys_of(J.g(g, "build", {})):
		f.c = J.g(cond, f.key, 1.0)
		f.used = false
		old.append(f)
	var condition := {}
	for f in _keys_of(new_build):
		# Prefer the same fitting, then any unused one of the same part.
		var same = null
		for o in old:
			if not o.used and o.id == f.id and o.key == f.key:
				same = o
				break
		if same == null:
			for o in old:
				if not o.used and o.id == f.id:
					same = o
					break
		if same == null: continue
		same.used = true
		if same.c < 0.999: condition[f.key] = same.c
	var scrapped := []
	var scrap_condition := {}
	for o in old:
		if o.used or o.c >= 0.999: continue
		scrapped.append(o.id)
		if not scrap_condition.has(o.id): scrap_condition[o.id] = []
		scrap_condition[o.id].append(o.c)
	return {"condition": condition, "scrapped": scrapped, "scrapCondition": scrap_condition}

## Sell one spare of a part back to the shop.
static func sell_part(reg: Registry, career: Dictionary, part_id) -> Dictionary:
	var sp: float = spares(reg, career).get(part_id, 0)
	if sp <= 0: return {"ok": false, "refund": 0}
	var g := garage_of(reg, career)
	g.owned[part_id] -= 1
	if g.owned[part_id] <= 0: g.owned.erase(part_id)
	var refund := resale_of(reg, part_id)
	Ledger.pay(career, refund, "Sold %s" % reg.part(part_id).name)
	return {"ok": true, "refund": refund}

static func _pick(d: Dictionary) -> Dictionary:
	var out := {}
	for k in ["name", "body", "build", "livery", "personality", "partner"]:
		if d.get(k) != null: out[k] = J.clone(d[k])
	if out.has("name"):
		var n := str(out.name).strip_edges().substr(0, 28)
		out.name = n if n != "" else "Unnamed"
	return out

## "weapon: Wedge -> 26in Horizontal Bar" style notes for the build log.
static func describe_change(reg: Registry, before: Dictionary, after: Dictionary) -> Array:
	var notes := []
	for k in SINGLE:
		var b = before.get(k) if J.truthy(before.get(k)) else null
		var a = after.get(k) if J.truthy(after.get(k)) else null
		if b == a: continue
		notes.append("%s: %s -> %s" % ["weapon motor" if k == "weaponMotor" else k,
			reg.part(b).name if b != null else "none", reg.part(a).name if a != null else "none"])
	var ba: Array = before.get("armor", []).duplicate()
	var aa: Array = after.get("armor", []).duplicate()
	ba.sort()
	aa.sort()
	if ba != aa: notes.append("armour refitted")
	return notes

## 1.0 -> 1.1 for a refit, -> 2.0 for a new weapon.
static func _bump_version(v, major: bool) -> String:
	var parts := str(v if J.truthy(v) else "1.0").split(".")
	var M := int(parts[0]) if parts.size() > 0 else 1
	var m := int(parts[1]) if parts.size() > 1 else 0
	return "%d.0" % (M + 1) if major else "%d.%d" % [M, m + 1]
