## Headless tests: the converted logic against reference output recorded from
## the JavaScript game (tests/golden/*.json, written by tools/golden/*.js).
##   tools/check.sh
extends SceneTree

var _pass := 0
var _fail := 0
var _shown := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_shown += 1
		if _shown <= 40: print("    FAIL ", msg)

func near(a, b, tol: float, msg: String) -> void:
	if a == null or b == null:
		ok(a == null and b == null, "%s: expected %s, got %s" % [msg, str(b), str(a)])
		return
	var fa := float(a)
	var fb := float(b)
	ok(absf(fa - fb) <= tol * maxf(1.0, absf(fb)), "%s: expected %s, got %s" % [msg, str(b), str(a)])

func eq(a, b, msg: String) -> void:
	ok(_same(a, b), "%s: expected %s, got %s" % [msg, str(b), str(a)])

func _same(a, b) -> bool:
	if (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT):
		return absf(float(a) - float(b)) <= 1e-9 * maxf(1.0, absf(float(b)))
	if a is Array and b is Array:
		if a.size() != b.size(): return false
		for i in a.size():
			if not _same(a[i], b[i]): return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size(): return false
		for k in b:
			if not a.has(k) or not _same(a[k], b[k]): return false
		return true
	return typeof(a) == typeof(b) and a == b

func golden(name: String):
	return Registry.read_json("res://tests/golden/%s.json" % name)

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var reg := Registry.load_all()
	var only := OS.get_cmdline_user_args()
	for suite in ["core", "extras", "career"]:
		if only.size() > 0 and not only.has(suite): continue
		var before := _fail
		_shown = 0
		var t1 := Time.get_ticks_msec()
		call("test_" + suite, reg)
		print("  %-10s %s  (%d ms)" % [suite, "ok" if _fail == before else "%d FAILED" % (_fail - before), Time.get_ticks_msec() - t1])
	print("tests: %d passed, %d failed  (%d ms)" % [_pass, _fail, Time.get_ticks_msec() - t0])
	quit(1 if _fail > 0 else 0)

func test_core(reg: Registry) -> void:
	var g = golden("core")
	for seed_s in g.rng:
		var r := Rng.new(int(seed_s))
		var want: Array = g.rng[seed_s]
		near(r.next(), want[0], 1e-15, "rng %s #1" % seed_s)
		near(r.next(), want[1], 1e-15, "rng %s #2" % seed_s)
		near(r.next(), want[2], 1e-15, "rng %s #3" % seed_s)
		eq(r.int_range(1, 6), want[3], "rng %s int" % seed_s)
		eq(r.shuffle([1, 2, 3, 4, 5, 6, 7]), want[4], "rng %s shuffle" % seed_s)
	for s in g.hash:
		eq(Rng.hash_seed(s), g.hash[s], "hash %s" % s)

	for id in g.robots:
		var w: Dictionary = g.robots[id]
		var a := Build.assemble_robot(reg, reg.robot(id))
		near(a.weightLb, w.weightLb, 1e-12, id + " weight")
		near(a.massKg, w.massKg, 1e-12, id + " mass")
		near(a.stats.topSpeedMps, w.top, 1e-12, id + " top speed")
		near(a.stats.forcePerWheelN, w.fpw, 1e-12, id + " force")
		near(a.stats.pivotAuthority if is_finite(a.stats.pivotAuthority) else null, w.pivot, 1e-12, id + " pivot")
		near(a.stats.weapon.energyJ, w.energy, 1e-12, id + " energy")
		near(a.stats.weapon.spinUpS if is_finite(a.stats.weapon.spinUpS) else null, w.spinUp, 1e-12, id + " spinUp")
		eq(a.stats.weapon["class"], w.cls, id + " class")
		eq(a.stats.selfRight.via, w.selfRight, id + " selfRight")
		eq(a.legality.legal, w.legal, id + " legal")
		eq(a.legality.errors, w.errors, id + " errors")
		eq(a.legality.warnings, w.warnings, id + " warnings")
		var sh := Shape.build_shape(a)
		var route := Shape.route_fittings(sh, a)
		eq(sh.invertible, w.invertible, id + " invertible")
		var pcs := []
		for p in sh.pieces: pcs.append("%s|%s|%s|%d|%s" % [p.id, p.slot, p.role, p.points.size(), route[p.id]])
		eq(pcs, w.pieces, id + " pieces")
		for k in 3:
			near(sh.bounds.min[k], w.bmin[k], 2e-6, id + " bounds min")
			near(sh.bounds.max[k], w.bmax[k], 2e-6, id + " bounds max")
		var wcol := []
		if sh.weapon != null:
			for c in sh.weapon.colliders: wcol.append(c.type)
		eq(wcol, w.wcol, id + " weapon colliders")
		eq(J.path(sh.weapon, ["visual", "kind"]), w.visual, id + " weapon visual")
		var prof := AI.ai_profile(reg.robot(id))
		near(prof.skill, w.skill, 1e-12, id + " skill")
		near(prof.herdBias, w.herd, 1e-12, id + " herd")

	for f in g.fights:
		var r := Resolver.resolve_fight(reg, reg.robot(f.a), reg.robot(f.b), {"seed": int(f.seed)})
		var tag := "%s v %s #%d" % [f.a, f.b, int(f.seed)]
		eq(r.winnerId, f.w, tag + " winner")
		eq(r.method, f.m, tag + " method")
		eq(r.cause, f.c, tag + " cause")
		near(r.elapsedS, f.t, 1e-9, tag + " elapsed")
		eq(r.sides[f.a].hpDealt, f.da, tag + " hp a")
		eq(r.sides[f.b].hpDealt, f.db, tag + " hp b")
		eq(r.sides[f.a].hitsLanded, f.ha, tag + " hits a")
		eq(r.sides[f.a].flips, f.fa, tag + " flips a")
		eq(r.sides[f.a].condition, f.ca, tag + " condition a")
		eq(r.sides[f.b].condition, f.cb, tag + " condition b")
		eq(r.votes, f.votes, tag + " votes")

# A career played through by the resolver: the same seasons, fights, money,
# off-seasons and newcomers as the JavaScript game produced.
func test_career(reg: Registry) -> void:
	var g = golden("career")
	var career := Career.new_career(reg, {"seed": 7, "difficulty": "hard"})
	Market.borrow(reg, career, reg.economy.loans.lenders[0].id, 3000)
	var name_of := func(id): return reg.robot(id).name
	var step_i := 0
	var seasons := 0
	var guard := 0
	var want_seasons: int = g.seasons.size()
	while seasons < want_seasons and guard < 5000:
		guard += 1
		Career.advance_career(reg, career)
		var nf = Career.next_fight(reg, career)
		if nf != null:
			var w: Dictionary = g.steps[step_i]
			var tag := "step %d (%s)" % [step_i, w.fixture]
			step_i += 1
			eq(nf.fixture.id, w.fixture, tag + " fixture")
			eq(nf.oppId, w.opp, tag + " opp")
			eq(nf.oppChanges, w.changes, tag + " opp changes")
			eq(nf.arena, w.arena, tag + " arena")
			eq(nf.seed, w.seed, tag + " seed")
			eq(Scouting.scout_report(reg, career, nf.oppId, name_of, "static").lines, w.scout, tag + " scout lines")
			eq(Rivalry.storyline(reg, career, nf.oppId, {"names": {"them": reg.robot(nf.oppId).name}}), w.story, tag + " story")
			var lf = Career.simulate_player_fight(reg, career)
			eq(lf.won, w.won, tag + " won")
			eq(lf.result.method, w.method, tag + " method")
			eq(lf.earned, w.earned, tag + " earned")
			eq(lf.repair.total, w.repair, tag + " repair")
			var plan := Career.pit_auto_plan(reg, career)
			var q := Career.pit_quote(reg, career, plan)
			eq(plan, w.plan, tag + " pit plan")
			eq(q.cost, w.pitCost, tag + " pit cost")
			eq(q.minutes, w.pitMinutes, tag + " pit minutes")
			Career.do_pit(reg, career, plan)
			eq(career.cash, w.cash, tag + " cash")
			var m := Market.market_of(reg, career)
			eq(m.listings.map(func(l): return "%s:%s:%s" % [l.partId, l.sellerId, J.num(l.price)]), w.market, tag + " market")
			eq(Market.spares_offers(reg, career).map(func(o): return "%s:%s:%s" % [o.partId, J.s(o.price), J.s(o.robotId)]), w.offers, tag + " offers")
			var ro := Market.robot_offer(reg, career)
			eq("%s:%s:%s" % [ro.buyerId, J.num(ro.price), J.num(ro.net)] if ro.ok else ro.reason, w.robotOffer, tag + " robot offer")
			continue
		if J.truthy(career.get("seasonOver")):
			var w: Dictionary = g.seasons[seasons]
			var s: Dictionary = career.season
			var tag := "season %d" % (seasons + 1)
			eq(s.index, w.index, tag + " index")
			eq(s.kind, w.kind, tag + " kind")
			eq(career.cash, w.cash, tag + " cash")
			eq(_jsonish(career.history[career.history.size() - 1]), w.history, tag + " history")
			eq(_jsonish(career.stats), w.stats, tag + " stats")
			eq(career.sponsors, w.sponsors, tag + " sponsors")
			eq(_jsonish(career.trophies), w.trophies, tag + " trophies")
			var champs := {}
			var ranks := {}
			if s.kind == "league":
				for k in s.leagues:
					champs[k] = s.leagues[k].champion
					ranks[k] = s.leagues[k].ranking
			else:
				champs["giantNut"] = s.giantNut.champion
				ranks["giantNut"] = s.giantNut.ranking
			eq(champs, w.champions, tag + " champions")
			eq(ranks, w.rankings, tag + " rankings")
			eq(career.wear.size(), w.wearCount, tag + " wear count")
			var ai := {}
			for k in career.ai.keys().slice(0, 12): ai[k] = career.ai[k]
			eq(_jsonish(ai), w.ai, tag + " ai memory")
			eq(Rivalry.rivals_list(reg, career).map(func(r): return "%s:%s:%s-%s" % [r.id, J.num(r.heat), J.num(r.w), J.num(r.l)]), w.rivals, tag + " rivals")
			var t1 := Time.get_ticks_msec()
			Career.start_next_season(reg, career)
			print("    off-season %d: %d ms" % [seasons + 1, Time.get_ticks_msec() - t1])
			var a: Dictionary = w.after
			eq(career.cash, a.cash, tag + " cash after")
			eq(career.membership, a.membership, tag + " membership")
			eq(_jsonish(career.offseason.moves), a.moves, tag + " moves")
			var ratings := {}
			var builds := {}
			var banks := {}
			for k in career.evolution:
				var e: Dictionary = career.evolution[k]
				ratings[k] = e.get("rating")
				banks[k] = e.get("bank")
				if e.get("build") != null: builds[k] = e.build
			eq(ratings, a.ratings, tag + " ratings")
			eq(builds, a.builds, tag + " builds")
			eq(banks, a.banks, tag + " banks")
			eq(_jsonish(career.offseason.field), a.field, tag + " field report")
			eq(_jsonish(career.newcomers.values().map(func(n): return {"id": n.id, "name": n.name, "team": n.get("team"), "build": n.get("build"), "body": n.get("body"), "rating": n.get("rating"), "livery": n.get("livery"), "personality": n.get("personality")})), a.newcomers, tag + " newcomers")
			var drivers := {}
			for k in career.drivers.keys().slice(0, 20): drivers[k] = career.drivers[k]
			eq(_jsonish(drivers), a.drivers, tag + " drivers")
			eq(_jsonish(career.notices), a.notices, tag + " notices")
			eq(_jsonish(J.slice(career.ledger, -12)), a.ledger, tag + " ledger")
			eq(career.season.fixtures.slice(0, 40).map(func(f): return f.id), a.fixtures, tag + " next fixtures")
			seasons += 1
	eq(step_i, g.steps.size(), "career: fights fought")
	# The save round-trips, and matches the JavaScript game's save.
	var back := Career.deserialize(Career.serialize(career))
	ok(back.ok, "career save loads")
	_diff(_jsonish(back.career), g.save, "save")

# What a value looks like after a trip through JSON (undefined keys dropped,
# as JSON.stringify drops them; INF becomes null).
func _jsonish(v):
	return J.parse_json(J.to_json(v))

# Report where two JSON-shaped values part ways (a few places, not a wall).
func _diff(a, b, path: String, depth := 0) -> void:
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				if b[k] != null: ok(false, "%s.%s: missing" % [path, k])
			else: _diff(a[k], b[k], "%s.%s" % [path, k], depth + 1)
		for k in a:
			if not b.has(k) and a[k] != null: ok(false, "%s.%s: extra (%s)" % [path, k, str(a[k]).substr(0, 60)])
		return
	if a is Array and b is Array:
		if a.size() != b.size():
			ok(false, "%s: %d items, expected %d" % [path, a.size(), b.size()])
			return
		for i in a.size(): _diff(a[i], b[i], "%s[%d]" % [path, i], depth + 1)
		return
	ok(_same(a, b), "%s: expected %s, got %s" % [path, str(b).substr(0, 80), str(a).substr(0, 80)])

# Tournament mode, the Hall of Fame, the commentary, the workshop and the
# build advisor.
func test_extras(reg: Registry) -> void:
	var g = golden("extras")
	for w in g.cups:
		var made := Cup.make_cup(reg, w.o)
		ok(made.ok, "cup %s made" % w.o.format)
		var cup: Dictionary = made.cup
		Cup.advance_cup(reg, cup)
		var steps := []
		var guard := 0
		while not cup.done and guard < 200:
			guard += 1
			var f = Cup.next_cup_fight(cup)
			if f == null: break
			steps.append({"id": f.id, "label": Cup.cup_stage_label(cup, f), "arena": Cup.cup_arena(reg, cup, f), "r": Cup.simulate_cup_fight(reg, cup, f.id).winnerId})
		var tag := "cup %s/%s" % [w.o.format, J.s(w.o.seed)]
		eq(cup.entrants, w.entrants, tag + " entrants")
		eq(cup.champion, w.champion, tag + " champion")
		eq(Cup.cup_ranking(cup).slice(0, 12), w.ranking, tag + " ranking")
		eq(cup.log.size(), w.log, tag + " fights")
		_diff(_jsonish(Cup.cup_tables(cup)), w.tables, tag + " tables")
		eq(steps, w.steps, tag + " people's fights")
		eq(cup.totalRounds, w.totalRounds, tag + " rounds")
		var back := Cup.deserialize_cup(Cup.serialize_cup(cup))
		ok(back.ok and back.cup.champion == cup.champion, tag + " save round-trips")

	eq(Catalog.catalog(reg).slice(0, 15).map(func(e): return "%s|%s|%s" % [e.id, e.league, e.archetype]), g.catalog, "catalog")
	eq(Catalog.filter_catalog(Catalog.catalog(reg), "elite", "spin").map(func(e): return e.id), g.filtered, "filtered catalog")
	var ci := 0
	for id in ["grim_reaper", "castor_pollux", "player_default", "hex_physician", "bricklayer"]:
		_diff(_jsonish(Catalog.spec_card(reg, id)), g.cards[ci], "spec card %s" % id)
		ci += 1
	ci = 0
	for id in ["grim_reaper", "coldsnap", "valhalla", "molar_patrol"]:
		_diff(_jsonish(Catalog.scouting(reg, reg.robot(id))), g.scouting[ci], "scouting %s" % id)
		ci += 1
	var base := reg.robot(reg.playerId)
	var design := {"name": base.name, "body": {"template": "wedge", "mount": "front", "extras": []}, "build": base.build, "livery": base.livery, "personality": base.personality}
	eq(Workshop.slots_of(reg, design.build).map(func(s): return "%s|%s|%s|%s" % [s.key, J.s(s.partId), s.label, J.s(s.optional)]), g.slots, "workshop slots")
	for key in ["weapon", "motor", "armor:front:0", "chassis"]:
		var got := Workshop.candidates(reg, null, design, key).map(func(c): return {"id": c.part.id, "fitted": c.fitted, "legal": c.legal, "delta": c.delta, "price": c.price, "w": c.after.weightLb if c.after != null else null})
		_diff(_jsonish(got), g.candidates[key], "candidates %s" % key)
	_diff(_jsonish(Workshop.summarize(reg, reg.robot("grim_reaper"))), g.summary, "summary")

	var career := Career.new_career(reg, {"seed": 3, "team": "Scrap Yard"})
	var gar := Garage.garage_of(reg, career)
	var nb: Dictionary = gar.build.duplicate()
	nb.weapon = "spinner_v_small"
	nb.weaponMotor = "wmotor_light"
	var a1 := Garage.apply_design(reg, career, {"build": nb, "name": "  Buzzkill  "})
	_diff(_jsonish({"ok": a1.ok, "errors": a1.errors, "cost": a1.cost, "cash": career.cash, "version": gar.version, "log": gar.log, "owned": gar.owned}), g.apply1, "apply design")
	var nb2: Dictionary = gar.build.duplicate()
	nb2.armor = ["armor_ar500_front", "armor_ar500_front"]
	var a2 := Garage.apply_design(reg, career, {"build": nb2})
	_diff(_jsonish({"ok": a2.ok, "errors": a2.errors}), g.apply2, "apply an illegal design")
	_diff(_jsonish(Garage.spares(reg, career)), g.spares, "spares")
	var sp := Garage.spares(reg, career).keys()
	if sp.size() > 0: _diff(_jsonish(Garage.sell_part(reg, career, sp[0])), g.sell, "sell a spare")
	var guard2 := 0
	while not J.truthy(career.get("seasonOver")) and guard2 < 400:
		guard2 += 1
		Career.advance_career(reg, career)
		if Career.next_fight(reg, career) != null:
			Career.simulate_player_fight(reg, career)
			Career.do_pit(reg, career, Career.pit_auto_plan(reg, career))
	_diff(_jsonish(HallOfFame.career_entry(reg, career)), g.entry, "hall of fame entry")
	var hall := HallOfFame.induct(reg, HallOfFame.empty_hall(), career)
	_diff(_jsonish(hall), g.hall, "hall of fame")
	var text := SaveFile.make_backup({"career": career, "hall": hall, "settings": {"difficulty": "hard", "bloom": false, "volume": 0.5, "junk": 1}}, "2026-01-01T00:00:00.000Z")
	var back2 := SaveFile.read_backup(text)
	ok(back2.ok, "backup reads: %s" % back2.error)
	if back2.ok: _diff(_jsonish({"describe": SaveFile.describe_backup(back2), "settings": back2.settings, "savedAt": back2.savedAt, "cash": back2.career.cash}), g.backup, "backup")
	ok(not SaveFile.read_backup("not json").ok and not SaveFile.read_backup("{\"schema\":\"robo-league-backup/9\"}").ok, "junk backups are refused")
	Career.start_next_season(reg, career)
	Career.advance_career(reg, career)
	var nf = Career.next_fight(reg, career)
	var bi := 0
	for b in ["a low wedge with a lifter", "fast drum, lots of armour, under $15,000", "invertible vertical spinner called Molar", "big hammer that hits hard, self-righting",
			"cheap horizontal bar with forks", "round shell spinner for 12k dollars", "", "an undercutter named Low Blow, with a plow"]:
		_diff(_jsonish(Advisor.parse_brief(b)), g.briefs[bi], "brief \"%s\"" % b)
		bi += 1
	var t1 := Time.get_ticks_msec()
	_diff(_jsonish(Advisor.advise(reg, {"kind": "design", "brief": "a fast vertical spinner with lots of armour", "career": career})), g.advice.design, "advice: design")
	_diff(_jsonish(Advisor.advise(reg, {"kind": "design", "brief": "something nice", "career": career})), g.advice.designNone, "advice: no brief")
	_diff(_jsonish(Advisor.advise(reg, {"kind": "opponent", "career": career, "oppId": nf.oppId})), g.advice.opponent, "advice: opponent")
	_diff(_jsonish(Advisor.advise(reg, {"kind": "fight", "career": career, "oppId": nf.oppId})), g.advice.fight, "advice: fight")
	_diff(_jsonish(Advisor.advise(reg, {"kind": "season", "career": career})), g.advice.season, "advice: season")
	_diff(_jsonish(Advisor.advise(reg, {"kind": "design", "brief": "a hammer that is tough"})), g.advice.sandbox, "advice: sandbox")
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
	_diff(_jsonish(lines), g.commentary, "commentary")
