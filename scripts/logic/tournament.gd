## tournament.gd - the formats: round-robin groups, standings, wild cards and
## single-elimination brackets.
##
## Pure logic on robot ids and fight results. season.gd decides WHO is drawn
## into what; this file only knows how a format works.
class_name Tournament

## Round-robin rounds by the circle method: every robot meets every other
## once, and each round nobody fights twice. Returns rounds of [a, b] pairs.
static func round_robin(ids: Array) -> Array:
	var list := ids.duplicate()
	if list.size() % 2 == 1: list.append(null)
	var n := list.size()
	var rounds := []
	for r in range(n - 1):
		var pairs := []
		for i in range(n / 2):
			var a = list[i]
			var b = list[n - 1 - i]
			if a != null and b != null:
				pairs.append([b, a] if r % 2 == 1 else [a, b])
		rounds.append(pairs)
		# Keep the first fixed, rotate the rest one place.
		list.insert(1, list.pop_back())
	return rounds

## A partial round robin: every robot fights exactly `k` of the others, one
## fight per round, nobody twice.
static func partial_round_robin(ids: Array, k: int, rng: Rng = null) -> Array:
	assert(ids.size() % 2 == 0, "partialRoundRobin needs an even group")
	var all := round_robin(rng.shuffle(ids) if rng != null else ids)
	assert(k <= all.size(), "a group of %d has only %d rounds" % [ids.size(), all.size()])
	var idx := range(all.size())
	var picked: Array
	if rng != null:
		picked = rng.shuffle(idx).slice(0, k)
		picked.sort()
	else:
		picked = idx.slice(0, k)
	return picked.map(func(i): return all[i])

## Standings from results. A row per robot:
##   { id, played, wins, losses, kos, koLosses, damage, damageTaken }
## sorted by wins, then knockouts, then damage score.
static func standings(ids: Array, fights: Array) -> Array:
	var rows := {}
	for id in ids:
		rows[id] = {"id": id, "played": 0, "wins": 0, "losses": 0, "kos": 0, "koLosses": 0, "damage": 0.0, "damageTaken": 0.0}
	for f in fights:
		var r = f.get("result")
		if r == null: continue
		for id in [f.a, f.b]:
			var row = rows.get(id)
			if row == null: continue
			var other_id = f.b if id == f.a else f.a
			row.played += 1
			var won: bool = r.winnerId == id
			if won:
				row.wins += 1
				if r.get("method") == "ko": row.kos += 1
			else:
				row.losses += 1
				if r.get("method") == "ko": row.koLosses += 1
			row.damage += J.path(r, ["damage", id], 0.0)
			row.damageTaken += J.path(r, ["damage", other_id], 0.0)
	return J.sorted(rows.values(), compare_rows)

## Wins, then KOs, then damage dealt; the id last so a sort is never ambiguous.
static func compare_rows(x, y) -> float:
	if y.wins != x.wins: return y.wins - x.wins
	if y.kos != x.kos: return y.kos - x.kos
	if y.damage != x.damage: return y.damage - x.damage
	return J.strcmp(x.id, y.id)

## The best `n` rows not already through, by record then damage.
## `qualified` is a Dictionary used as a set of ids.
static func wild_cards(tables: Array, qualified: Dictionary, n: int) -> Array:
	var rest := []
	for t in tables:
		for r in t:
			if not qualified.has(r.id): rest.append(r)
	return J.sorted(rest, compare_rows).slice(0, n)

## Bracket slot order for `size` (a power of two): seed 1 meets the lowest
## seed, and 1 and 2 can only meet in the final. [1, 16, 8, 9, 5, 12, 4, 13, ...]
static func seed_order(size: int) -> Array:
	var order := [1]
	while order.size() < size:
		var m := order.size() * 2 + 1
		var nxt := []
		for s in order:
			nxt.append(s)
			nxt.append(m - s)
		order = nxt
	return order

static func next_pow2(n: int) -> int:
	var p := 1
	while p < n: p *= 2
	return p

## A single-elimination bracket from robots listed in seed order. With fewer
## robots than slots the top seeds get byes.
## Returns { size, rounds: [[match]] }, match = { a, b, winner, result, bye }
static func make_bracket(seeded: Array, size: int = -1) -> Dictionary:
	if size < 0: size = next_pow2(seeded.size())
	assert(seeded.size() <= size, "%d robots do not fit a %d bracket" % [seeded.size(), size])
	var slots := seed_order(size).map(func(s): return seeded[s - 1] if s - 1 < seeded.size() else null)
	var first := []
	for i in range(0, size, 2):
		var a = slots[i]
		var b = slots[i + 1]
		var bye: bool = a == null or b == null
		first.append({"a": a, "b": b, "winner": (a if a != null else b) if bye else null, "result": null, "bye": bye})
	var rounds := [first]
	var n := size / 4
	while n >= 1:
		var ms := []
		for i in n: ms.append({"a": null, "b": null, "winner": null, "result": null, "bye": false})
		rounds.append(ms)
		n /= 2
	var bracket := {"size": size, "rounds": rounds}
	_propagate(bracket)
	return bracket

## Record a bracket result and move the winner on.
static func record_bracket(bracket: Dictionary, round_i, index, result: Dictionary) -> void:
	var m = bracket.rounds[int(round_i)][int(index)]
	assert(m != null and m.a != null and m.b != null, "no fight at round %d match %d" % [int(round_i), int(index)])
	assert(result.winnerId == m.a or result.winnerId == m.b, "%s is not in this fight" % str(result.winnerId))
	m.result = result
	m.winner = result.winnerId
	_propagate(bracket)

## Fill later rounds from winners so far.
static func _propagate(bracket: Dictionary) -> void:
	for r in range(1, bracket.rounds.size()):
		var ms: Array = bracket.rounds[r]
		for i in ms.size():
			var m: Dictionary = ms[i]
			var fa: Dictionary = bracket.rounds[r - 1][i * 2]
			var fb: Dictionary = bracket.rounds[r - 1][i * 2 + 1]
			m.a = fa.winner
			m.b = fb.winner
			if m.result != null and m.winner != m.a and m.winner != m.b:
				m.result = null
				m.winner = null

## Fights ready to be fought: both robots known, no result yet.
static func open_matches(bracket: Dictionary) -> Array:
	var out := []
	for r in bracket.rounds.size():
		var ms: Array = bracket.rounds[r]
		for i in ms.size():
			var m: Dictionary = ms[i]
			if m.a != null and m.b != null and m.winner == null:
				out.append({"round": r, "index": i, "a": m.a, "b": m.b})
	return out

## The champion, once the final is decided.
static func champion(bracket: Dictionary):
	return bracket.rounds[bracket.rounds.size() - 1][0].winner

## How far each robot got: { id: roundReached } where the champion gets
## rounds.size() and a first-round loser 0 (a bye counts as winning round 0).
static func bracket_finish(bracket: Dictionary) -> Dictionary:
	var out := {}
	for r in bracket.rounds.size():
		for m in bracket.rounds[r]:
			for id in [m.a, m.b]:
				if id != null: out[id] = maxi(out.get(id, 0), r)
			if m.winner != null: out[m.winner] = maxi(out.get(m.winner, 0), r + 1)
	return out

## Display name of a round, counted back from the final.
static func round_name(bracket: Dictionary, r) -> String:
	var left: int = bracket.rounds.size() - int(r)
	if left == 1: return "Final"
	if left == 2: return "Semifinals"
	if left == 3: return "Quarterfinals"
	return "Round of %d" % (int(bracket.size) >> int(r))
