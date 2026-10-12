## halloffame.gd - what outlasts a career.
##
## The Hall of Fame is kept apart from any one career and grows every time a
## career is retired: the team's entry - its record, titles, Giant Nuts, every
## robot it built - the AI robots that became legends in that career, and the
## all-time records across all of them.
class_name HallOfFame

const HOF_SCHEMA := "halloffame/1"

## Who the AI legends of a career are: by titles won in it.
const LEGEND_RULES := {"worldTitles": 3, "giantNuts": 2, "both": [2, 1]}

## An empty hall.
static func empty_hall() -> Dictionary:
	return {"schema": HOF_SCHEMA, "careers": [], "legends": [], "records": {}}

## A hall from storage, or a fresh one if there is none (or it is junk).
static func load_hall(text) -> Dictionary:
	return from_data(J.parse_json(text) if (text is String and text != "") else null)

static func from_data(h) -> Dictionary:
	if h is Dictionary and h.get("schema") == HOF_SCHEMA: return J.merge(empty_hall(), h)
	return empty_hall()

static func _legend_score(l: Dictionary) -> float:
	return l.giantNuts * 3.0 + l.worldTitles

## The AI robots that dominated this career: three World Championships, two
## Giant Nuts, or two Worlds and a Giant Nut.
static func legends_of(reg: Registry, career: Dictionary) -> Array:
	var tally := {}
	var get_t := func(id) -> Dictionary:
		if not tally.has(id): tally[id] = {"worldTitles": 0, "giantNuts": 0, "titles": {}, "first": INF, "last": 0}
		return tally[id]
	for h in career.get("history", []):
		if h.get("kind") == "league" and h.get("champions") != null:
			for lg in h.champions:
				var id = h.champions[lg]
				if not J.truthy(id) or id == career.playerId: continue
				var t: Dictionary = get_t.call(id)
				t.titles[lg] = t.titles.get(lg, 0) + 1
				if lg == "world": t.worldTitles += 1
				t.first = minf(t.first, h.season)
				t.last = maxf(t.last, h.season)
	for g in career.get("giantNutHistory", []):
		if not J.truthy(g.get("champion")) or g.champion == career.playerId: continue
		var t: Dictionary = get_t.call(g.champion)
		t.giantNuts += 1
		t.first = minf(t.first, g.season)
		t.last = maxf(t.last, g.season)
	var L := LEGEND_RULES
	var out := []
	for id in tally:
		var t: Dictionary = tally[id]
		if not (t.worldTitles >= L.worldTitles or t.giantNuts >= L.giantNuts or (t.worldTitles >= L.both[0] and t.giantNuts >= L.both[1])): continue
		var r := reg.robot(id)
		var ver = J.path(career, ["evolution", id, "version"])
		out.append({"id": id, "name": r.name, "team": J.g(r, "team", ""), "inspiredBy": r.get("inspiredBy"), "livery": J.g(r, "livery", {}),
			"worldTitles": t.worldTitles, "giantNuts": t.giantNuts, "titles": t.titles, "seasons": [t.first, t.last], "version": ver if J.truthy(ver) else "1.0"})
	return J.sorted(out, func(a, b): return _legend_score(b) - _legend_score(a))

static func _rank(l) -> int:
	if l == null: return 0
	return {"Champion": 9, "Final": 8, "Semi-final": 7, "Quarter-final": 6}.get(l, 1)

## The best the player reached: { league, giantNut: finish label or null }.
static func _best_of(reg: Registry, career: Dictionary) -> Dictionary:
	var order: Array = reg.league.leagues
	var best := 0
	for h in career.get("history", []):
		for lg in [h.get("league"), h.get("nextLeague")]:
			if J.truthy(lg): best = maxi(best, order.find(lg))
	best = maxi(best, order.find(J.path(career, ["membership", career.playerId], order[0])))
	var gn = null
	for g in career.get("giantNutHistory", []):
		if g.get("champion") == career.playerId:
			gn = "Champion"
			break
		if J.path(g, ["finish", "stage"]) == "final":
			var left: int = int(g.finish.rounds - g.finish.finish)
			var label: String
			if left == 1: label = "Final"
			elif left == 2: label = "Semi-final"
			elif left == 3: label = "Quarter-final"
			else: label = "Last %d" % (64 >> int(g.finish.finish))
			if gn == null or _rank(label) > _rank(gn): gn = label
	return {"league": order[best], "giantNut": gn}

## A retiring career's entry in the Hall of Fame.
static func career_entry(reg: Registry, career: Dictionary) -> Dictionary:
	var g := Garage.garage_of(reg, career)
	var s: Dictionary = career.stats
	var rec: Dictionary = J.g(g, "record", {})
	var robots: Array = J.g(g, "museum", []).duplicate()
	robots.append({
		"name": g.name, "version": g.get("version"), "from": J.g(rec, "since", 1), "to": career.seasonIndex,
		"fights": J.g(rec, "fights", s.fights), "wins": J.g(rec, "wins", s.wins), "kos": J.g(rec, "kos", s.kos), "titles": J.g(rec, "titles", 0),
		"weapon": reg.part(g.build.weapon).name if J.truthy(g.build.get("weapon")) else "None", "livery": g.get("livery"),
	})
	var giant_nuts: int = career.get("giantNutHistory", []).filter(func(x): return x.get("champion") == career.playerId).size()
	var n = Rivalry.nemesis_of(reg, career)
	return {
		"id": "%s:%s:%s" % [J.s(career.seed), career.team, J.s(career.seasonIndex)],
		"team": career.team,
		"seasons": career.seasonIndex,
		"record": {"fights": s.fights, "wins": s.wins, "losses": s.losses, "kos": s.kos},
		"titles": career.get("trophies", []).map(func(t): return {"season": t.season, "title": t.title, "robot": t.get("robot")}),
		"giantNuts": giant_nuts,
		"best": _best_of(reg, career),
		"earned": J.rnd(J.g(career, "earned", 0.0)),
		"cash": J.rnd(career.cash),
		"records": {"bestStreak": J.g(s, "bestStreak", 0), "fastestKoS": s.get("fastestKoS"), "mostDamage": J.rnd(J.g(s, "mostDamage", 0.0))},
		"robots": robots,
		"legends": legends_of(reg, career).map(func(l): return l.id),
		"nemesis": {"name": reg.robot(n.id).name if reg.has_robot(n.id) else n.id, "w": n.w, "l": n.l, "fights": n.fights} if n != null else null,
		"score": _career_score(career, giant_nuts),
	}

## One number to rank careers by: titles, Giant Nuts, then wins.
static func _career_score(career: Dictionary, giant_nuts: int) -> float:
	var titles: Array = career.get("trophies", [])
	var worlds: int = titles.filter(func(t): return t.get("league") == "world").size()
	return giant_nuts * 40.0 + worlds * 20.0 + (titles.size() - worlds) * 6.0 + J.g(career.stats, "wins", 0) * 0.5

## Put a retiring career into the hall (once), with its legends, and work the
## all-time records out again. Returns the hall.
static func induct(reg: Registry, hall, career: Dictionary) -> Dictionary:
	var entry := career_entry(reg, career)
	var h := J.merge(empty_hall(), hall if hall is Dictionary else {})
	if not J.some(h.careers, func(c): return c.id == entry.id):
		var cs: Array = h.careers.duplicate()
		cs.append(entry)
		h.careers = J.sorted(cs, func(a, b): return b.score - a.score)
	var legends: Array = h.legends.duplicate()
	for l in legends_of(reg, career):
		var key := "%s:%s" % [entry.id, l.id]
		if not J.some(legends, func(x): return x.get("key") == key):
			var nl: Dictionary = l.duplicate()
			nl.key = key
			nl.era = entry.team
			legends.append(nl)
	h.legends = J.sorted(legends, func(a, b): return _legend_score(b) - _legend_score(a))
	h.records = records_of(h.careers)
	return h

static func _best(careers: Array, pick: Callable, lower_is_better := false):
	var top = null
	for c in careers:
		var v = pick.call(c)
		if v == null or float(v) == 0.0: continue
		if top == null or (v < top.value if lower_is_better else v > top.value): top = {"value": v, "team": c.team}
	return top

## The all-time records across every career in the hall.
static func records_of(careers: Array) -> Dictionary:
	return {
		"mostTitles": _best(careers, func(c): return c.titles.size()),
		"mostGiantNuts": _best(careers, func(c): return c.giantNuts),
		"mostWins": _best(careers, func(c): return c.record.wins),
		"bestStreak": _best(careers, func(c): return c.records.bestStreak),
		"fastestKoS": _best(careers, func(c): return c.records.get("fastestKoS"), true),
		"mostDamage": _best(careers, func(c): return c.records.mostDamage),
		"longestCareer": _best(careers, func(c): return c.seasons),
	}
