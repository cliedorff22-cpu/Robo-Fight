## cup.gd - tournament mode: a one-off tournament outside the career.
##
## Three formats (data/league.json `cup`):
##   knockout   a seeded single-elimination bracket (byes for the top seeds)
##   groups     groups of four, round robin, the top two of each into a
##              seeded bracket
##   giantNut   the real thing: 120 robots, ten groups of twelve, eight fights
##              each, the top six of every group into a 64 bracket
##
## Any entrant can be driven by a person - one player, or friends taking
## turns. Every fight without a person in it is settled by the fast resolver;
## a person's fight waits to be fought in the arena or handed to the AI.
## Robots are repaired between fights.
##
## Pure logic over a plain Dictionary - the cup is its own save.
class_name Cup

const CUP_SCHEMA := "cup/1"
const GROUP_NAMES := ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]

## Formats and sizes (league.json `cup`), with defaults.
static func cup_config(reg: Registry) -> Dictionary:
	var c: Dictionary = J.g(reg.league, "cup", {})
	return {
		"formats": J.g(c, "formats", [
			{"id": "knockout", "name": "Knockout", "sizes": [4, 8, 16, 32, 64], "blurb": "One bracket. Lose once and you are out."},
			{"id": "groups", "name": "Groups, then knockout", "sizes": [8, 16, 32, 64], "blurb": "Groups of four fight a round robin; the top two of each go into the bracket."},
			{"id": "giantNut", "name": "The Giant Nut", "sizes": [120], "blurb": "All 120 robots: ten groups of twelve, eight fights each, a 64-robot bracket."},
		]),
		"groupSize": J.g(c, "groupSize", 4),
		"advance": J.g(c, "advance", 2),
		"maxPlayers": J.g(c, "maxPlayers", 8),
	}

## The id a person's own robot (brought from their career) races under in a cup.
static func custom_id(slot: int) -> String:
	return "cup_custom_%d" % slot

static func _rating(reg: Registry, custom: Dictionary, id) -> float:
	var c = custom.get(id)
	if c != null and c.get("rating") != null: return c.rating
	return reg.robot(id).rating

## A new tournament. Returns { ok, cup, error }.
##   o.format   "knockout" | "groups" | "giantNut"
##   o.size     entrants (ignored for the Giant Nut: the whole field)
##   o.players  [{ name, robot, def? }] - the people, each with a robot id
##              from the field, or `def` (a robot they built)
##   o.fill     who else is in: "random", "top" (the best-rated) or a league id
##   o.venue    a venue id, or "rounds" (it moves up the venues as the cup goes on)
##   o.layout   a layout id, or "random" (from the venue's rotation, by fight)
static func make_cup(reg: Registry, o: Dictionary = {}) -> Dictionary:
	var format: String = J.g(o, "format", "knockout")
	var size: int = int(J.g(o, "size", 8))
	var players: Array = J.g(o, "players", [])
	var fill = J.g(o, "fill", "random")
	var seed_v = J.g(o, "seed", 1)
	var cfg := cup_config(reg)
	if not J.some(cfg.formats, func(f): return f.id == format): return {"ok": false, "cup": null, "error": "no cup format %s" % format}
	var rng := Rng.new(Rng.hash_seed("cup:%s" % J.s(seed_v)))
	var field: Array = reg.roster().map(func(r): return r.id)
	# The people and their robots.
	var custom := {}
	var humans := {}
	var people: Array = players.slice(0, int(cfg.maxPlayers))
	for i in people.size():
		var p: Dictionary = people[i]
		var id = p.get("robot")
		if p.get("def") != null:
			id = custom_id(i)
			var d: Dictionary = p.def.duplicate()
			d.id = id
			d.league = p.def.league if J.truthy(p.def.get("league")) else "rookie"
			d.rating = J.g(p.def, "rating", 50)
			d.team = p.name if J.truthy(p.get("name")) else "Player %d" % (i + 1)
			custom[id] = d
		if not J.truthy(id) or (not custom.has(id) and not reg.has_robot(id)): return {"ok": false, "cup": null, "error": "player %d has no robot" % (i + 1)}
		if humans.has(id): return {"ok": false, "cup": null, "error": "two players picked %s" % (reg.robot(id).name if reg.has_robot(id) else id)}
		humans[id] = i
	var n: int = field.size() if format == "giantNut" else maxi(2, size)
	# Everyone else, by the fill rule.
	var pool := field.filter(func(id): return not humans.has(id))
	if fill == "top":
		pool = J.sorted(pool, func(a, b):
			var d: float = _rating(reg, custom, b) - _rating(reg, custom, a)
			return d if d != 0.0 else (-1.0 if a < b else 1.0))
	elif reg.league.leagues.has(fill):
		var in_league := pool.filter(func(id): return reg.robot(id).league == fill)
		var rest := pool.filter(func(id): return reg.robot(id).league != fill)
		pool = rng.shuffle(in_league)
		pool.append_array(rng.shuffle(rest))
	else:
		pool = rng.shuffle(pool)
	var entrants: Array = humans.keys()
	entrants.append_array(pool)
	entrants = entrants.slice(0, maxi(n, humans.size()))

	var ratings := {}
	for id in entrants: ratings[id] = _rating(reg, custom, id)
	var nm := str(J.g(o, "name", "Tournament")).strip_edges().substr(0, 40)
	var cup := {
		"schema": CUP_SCHEMA, "version": 1, "name": nm if nm != "" else "Tournament", "format": format, "seed": seed_v,
		"players": [],
		"humans": humans, "custom": custom, "entrants": entrants, "venue": J.g(o, "venue", "rounds"), "layout": J.g(o, "layout", "random"),
		"ratings": ratings,
		"round": 0, "groups": null, "groupRounds": 0, "fixtures": [], "bracket": null, "bracketRounds": 0, "done": false, "champion": null, "log": [],
	}
	for i in people.size():
		var pn := str(J.g(people[i], "name", "")).strip_edges().substr(0, 20)
		cup.players.append({"name": pn if pn != "" else "Player %d" % (i + 1)})
	var seeded := J.sorted(entrants, func(a, b):
		var d: float = ratings[b] - ratings[a]
		return d if d != 0.0 else (-1.0 if a < b else 1.0))
	if format == "knockout":
		cup.bracket = Tournament.make_bracket(seeded, Tournament.next_pow2(entrants.size()))
		cup.bracketRounds = cup.bracket.rounds.size()
	else:
		var gn = reg.league.giantNut if format == "giantNut" else null
		var G: int = int(gn.groups) if gn != null else maxi(2, J.rndi(float(entrants.size()) / cfg.groupSize))
		# Pots by rating: one from each pot of G per group.
		var groups := []
		for i in G: groups.append([])
		var p := 0
		while p < seeded.size():
			var pot := rng.shuffle(seeded.slice(p, p + G))
			for i in pot.size(): groups[i % G].append(pot[i])
			p += G
		cup.groups = []
		for i in groups.size(): cup.groups.append({"name": GROUP_NAMES[i], "ids": groups[i]})
		for g in cup.groups:
			var rounds: Array
			if gn != null and g.ids.size() % 2 == 0 and gn.fightsEach < g.ids.size() - 1: rounds = Tournament.partial_round_robin(g.ids, int(gn.fightsEach), rng)
			else: rounds = Tournament.round_robin(g.ids)
			for r in rounds.size():
				for pr in rounds[r]:
					cup.fixtures.append({"id": "g:%s:%d:%s:%s" % [g.name, r, pr[0], pr[1]], "stage": "group", "group": g.name, "round": r, "a": pr[0], "b": pr[1], "result": null})
			cup.groupRounds = maxi(int(cup.groupRounds), rounds.size())
		cup.advance = gn.advance if gn != null else cfg.advance
		cup.bracketSize = gn.bracket if gn != null else Tournament.next_pow2(int(cup.groups.size() * cup.advance))
		cup.bracketRounds = int(round(log(float(cup.bracketSize)) / log(2.0)))
	cup.totalRounds = cup.groupRounds + cup.bracketRounds
	return {"ok": true, "cup": cup, "error": ""}

## Register a cup's own robots (people's career robots) with the registry.
static func register_cup_robots(reg: Registry, cup) -> void:
	if not (cup is Dictionary): return
	for def in cup.get("custom", {}).values(): reg.add_robot(def)

## The robot def a cup entrant fights as.
static func cup_def(reg: Registry, cup: Dictionary, id) -> Dictionary:
	var c = J.path(cup, ["custom", id])
	return c if c != null else reg.robot(id)

## Is this robot driven by a person? Their player index, or null.
static func human_of(cup: Dictionary, id):
	return J.path(cup, ["humans", id])

static func _has_human(cup: Dictionary, f: Dictionary) -> bool:
	return human_of(cup, f.a) != null or human_of(cup, f.b) != null

## Fights still to fight this round.
static func cup_pending(cup: Dictionary) -> Array:
	if cup.done: return []
	if cup.round < cup.groupRounds: return cup.fixtures.filter(func(f): return f.round == cup.round and f.get("result") == null)
	var br: int = int(cup.round - cup.groupRounds)
	var out := []
	for m in Tournament.open_matches(cup.bracket):
		if m.round == br: out.append({"id": "k:%d:%d" % [m.round, m.index], "stage": "final", "bracketRound": m.round, "index": m.index, "a": m.a, "b": m.b})
	return out

## The next fight a person has to fight (or hand to the AI), or null.
static func next_cup_fight(cup: Dictionary):
	for f in cup_pending(cup):
		if _has_human(cup, f): return f
	return null

## A fixture's seed, the same every time.
static func cup_seed(cup: Dictionary, f: Dictionary) -> int:
	return Rng.hash_seed("%s:%s" % [J.s(cup.seed), f.id]) & 0x7fffffff

## What a cup keeps of a fight.
static func _compact(r: Dictionary, by: String) -> Dictionary:
	var damage := {}
	var sides: Dictionary = J.g(r, "sides", {})
	for id in sides: damage[id] = sides[id].get("damageScore")
	return {"winnerId": r.winnerId, "loserId": r.get("loserId"), "method": r.get("method"), "cause": r.get("cause"), "elapsedS": J.rnd(J.g(r, "elapsedS", 0.0)),
		"decision": r.get("decision"), "damage": damage, "by": by}

## Settle a fight with the resolver (both robots fresh).
static func _resolve(reg: Registry, cup: Dictionary, f: Dictionary) -> Dictionary:
	return _compact(Resolver.resolve_fight(reg, cup_def(reg, cup, f.a), cup_def(reg, cup, f.b), {"seed": cup_seed(cup, f)}), "sim")

static func _find_pending(cup: Dictionary, fixture_id):
	for x in cup_pending(cup):
		if x.id == fixture_id: return x
	return null

## Store a result and move the cup on as far as it goes without a person.
## Returns the fights then resolved, in order (null if there is no such fight).
static func record_cup_result(reg: Registry, cup: Dictionary, fixture_id, result: Dictionary):
	var f = _find_pending(cup, fixture_id)
	if f == null: return null
	if result.winnerId != f.a and result.winnerId != f.b: return null
	var r: Dictionary = result.duplicate()
	r.loserId = f.b if result.winnerId == f.a else f.a
	_store(cup, f, r)
	return advance_cup(reg, cup)

## Hand a person's fight to the AI: the resolver fights it.
static func simulate_cup_fight(reg: Registry, cup: Dictionary, fixture_id):
	var f = _find_pending(cup, fixture_id)
	if f == null: return null
	var r := _resolve(reg, cup, f)
	_store(cup, f, r)
	advance_cup(reg, cup)
	return r

static func _store(cup: Dictionary, f: Dictionary, result: Dictionary) -> void:
	if f.stage == "group":
		for x in cup.fixtures:
			if x.id == f.id:
				x.result = result
				break
	else:
		Tournament.record_bracket(cup.bracket, f.bracketRound, f.index, result)
	cup.log.append({"id": f.id, "stage": f.stage, "group": f.get("group"), "round": cup.round, "bracketRound": f.get("bracketRound"), "a": f.a, "b": f.b, "result": result})

## Fight every pending fight with no person in it, round after round, until a
## person's fight is waiting or the cup is over. Returns the fights resolved.
static func advance_cup(reg: Registry, cup: Dictionary) -> Array:
	var out := []
	var guard := 0
	while guard < 400 and not cup.done:
		guard += 1
		for f in cup_pending(cup):
			if _has_human(cup, f): continue
			var r := _resolve(reg, cup, f)
			_store(cup, f, r)
			out.append({"fixture": f, "result": r})
		if cup_pending(cup).size() > 0: break
		_next_round(cup)
	return out

static func _next_round(cup: Dictionary) -> void:
	cup.round += 1
	if cup.round == cup.groupRounds and cup.get("groups") != null: _draw_bracket(cup)
	if cup.round >= cup.totalRounds:
		cup.done = true
		cup.champion = Tournament.champion(cup.bracket)

## Group tables: { group: rows }.
static func cup_tables(cup: Dictionary) -> Dictionary:
	var out := {}
	if cup.get("groups") == null: return out
	for g in cup.groups:
		out[g.name] = Tournament.standings(g.ids, cup.fixtures.filter(func(f): return f.get("group") == g.name))
	return out

## After the groups: the top of every group into the bracket, seeded by
## finishing place, then record.
static func _draw_bracket(cup: Dictionary) -> void:
	var tables: Array = cup_tables(cup).values()
	var seeded := []
	for pos in int(cup.advance):
		var tier := []
		for rows in tables:
			if pos < rows.size(): tier.append(rows[pos])
		for r in J.sorted(tier, Tournament.compare_rows): seeded.append(r.id)
	cup.bracket = Tournament.make_bracket(seeded, int(cup.bracketSize))

## How far each robot got, best first: [{ id, finish }].
static func cup_ranking(cup: Dictionary) -> Array:
	var fin: Dictionary = Tournament.bracket_finish(cup.bracket) if cup.get("bracket") != null else {}
	var out: Array = cup.entrants.map(func(id): return {"id": id, "finish": fin.get(id, -1)})
	return J.sorted(out, func(a, b):
		var d: float = float(b.finish) - float(a.finish)
		return d if d != 0.0 else float(cup.ratings[b.id] - cup.ratings[a.id]))

## "Group B · round 2" / "Quarterfinals".
static func cup_stage_label(cup: Dictionary, f: Dictionary) -> String:
	if f.stage == "group": return "Group %s · round %d" % [f.get("group"), int(f.round) + 1]
	return Tournament.round_name(cup.bracket, f.bracketRound) if cup.get("bracket") != null else "Bracket"

## Where a fight is: the cup's venue (or, for "rounds", the venues in order
## from the first round to the final, the final in the biggest), on its
## layout or one from the venue's rotation by the fight's seed.
static func cup_arena(reg: Registry, cup: Dictionary, f: Dictionary) -> Dictionary:
	var venue = cup.get("venue")
	if Arenas.venue_of(reg, venue) == null:
		var all := Arenas.venue_ids(reg)
		var big: Array = all if cup.format == "giantNut" else all.filter(func(v): return v != "giantNut")
		var at: float = cup.round / maxf(1.0, cup.totalRounds - 1)
		venue = big[big.size() - 1] if cup.done else big[mini(big.size() - 1, int(floor(at * big.size())))]
		if cup.format == "giantNut": venue = "giantNut"
	var layout = cup.layout if Arenas.layout_of(reg, cup.get("layout")) != null else Arenas.layout_for_fight(reg, venue, cup_seed(cup, f))
	return {"venue": venue, "layout": layout}

## The cup as a save string, and back ({ ok, cup, error }).
static func serialize_cup(cup: Dictionary) -> String:
	return J.to_json(cup)

static func deserialize_cup(text: String) -> Dictionary:
	return from_data(J.parse_json(text))

static func from_data(c) -> Dictionary:
	if not (c is Dictionary) or c.get("schema") != CUP_SCHEMA: return {"ok": false, "cup": null, "error": "not a ROBO LEAGUE tournament"}
	return {"ok": true, "cup": c, "error": ""}
