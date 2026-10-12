## ailearn.gd - AI teams that adapt and learn, the way real teams do.
##
## Every AI robot in a career has a MEMORY (career.ai[id]):
##   vs[class]   its record against each weapon class, how it lost, and the
##               tactics it has learned for that class (flank / press / herd)
##   setups[class][change]   how each pre-fight change has worked against
##               that class - +1 for a win with it fitted, -1 for a loss
##
## BEFORE a fight (prepare_for) it sets the robot up for that opponent; IN the
## fight its driver learns as it goes (ai.gd, resolver.gd); AFTER the fight
## (learn_from_fight) it remembers the result; IN the pit it fixes first what
## the NEXT opponent will hit (pit_prefer); and in the OFF-SEASON it shops for
## what has been beating it (learned_upgrades, read by evolution.gd).
##
## Pure logic over the career save.
class_name AILearn

## Where each weapon class mostly lands its hits.
const THREAT_FACES := {
	"spinner_h": ["side", "front"], "spinner_v": ["front", "top"], "drum": ["front"], "hammer": ["top"],
	"crusher": ["top", "front"], "flipper": ["front"], "lifter": ["front"], "static": ["front"], "none": ["front"],
}
const FLIPS := ["flipper", "lifter", "spinner_v"]
const TIER_OF := {"rookie": 1, "pro": 2, "elite": 3, "world": 3}

## A robot's memory, made on first use.
static func memory_of(career: Dictionary, id) -> Dictionary:
	if career.get("ai") == null: career.ai = {}
	if career.ai.get(id) == null: career.ai[id] = {"vs": {}, "setups": {}, "fights": 0}
	return career.ai[id]

## The tactics a robot has learned against a weapon class.
static func tactics_vs(career: Dictionary, id, opp_class):
	var t = J.path(career, ["ai", id, "vs", opp_class, "t"])
	if t == null: return null
	return {"flank": _z(t.get("flank")), "aggression": _z(t.get("aggression")), "herd": _z(t.get("herd"))}

static func _z(v) -> float:
	return 0.0 if v == null else float(v)

# ---------------------------------------------------------------- before a fight

# The same robot against the same weapon class has the same options: a season
# asks thousands of times, so remember them (not saved - derived).
static var _option_cache := {}

## The changes a team could make to its robot for this opponent. Each is
## { label, design, why } where design is the robot's { build, body,
## personality }, legal and on weight.
static func setup_options(reg: Registry, def: Dictionary, opp_def: Dictionary) -> Array:
	var opp_cls := Workshop.weapon_class_of(reg, opp_def.build)
	var key := "%s|%s|%s|%s|%s" % [def.id, def.get("league"), JSON.stringify(def.build), JSON.stringify(def.get("body")), opp_cls]
	if _option_cache.has(key): return _option_cache[key]
	if _option_cache.size() > 4000: _option_cache.clear()
	var result := _compute_options(reg, def, opp_def)
	_option_cache[key] = result
	return result

static func _add_option(reg: Registry, def: Dictionary, out: Array, label: String, d: Dictionary, why: String) -> void:
	var fitted = Workshop.fit_within(reg, d, ["rear", "top", "side"])
	if fitted == null: return
	var merged := def.duplicate()
	merged.merge(fitted, true)
	var sum = Workshop.legality_of(reg, merged)
	if sum == null or not sum.legal: return
	out.append({"label": label, "design": fitted, "why": why})

static func _compute_options(reg: Registry, def: Dictionary, opp_def: Dictionary) -> Array:
	var opp_cls := Workshop.weapon_class_of(reg, opp_def.build)
	var my_cls := Workshop.weapon_class_of(reg, def.build)
	var tier: float = J.g(TIER_OF, def.get("league"), 1)
	var body0 = J.clone(def.get("body"))
	var base := {"name": def.get("name"), "build": J.clone(def.build), "body": body0 if body0 != null else {}, "livery": def.get("livery"), "personality": def.get("personality")}
	var out := []
	if def.get("partner") != null: return out   # a multibot keeps its pair as built

	# 1. The weapon: a heavier or lighter rotor, a different blade - whatever
	#    of the same kind its body carries and the team can get at this level.
	var cur = reg.part(def.build.weapon) if J.truthy(def.build.get("weapon")) else null
	if cur != null and J.truthy(cur.spec.get("powered")):
		var cur_e := _energy_of(reg, def.build)
		for p in Workshop.parts_for(reg, "weapon"):
			if p.id == cur.id or p.spec["class"] != cur.spec["class"] or J.g(p, "tier", 1) > tier: continue
			var build := Workshop.set_slot(reg, def.build, "weapon", p.id)
			if not Workshop.mounts_for(reg, build).has(J.g(def.get("body"), "mount", "front")): continue
			var e := _energy_of(reg, build)
			var different: bool = J.g(p.spec, "style", "") != J.g(cur.spec, "style", "") or p.spec.get("radiusIn") != cur.spec.get("radiusIn")
			var label: String
			if e > cur_e * 1.08: label = "heavier %s" % p.name
			elif e < cur_e * 0.92: label = "lighter, faster-spinning %s" % p.name
			else: label = "%s %s" % ["a different" if different else "another", p.name]
			var d := base.duplicate()
			d.build = build
			d.body = Workshop.fit_body(reg, base.body, build)
			_add_option(reg, def, out, label, d, "more energy per hit" if e > cur_e else "spins up faster between hits")
	# 2. A wedge on the front: forks or a plow make a horizontal bar glance
	#    off and get under pushers, lifters and flippers.
	if ["spinner_h", "static", "lifter", "flipper"].has(opp_cls):
		for type in ["forks", "plow"]:
			var extras: Array = base.body.get("extras", [])
			if J.some(extras, func(e): return e.type == type): continue
			if base.body.get("mount") == "low" or my_cls == "static": continue
			var nb: Dictionary = base.body.duplicate()
			var ne := extras.duplicate()
			ne.append({"type": type})
			nb.extras = Workshop.uniq_extras(ne)
			var d := base.duplicate()
			d.body = nb
			_add_option(reg, def, out, "added %s" % ("a plow" if type == "plow" else "wedge forks"), d,
				"a horizontal bar glances off a wedge" if opp_cls == "spinner_h" else "gets under it first")
	# 3. Armour where this opponent hits.
	var faces: Array = THREAT_FACES.get(opp_cls, ["front"])
	for face in faces:
		var d = Workshop.reinforce(reg, base, face, faces)
		if d != null: _add_option(reg, def, out, "heavier %s armour" % face, d, "its %s hits the %s" % [opp_cls.replace("_", " "), face])
	# 4. A way back over, against something that flips.
	if FLIPS.has(opp_cls) and not J.truthy(def.build.get("srimech")):
		var a := Build.assemble_robot(reg, def)
		var inv: bool = Shape.build_shape(a).invertible
		if not inv and a.stats.selfRight.via != "weapon":
			var d := base.duplicate()
			d.build = Workshop.set_slot(reg, def.build, "srimech", "srimech_arm")
			_add_option(reg, def, out, "fitted a self-righter", d, "it wins by flipping")
	return out

static func _energy_of(reg: Registry, build: Dictionary) -> float:
	if not J.truthy(build.get("weapon")): return 0.0
	var w: Dictionary = reg.part(build.weapon).spec
	if J.truthy(w.get("impactEnergyJ")): return w.impactEnergyJ
	var r: float = _or(w.get("radiusIn"), 6.0) * 0.0254
	var om: float = _or(w.get("maxTipSpeedMps"), 100.0) / r
	return 0.5 * _z(w.get("rotorInertiaKgM2")) * om * om

static func _or(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if f == 0.0 else f

## How promising a change looks before any testing: memory first, then the matchup.
static func _prior_score(career: Dictionary, id, opp_cls: String, opt: Dictionary) -> float:
	var mem: float = J.path(career, ["ai", id, "setups", opp_cls, key_of(opt.label)], 0.0)
	var s := mem * 0.25
	var l: String = opt.label
	if l.contains("forks") or l.contains("plow"): s += 0.35 if opp_cls == "spinner_h" else 0.12
	if l.contains("self-righter"): s += 0.4
	if l.contains("armour"): s += 0.15
	if l.contains("heavier"): s += 0.2 if ["hammer", "crusher", "static", "lifter"].has(opp_cls) else 0.05
	if l.contains("lighter"): s += 0.12 if ["spinner_h", "spinner_v", "drum"].has(opp_cls) else -0.05
	return s

## Memory keys ignore the specific part ("heavier 34in bar" and "heavier 26in
## bar" are both "heavier").
static func key_of(label: String) -> String:
	var first := label.split(" ")[0]
	if first == "heavier" or first == "lighter,": return first.replace(",", "")
	# label.replace(/ \d.*$/, "")
	for i in range(label.length() - 1):
		if label[i] == " " and label[i + 1] >= "0" and label[i + 1] <= "9": return label.substr(0, i)
	return label

## Set a robot up for one fight. Returns the def it fights as and the changes
## made (for scouting and the results), and remembers it for learn_from_fight.
##   o.depth   0: judge from memory (AI vs AI, instant); n: test the best n
##             options in trial fights (against the player)
##   o.fights  trial fights per option
##   o.cond    { id: [conditions] } for the trial fights
##   o.salt, o.explore
static func prepare_for(reg: Registry, career: Dictionary, id, def: Dictionary, opp_def: Dictionary, o: Dictionary = {}) -> Dictionary:
	var depth: int = int(J.g(o, "depth", 0))
	var fights: int = int(J.g(o, "fights", 12))
	var salt = J.g(o, "salt", "")
	var cond = o.get("cond")
	var explore: float = J.g(o, "explore", 0.15)
	var opp_cls := Workshop.weapon_class_of(reg, opp_def.build)
	var tactics = tactics_vs(career, id, opp_cls)
	var fighting := func(d: Dictionary) -> Dictionary:
		var f := def.duplicate()
		f.build = d.build
		f.body = d.get("body")
		f.personality = d.get("personality")
		f.tactics = tactics
		f.learnRate = def.get("learnRate")
		return f
	var opts := []
	for op in setup_options(reg, def, opp_def):
		var c: Dictionary = op.duplicate()
		c.prior = _prior_score(career, id, opp_cls, op)
		opts.append(c)
	opts = J.sorted(opts, func(a, b): return b.prior - a.prior)
	var chosen := []
	var plain := {"build": def.build, "body": def.get("body"), "personality": def.get("personality")}
	if depth > 0 and opts.size() > 0:
		# Test the best-looking options (and the best two together) against this opponent.
		var t := func(d: Dictionary) -> float:
			return Trials.gauntlet(reg, fighting.call(d), [opp_def], {"seeds": fights, "salt": "prep:%s" % J.s(salt), "cond": cond}).winRate
		var base: float = t.call(plain)
		var tried := []
		for op in opts.slice(0, depth):
			var c: Dictionary = op.duplicate()
			c.win = t.call(op.design)
			tried.append(c)
		tried = J.sorted(tried, func(a, b): return b.win - a.win)
		var good := tried.filter(func(x): return x.win > base + 0.04)
		if good.size() >= 2:
			var both = _combine(reg, def, good[0], good[1])
			if both != null:
				var w: float = t.call(both.design)
				if w > good[0].win + 0.03:
					both.win = w
					chosen = [both]
		if chosen.is_empty() and good.size() > 0: chosen = [good[0]]
	elif opts.size() > 0:
		# Judgement: the most promising change, if it looks worth making; and
		# now and then something new, which is how a team finds out.
		var rng := Rng.new(Rng.hash_seed("prep:%s:%s:%s" % [J.s(career.seed), J.s(salt), id]))
		if rng.next() < explore: chosen = [opts[int(floor(rng.next() * opts.size()))]]
		elif opts[0].prior >= 0.15: chosen = [opts[0]]
	var pick = chosen[0] if chosen.size() > 0 else null
	var d: Dictionary = pick.design if pick != null else plain
	var changes: Array = Array(pick.label.split(" + ")) if pick != null else []
	memory_of(career, id).pending = {"oppClass": opp_cls, "changes": changes}
	return {"def": fighting.call(d), "changes": changes, "tactics": tactics}

## Two changes made together, if they still fit.
static func _combine(reg: Registry, def: Dictionary, a: Dictionary, b: Dictionary):
	var build: Dictionary = J.clone(a.design.build)
	var bb: Dictionary = b.design.build
	for k in bb:
		if k != "armor" and bb[k] != def.build.get(k): build[k] = bb[k]
	if bb.get("armor") != def.build.get("armor"): build.armor = bb.get("armor")
	var body: Dictionary = J.g(a.design, "body", {}).duplicate()
	var ex: Array = J.g(a.design.get("body"), "extras", []).duplicate()
	ex.append_array(J.g(b.design.get("body"), "extras", []))
	body.extras = Workshop.uniq_extras(ex)
	var nd: Dictionary = a.design.duplicate()
	nd.build = build
	nd.body = Workshop.fit_body(reg, body, build)
	var d = Workshop.fit_within(reg, nd, ["rear", "top"])
	return {"label": "%s + %s" % [a.label, b.label], "design": d} if d != null else null

# ---------------------------------------------------------------- after a fight

## Remember a fight: the record against that class, how it lost, whether the
## setup it ran worked, and the tactics to try next time - including what its
## driver learned during the fight (physics fights report it).
##   o { oppClass, won, method, cause, learned?: { flank, aggression }, learnRate }
static func learn_from_fight(career: Dictionary, id, o: Dictionary) -> void:
	var opp_class = o.get("oppClass")
	var won: bool = J.truthy(o.get("won"))
	var method = o.get("method")
	var cause = o.get("cause")
	var learned = o.get("learned")
	var learn_rate: float = J.g(o, "learnRate", 0.7)
	var m := memory_of(career, id)
	if m.vs.get(opp_class) == null: m.vs[opp_class] = {"f": 0, "w": 0, "lossBy": {}, "t": {"flank": 0.0, "aggression": 0.0, "herd": 0.0}}
	var v: Dictionary = m.vs[opp_class]
	v.f += 1
	if won: v.w += 1
	m.fights += 1
	var lr := 0.12 * learn_rate
	var how: String = "ko:%s" % (cause if J.truthy(cause) else "disabled") if method == "ko" else str(method)
	if not won: v.lossBy[how] = v.lossBy.get(how, 0) + 1
	# Tactics: lost on points -> press harder; knocked out by a weapon -> come
	# in from the side; flipped or beached -> keep the nose away and herd.
	if not won:
		if method == "decision": v.t.aggression += lr
		elif cause == "flipped" or cause == "beached":
			v.t.flank += lr
			v.t.herd -= lr * 0.5
		elif method == "ko" or method == "tapout": v.t.flank += lr * 0.8
	else:
		v.t.aggression += lr * 0.2
	# What the driver learned in the fight carries over, partly.
	if learned is Dictionary:
		v.t.flank += _z(learned.get("flank")) * 0.3 * learn_rate
		v.t.aggression += _z(learned.get("aggression")) * 0.3 * learn_rate
	for k in ["flank", "aggression", "herd"]: v.t[k] = clampf(v.t[k] * 0.97, -0.4, 0.4)   # slowly forgets
	# The setup it ran: credit or blame.
	var p = m.get("pending")
	var delta := 1.0 if won else -1.0
	if p != null and p.oppClass == opp_class:
		if m.setups.get(opp_class) == null: m.setups[opp_class] = {}
		var s: Dictionary = m.setups[opp_class]
		for c in p.changes: s[key_of(c)] = clampf(_z(s.get(key_of(c))) * 0.85 + delta, -4.0, 4.0)
		if p.changes.size() == 0: s.none = clampf(_z(s.get("none")) * 0.85 + delta, -4.0, 4.0)
	m.last = {"oppClass": opp_class, "won": won, "how": how, "changes": p.changes if p != null else []}
	m.erase("pending")

# ---------------------------------------------------------------- rebuilding

## The pit's preferences before a fight against `opp_class`: the faces it
## hits, and a self-righter against a flipper.
static func pit_prefer(opp_class):
	if not J.truthy(opp_class): return null
	return {"faces": THREAT_FACES.get(opp_class, []), "categories": ["srimech"] if FLIPS.has(opp_class) else []}

## The weapon classes a robot has lost to most, worst first: [{ cls, losses, f, how }].
static func threats_of(career: Dictionary, id) -> Array:
	var vs: Dictionary = J.path(career, ["ai", id, "vs"], {})
	var out := []
	for cls in vs:
		var v: Dictionary = vs[cls]
		var losses: float = v.f - v.w
		if losses <= 0: continue
		var pairs := []
		for h in v.lossBy: pairs.append([h, v.lossBy[h]])
		pairs = J.sorted(pairs, func(a, b): return b[1] - a[1])
		out.append({"cls": cls, "losses": losses, "f": v.f, "how": pairs[0][0] if pairs.size() > 0 else null})
	return J.sorted(out, func(a, b): return b.losses - a.losses)

## Off-season ideas from experience: designs aimed at what has been beating
## this robot. evolution.gd tests them like any other upgrade.
static func learned_upgrades(reg: Registry, career: Dictionary, def: Dictionary) -> Array:
	var out := []
	var body0 = J.clone(def.get("body"))
	var base := {"name": def.get("name"), "build": J.clone(def.build), "body": body0 if body0 != null else {}, "personality": def.get("personality")}
	for t in threats_of(career, def.id).slice(0, 2):
		var cls_name: String = str(t.cls).replace("_", " ")
		if t.how == "ko:flipped" and not J.truthy(def.build.get("srimech")):
			var nd := base.duplicate()
			nd.build = Workshop.set_slot(reg, def.build, "srimech", "srimech_arm")
			var d = Workshop.fit_within(reg, nd, ["rear", "top", "side"])
			if d != null: out.append({"build": d.build, "note": "fitted a self-righter after losing to %ss" % cls_name, "cost": reg.part("srimech_arm").cost})
		var faces: Array = THREAT_FACES.get(t.cls, [])
		for face in faces.slice(0, 1):
			var d = Workshop.reinforce(reg, base, face, faces)
			if d != null: out.append({"build": d.build, "note": "heavier %s armour against %ss" % [face, cls_name], "cost": _armour_cost(reg, def.build, d.build)})
		if t.how == "decision" or t.how == "ko:beached":
			var cur_cost: float = reg.part(def.build.motor).cost
			var max_tier: float = J.g(TIER_OF, def.get("league"), 1)
			var motors := Workshop.parts_for(reg, "motor").filter(func(p): return p.cost > cur_cost and J.g(p, "tier", 1) <= max_tier)
			for p in motors.slice(0, 1):
				var nd := base.duplicate()
				nd.build = Workshop.set_slot(reg, def.build, "motor", p.id)
				var d = Workshop.fit_within(reg, nd, ["rear", "top", "side"])
				if d != null: out.append({"build": d.build, "note": "stronger drive after being out-pushed", "cost": p.cost})
	return out

static func _armour_cost(reg: Registry, a: Dictionary, b: Dictionary) -> float:
	var ta := 0.0
	var tb := 0.0
	for id in a.get("armor", []): ta += reg.part(id).cost
	for id in b.get("armor", []): tb += reg.part(id).cost
	return maxf(0.0, tb - ta * 0.4)
