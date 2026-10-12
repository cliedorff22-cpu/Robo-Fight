## evolution.gd - the off-season: every AI team works on its robot, as teams
## do between seasons on the show.
##
## For each robot in the field (never the player's - that is the workshop):
##   - the DRIVER gets better with fights fought and fights won, and can slip
##     after a bad season (its rating moves);
##   - the TEAM has a budget - money from its league and its results, plus
##     whatever it saved - and buys upgrades from the real parts catalog.
##     Every candidate must stay legal and is TESTED: fought against robots
##     from its league with the fast resolver, the same seeds before and
##     after, and only bought if it actually wins more;
##   - a robot stuck at the bottom for two seasons may be REDESIGNED around a
##     different weapon its body can carry.
##
## The robot keeps its identity: chassis, body and paint never change. What
## changed is kept in `career.evolution[id]` and merged over the robot file
## by Career.fielded_def(). All tunables are in data/league.json `evolution`.
##
## The trial fights are the slow part - thousands of them, a few seconds'
## worth - so the game runs the off-season on a background thread while the
## player reads how the season ended (see ui/career_jobs.gd), and
## evolve_field() reports its progress as it goes. (GDScript gains nothing
## from spreading the fights over several threads; one in the background is
## what helps.)
class_name Evolution

const DEFAULTS := {
	"budget": {"rookie": 2500, "pro": 4000, "elite": 6500, "world": 10000},
	"perWin": 600,
	"resale": 0.4,             # an old part fetches this share of its price
	"maxUpgrades": 2,          # per off-season
	"candidates": 5,           # upgrades tested per robot
	"evalOpponents": 6,        # how many league robots a candidate is tested against
	"minGain": 0.05,           # the win rate a part has to add to be worth buying
	"rating": {"talent": 12, "learn": 0.3, "perWinShare": 8, "noise": 2, "min": 5, "max": 99},
	"redesign": {"worstSeasons": 2, "belowWinShare": 0.3, "chance": 0.2, "minGain": 0.15, "everySeasons": 6},
	"bankSeasons": 4,          # a team saves at most this many seasons' budget
}

static func evolution_config(reg: Registry) -> Dictionary:
	var e: Dictionary = J.g(reg.league, "evolution", {})
	var cfg := J.merge(DEFAULTS, e)
	cfg.budget = J.merge(DEFAULTS.budget, e.get("budget", {}))
	cfg.rating = J.merge(DEFAULTS.rating, e.get("rating", {}))
	cfg.redesign = J.merge(DEFAULTS.redesign, e.get("redesign", {}))
	return cfg

## The robot's version: the major number goes up with a redesign, the minor
## with every off-season it was upgraded. "2.1" = rebuilt once, upgraded since.
static func version_of(career: Dictionary, id) -> String:
	var e = J.path(career, ["evolution", id])
	if e == null: return "1.0"
	return "%s.%s" % [J.num(_nz(e.get("version"), 1)), J.num(_nz(e.get("revision"), 0))]

static func _nz(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if f == 0.0 else f

## A robot def with its off-season changes applied.
static func evolved_def(reg: Registry, career: Dictionary, id) -> Dictionary:
	var base := reg.robot(id)
	var e = J.path(career, ["evolution", id])
	if e == null: return base
	var d := base.duplicate()
	d.build = J.g(e, "build", base.build)
	d.rating = J.g(e, "rating", base.get("rating"))
	d.archetype = J.g(e, "archetype", base.get("archetype"))
	d.version = e.get("version")
	return d

## Run the off-season after `season`. Mutates career.evolution.
##   fielded: Callable(id) -> the def a robot fights as (league applied)
##   progress: optional Callable(done, total)
## Returns { season, moves: [{ id, version, notes: [text] }] } - the report.
static func evolve_field(reg: Registry, career: Dictionary, season: Dictionary, fielded: Callable, progress: Callable = Callable()) -> Dictionary:
	var cfg := evolution_config(reg)
	var rng := Rng.new(Rng.hash_seed("%s:evolve:%s" % [J.s(career.seed), J.s(season.index)]))
	if career.get("evolution") == null: career.evolution = {}
	var moves := []
	var membership: Dictionary = career.membership
	# The field as it stands - robots retire and new ones join (field.gd).
	var field := []
	for id in membership:
		if id != career.playerId: field.append(id)
	var by_league := {}
	for id in field:
		var lg = membership[id]
		if not by_league.has(lg): by_league[lg] = []
		by_league[lg].append(id)
	var ai_budget: float = J.g(Settings.difficulty_of(reg, J.g(career, "difficulty", "medium")), "aiBudget", 1.0)

	var done := 0
	for id in field:
		if progress.is_valid(): progress.call(done, field.size())
		done += 1
		if career.evolution.get(id) == null: career.evolution[id] = {"version": 1, "bank": 0, "history": []}
		var e: Dictionary = career.evolution[id]
		var rec := _record_in(season, id)
		var notes := []
		var league = membership[id]

		# ---- the driver: learns toward their own ceiling, and a good or bad
		# season moves them about it.
		var def0: Dictionary = fielded.call(id)
		var share: float = float(rec.wins) / rec.fights if rec.fights > 0 else 0.5
		var r0: float = def0.rating
		# Toward the driver's own potential (field.gd), or the robot file's rating plus talent.
		var ceiling: float = minf(cfg.rating.max, J.path(career, ["drivers", id, "potential"], reg.robot(id).rating + cfg.rating.talent))
		var delta: float = (ceiling - r0) * cfg.rating.learn + (share - 0.5) * cfg.rating.perWinShare + rng.float_range(-cfg.rating.noise, cfg.rating.noise)
		e.rating = J.rnd(maxf(cfg.rating.min, minf(cfg.rating.max, r0 + delta)))
		if absf(e.rating - r0) >= 4: notes.append("driver %s: rated %s -> %s" % ["improved" if e.rating > r0 else "slipped", J.num(r0), J.num(e.rating)])

		# ---- the money. The difficulty setting scales what AI teams can spend.
		var budget: float = J.g(cfg.budget, league, cfg.budget.rookie) * ai_budget
		e.bank = minf(budget * cfg.bankSeasons, _z(e.get("bank")) + budget + rec.wins * cfg.perWin)
		var hist: Array = J.g(e, "history", []).duplicate()
		hist.append(share)
		e.history = J.slice(hist, -4)

		# ---- the build
		var opponents: Array = rng.shuffle(by_league.get(league, []).filter(func(x): return x != id)).slice(0, int(cfg.evalOpponents))
		var eval_seeds := []
		for k in opponents.size(): eval_seeds.append(Rng.hash_seed("%s:eval:%s:%s:%d" % [J.s(career.seed), J.s(season.index), id, k]))
		var opp_defs: Array = opponents.map(func(o): return fielded.call(o))
		var with_league := func(d: Dictionary) -> Dictionary:
			var x := d.duplicate()
			x.league = league
			return x
		var test := func(d: Dictionary) -> float:
			return _win_share(reg, with_league.call(d), opp_defs, eval_seeds)

		var fielded_now: Dictionary = fielded.call(id)
		var def: Dictionary = fielded_now.duplicate()
		def.rating = e.rating
		# A redesign: two bad seasons running, and the team decides to start
		# over around a different weapon its body can carry.
		var worst_n := int(cfg.redesign.worstSeasons)
		var slumped: bool = e.history.size() >= worst_n and J.every(J.slice(e.history, -worst_n), func(x): return x < cfg.redesign.belowWinShare)
		var can_redesign: bool = season.index - J.g(e, "redesignedAt", -99) >= cfg.redesign.everySeasons
		if slumped and can_redesign and rng.bool_p(cfg.redesign.chance):
			var re = _redesign(reg, def, rng, test, cfg.redesign.minGain)
			if re != null:
				def = re.def
				e.version = _nz(e.get("version"), 1) + 1
				e.revision = 0
				e.archetype = re.def.archetype
				e.redesignedAt = season.index
				e.history = []
				notes.append("rebuilt as %s" % re.label)

		var base: float = test.call(def)
		for n in int(cfg.maxUpgrades):
			# What has been beating it this season comes first (ailearn.gd),
			# then the catalog's step-ups - all of them tested the same way.
			var ld := def.duplicate()
			ld.id = id
			ld.league = league
			var cands := []
			for c in AILearn.learned_upgrades(reg, career, ld):
				var cd := def.duplicate()
				cd.build = c.build
				if c.cost <= e.bank and _legal(reg, cd): cands.append({"def": cd, "cost": c.cost, "note": c.note})
			var n_learned := cands.size()
			cands.append_array(_upgrade_candidates(reg, def, e.bank, cfg))
			cands = cands.slice(0, int(cfg.candidates) + n_learned)
			var wins := _test_many(reg, cands.map(func(c): return with_league.call(c.def)), opp_defs, eval_seeds)
			var best = null
			for ci in cands.size():
				var c: Dictionary = cands[ci]
				var w: float = wins[ci]
				if w >= base + cfg.minGain and (best == null or w - c.cost / 20000.0 > best.w - best.cost / 20000.0):
					best = c.duplicate()
					best.w = w
			if best == null: break
			def = best.def
			e.bank -= best.cost
			notes.append(best.note)
			base = best.w
		if not is_same(def.build, fielded_now.build):
			e.build = def.build
			if not J.some(notes, func(x): return x.begins_with("rebuilt")): e.revision = _z(e.get("revision")) + 1
		if notes.size() > 0:
			moves.append({"id": id, "version": version_of(career, id), "notes": notes})
			var lg_log: Array = J.g(e, "log", []).duplicate()
			lg_log.append({"season": season.index, "notes": notes})
			e.log = J.slice(lg_log, -6)
	if progress.is_valid(): progress.call(field.size(), field.size())
	return {"season": season.index, "moves": moves}

static func _z(v) -> float:
	return 0.0 if v == null else float(v)

## Wins/fights for a robot in a season (group and finals).
static func _record_in(season: Dictionary, id) -> Dictionary:
	var fights := 0
	var wins := 0
	for f in season.fixtures:
		if f.get("result") != null and (f.a == id or f.b == id):
			fights += 1
			if f.result.winnerId == id: wins += 1
	for f in season.get("finalsLog", []):
		if f.get("result") != null and (f.a == id or f.b == id):
			fights += 1
			if f.result.winnerId == id: wins += 1
	return {"fights": fights, "wins": wins}

## Share of fights won against these opponents, with fixed seeds.
static func _win_share(reg: Registry, def: Dictionary, opponents: Array, seeds: Array) -> float:
	var w := 0
	for k in opponents.size():
		var o: Dictionary = opponents[k]
		# Both corners, so a candidate is not judged on corner luck.
		if Resolver.resolve_fight(reg, def, o, {"seed": seeds[k]}).winnerId == def.id: w += 1
		if Resolver.resolve_fight(reg, o, def, {"seed": J.i32(int(seeds[k]) ^ 0x5bd1)}).winnerId == def.id: w += 1
	return float(w) / (opponents.size() * 2) if opponents.size() > 0 else 0.5

## _win_share for several designs.
static func _test_many(reg: Registry, defs: Array, opponents: Array, seeds: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(defs.size())
	for i in defs.size(): out[i] = _win_share(reg, defs[i], opponents, seeds)
	return out

## A build is legal (and a multibot still makes weight with its partner).
static func _legal(reg: Registry, def: Dictionary) -> bool:
	if not Build.can_assemble(reg, def): return false
	var a := Build.assemble_robot(reg, def)
	if not a.legality.legal: return false
	if def.get("partner") != null:
		var p = Build.assemble_partner(reg, def)
		if a.weightLb + p.weightLb > reg.rules.weightClass.cap + reg.rules.weightClass.tolerance: return false
	return true

const SINGLE := ["weaponMotor", "weapon", "motor", "battery", "electronics", "drive", "wheel"]
const LABELS := {"weaponMotor": "weapon motor", "weapon": "weapon", "motor": "drive motors", "battery": "batteries", "electronics": "electronics", "drive": "drivetrain", "wheel": "wheels"}

## Part swaps a team could afford that are a step UP (cost more than what is
## fitted), legal, and keep the body's weapon style. Cheapest first.
static func _upgrade_candidates(reg: Registry, def: Dictionary, bank: float, cfg: Dictionary) -> Array:
	var out := []
	var b: Dictionary = def.build
	for slot in SINGLE:
		if not J.truthy(b.get(slot)): continue
		var cur := reg.part(b[slot])
		for p in reg.parts_in(slot):
			if p.id == cur.id or _z(p.get("cost")) <= _z(cur.get("cost")): continue
			if slot == "weapon" and not _same_mount(p, cur): continue
			if slot == "wheel" and p.spec.diameterIn != cur.spec.diameterIn: continue   # wheels set the ride height
			var cost := J.rnd(_z(p.get("cost")) - _z(cur.get("cost")) * cfg.resale)
			if cost > bank: continue
			var nb := b.duplicate()
			nb[slot] = p.id
			var d := def.duplicate()
			d.build = nb
			if _legal(reg, d): out.append({"def": d, "cost": cost, "note": "%s: %s -> %s" % [LABELS.get(slot, slot), cur.name, p.name]})
	# Armour, panel by panel, same face.
	var armor: Array = b.get("armor", [])
	for i in armor.size():
		var cur := reg.part(armor[i])
		for p in reg.parts_in("armor"):
			if p.id == cur.id or p.spec.slot != cur.spec.slot or _z(p.get("hp")) <= _z(cur.get("hp")): continue
			var cost := J.rnd(_z(p.get("cost")) - _z(cur.get("cost")) * cfg.resale)
			if cost > bank: continue
			var na := armor.duplicate()
			na[i] = p.id
			var nb := b.duplicate()
			nb.armor = na
			var d := def.duplicate()
			d.build = nb
			if _legal(reg, d): out.append({"def": d, "cost": cost, "note": "%s armour: %s -> %s" % [cur.spec.slot, cur.name, p.name]})
	return J.sorted(out, func(x, y): return x.cost - y.cost)

static func _special(id: String) -> bool:
	return id.contains("shell") or id.contains("lid") or id.contains("tri")

## A weapon swap that the body still carries: same class, same style.
static func _same_mount(p: Dictionary, cur: Dictionary) -> bool:
	return p.spec["class"] == cur.spec["class"] and p.spec.get("style") == cur.spec.get("style") \
		and _special(p.id) == _special(cur.id)

## A new weapon for a slumping robot: only for front-weapon bodies, which can
## carry any of these, and only if the team's tests say it fights better.
const REDESIGNS := [
	{"cls": "spinner_v", "weapon": "spinner_v_disc", "label": "a vertical spinner", "archetype": "spinner_v"},
	{"cls": "drum", "weapon": "drum_kinetic", "label": "a drum spinner", "archetype": "drum"},
	{"cls": "spinner_v", "weapon": "spinner_v_small", "label": "a compact vertical spinner", "archetype": "spinner_v"},
	{"cls": "flipper", "weapon": "flipper_electric", "label": "a flipper", "archetype": "flipper"},
]

static func _redesign(reg: Registry, def: Dictionary, rng: Rng, test: Callable, min_gain: float):
	var mount = J.path(def, ["body", "mount"], "front")
	if not J.truthy(mount): mount = "front"
	if mount != "front" or def.get("partner") != null: return null
	var cur: String = reg.part(def.build.weapon).spec["class"]
	var now: float = test.call(def)
	var best = null
	for r in rng.shuffle(REDESIGNS):
		if r.cls == cur: continue
		var build: Dictionary = def.build.duplicate()
		build.weapon = r.weapon
		if Weapon.family_of(r.cls) == "kinetic" and not J.truthy(build.get("weaponMotor")): build.weaponMotor = "wmotor_light"
		var d := def.duplicate()
		d.build = build
		d.archetype = r.archetype
		if not _legal(reg, d): continue
		var w: float = test.call(d)
		if w > now + min_gain and (best == null or w > best.w): best = {"def": d, "w": w, "label": r.label}
	return best
