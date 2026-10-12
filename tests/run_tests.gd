## Headless tests: the game's logic against its own recorded output.
##
## Each suite plays a fixed script through the logic - every robot built and
## shaped, 600 simulated fights, three career seasons with their off-seasons,
## tournaments, the workshop, the advisor, the commentary - and gathers what
## came out into one snapshot. tests/golden/<suite>.json is that snapshot as
## it was last recorded; the test is that today's is the same.
##
##   tools/check.sh                 check every suite
##   tools/check.sh core            just that one
##   tools/check.sh record          record all three again
##   tools/check.sh record career   record one
##
## Record only after a change that is MEANT to alter what the logic produces,
## once the differences the check reports are the ones you expected.
extends SceneTree

const SUITES := ["core", "extras", "career"]
const RNG_SEEDS := [1, 12345, 4294967295]
const HASHES := ["a", "season:1:1", "resolve:7:grim_reaper:coldsnap", "layout:s1:rookie:A:0:x:y"]
const CAREER_SEASONS := 3
const CUPS := [
	{"format": "knockout", "size": 16, "fill": "top", "seed": 5},
	{"format": "groups", "size": 16, "fill": "random", "seed": 9},
	{"format": "knockout", "size": 8, "fill": "rookie", "seed": 2, "players": [{"name": "Ann", "robot": "grim_reaper"}, {"name": "Bo", "robot": "coldsnap"}]},
	{"format": "giantNut", "seed": 4},
]

var _pass := 0
var _fail := 0
var _shown := 0
## How far apart two numbers may be (as a share of their size) and still match.
var _tol := 1e-9

func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_shown += 1
		if _shown <= 40: print("    FAIL ", msg)

func _same(a, b) -> bool:
	if (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT):
		return absf(float(a) - float(b)) <= _tol * maxf(1.0, absf(float(b)))
	return typeof(a) == typeof(b) and a == b

func golden(name: String):
	return Registry.read_json("res://tests/golden/%s.json" % name)

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var reg := Registry.load_all()
	var only := Array(OS.get_cmdline_user_args())
	var record := only.has("record")
	only.erase("record")
	for a in only.duplicate():
		if str(a).begins_with("tol="):
			_tol = float(str(a).substr(4))
			only.erase(a)
	for suite in SUITES:
		if only.size() > 0 and not only.has(suite): continue
		var before := _fail
		_shown = 0
		var t1 := Time.get_ticks_msec()
		var got = _jsonish(call("snap_" + suite, reg))
		if record and _fail == before:
			var f := FileAccess.open("res://tests/golden/%s.json" % suite, FileAccess.WRITE)
			f.store_string(JSON.stringify(got, "", false, true))
			f.close()
			print("  %-10s recorded  (%d ms)" % [suite, Time.get_ticks_msec() - t1])
			continue
		if not record:
			var want = golden(suite)
			if want == null: ok(false, "tests/golden/%s.json is missing: tools/check.sh record %s" % [suite, suite])
			else: _diff(got, want, suite)
		print("  %-10s %s  (%d ms)" % [suite, "ok" if _fail == before else "%d FAILED" % (_fail - before), Time.get_ticks_msec() - t1])
	print("tests: %d passed, %d failed  (%d ms)" % [_pass, _fail, Time.get_ticks_msec() - t0])
	quit(1 if _fail > 0 else 0)

# A copy of a value as JSON would keep it: Callables and INF dropped, numbers
# at full precision. A snapshot takes one of anything that will change later.
func _jsonish(v):
	return JSON.parse_string(JSON.stringify(J._json_safe(v), "", false, true))

# Where two JSON-shaped values part ways (a few places, not a wall).
func _diff(a, b, path: String) -> void:
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				if b[k] != null: ok(false, "%s.%s: missing" % [path, k])
			else: _diff(a[k], b[k], "%s.%s" % [path, k])
		for k in a:
			if not b.has(k) and a[k] != null: ok(false, "%s.%s: extra (%s)" % [path, k, str(a[k]).substr(0, 60)])
		return
	if a is Array and b is Array:
		if a.size() != b.size():
			ok(false, "%s: %d items, expected %d" % [path, a.size(), b.size()])
			return
		for i in a.size(): _diff(a[i], b[i], "%s[%d]" % [path, i])
		return
	ok(_same(a, b), "%s: expected %s, got %s" % [path, str(b).substr(0, 80), str(a).substr(0, 80)])

# ---------------------------------------------------------------- core
# The random numbers, every robot as built and shaped, and 600 fights.

func snap_core(reg: Registry) -> Dictionary:
	var out := {"rng": {}, "hash": {}, "robots": {}, "fights": []}
	for sd in RNG_SEEDS:
		var r := Rng.new(sd)
		var draws := [r.next(), r.next(), r.next()]
		draws.append(r.int_range(1, 6))
		draws.append(r.shuffle([1, 2, 3, 4, 5, 6, 7]))
		out.rng[str(sd)] = draws
	for s in HASHES: out.hash[s] = Rng.hash_seed(s)

	for def in reg.all_robots():
		var id: String = def.id
		var a := Build.assemble_robot(reg, def)
		var sh := Shape.build_shape(a)
		var route := Shape.route_fittings(sh, a)
		var pcs := []
		for p in sh.pieces: pcs.append("%s|%s|%s|%d|%s" % [p.id, p.slot, p.role, p.points.size(), route[p.id]])
		var wcol := []
		if sh.weapon != null:
			for c in sh.weapon.colliders: wcol.append(c.type)
		var prof := AI.ai_profile(def)
		out.robots[id] = {
			"weightLb": a.weightLb, "massKg": a.massKg, "top": a.stats.topSpeedMps, "fpw": a.stats.forcePerWheelN,
			"pivot": a.stats.pivotAuthority if is_finite(a.stats.pivotAuthority) else null,
			"energy": a.stats.weapon.energyJ, "spinUp": a.stats.weapon.spinUpS if is_finite(a.stats.weapon.spinUpS) else null,
			"cls": a.stats.weapon["class"], "selfRight": a.stats.selfRight.via, "legal": a.legality.legal,
			"errors": a.legality.errors, "warnings": a.legality.warnings,
			"invertible": sh.invertible, "pieces": pcs,
			"bmin": [sh.bounds.min.x, sh.bounds.min.y, sh.bounds.min.z], "bmax": [sh.bounds.max.x, sh.bounds.max.y, sh.bounds.max.z],
			"wcol": wcol, "visual": J.path(sh.weapon, ["visual", "kind"]),
			"skill": prof.skill, "herd": prof.herdBias,
		}

	var bots := reg.all_robots()
	var pick := Rng.new(99)
	for k in 600:
		var a: Dictionary = bots[int(floor(pick.next() * bots.size()))]
		var b: Dictionary = bots[int(floor(pick.next() * bots.size()))]
		if a.id == b.id: continue
		var f := Resolver.resolve_fight(reg, a, b, {"seed": k * 7 + 1})
		out.fights.append({"a": a.id, "b": b.id, "seed": k * 7 + 1, "w": f.winnerId, "m": f.method, "c": f.cause, "t": f.elapsedS,
			"da": f.sides[a.id].hpDealt, "db": f.sides[b.id].hpDealt, "ha": f.sides[a.id].hitsLanded, "fa": f.sides[a.id].flips,
			"ca": f.sides[a.id].condition, "cb": f.sides[b.id].condition, "votes": f.votes})
	return out

# ---------------------------------------------------------------- career
# A career played through by the resolver: its seasons, fights, money,
# off-seasons and newcomers, and the save at the end of it.

func snap_career(reg: Registry) -> Dictionary:
	var out := {"seasons": [], "steps": []}
	var career := Career.new_career(reg, {"seed": 7, "difficulty": "hard"})
	Market.borrow(reg, career, reg.economy.loans.lenders[0].id, 3000)
	var name_of := func(id): return reg.robot(id).name
	var guard := 0
	while out.seasons.size() < CAREER_SEASONS and guard < 5000:
		guard += 1
		Career.advance_career(reg, career)
		var nf = Career.next_fight(reg, career)
		if nf != null:
			var step := {"fixture": nf.fixture.id, "opp": nf.oppId, "changes": nf.oppChanges, "arena": nf.arena, "seed": nf.seed,
				"scout": Scouting.scout_report(reg, career, nf.oppId, name_of, "static").lines,
				"story": Rivalry.storyline(reg, career, nf.oppId, {"names": {"them": reg.robot(nf.oppId).name}})}
			step = _jsonish(step)
			var lf = Career.simulate_player_fight(reg, career)
			step.won = lf.won
			step.method = lf.result.method
			step.earned = lf.earned
			step.repair = lf.repair.total
			var plan := Career.pit_auto_plan(reg, career)
			var q := Career.pit_quote(reg, career, plan)
			step.plan = _jsonish(plan)
			step.pitCost = q.cost
			step.pitMinutes = q.minutes
			Career.do_pit(reg, career, plan)
			step.cash = career.cash
			var m := Market.market_of(reg, career)
			step.market = m.listings.map(func(l): return "%s:%s:%s" % [l.partId, l.sellerId, J.num(l.price)])
			step.offers = Market.spares_offers(reg, career).map(func(o): return "%s:%s:%s" % [o.partId, J.s(o.price), J.s(o.robotId)])
			var ro := Market.robot_offer(reg, career)
			step.robotOffer = "%s:%s:%s" % [ro.buyerId, J.num(ro.price), J.num(ro.net)] if ro.ok else ro.reason
			out.steps.append(step)
			continue
		if J.truthy(career.get("seasonOver")):
			var s: Dictionary = career.season
			var champs := {}
			var ranks := {}
			if s.kind == "league":
				for k in s.leagues:
					champs[k] = s.leagues[k].champion
					ranks[k] = s.leagues[k].ranking
			else:
				champs["giantNut"] = s.giantNut.champion
				ranks["giantNut"] = s.giantNut.ranking
			var ai := {}
			for k in career.ai.keys().slice(0, 12): ai[k] = career.ai[k]
			var snap: Dictionary = _jsonish({
				"index": s.index, "kind": s.kind, "cash": career.cash, "history": career.history[career.history.size() - 1],
				"stats": career.stats, "sponsors": career.sponsors, "trophies": career.trophies,
				"champions": champs, "rankings": ranks, "wearCount": career.wear.size(), "ai": ai,
				"rivals": Rivalry.rivals_list(reg, career).map(func(r): return "%s:%s:%s-%s" % [r.id, J.num(r.heat), J.num(r.w), J.num(r.l)]),
			})
			var t1 := Time.get_ticks_msec()
			Career.start_next_season(reg, career)
			print("    off-season %d: %d ms" % [out.seasons.size() + 1, Time.get_ticks_msec() - t1])
			var ratings := {}
			var builds := {}
			var banks := {}
			for k in career.evolution:
				var e: Dictionary = career.evolution[k]
				ratings[k] = e.get("rating")
				banks[k] = e.get("bank")
				if e.get("build") != null: builds[k] = e.build
			var drivers := {}
			for k in career.drivers.keys().slice(0, 20): drivers[k] = career.drivers[k]
			snap.after = _jsonish({
				"cash": career.cash, "membership": career.membership, "moves": career.offseason.moves,
				"ratings": ratings, "builds": builds, "banks": banks, "field": career.offseason.field,
				"newcomers": career.newcomers.values().map(func(n): return {"id": n.id, "name": n.name, "team": n.get("team"), "build": n.get("build"), "body": n.get("body"),
					"rating": n.get("rating"), "livery": n.get("livery"), "personality": n.get("personality")}),
				"drivers": drivers, "notices": career.notices, "ledger": J.slice(career.ledger, -12),
				"fixtures": career.season.fixtures.slice(0, 40).map(func(f): return f.id),
			})
			out.seasons.append(snap)
	# The save, as it comes back from a trip to disk.
	var back := Career.deserialize(Career.serialize(career))
	ok(back.ok, "career save loads")
	out.save = back.career
	return out

# ---------------------------------------------------------------- extras
# Tournament mode, the Hall of Fame, the commentary, the workshop and the
# build advisor.

func snap_extras(reg: Registry) -> Dictionary:
	var out := {"cups": []}
	for o in CUPS:
		var made := Cup.make_cup(reg, o.duplicate(true))
		var tag := "cup %s/%s" % [o.format, J.s(o.seed)]
		ok(made.ok, tag + " made")
		var cup: Dictionary = made.cup
		Cup.advance_cup(reg, cup)
		var steps := []
		var guard := 0
		while not cup.done and guard < 200:
			guard += 1
			var f = Cup.next_cup_fight(cup)
			if f == null: break
			steps.append({"id": f.id, "label": Cup.cup_stage_label(cup, f), "arena": Cup.cup_arena(reg, cup, f), "r": Cup.simulate_cup_fight(reg, cup, f.id).winnerId})
		var back := Cup.deserialize_cup(Cup.serialize_cup(cup))
		ok(back.ok and back.cup.champion == cup.champion, tag + " save round-trips")
		out.cups.append(_jsonish({"o": o, "entrants": cup.entrants, "champion": cup.champion, "ranking": Cup.cup_ranking(cup).slice(0, 12), "log": cup.log.size(),
			"tables": Cup.cup_tables(cup), "steps": steps, "totalRounds": cup.totalRounds}))

	out.catalog = Catalog.catalog(reg).slice(0, 15).map(func(e): return "%s|%s|%s" % [e.id, e.league, e.archetype])
	out.filtered = Catalog.filter_catalog(Catalog.catalog(reg), "elite", "spin").map(func(e): return e.id)
	out.cards = ["grim_reaper", "castor_pollux", "player_default", "hex_physician", "bricklayer"].map(func(id): return Catalog.spec_card(reg, id))
	out.scouting = ["grim_reaper", "coldsnap", "valhalla", "molar_patrol"].map(func(id): return Catalog.scouting(reg, reg.robot(id)))
	var base := reg.robot(reg.playerId)
	var design := {"name": base.name, "body": {"template": "wedge", "mount": "front", "extras": []}, "build": base.build, "livery": base.livery, "personality": base.personality}
	out.slots = Workshop.slots_of(reg, design.build).map(func(s): return "%s|%s|%s|%s" % [s.key, J.s(s.partId), s.label, J.s(s.optional)])
	out.candidates = {}
	for key in ["weapon", "motor", "armor:front:0", "chassis"]:
		out.candidates[key] = Workshop.candidates(reg, null, design, key).map(func(c): return {"id": c.part.id, "fitted": c.fitted, "legal": c.legal, "delta": c.delta, "price": c.price,
			"w": c.after.weightLb if c.after != null else null})
	out.summary = Workshop.summarize(reg, reg.robot("grim_reaper"))
	out = _jsonish(out)

	# A career: the garage, the Hall of Fame, a backup, the advisor.
	var career := Career.new_career(reg, {"seed": 3, "team": "Scrap Yard"})
	var gar := Garage.garage_of(reg, career)
	var nb: Dictionary = gar.build.duplicate()
	nb.weapon = "spinner_v_small"
	nb.weaponMotor = "wmotor_light"
	var a1 := Garage.apply_design(reg, career, {"build": nb, "name": "  Buzzkill  "})
	out.apply1 = _jsonish({"ok": a1.ok, "errors": a1.errors, "cost": a1.cost, "cash": career.cash, "version": gar.version, "log": gar.log, "owned": gar.owned})
	var nb2: Dictionary = gar.build.duplicate()
	nb2.armor = ["armor_ar500_front", "armor_ar500_front"]
	var a2 := Garage.apply_design(reg, career, {"build": nb2})
	out.apply2 = _jsonish({"ok": a2.ok, "errors": a2.errors})
	out.spares = _jsonish(Garage.spares(reg, career))
	var sp := Garage.spares(reg, career).keys()
	out.sell = _jsonish(Garage.sell_part(reg, career, sp[0])) if sp.size() > 0 else null
	var guard2 := 0
	while not J.truthy(career.get("seasonOver")) and guard2 < 400:
		guard2 += 1
		Career.advance_career(reg, career)
		if Career.next_fight(reg, career) != null:
			Career.simulate_player_fight(reg, career)
			Career.do_pit(reg, career, Career.pit_auto_plan(reg, career))
	out.entry = _jsonish(HallOfFame.career_entry(reg, career))
	var hall := HallOfFame.induct(reg, HallOfFame.empty_hall(), career)
	out.hall = _jsonish(hall)
	var text := SaveFile.make_backup({"career": career, "hall": hall, "settings": {"difficulty": "hard", "bloom": false, "volume": 0.5, "junk": 1}}, "2026-01-01T00:00:00.000Z")
	var back2 := SaveFile.read_backup(text)
	ok(back2.ok, "backup reads: %s" % back2.error)
	out.backup = _jsonish({"describe": SaveFile.describe_backup(back2), "settings": back2.settings, "savedAt": back2.savedAt, "cash": back2.career.cash}) if back2.ok else null
	ok(not SaveFile.read_backup("not json").ok and not SaveFile.read_backup("{\"schema\":\"robo-league-backup/9\"}").ok, "junk backups are refused")
	Career.start_next_season(reg, career)
	Career.advance_career(reg, career)
	var nf = Career.next_fight(reg, career)
	out.briefs = ["a low wedge with a lifter", "fast drum, lots of armour, under $15,000", "invertible vertical spinner called Molar", "big hammer that hits hard, self-righting",
		"cheap horizontal bar with forks", "round shell spinner for 12k dollars", "", "an undercutter named Low Blow, with a plow"].map(func(b): return Advisor.parse_brief(b))
	var t1 := Time.get_ticks_msec()
	out.advice = {}
	out.advice.design = _jsonish(Advisor.advise(reg, {"kind": "design", "brief": "a fast vertical spinner with lots of armour", "career": career}))
	out.advice.designNone = _jsonish(Advisor.advise(reg, {"kind": "design", "brief": "something nice", "career": career}))
	out.advice.opponent = _jsonish(Advisor.advise(reg, {"kind": "opponent", "career": career, "oppId": nf.oppId}))
	out.advice.fight = _jsonish(Advisor.advise(reg, {"kind": "fight", "career": career, "oppId": nf.oppId}))
	out.advice.season = _jsonish(Advisor.advise(reg, {"kind": "season", "career": career}))
	out.advice.sandbox = _jsonish(Advisor.advise(reg, {"kind": "design", "brief": "a hammer that is tough"}))
	print("    advisor: %d ms" % (Time.get_ticks_msec() - t1))

	var rng := Rng.new(42)
	var c := Commentary.new({"names": {"r": "Red Bot", "b": "Blue Bot"}, "corners": {"r": "red", "b": "blue"}, "weapons": {"r": "vertical disc", "b": "hammer"},
		"story": {"level": 2, "series": {"w": 1, "l": 2, "fights": 3}, "last": {"won": false, "method": "ko"}, "grudge": true, "asked": "them"}, "playerId": "r", "where": {"venue": "Ironworks Hall"}, "rng": rng})
	var lines := c.intro()
	var ev := [
		["countdown", {}, 0], ["live", {}, 0],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "heavy", "kind": "weapon", "deliveredJ": 9000}, 4],
		["hit", {"attackerId": "b", "defenderId": "r", "severity": "hit", "kind": "weapon", "deliveredJ": 2000}, 7],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "catastrophic", "kind": "weapon", "deliveredJ": 30000}, 12],
		["failed", {"botId": "b", "category": "armor"}, 12], ["failed", {"botId": "b", "category": "battery"}, 13],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "heavy", "kind": "ram"}, 20],
		["hit", {"attackerId": null, "defenderId": "b", "severity": "heavy", "kind": "hazard", "hazardType": "pulverizer"}, 25],
		["hazard", {"type": "pit"}, 30], ["hazard", {"type": "killsaw"}, 31], ["hazard", {"type": "killsaw"}, 32],
		["count", {"botId": "b", "count": 1, "of": 10}, 40], ["count", {"botId": "b", "count": 7, "of": 10}, 46], ["recovered", {"botId": "b"}, 47],
		["pin", {"botId": "r", "pinnedId": "b"}, 60], ["separate", {}, 70],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "heavy", "kind": "weapon", "deliveredJ": 25000}, 80],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "hit", "kind": "weapon", "deliveredJ": 100}, 81],
		["hit", {"attackerId": "r", "defenderId": "b", "severity": "hit", "kind": "weapon", "deliveredJ": 100}, 82],
	]
	for e in ev: lines.append_array(c.event(e[0], e[1], e[2]))
	for i in 300: lines.append_array(c.tick(100.0 - i * 0.4, true, 0.4))
	lines.append_array(c.event("end", {"method": "decision", "decision": "split", "winnerId": "r", "loserId": "b"}, 180))
	c.reset()
	lines.append_array(c.event("end", {"method": "ko", "winnerId": "b", "loserId": "r"}, 90))
	out.commentary = lines
	return out
