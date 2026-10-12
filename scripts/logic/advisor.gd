## advisor.gd - the optional build advisor. Offline: no network, no API key.
##
## It never has to be used - everything it suggests can be done by hand in
## the workshop - and it only ever SUGGESTS: the player applies a design or
## not. It reasons from three things it can see:
##   - the parts and what build.gd derives from them;
##   - data/matchups.json: how each weapon class actually does against each
##     other one in refereed physics;
##   - trial fights: it runs candidate designs through the fast resolver
##     against the real opponents and reports the measured change, not a guess.
##
## One entry point, advise(reg, request), returning plain Advice dictionaries.
## That shape is deliberately narrow so an LLM-backed advisor could sit behind
## the same call later and the workshop screen would not change:
##
##   request = { kind: "design" | "opponent" | "fight" | "season",
##               career?, design?, brief?, oppId?, budget? }
##   Advice  = { kind, title, summary, points: [text], design?, evidence?,
##               options?: [{ label, design, winRate, delta, cost, notes }] }
##
## It is thousands of trial fights for a big question, so the screens call it
## on a background thread (ui/jobs.gd).
class_name Advisor

## Where each weapon class mostly lands its hits (physics and resolver agree).
const THREAT_FACES := {
	"spinner_h": ["side", "front"], "spinner_v": ["front", "top"], "drum": ["front"], "hammer": ["top"],
	"crusher": ["top", "front"], "flipper": ["front"], "lifter": ["front"], "static": ["front"], "none": ["front"],
}
## Classes that win by turning robots over.
const FLIPPERS := ["flipper", "lifter", "spinner_v"]
## Trial fights per option against one opponent.
const MATCH_SEEDS := 60

static func _pct(x: float) -> String: return "%d%%" % J.rndi(x * 100.0)
static func _money(n) -> String: return "$" + J.commas(J.rnd(float(n)))
static func _class_name(c) -> String: return str(Catalog.WEAPON_NAMES.get(c, c)).to_lower()
static func _league_name(lg) -> String: return Career.league_name(lg)

# ---------------------------------------------------------------- entry point

## Ask the advisor something. See the header for the request and the answer.
static func advise(reg: Registry, req: Dictionary) -> Dictionary:
	match req.get("kind"):
		"design": return _design_from_brief(reg, req)
		"opponent": return _tailor_for_opponent(reg, req)
		"fight": return _fight_plan(reg, req)
		"season": return _season_plan(reg, req)
	return {"kind": req.get("kind"), "title": "I do not know how to answer that", "summary": "", "points": []}

# ---------------------------------------------------------------- trial fights

static func _design_of(g: Dictionary) -> Dictionary:
	return {"name": g.get("name"), "body": g.get("body"), "build": g.build, "livery": g.get("livery"), "personality": g.get("personality")}

## The player's design as a fielded def (league applied), for the resolver.
static func _my_def(reg: Registry, career, design: Dictionary) -> Dictionary:
	var base: Dictionary = Garage.player_def(reg, career) if career != null else reg.robot(reg.playerId)
	var def := Workshop.def_of(reg, design, base)
	def.league = Career.player_league(career) if career != null else J.g(design, "league", "rookie")
	return def

## The robots the player meets: their league's field (fielded, in a career).
static func _league_field(reg: Registry, career, league := "rookie") -> Array:
	var out := []
	if career != null:
		var lg = Career.player_league(career)
		for id in career.membership:
			if career.membership[id] == lg and id != career.playerId: out.append(Career.fielded_def(reg, career, id))
		return out
	for r in reg.roster():
		if r.league == league and r.id != reg.playerId: out.append(r)
	return out

# ---------------------------------------------------------------- design from a brief

static var _weapon_words: Array = []

static func _re(pattern: String) -> RegEx:
	var r := RegEx.new()
	r.compile(pattern)
	return r

static func _has(t: String, pattern: String) -> bool:
	return _re(pattern).search(t) != null

static func _weapon_table() -> Array:
	if _weapon_words.is_empty():
		_weapon_words = [
			[_re("undercut"), {"cls": "spinner_h", "part": "spinner_h_undercutter", "mount": "low"}],
			[_re("shell|full[- ]body|ring spinner"), {"cls": "spinner_h", "part": "spinner_h_shell"}],
			[_re("three[- ]hammer|tri[- ]?(rotor|blade)"), {"cls": "spinner_h", "part": "spinner_h_tri"}],
			[_re("overhead|over[- ]the[- ]top spin"), {"cls": "spinner_h", "mount": "overhead"}],
			[_re("horizontal|tombstone|bar spinner|spinning bar"), {"cls": "spinner_h"}],
			[_re("eggbeater"), {"cls": "drum", "part": "drum_eggbeater"}],
			[_re("drum|minotaur"), {"cls": "drum"}],
			[_re("vertical|\\bdis[ck]\\b|bite ?force|witch doctor|blade"), {"cls": "spinner_v"}],
			[_re("sledge"), {"cls": "hammer", "part": "hammer_sledge"}],
			[_re("hammer ?saw|\\bsaw\\b"), {"cls": "hammer", "part": "hammer_saw"}],
			[_re("hammer|\\baxe\\b|chomp|\\bspike\\b"), {"cls": "hammer"}],
			[_re("lid flip"), {"cls": "flipper", "part": "flipper_lid", "mount": "lid"}],
			[_re("flip|bronco|hydra"), {"cls": "flipper"}],
			[_re("clamp"), {"cls": "lifter", "part": "lifter_clamp"}],
			[_re("lift"), {"cls": "lifter"}],
			[_re("claw|grab"), {"cls": "crusher", "part": "grabber_claw"}],
			[_re("crush|\\bbeak\\b|\\bjaws?\\b|kraken"), {"cls": "crusher"}],
		]
	return _weapon_words

## Read a builder's description: "a low wedge with a lifter", "fast drum,
## lots of armour, under $15,000", "invertible vertical spinner called Molar".
static func parse_brief(text) -> Dictionary:
	var src := str(text if text != null else "")
	var t := " %s " % src.to_lower()
	# The weapon: the first weapon word in the text. "Wedge" is the weapon
	# only when nothing else is - "a low wedge with a lifter" is a lifter on
	# a wedge.
	var weapon = null
	var at := 1 << 30
	for ww in _weapon_table():
		var m: RegExMatch = ww[0].search(t)
		if m != null and m.get_start() < at:
			at = m.get_start()
			weapon = ww[1]
	var wedge_word := _has(t, "wedge|pusher|rammer|\\bram\\b|control bot")
	if weapon == null and wedge_word: weapon = {"cls": "static"}
	var template = null
	if _has(t, "twin|pods"): template = "twin"
	elif _has(t, "round|dome|circular|disc[- ]shaped"): template = "round"
	elif wedge_word or _has(t, "\\blow\\b"): template = "wedge"
	elif _has(t, "\\bslab\\b|flat"): template = "slab"
	elif _has(t, "arrow|dart"): template = "dart"
	elif _has(t, "\\bbox\\b|boxy|brick"): template = "box"
	var chassis = null
	if _has(t, "long"): chassis = "chassis_long"
	elif _has(t, "wide"): chassis = "chassis_wide"
	elif _has(t, "tall"): chassis = "chassis_tall_box"
	elif _has(t, "small|compact|tiny"): chassis = "chassis_compact"
	elif _has(t, "\\blow\\b|flat|slab"): chassis = "low"
	var extras := []
	if _has(t, "fork|wedgelet"): extras.append("forks")
	if _has(t, "plow|plough|scoop"): extras.append("plow")
	if _has(t, "wheel ?guard"): extras.append("wheelGuards")
	var p := {
		"weapon": weapon, "template": template, "chassis": chassis,
		"invertible": _has(t, "invertible|both ways|upside[- ]down|either way up"),
		"srimech": _has(t, "self[- ]?right|srimech"),
		"extras": extras,
		"priorities": {
			"speed": _has(t, "fast|quick|speed|nimble|agile|zippy"),
			"armour": _has(t, "armou?r|tough|tank|durable|survive|heavy plate"),
			"push": _has(t, "push|strong|torque|bully|shove"),
			"power": _has(t, "hit hard|big hits?|damage|destruct|kinetic|energy|powerful|heavy hitter"),
			"cheap": _has(t, "cheap|budget|inexpensive|low[- ]cost"),
		},
		"budget": null, "name": null,
	}
	var b := _re("\\$\\s?([\\d,.]+)\\s*(k)?").search(t)
	if b == null: b = _re("(?:under|budget of|for)\\s+([\\d,.]+)\\s*(k)?\\s*(?:dollars|bucks)").search(t)
	if b != null:
		var num := b.get_string(1).replace(",", "")
		if num.is_valid_float(): p.budget = J.rnd(num.to_float() * (1000.0 if b.get_string(2) != "" else 1.0))
	var n := _re("(?i)(?:called|named)\\s+[\"']?([A-Za-z0-9][\\w' &-]{0,26}?)[\"']?(?:[,.;!]|\\s+(?:with|and|that|which)\\b|$)").search(src)
	if n != null: p.name = n.get_string(1).strip_edges()
	return p

## How well a design matches what was asked for, on top of its trial-fight results.
static func _brief_score(sum: Dictionary, p: Dictionary, chassis: Dictionary) -> float:
	# Unused weight is wasted armour or power, whatever was asked for.
	var s: float = -maxf(0.0, sum.spareLb - 4.0) * 0.15
	var pr: Dictionary = p.priorities
	if pr.speed: s += (sum.topSpeedMph - 14.0) * 5.0
	# The shape asked for: "low" means a low chassis, "long" that frame, and so on.
	if p.chassis == "low": s += 6.0 if chassis.spec.sizeIn[1] <= 5.5 else -14.0
	elif p.chassis != null: s += 6.0 if chassis.id == p.chassis else -14.0
	if pr.armour: s += sum.armourHp / 55.0
	if pr.push: s += sum.pushRatio * 12.0
	if pr.power: s += sum.energyKJ * 0.6
	if pr.cheap: s -= sum.listPrice / 1200.0
	if p.invertible: s += 18.0 if sum.invertible else -18.0
	if p.srimech: s += 8.0 if (sum.selfRight != "none" or sum.invertible) else -12.0
	return s

static func _def_to_design(def: Dictionary) -> Dictionary:
	var body = J.clone(def.get("body"))
	var livery = J.clone(def.get("livery"))
	return {"name": def.get("name"), "body": body if body != null else {}, "build": J.clone(def.build), "livery": livery if livery != null else {}, "personality": def.get("personality")}

static func _with(d: Dictionary, changes: Dictionary) -> Dictionary:
	var o := d.duplicate()
	o.merge(changes, true)
	return o

# Everything the brief's helpers share.
class Brief:
	var reg: Registry
	var career = null
	var p: Dictionary
	var cap := INF
	var field: Array
	var salt := ""

	# What the design must cost (beyond parts already owned) and be allowed.
	func affordable(d: Dictionary) -> Dictionary:
		if career == null: return {"ok": true, "cost": 0.0}
		var q := Garage.quote(reg, career, d.build)
		return {"ok": q.locked.size() == 0 and q.total <= cap, "cost": q.total}

	func shape(d: Dictionary) -> Dictionary:
		var out: Dictionary = J.clone(d)
		if out.get("body") == null: out.body = {}
		if p.template != null: out.body.template = p.template
		if p.extras.size() > 0:
			var ex: Array = out.body.get("extras", []).duplicate()
			for type in p.extras: ex.append({"type": type})
			out.body.extras = Workshop.uniq_extras(ex)
		if p.weapon != null and p.weapon.get("mount") != null: out.body.mount = p.weapon.mount
		out.body = Workshop.fit_body(reg, out.body, out.build)
		return out

	func eval_design(d: Dictionary):
		var def := Advisor._my_def(reg, career, d)
		var sum = Workshop.summarize(reg, def)
		if sum == null or not sum.legal: return null
		var buy := affordable(d)
		if not buy.ok: return null
		if p.weapon != null and sum.weaponClass != p.weapon.cls: return null
		if p.weapon != null and p.weapon.get("part") != null and d.build.get("weapon") != p.weapon.part: return null
		var g8 := Trials.gauntlet(reg, def, field, {"seeds": 2, "salt": salt})
		return {"design": d, "sum": sum, "cost": buy.cost, "win": g8.winRate, "score": g8.winRate * 100.0 + Advisor._brief_score(sum, p, reg.part(d.build.chassis))}

## Turn a description into a legal, buildable design: start from proven
## layouts in the field with the asked-for weapon, then improve slot by slot,
## keeping only changes that win more trial fights or fit the brief better.
static func _design_from_brief(reg: Registry, req: Dictionary) -> Dictionary:
	var brief = req.get("brief")
	var career = req.get("career")
	var current = req.get("design")
	var p := parse_brief(brief)
	var g = Garage.garage_of(reg, career) if career != null else null
	var start: Dictionary
	if current != null: start = current
	elif g != null: start = _design_of(g)
	else: start = _def_to_design(reg.robot(reg.playerId))
	var x := Brief.new()
	x.reg = reg
	x.career = career
	x.p = p
	if req.get("budget") != null: x.cap = req.budget
	elif p.budget != null: x.cap = p.budget
	elif career != null: x.cap = maxf(0.0, career.cash)
	x.field = Trials.sample(_league_field(reg, career), 8, "brief:%s" % J.s(brief))
	x.salt = "brief:%s" % J.s(brief)

	var any_priority := false
	for k in p.priorities:
		if p.priorities[k]: any_priority = true
	if p.weapon == null and p.template == null and not any_priority and not p.invertible:
		return {
			"kind": "design", "title": "Tell me what you want to build",
			"summary": "Describe the robot in a sentence and I will turn it into a legal part list.",
			"points": [
				"Name a weapon: horizontal bar, undercutter, vertical disc, drum, hammer, flipper, lifter, crusher - or a wedge.",
				"Add a shape or a priority: low, round, invertible, fast, heavily armoured, strong pusher, cheap.",
				"A budget works too: \"a fast drum under $12,000\".",
			],
		}

	# Seeds: the proven layouts in the field with this weapon, and the
	# player's own robot with the weapon swapped in.
	var seeds := []
	var want = p.weapon.cls if p.weapon != null else null
	var want_part = p.weapon.get("part") if p.weapon != null else null
	for r in reg.roster():
		if r.get("partner") != null or r.id == reg.playerId: continue
		var cls := Workshop.weapon_class_of(reg, r.build)
		if want != null and cls != want: continue
		if want_part != null and r.build.get("weapon") != want_part: continue
		var mini := false
		for v in r.build.values():
			for id in (v if v is Array else [v]):
				if reg.has_part(id) and J.truthy(reg.part(id).spec.get("minibot")): mini = true
		if mini: continue
		var body = J.clone(r.get("body"))
		seeds.append(x.shape(_with(start, {"build": J.clone(r.build), "body": body if body != null else {}})))
	if want != null and Workshop.weapon_class_of(reg, start.build) != want:
		var part = want_part
		if part == null:
			var pool := J.sorted(Workshop.parts_for(reg, "weapon").filter(func(q): return q.spec["class"] == want), func(a, b): return a.cost - b.cost)
			if pool.size() > 0: part = pool[0].id
		if part != null:
			var b := Workshop.set_slot(reg, start.build, "weapon", part)
			if J.truthy(reg.part(part).spec.get("powered")) and not J.truthy(b.get("weaponMotor")): b = Workshop.set_slot(reg, b, "weaponMotor", "wmotor_mid")
			seeds.append(x.shape(_with(start, {"build": b})))
	else:
		seeds.append(x.shape(start))
	if p.chassis != null:
		for s in seeds.duplicate():
			var ids: Array = ["chassis_low_wedge", "chassis_slab_ti"] if p.chassis == "low" else [p.chassis]
			for id in ids:
				if reg.has_part(id): seeds.append(x.shape(_with(s, {"build": Workshop.set_slot(reg, s.build, "chassis", id)})))

	# Score the seeds, then climb from the best few.
	var scored := []
	for d in seeds:
		var r = _try_repair(reg, d, x)
		if r != null: scored.append(r)
	scored = J.sorted(scored, func(a, b): return b.score - a.score)
	if scored.is_empty():
		var what: String = "a %s" % _class_name(p.weapon.cls) if p.weapon != null else "that layout"
		return {
			"kind": "design", "title": "I could not make that work",
			"summary": "Nothing with %s fits the weight limit%s%s." % [what, " and %s" % _money(x.cap) if is_finite(x.cap) else "", " with the parts you can buy now" if career != null else ""],
			"points": ["Your budget is the problem: win some purses, or sell spare parts." if (career != null and x.cap < 3000) else "Try a lighter weapon, or drop a requirement."],
		}
	var best: Dictionary = scored[0]
	for s in scored.slice(0, 2):
		var climbed := _climb(reg, s, x, 2)
		if climbed.score > best.score: best = climbed
	var final: Dictionary = best.design.duplicate()
	if p.name != null: final.name = p.name
	var final_sum: Dictionary = Workshop.summarize(reg, _my_def(reg, career, final))
	var now := Trials.gauntlet(reg, _my_def(reg, career, start), x.field, {"seeds": 4, "salt": "report"})
	var then := Trials.gauntlet(reg, _my_def(reg, career, final), x.field, {"seeds": 4, "salt": "report"})

	var points := [
		"%s on %s: %s lb, %s mph, push %sx, %s hp of armour%s." % [final_sum.weaponName, reg.part(final.build.chassis).name, J.num(final_sum.weightLb), J.num(final_sum.topSpeedMph),
			J.num(final_sum.pushRatio), J.num(final_sum.armourHp), ", %s kJ" % J.num(final_sum.energyKJ) if final_sum.energyKJ != 0.0 else ""],
		"Runs upside down." if final_sum.invertible else ("Rights itself (%s)." % final_sum.selfRight if final_sum.selfRight != "none" else "Cannot right itself - a flip ends the fight."),
	]
	points.append_array(_why_class(reg, final_sum.weaponClass))
	points.append("Trial fights against %d %s: %s (your current robot: %s)." % [x.field.size(), "robots in your league" if career != null else "Rookie robots", _pct(then.winRate), _pct(now.winRate)])
	if career != null: points.append("New parts: %s (you have %s)." % [_money(best.cost), _money(career.cash)] if best.cost != 0.0 else "You own every part already.")
	# Say so when the shop held back what was asked for.
	if career != null and p.priorities.speed and final_sum.topSpeedMph < 15:
		var drive_parts := Workshop.parts_for(reg, "motor")
		drive_parts.append_array(Workshop.parts_for(reg, "wheel"))
		drive_parts.append_array(Workshop.parts_for(reg, "drive"))
		var faster = J.find(drive_parts, func(q): return not Garage.can_buy(reg, career, q.id).ok)
		if faster != null: points.append("For more speed you need better drive parts (motors, wheels, drivetrain): the faster ones are tier %s and unlock as you move up the leagues." % J.num(faster.get("tier")))
	# Say so when the shop could not supply the shape that was asked for.
	if career != null and p.chassis != null:
		var fits := func(c: Dictionary) -> bool:
			return c.spec.sizeIn[1] <= 5.5 if p.chassis == "low" else c.id == p.chassis
		if not fits.call(reg.part(final.build.chassis)):
			var wanted := J.sorted(Workshop.parts_for(reg, "chassis").filter(fits), func(a, b): return J.g(a, "tier", 1) - J.g(b, "tier", 1))
			if wanted.size() > 0:
				var why := Garage.can_buy(reg, career, wanted[0].id)
				if not why.ok: points.append("The chassis you described (%s) is not for sale to you yet: %s" % [wanted[0].name, why.reason])
	for w in final_sum.warnings.slice(0, 2): points.append("Note: %s" % w)
	return {
		"kind": "design", "title": "\"%s\"" % final.name if p.name != null else "A %s build" % _class_name(final_sum.weaponClass),
		"summary": "Here is a legal design for \"%s\"." % str(brief).strip_edges(),
		"points": points, "design": final, "evidence": {"winRate": then.winRate, "baseline": now.winRate, "fights": then.n, "cost": best.cost},
	}

## A seed may come in overweight or illegal once reshaped; try a few cheap fixes.
static func _try_repair(reg: Registry, d: Dictionary, x: Brief):
	var r = x.eval_design(d)
	if r != null: return r
	# Lighter armour panels (then none), heaviest first, until it fits.
	var c: Dictionary = J.clone(d)
	for i in 6:
		var armor: Array = c.build.get("armor", [])
		var parts := J.sorted(armor.map(func(id): return reg.part(id)), func(a, b): return b.weight - a.weight)
		if parts.is_empty(): break
		var heavy: Dictionary = parts[0]
		var lighter := J.sorted(Workshop.parts_for(reg, "armor", heavy.spec.slot).filter(func(q): return q.weight < heavy.weight), func(a, b): return b.weight - a.weight)
		var idx := armor.find(heavy.id)
		var na := armor.duplicate()
		if lighter.size() > 0: na[idx] = lighter[0].id
		else: na.remove_at(idx)
		c.build.armor = na
		var t = x.eval_design(c)
		if t != null: return t
	return null

## Greedy improvement, one slot at a time, for `rounds` passes.
static func _climb(reg: Registry, start: Dictionary, x: Brief, rounds: int) -> Dictionary:
	var best := start
	for r in rounds:
		var improved := false
		for slot in Workshop.slots_of(reg, best.design.build):
			if slot.key == "weapon": continue   # the weapon is what was asked for
			var options: Array = Workshop.parts_for(reg, slot.category, slot.get("face")).map(func(q): return q.id)
			if slot.optional: options.append(null)
			for id in options:
				if id == slot.partId: continue
				var build := Workshop.set_slot(reg, best.design.build, slot.key, id)
				var d := _with(best.design, {"build": build, "body": Workshop.fit_body(reg, best.design.get("body"), build)})
				var t = x.eval_design(d)
				if t != null and t.score > best.score + 0.5:
					best = t
					improved = true
		if not improved: break
	return best

static func _why_class(reg: Registry, cls) -> Array:
	var vs = J.path(reg.matchups, ["vs", cls])
	if vs == null: return []
	var pairs := []
	for c in vs: pairs.append([c, vs[c]])
	var good := J.sorted(pairs.filter(func(e): return e[1] >= 0.58), func(a, b): return b[1] - a[1]).map(func(e): return _class_name(e[0]))
	var bad := J.sorted(pairs.filter(func(e): return e[1] <= 0.42), func(a, b): return a[1] - b[1]).map(func(e): return _class_name(e[0]))
	var out := []
	if good.size() > 0: out.append("In physics testing %ss do best against: %s." % [_class_name(cls), ", ".join(good.slice(0, 3))])
	if bad.size() > 0: out.append("They struggle against: %s." % ", ".join(bad.slice(0, 3)))
	return out

# ---------------------------------------------------------------- tailor for an opponent

# The trial fights and the list of ideas for one opponent.
class Tailor:
	var reg: Registry
	var career: Dictionary
	var opp: Dictionary
	var opp_id
	var salt := ""
	var ideas := []

	# Both robots as they will turn up: the damage they carry is part of the
	# fight. A changed design carries the damage only of the parts it keeps.
	func test(d: Dictionary) -> float:
		var mine: Dictionary = Garage.carry_condition(reg, Garage.garage_of(reg, career), d.build).condition
		var cond := {career.playerId: [mine] if not mine.is_empty() else null, opp_id: Career.wear_of(reg, career, opp_id)}
		return Trials.gauntlet(reg, Advisor._my_def(reg, career, d), [opp], {"seeds": Advisor.MATCH_SEEDS, "salt": salt, "cond": cond}).winRate

	func add(label: String, d: Dictionary, notes: String) -> void:
		var sum = Workshop.summarize(reg, Advisor._my_def(reg, career, d))
		if sum == null or not sum.legal: return
		var q := Garage.quote(reg, career, d.build)
		if q.locked.size() > 0: return
		ideas.append({"label": label, "design": d, "notes": notes, "cost": q.total, "win": test(d)})

## Changes aimed at one opponent, each tested: the armour where its weapon
## lands, a way back from a flip, forks or a plow against a horizontal bar, a
## different driving style. Combinations of the best are tested too.
static func _tailor_for_opponent(reg: Registry, req: Dictionary) -> Dictionary:
	var career: Dictionary = req.career
	var opp_id = req.oppId
	var g := Garage.garage_of(reg, career)
	var base: Dictionary = req.design if req.get("design") != null else _design_of(g)
	var opp := Career.fielded_def(reg, career, opp_id)
	var opp_sum: Dictionary = Workshop.summarize(reg, opp)
	var mine: Dictionary = Workshop.summarize(reg, _my_def(reg, career, base))
	var x := Tailor.new()
	x.reg = reg
	x.career = career
	x.opp = opp
	x.opp_id = opp_id
	x.salt = "opp:%s:%s" % [opp_id, J.s(career.seasonIndex)]
	var base_win := x.test(base)
	var opp_cls: String = opp_sum.weaponClass
	var faces: Array = THREAT_FACES.get(opp_cls, ["front"])
	var body: Dictionary = J.g(base, "body", {})

	# 1. Armour where its weapon lands, paid for by the faces it rarely hits.
	for face in faces:
		var d = Workshop.reinforce(reg, base, face, faces)
		if d != null: x.add("Heavier %s armour" % face, d, "%s's %s mostly hits the %s." % [opp.name, _class_name(opp_cls), face])
	# 2. A way back from a flip, against something that turns robots over.
	if FLIPPERS.has(opp_cls) and not mine.invertible and mine.selfRight == "none":
		for id in ["srimech_arm", "srimech_pneumatic"]:
			if not reg.has_part(id): continue
			var d = Workshop.fit_within(reg, _with(base, {"build": Workshop.set_slot(reg, base.build, "srimech", id)}), ["top", "rear"])
			if d != null: x.add("Fit a %s" % reg.part(id).name, d, "%ss win by flipping - and you cannot get back over." % J.cap(_class_name(opp_cls)))
	# 3. Forks or a plow: a horizontal bar glances off a wedge.
	if opp_cls == "spinner_h":
		for type in ["forks", "plow"]:
			var extras: Array = body.get("extras", [])
			if J.some(extras, func(e): return e.type == type): continue
			var ne := extras.duplicate()
			ne.append({"type": type})
			var d := _with(base, {"body": Workshop.fit_body(reg, _with(body, {"extras": ne}), base.build)})
			x.add("Add %s" % ("a plow" if type == "plow" else "forks"), d, "A horizontal bar that hits a wedge rides up it and loses most of its hit.")
	# 4. Out-drive a slow, heavy-hitting opponent; out-push a pusher.
	if ["hammer", "crusher", "spinner_h"].has(opp_cls) or opp_sum.pushRatio > mine.pushRatio:
		for m in Workshop.parts_for(reg, "motor"):
			if m.id == base.build.get("motor"): continue
			var d = Workshop.fit_within(reg, _with(base, {"build": Workshop.set_slot(reg, base.build, "motor", m.id)}), ["rear", "top", "side"])
			if d != null: x.add("Drive motors: %s" % m.name, d, "It out-pushes you now." if opp_sum.pushRatio > mine.pushRatio else "Speed keeps you out of its reach.")
	# 5. Driving style (no parts): who should press, who should wait.
	for style in ["aggressive", "defensive", "opportunistic"]:
		if style == base.get("personality"): continue
		x.add("Drive %s" % ("opportunistically" if style == "opportunistic" else style + "ly"), _with(base, {"personality": style}), _style_note(style, opp_cls))

	# The best two together, if they are compatible.
	var good := J.sorted(x.ideas.filter(func(i): return i.win > base_win + 0.025), func(a, b): return b.win - a.win)
	if good.size() >= 2:
		var combo = _merge_designs(reg, base, good[0].design, good[1].design)
		if combo != null: x.add("%s + %s" % [good[0].label, str(good[1].label).to_lower()], combo, "The two best changes together.")
	var ranked := J.sorted(x.ideas.filter(func(i): return i.win > base_win + 0.025), func(a, b):
		var dw: float = b.win - a.win
		return dw if dw != 0.0 else a.cost - b.cost).slice(0, 4)
	var sc := Catalog.scouting(reg, opp)
	var points := [
		"%s: %s (%s), %s mph, push %sx, %s hp of armour." % [opp.name, sc.weapon, _class_name(opp_cls), J.num(opp_sum.topSpeedMph), J.num(opp_sum.pushRatio), J.num(opp_sum.armourHp)],
		"Your robot as it stands wins %s of %d trial fights against it." % [_pct(base_win), MATCH_SEEDS],
	]
	points.append_array(_matchup_line(reg, mine.weaponClass, opp_cls))
	if ranked.is_empty(): points.append("Nothing I tried does clearly better - your current build is a fair answer to it.")
	return {
		"kind": "opponent", "title": "Against %s" % opp.name,
		"summary": "%d change%s that win more often, each tested in %d trial fights." % [ranked.size(), "s" if ranked.size() > 1 else "", MATCH_SEEDS] if ranked.size() > 0 else "Your robot is already a fair answer.",
		"points": points,
		"options": ranked.map(func(i): return {"label": i.label, "design": i.design, "winRate": i.win, "delta": i.win - base_win, "cost": i.cost, "notes": i.notes}),
		"evidence": {"baseline": base_win, "fights": MATCH_SEEDS},
	}

## Two tweaks of the same base, together: take every slot either one changed.
static func _merge_designs(reg: Registry, base: Dictionary, a: Dictionary, b: Dictionary):
	var build: Dictionary = J.clone(a.build)
	var keys := {}
	for k in base.build: keys[k] = true
	for k in b.build: keys[k] = true
	for k in keys:
		if k == "armor": continue
		if b.build.get(k) != base.build.get(k):
			if b.build.get(k) != null: build[k] = b.build[k]
			else: build.erase(k)
	var sb := Workshop.slots_of(reg, b.build)
	var s0 := Workshop.slots_of(reg, base.build)
	var out := build
	for s in sb:
		var was = null
		for z in s0:
			if z.key == s.key:
				was = z.partId
				break
		if s.category == "armor" and s.partId != was: out = Workshop.set_slot(reg, out, s.key, s.partId)
	var ex: Array = J.g(a.get("body"), "extras", []).duplicate()
	ex.append_array(J.g(b.get("body"), "extras", []))
	var body := _with(J.g(a, "body", {}), {"extras": Workshop.uniq_extras(ex)})
	var d := _with(base, {"build": out, "body": Workshop.fit_body(reg, body, out),
		"personality": b.get("personality") if b.get("personality") != base.get("personality") else a.get("personality")})
	return Workshop.fit_within(reg, d, ["rear", "top", "side"])

# ---------------------------------------------------------------- fight plan

## A game plan for one fight, from the matchup and both robots' numbers.
static func _fight_plan(reg: Registry, req: Dictionary) -> Dictionary:
	var career: Dictionary = req.career
	var opp_id = req.oppId
	var g := Garage.garage_of(reg, career)
	var base: Dictionary = req.design if req.get("design") != null else _design_of(g)
	var me_def := _my_def(reg, career, base)
	var opp := Career.fielded_def(reg, career, opp_id)
	var me: Dictionary = Workshop.summarize(reg, me_def)
	var them: Dictionary = Workshop.summarize(reg, opp)
	var sc := Catalog.scouting(reg, opp)
	# The same trial fights the opponent advice uses, so the two never disagree.
	var salt := "opp:%s:%s" % [opp_id, J.s(career.seasonIndex)]
	var cond := {career.playerId: Career.wear_of(reg, career, career.playerId), opp_id: Career.wear_of(reg, career, opp_id)}
	var styles := []
	for style in ["aggressive", "opportunistic", "defensive"]:
		styles.append({"style": style, "win": Trials.gauntlet(reg, _with(me_def, {"personality": style}), [opp], {"seeds": MATCH_SEEDS, "salt": salt, "cond": cond}).winRate})
	styles = J.sorted(styles, func(a, b): return b.win - a.win)
	var best_style: Dictionary = styles[0]
	var current: Dictionary = styles[0]
	for s in styles:
		if s.style == base.get("personality"):
			current = s
			break

	var pts := []
	pts.append_array(_matchup_line(reg, me.weaponClass, them.weaponClass))
	var tc: String = them.weaponClass
	# Their weapon.
	if ["spinner_h", "spinner_v", "drum"].has(tc):
		pts.append("Their %s stores %s kJ and needs %s s to spin back up: hit them in the opening seconds or straight after they land one." % [_class_name(tc), J.num(them.energyKJ), J.num(them.spinUpS) if them.spinUpS != null else "?"])
		if tc == "spinner_h": pts.append("A horizontal bar hits your sides and front - never give it a side. Come at it nose-first, and a wedge or forks make its hits glance.")
		else: pts.append("A %s only hits what is in front of it: get round to its side or back." % _class_name(tc))
	elif tc == "hammer": pts.append("A hammer has to line you up and reload after every swing: keep moving, and go in right after it fires.")
	elif tc == "crusher": pts.append("Do not let the jaw close on you - once it has you it holds and bites again. Stay out of its front.")
	elif FLIPPERS.has(tc): pts.append("It wins by getting under you and turning you over: never give it your nose square-on%s." % ("" if (me.invertible or me.selfRight != "none") else ", and you cannot right yourself, so one flip ends it"))
	elif tc == "static": pts.append("A wedge cannot hurt you much - it wants you in the hazards or stranded on top of it. Keep off the walls and the screws.")
	# Damage either side is carrying in: their pit did not fix everything.
	var opp_a := Build.assemble_robot(reg, opp)
	var ow = Career.wear_of(reg, career, opp_id)
	if ow != null and ow.size() > 0 and ow[0] is Dictionary:
		for k in ow[0]: opp_a.condition[k] = ow[0][k]
	var hurt := J.sorted(opp_a.fittings.filter(func(f): return J.g(opp_a.condition, f.key, 1.0) < 0.7), func(a, b): return opp_a.condition[a.key] - opp_a.condition[b.key]).slice(0, 3)
	if hurt.size() > 0:
		var parts := ", ".join(hurt.map(func(f): return "%s at %d%%" % [f.part.name, J.rndi(opp_a.condition[f.key] * 100.0)]))
		var face = J.find(hurt, func(f): return f.part.category == "armor")
		var drive_hurt := J.some(hurt, func(f): return ["drive", "motor", "wheel"].has(f.part.category))
		pts.append("It comes in damaged from its last fight: %s.%s%s" % [parts, " Go for its %s - that panel will not take much more." % face.part.spec.slot if face != null else "", " Its drive is hurt: out-push it." if drive_hurt else ""])
	var mine_a := Build.assemble_robot(reg, me_def)
	var mw = Career.wear_of(reg, career, career.playerId)
	if mw != null and mw.size() > 0 and mw[0] is Dictionary:
		for k in mw[0]: mine_a.condition[k] = mw[0][k]
	var my_hurt: Array = mine_a.fittings.filter(func(f): return J.g(mine_a.condition, f.key, 1.0) < 0.6).map(func(f): return f.part.name)
	if my_hurt.size() > 0: pts.append("You are carrying damage yourself (%s): protect it, or fix it in the pit first." % ", ".join(my_hurt.slice(0, 3)))
	# Their weak points, from the scouting card.
	for w in sc.weak.slice(0, 3): pts.append("Weak point: %s" % w)
	# Speed and push.
	if me.topSpeedMph > them.topSpeedMph + 1.5: pts.append("You are faster (%s vs %s mph): pick your moments and take their flanks." % [J.num(me.topSpeedMph), J.num(them.topSpeedMph)])
	elif them.topSpeedMph > me.topSpeedMph + 1.5: pts.append("They are faster (%s vs %s mph): do not chase - make them come to your weapon." % [J.num(them.topSpeedMph), J.num(me.topSpeedMph)])
	if me.pushRatio > them.pushRatio + 0.1: pts.append("You out-push them (%sx vs %sx): shove them into the walls and hazards for control points." % [J.num(me.pushRatio), J.num(them.pushRatio)])
	elif them.pushRatio > me.pushRatio + 0.1: pts.append("They out-push you (%sx vs %sx): stay out of shoving matches near the hazards." % [J.num(them.pushRatio), J.num(me.pushRatio)])
	# Can we finish it with a flip?
	if FLIPPERS.has(me.weaponClass) and not them.invertible and them.selfRight == "none": pts.append("It cannot right itself: one good flip wins the fight.")
	var pb = AI.PLAYBOOK.get("wedge" if me.weaponClass == "static" else me.weaponClass)
	if pb != null and J.g(pb, "herdBias", 0.0) >= 0.8: pts.append("Your weapon does its best work with the arena's help: herd them toward the pulverizers and screws.")

	var better: bool = best_style.style != current.style and best_style.win > current.win + 0.04
	return {
		"kind": "fight", "title": "Game plan: %s" % opp.name,
		"summary": "Trial fights give you %s driving %s%s." % [_pct(current.win), current.style, "; %s driving %s" % [_pct(best_style.win), best_style.style] if better else ""],
		"points": pts,
		"evidence": {"styles": styles, "fights": MATCH_SEEDS},
		"options": [{"label": "Set your AI driver to %s" % best_style.style, "design": _with(base, {"personality": best_style.style}), "winRate": best_style.win, "delta": best_style.win - current.win, "cost": 0,
			"notes": "Used when your AI driver fights for you, and when you hand it the controls in the arena."}] if better else [],
	}

# ---------------------------------------------------------------- season plan

## Where the season stands, what the league is made of, and the best value
## upgrades for the money: every affordable one-part change is tested against
## the league and ranked by win rate gained per dollar.
static func _season_plan(reg: Registry, req: Dictionary) -> Dictionary:
	var career: Dictionary = req.career
	var g := Garage.garage_of(reg, career)
	var base: Dictionary = req.design if req.get("design") != null else _design_of(g)
	var lg = Career.player_league(career)
	var field := _league_field(reg, career)
	var me_def := _my_def(reg, career, base)
	var salt := "season:%s" % J.s(career.seasonIndex)
	var now := Trials.gauntlet(reg, me_def, field, {"seeds": 2, "salt": salt})

	# League make-up.
	var mix := {}
	for o in field:
		var c := Workshop.weapon_class_of(reg, o.build)
		mix[c] = mix.get(c, 0) + 1
	var mix_pairs := []
	for c in mix: mix_pairs.append([c, mix[c]])
	var mix_text := ", ".join(J.sorted(mix_pairs, func(a, b): return b[1] - a[1]).map(func(e): return "%d %s%s" % [e[1], _class_name(e[0]), "s" if e[1] > 1 else ""]))
	var worst: Array = now.byOpp.filter(func(o): return o.wins == 0).slice(0, 4).map(func(o): return o.name)

	# Money: what a fight costs to fix, roughly, and how many that buys.
	var econ: Dictionary = reg.economy.league[lg]
	var reserve := J.rnd((econ.appearance + econ.win) * 2.5)
	var spend := maxf(0.0, career.cash - reserve)

	# Upgrades: every one-slot change the shop sells, tested on a sample.
	var sample_field := Trials.sample(field, 10, salt)
	var base_win: float = Trials.gauntlet(reg, me_def, sample_field, {"seeds": 2, "salt": "%s:u" % salt}).winRate
	var ups := []
	var body = base.get("body")
	for slot in Workshop.slots_of(reg, base.build):
		var pool := Workshop.parts_for(reg, slot.category, slot.get("face"))
		if slot.key == "weapon":
			var my_cls := Workshop.weapon_class_of(reg, base.build)
			pool = pool.filter(func(q): return J.truthy(base.build.get("weapon")) and q.spec["class"] == my_cls)
		for part in pool:
			if part.id == slot.partId or not Garage.can_buy(reg, career, part.id).ok: continue
			var build := Workshop.set_slot(reg, base.build, slot.key, part.id)
			var d = Workshop.fit_within(reg, _with(base, {"build": build, "body": Workshop.fit_body(reg, body, build)}), ["rear", "top", "side"])
			if d == null: continue
			var q := Garage.quote(reg, career, d.build)
			if q.total > spend or q.total <= 0: continue
			var win: float = Trials.gauntlet(reg, _my_def(reg, career, d), sample_field, {"seeds": 2, "salt": "%s:u" % salt}).winRate
			if win > base_win + 0.03: ups.append({"label": "%s: %s" % [slot.label, part.name], "design": d, "winRate": win, "delta": win - base_win, "cost": q.total, "notes": ""})
	ups = J.sorted(ups, func(a, b): return b.delta / b.cost - a.delta / a.cost)

	var points := [
		"%s league, %s." % [_league_name(lg), mix_text],
		"Your robot wins %s of %d trial fights across the league.%s" % [_pct(now.winRate), now.n, " Hardest: %s." % ", ".join(worst) if worst.size() > 0 else ""],
		"You have %s. Keep about %s back for repairs; that leaves %s to spend." % [_money(career.cash), _money(reserve), _money(spend)],
	]
	var finals_cut = J.path(reg.league, ["league", "finals", "perGroup"], 2)
	points.append("To go up: finish in the top %s of your group of five to reach the 16-robot finals, then reach the last four." % J.num(finals_cut))
	var best_class = _class_advice(reg, mix)
	if best_class != null: points.append(best_class)
	if ups.is_empty(): points.append("Nothing worth buying fits the budget yet: bank some purses first." if spend < 1000 else "No single part makes a clear difference right now - save for a bigger change.")
	return {
		"kind": "season", "title": "Season %s plan" % J.num(career.seasonIndex),
		"summary": "%d upgrade%s that pay their way, tested against your league." % [mini(3, ups.size()), "s" if ups.size() > 1 else ""] if ups.size() > 0 else "Where you stand this season.",
		"points": points, "options": ups.slice(0, 3), "evidence": {"winRate": now.winRate, "fights": now.n, "mix": mix},
	}

## Which weapon class the measured matchups favour against this league's mix.
static func _class_advice(reg: Registry, mix: Dictionary):
	var m = J.g(reg.matchups, "vs")
	if m == null: return null
	var total := 0.0
	for n in mix.values(): total += n
	var score := []
	for c in m:
		var s := 0.0
		var w := 0.0
		for d in mix:
			var v = 0.5 if d == c else m[c].get(d)
			if v == null: continue
			s += v * mix[d]
			w += mix[d]
		score.append({"c": c, "v": s / w if w != 0.0 else 0.5})
	score = J.sorted(score, func(a, b): return b.v - a.v)
	if score.is_empty() or total == 0.0: return null
	var top: Dictionary = score[0]
	return "Against this league's mix, %ss have the best measured record (%s in physics testing) - worth knowing if you are planning a rebuild." % [_class_name(top.c), _pct(top.v)]

# ---------------------------------------------------------------- bits

static func _matchup_line(reg: Registry, mine, theirs) -> Array:
	var v = J.path(reg.matchups, ["vs", mine, theirs])
	if v == null or mine == theirs: return []
	var wins_by: Dictionary = J.path(reg.matchups, ["winsBy", mine], {})
	var pairs := []
	for h in wins_by: pairs.append([h, wins_by[h]])
	pairs = J.sorted(pairs, func(a, b): return b[1] - a[1])
	var how = pairs[0][0] if pairs.size() > 0 else null
	var verdict := "an even matchup"
	if v >= 0.58: verdict = "a good matchup for you"
	elif v <= 0.42: verdict = "a hard matchup for you"
	return ["In physics testing %ss beat %ss %s of the time: %s%s." % [_class_name(mine), _class_name(theirs), _pct(v), verdict, " (they mostly win by %s)" % _how_name(how) if how != null else ""]]

static func _how_name(h) -> String:
	return {"ko:disabled": "breaking the opponent", "ko:flipped": "flipping", "ko:beached": "beaching", "ko:pitted": "the pit", "decision": "the judges", "tapout": "tap-outs"}.get(h, str(h))

static func _style_note(style: String, opp_cls: String) -> String:
	if style == "aggressive": return "Press it before its weapon is up to speed." if ["spinner_h", "spinner_v", "drum"].has(opp_cls) else "Keep it under pressure."
	if style == "defensive": return "Wait for its mistakes and keep your distance."
	return "Flank it and punish openings."
