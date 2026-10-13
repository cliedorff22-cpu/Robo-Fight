## season.gd - one season of the career: a league season or the Giant Nut.
##
## Pure logic over robot ids. A season is a plain Dictionary (it goes straight
## into the save file), advanced ROUND by round: a round is one fight for
## everyone scheduled, across all four leagues at once. Fights are settled by
## a `resolve(aId, bId, fixture)` callable the caller supplies; the player's
## own fight is left open, and recorded with record_result() when fought.
##
## League season (data/league.json `league`), per league:
##   group stage  6 groups of 5 drawn from rating pots, round robin
##   finals       group winners and runners-up plus the 4 best of the rest,
##                a seeded 16-robot bracket
##   movement     the top 4 of the final ranking go up, the bottom 4 down
##
## Giant Nut season (`giantNut`): 10 groups of 12, each drawn with three
## robots from every league; 8 fights each; the top 6 of every group into a
## 64 bracket seeded by group performance.
class_name Season

const GROUP_NAMES := ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]

static func _by_rating(ids: Array, ratings: Dictionary) -> Array:
	return J.sorted(ids, func(x, y):
		var d: float = J.g(ratings, y, 0.0) - J.g(ratings, x, 0.0)
		if d != 0.0: return d
		return -1 if x < y else 1)

static func _members_of(membership: Dictionary, lg: String) -> Array:
	var out := []
	for id in membership:
		if membership[id] == lg: out.append(id)
	return out

## Start a season.
##   format  reg.league (data/league.json)
##   o       { index, kind: "league" | "giantNut", membership: { id: league },
##             ratings: { id: rating }, seed }
static func make_season(format: Dictionary, o: Dictionary) -> Dictionary:
	var index: int = int(o.index)
	var kind: String = o.kind
	var membership: Dictionary = o.membership
	var ratings: Dictionary = o.ratings
	var seed_v = o.seed
	var rng := Rng.new(Rng.hash_seed("season:%s:%d" % [J.s(seed_v), index]))
	var season := {"schema": "season/1", "index": index, "kind": kind, "seed": seed_v, "round": 0, "done": false, "fixtures": []}

	if kind == "league":
		var f: Dictionary = format.league
		var group_size := int(f.groupSize)
		season.leagues = {}
		season.groupRounds = group_size - (0 if group_size % 2 == 1 else 1)
		for lg in format.leagues:
			var members := _by_rating(_members_of(membership, lg), ratings)
			var drawn := _draw_groups(members, int(f.groups), rng)
			var groups := []
			# The order inside a group sets who meets whom in which round: mix
			# it, or the pot a robot sits in would fix its opponents' order.
			for g in drawn.size(): groups.append({"name": GROUP_NAMES[g], "ids": rng.shuffle(drawn[g])})
			season.leagues[lg] = {"members": members, "groups": groups, "finals": null, "ranking": null, "movement": null}
			for grp in groups:
				var rounds := Tournament.round_robin(grp.ids)
				for r in rounds.size():
					for pr in rounds[r]:
						season.fixtures.append({"id": "s%d:%s:%s:%d:%s:%s" % [index, lg, grp.name, r, pr[0], pr[1]], "stage": "group", "league": lg, "group": grp.name, "round": r, "a": pr[0], "b": pr[1], "result": null})
		season.finalsRounds = int(round(log(float(f.finals.size)) / log(2.0)))
	else:
		var g: Dictionary = format.giantNut
		var n_groups := int(g.groups)
		# Three from every league in every group: each league's robots are
		# drawn in pots of ten by rating, one from each pot per group.
		var groups := []
		for i in n_groups: groups.append([])
		for lg in format.leagues:
			var members := _by_rating(_members_of(membership, lg), ratings)
			var p := 0
			while p < members.size():
				var pot := rng.shuffle(members.slice(p, p + n_groups))
				for i in pot.size(): groups[i % n_groups].append(pot[i])
				p += n_groups
		var named := []
		for i in groups.size(): named.append({"name": GROUP_NAMES[i], "ids": groups[i]})
		season.giantNut = {"groups": named, "bracket": null, "ranking": null}
		season.groupRounds = int(g.fightsEach)
		for grp in named:
			var rounds := Tournament.partial_round_robin(grp.ids, int(g.fightsEach), rng)
			for r in rounds.size():
				for pr in rounds[r]:
					season.fixtures.append({"id": "s%d:gn:%s:%d:%s:%s" % [index, grp.name, r, pr[0], pr[1]], "stage": "group", "league": "giantNut", "group": grp.name, "round": r, "a": pr[0], "b": pr[1], "result": null})
		season.finalsRounds = int(round(log(float(g.bracket)) / log(2.0)))
	season.totalRounds = season.groupRounds + season.finalsRounds
	return season

## Deal ranked robots into groups by pots: one from each pot of `n`, in a random
## order. Then a robot of each pot trades places with one of the next pot down
## in another group, now and then, so the same pots do not make the same groups
## every season (ratings barely move, so the pots hardly change).
static func _draw_groups(ranked: Array, n: int, rng: Rng) -> Array:
	var groups := []
	for i in n: groups.append([])
	var p := 0
	while p < ranked.size():
		var pot := rng.shuffle(ranked.slice(p, p + n))
		for i in pot.size(): groups[i % n].append(pot[i])
		p += n
	for k in range(n - 1):
		if rng.next() < 0.6:
			var a: int = int(floor(rng.next() * n))
			var b: int = int(floor(rng.next() * (n - 1)))
			if b >= a: b += 1
			var ai: int = mini(k, (groups[a] as Array).size() - 1)
			var bi: int = mini(k + 1, (groups[b] as Array).size() - 1)
			var t = groups[a][ai]
			groups[a][ai] = groups[b][bi]
			groups[b][bi] = t
	return groups

## Is this round in the group stage?
static func in_groups(season: Dictionary) -> bool:
	return season.round < season.groupRounds

## Fights still to be fought this round.
static func pending(season: Dictionary) -> Array:
	if season.done: return []
	if in_groups(season):
		return season.fixtures.filter(func(f): return f.stage == "group" and f.round == season.round and f.result == null)
	var out := []
	var fr: int = int(season.round - season.groupRounds)
	for cb in _brackets(season):
		var comp: String = cb[0]
		for m in Tournament.open_matches(cb[1]):
			if m.round != fr: continue
			out.append({"id": "s%d:%s:final:%d:%d" % [int(season.index), comp, m.round, m.index], "stage": "final", "league": comp, "round": season.round, "bracketRound": m.round, "index": m.index, "a": m.a, "b": m.b})
	return out

## Every bracket in play: [[competition, bracket]].
static func _brackets(season: Dictionary) -> Array:
	var out := []
	if season.kind == "league":
		for lg in season.leagues:
			var l: Dictionary = season.leagues[lg]
			if l.get("finals") != null: out.append([lg, l.finals])
		return out
	if season.giantNut.get("bracket") != null: out.append(["giantNut", season.giantNut.bracket])
	return out

## The player's fight this round, if they have one still to fight.
static func player_fixture(season: Dictionary, player_id):
	for f in pending(season):
		if f.a == player_id or f.b == player_id: return f
	return null

## Store a fight's result. `result` = { winnerId, method, damage: { id: n }, ... }.
static func record_result(season: Dictionary, fixture: Dictionary, result: Dictionary) -> void:
	if fixture.stage == "group":
		var found = null
		for x in season.fixtures:
			if x.id == fixture.id:
				found = x
				break
		assert(found != null, "no fixture %s" % fixture.id)
		found.result = result
	else:
		var bracket: Dictionary = season.giantNut.bracket if fixture.league == "giantNut" else season.leagues[fixture.league].finals
		Tournament.record_bracket(bracket, fixture.bracketRound, fixture.index, result)
		if season.get("finalsLog") == null: season.finalsLog = []
		var entry: Dictionary = fixture.duplicate()
		entry.result = result
		season.finalsLog.append(entry)

## Fight every pending fight this round except the player's, then, if the
## round is complete, move on (drawing the finals after the group stage and
## closing the season after the last final). Repeats round after round until
## the player has a fight to fight or the season is over.
##   o: { resolve: Callable(aId, bId, fixture) -> result, playerId, stopForPlayer = true }
## Returns [{ fixture, result }] everything resolved, in order.
static func advance(season: Dictionary, format: Dictionary, o: Dictionary) -> Array:
	var resolve: Callable = o.resolve
	var player_id = o.get("playerId")
	var stop_for_player: bool = o.get("stopForPlayer", true)
	var out_log := []
	var guard := 0
	while guard < 200 and not season.done:
		guard += 1
		for f in pending(season):
			if stop_for_player and (f.a == player_id or f.b == player_id): continue
			var result = resolve.call(f.a, f.b, f)
			record_result(season, f, result)
			out_log.append({"fixture": f, "result": result})
		if pending(season).size() > 0: break          # the player's fight is waiting
		_next_round(season, format)
	return out_log

## Close the round: draw the finals after the group stage, finish after the final.
static func _next_round(season: Dictionary, format: Dictionary) -> void:
	season.round += 1
	if season.round == season.groupRounds: _start_finals(season, format)
	if season.round >= season.totalRounds: _finish(season, format)

## Group tables: { competition: { group: rows } }.
static func group_tables(season: Dictionary) -> Dictionary:
	var out := {}
	var comps := []
	if season.kind == "league":
		for lg in season.leagues: comps.append([lg, season.leagues[lg].groups])
	else:
		comps.append(["giantNut", season.giantNut.groups])
	# One pass over the fixtures, bucketed by competition and group.
	var buckets := {}
	for f in season.fixtures:
		var k := "%s|%s" % [f.league, f.group]
		if not buckets.has(k): buckets[k] = []
		buckets[k].append(f)
	for cg in comps:
		var comp: String = cg[0]
		out[comp] = {}
		for g in cg[1]:
			out[comp][g.name] = Tournament.standings(g.ids, buckets.get("%s|%s" % [comp, g.name], []))
	return out

static func _start_finals(season: Dictionary, format: Dictionary) -> void:
	var tables := group_tables(season)
	if season.kind == "league":
		var f: Dictionary = format.league.finals
		for lg in season.leagues:
			var l: Dictionary = season.leagues[lg]
			var t: Array = l.groups.map(func(g): return tables[lg][g.name])
			var winners := J.sorted(t.map(func(rows): return rows[0]), Tournament.compare_rows)
			var runners := J.sorted(t.map(func(rows): return rows[1]), Tournament.compare_rows)
			var through := {}
			for r in winners: through[r.id] = true
			for r in runners: through[r.id] = true
			var wild := Tournament.wild_cards(t, through, int(f.wildCards))
			var seeded := []
			for r in winners: seeded.append(r.id)
			for r in runners: seeded.append(r.id)
			for r in wild: seeded.append(r.id)
			l.finals = Tournament.make_bracket(seeded, int(f.size))
			l.wildCards = wild.map(func(r): return r.id)
	else:
		var g: Dictionary = format.giantNut
		var t: Array = season.giantNut.groups.map(func(grp): return tables.giantNut[grp.name])
		# Seeded by group performance: every group winner ahead of every
		# runner-up, and so on, each tier by record.
		var seeded := []
		for pos in int(g.advance):
			for r in J.sorted(t.map(func(rows): return rows[pos]), Tournament.compare_rows): seeded.append(r.id)
		season.giantNut.bracket = Tournament.make_bracket(seeded, int(g.bracket))

## The final ranking of a league: how far a robot got in the finals, then its
## group record. Non-qualifiers follow, by record.
static func league_ranking(season: Dictionary, lg: String) -> Array:
	var l: Dictionary = season.leagues[lg]
	var row := {}
	var tables: Dictionary = group_tables(season)[lg]
	for g in tables:
		for r in tables[g]: row[r.id] = r
	var fin: Dictionary = Tournament.bracket_finish(l.finals) if l.get("finals") != null else {}
	return J.sorted(l.members, func(x, y):
		var d: float = float(fin.get(y, -1)) - float(fin.get(x, -1))
		if d != 0.0: return d
		return Tournament.compare_rows(row[x], row[y]))

static func _finish(season: Dictionary, format: Dictionary) -> void:
	season.done = true
	if season.kind == "league":
		var order: Array = format.leagues
		for lg in season.leagues:
			var l: Dictionary = season.leagues[lg]
			l.ranking = league_ranking(season, lg)
			l.champion = Tournament.champion(l.finals)
			var i := order.find(lg)
			l.movement = {
				"promoted": l.ranking.slice(0, int(format.league.promote)) if i < order.size() - 1 else [],
				"relegated": J.slice(l.ranking, -int(format.league.relegate)) if i > 0 else [],
			}
	else:
		var gn: Dictionary = season.giantNut
		gn.champion = Tournament.champion(gn.bracket)
		var fin := Tournament.bracket_finish(gn.bracket)
		var rows := []
		var row := {}
		var tables: Dictionary = group_tables(season).giantNut
		for g in tables:
			for r in tables[g]:
				rows.append(r)
				row[r.id] = r
		gn.ranking = J.sorted(rows.map(func(r): return r.id), func(x, y):
			var d: float = float(fin.get(y, -1)) - float(fin.get(x, -1))
			if d != 0.0: return d
			return Tournament.compare_rows(row[x], row[y]))

## League membership after a finished league season: everyone moved up or down.
static func next_membership(season: Dictionary, membership: Dictionary, format: Dictionary) -> Dictionary:
	var out := membership.duplicate()
	if season.kind != "league": return out
	var order: Array = format.leagues
	for lg in season.leagues:
		var l: Dictionary = season.leagues[lg]
		var i := order.find(lg)
		for id in l.movement.promoted: out[id] = order[i + 1]
		for id in l.movement.relegated: out[id] = order[i - 1]
	return out

## How far a robot got: { stage: "group" | "final", finish } where finish is
## the bracket round reached (the champion gets the number of rounds).
static func robot_finish(season: Dictionary, id) -> Dictionary:
	var bracket = null
	if season.kind == "league":
		for lg in season.leagues:
			var l: Dictionary = season.leagues[lg]
			if l.members.has(id):
				bracket = l.get("finals")
				break
	else:
		bracket = season.giantNut.get("bracket")
	if bracket == null: return {"stage": "group", "finish": -1}
	var fin := Tournament.bracket_finish(bracket)
	if fin.has(id): return {"stage": "final", "finish": fin[id], "rounds": bracket.rounds.size()}
	return {"stage": "group", "finish": -1, "rounds": bracket.rounds.size()}
