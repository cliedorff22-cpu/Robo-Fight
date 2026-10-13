## career.gd - the player's career: seasons in a row, money, sponsors,
## trophies and the save file.
##
## Pure logic over plain JSON-shaped data (the whole career IS the save file -
## see serialize()). The season formats are season.gd; the money is
## data/economy.json; AI-vs-AI fights go to the fast resolver. The player's
## own fights are either fought in the arena (the fight scene hands the
## result back) or simulated with the resolver if they would rather not.
class_name Career

const CAREER_SCHEMA := "career/1"
# 2: the garage (the player's own robot and parts) - see garage.gd.
# 3: damage carries between fights (`wear`, garage.condition), the pit, the
#    crew, per-robot records and retired robots.
# 4: the living field - drivers age and retire, new teams join (field.gd),
#    AI memory (ailearn.gd), difficulty and the player's multibot.
# 5: rivalries - head-to-head records, grudge matches, call-outs (rivalry.gd).
# 6: loans and trading - bank loans, the paddock market, robots sold to AI
#    teams (market.gd).
const CAREER_VERSION := 6

const LEAGUE_TITLES := {"rookie": "Rookie", "pro": "Pro", "elite": "Elite", "world": "World Championship"}

static func league_name(lg) -> String:
	return LEAGUE_TITLES.get(lg, str(lg))

static func register_career_robots(reg: Registry, career) -> void:
	Field.register_career_robots(reg, career)

## A fresh career: the player in the bottom league with the starting cash.
##   o: { seed = 1, team = "Your Team", startingCash = null, difficulty = "medium" }
static func new_career(reg: Registry, o: Dictionary = {}) -> Dictionary:
	var field := reg.roster()
	var membership := {}
	for r in field: membership[r.id] = r.league
	# The player starts at the bottom, whatever their robot file says.
	membership[reg.playerId] = reg.league.leagues[0]
	var career := {
		"schema": CAREER_SCHEMA, "version": CAREER_VERSION,
		"seed": J.g(o, "seed", 1), "team": J.g(o, "team", "Your Team"),
		"playerId": reg.playerId,
		"cash": J.g(o, "startingCash", reg.economy.startingCash),
		"difficulty": J.g(o, "difficulty", "medium"),   # Settings -> Difficulty; the menus keep it in step
		"ledger": [],
		"sponsors": [],            # ids signed, league kind
		"perks": [],               # Giant Nut deals: { id, partsDiscount, until (season index) }
		"unlocks": [],
		"membership": membership,
		"seasonIndex": 0,
		"season": null,
		"history": [],
		"trophies": [],            # league titles
		"giantNutHistory": [],     # its own record and trophy case
		"evolution": {},           # every other robot's off-season changes (evolution.gd)
		"offseason": null,         # the last off-season's report
		"stats": {"fights": 0, "wins": 0, "losses": 0, "kos": 0, "koLosses": 0, "damageDealt": 0, "streak": 0, "bestStreak": 0, "fastestKoS": null, "mostDamage": 0},
		"wear": {},                # every AI robot's damage as it stands: id -> [per unit condition]
		"crew": {"size": null},    # pit crew (null = economy.json crew.base)
		"pit": null,               # the open pit after the player's last fight
		"lastFight": null,
		"notices": [],
		"garage": Garage.new_garage(reg),  # the player's robot and parts (garage.gd)
		"drivers": {},             # every AI robot's driver: name, career span, seasons driven (field.gd)
		"robotLife": {},           # and each robot's working life
		"newcomers": {},           # robots that joined the field during this career
		"retired": [],             # who has retired, and when
		"ai": {},                  # what every AI team has learned (ailearn.gd)
		"rivals": {},              # every robot's history against the player (rivalry.gd)
		"grudge": null,            # a booked grudge match: fought before the next fight
		"challenge": null,         # a rival's call-out, waiting for an answer
		"grudgeLog": [],           # grudge matches fought
		"loans": [],               # bank loans (market.gd)
		"tape": {},                # every robot's last fight, for the scouts (scouting.gd)
		"market": null,            # today's paddock market
		"robotSales": [],          # robots the player sold to AI teams
	}
	Field.seed_drivers(reg, career)
	_start_season(reg, career)
	return career

## What kind of season number `index` is: the cycle in data/league.json.
static func season_kind(reg: Registry, index) -> String:
	var cycle: Array = reg.league.cycle
	return cycle[(int(index) - 1) % cycle.size()]

## The league the player is in now.
static func player_league(career: Dictionary):
	return career.membership[career.playerId]

static func _sponsor(reg: Registry, id):
	for s in reg.economy.sponsors:
		if s.id == id: return s
	return null

static func _start_season(reg: Registry, career: Dictionary) -> void:
	career.seasonIndex += 1
	# Seeded by how good each driver is now (evolution and the field move them).
	var ratings := {}
	for id in career.membership:
		ratings[id] = reg.robot(id).get("rating") if id == career.playerId else fielded_def(reg, career, id).get("rating")
	career.season = Season.make_season(reg.league, {
		"index": career.seasonIndex, "kind": season_kind(reg, career.seasonIndex),
		"membership": career.membership, "ratings": ratings, "seed": career.seed,
	})
	# Sponsors pay their retainer at the start of every league season.
	if career.season.kind == "league":
		for id in career.sponsors:
			var sp = _sponsor(reg, id)
			if sp != null and J.truthy(sp.get("retainer")): Ledger.pay(career, sp.retainer, "%s retainer" % sp.name)
	career.perks = career.perks.filter(func(p): return p.until >= career.seasonIndex)
	# The banks take their payment, interest first (market.gd).
	for p in Market.service_loans(reg, career):
		if p.owed > 0:
			career.notices.append({"kind": "relegation", "text": "%s took a $%s loan payment. You still owe $%s." % [p.name, J.commas(p.payment), J.commas(p.owed)]})
		else:
			career.notices.append({"kind": "sponsor", "text": "%s: your loan is paid off." % p.name})

## The robot def a robot fights as this season: its latest version (the
## off-season's upgrades, evolution.gd) in whatever league it is in now.
static func fielded_def(reg: Registry, career: Dictionary, id) -> Dictionary:
	# The player fights whatever they built in the workshop.
	var out: Dictionary
	if id == career.playerId:
		out = Garage.player_def(reg, career)
	else:
		out = Evolution.evolved_def(reg, career, id).duplicate()
	out.league = J.g(career.membership, id, out.get("league"))
	# Every AI driver learns at the difficulty's rate (ailearn.gd, ai.gd).
	if id != career.playerId: out.learnRate = career_difficulty(reg, career).get("learnRate")
	return out

static func version_of(career: Dictionary, id) -> String:
	return Evolution.version_of(career, id)

## A seed for one fixture, the same every time the save is loaded.
static func fixture_seed(career: Dictionary, fixture: Dictionary) -> int:
	return Rng.hash_seed("%s:%s" % [J.s(career.seed), fixture.id]) & 0x7fffffff

## Resolve a fight with the fast resolver, compacted for the season record.
static func resolve_fixture(reg: Registry, career: Dictionary, a_id, b_id, fixture: Dictionary) -> Dictionary:
	# Both teams set their robots up for this opponent - from what they have
	# learned, without trial fights (ailearn.gd) - then fight, then learn.
	var da := fielded_def(reg, career, a_id)
	var db := fielded_def(reg, career, b_id)
	var pa := AILearn.prepare_for(reg, career, a_id, da, db, {"depth": 0, "salt": fixture.id})
	var pb := AILearn.prepare_for(reg, career, b_id, db, da, {"depth": 0, "salt": fixture.id})
	var r := Resolver.resolve_fight(reg, pa.def, pb.def, {
		"seed": fixture_seed(career, fixture), "conditionA": wear_of(reg, career, a_id), "conditionB": wear_of(reg, career, b_id),
	})
	for t in [[a_id, da, db], [b_id, db, da]]:
		AILearn.learn_from_fight(career, t[0], {"oppClass": Workshop.weapon_class_of(reg, t[2].build), "won": r.winnerId == t[0], "method": r.method, "cause": r.cause, "learnRate": J.g(t[1], "learnRate", 0.7)})
	for id in [a_id, b_id]: _after_fight(reg, career, id, r.sides[id].condition, fixture)
	var out := compact_result(r, {a_id: r.sides[a_id].damageScore, b_id: r.sides[b_id].damageScore}, "sim")
	# The tape the scouts keep: every robot's last fight (scouting.gd).
	Scouting.record_tape(reg, career, career.season, fixture, out)
	return out

## What the difficulty setting does, as the career stands.
static func career_difficulty(reg: Registry, career: Dictionary) -> Dictionary:
	var level = career.get("difficulty")
	if not J.truthy(level): level = "medium"
	var key := "difficulty:%s" % level
	var d = reg.cache_get(key)
	if d == null:
		d = Settings.difficulty_of(reg, level)
		reg.cache_set(key, d)
	return d

## The robot a team will meet next this season (the group draw is known), or null.
static func _next_opponent_of(career: Dictionary, id):
	for x in J.path(career, ["season", "fixtures"], []):
		if x.get("result") == null and (x.a == id or x.b == id):
			return x.b if x.a == id else x.a
	return null

## The damage a robot brings to its next fight: [per unit condition map], or null if fresh.
static func wear_of(reg: Registry, career: Dictionary, id):
	if id == career.playerId:
		var g := Garage.garage_of(reg, career)
		var c: Dictionary = J.g(g, "condition", {})
		var pc: Dictionary = J.g(g, "partnerCondition", {})
		if c.is_empty() and pc.is_empty(): return null
		return [c, pc] if g.get("partner") != null else [c]
	return J.path(career, ["wear", id])

## After a fight: an AI team's crew works through its pit window and the
## robot carries what is left into its next fight. The player's robot keeps
## its damage until the player's own pit (do_pit).
static func _after_fight(reg: Registry, career: Dictionary, id, conditions, fixture) -> void:
	if conditions == null: return
	if id == career.playerId:
		var g := Garage.garage_of(reg, career)
		g.condition = Pit.prune_fresh(conditions[0])
		if g.get("partner") != null: g.partnerCondition = Pit.prune_fresh(conditions[1] if conditions.size() > 1 else {})
		return
	if career.get("wear") == null: career.wear = {}
	# The crew fixes first what its next opponent will go for.
	var next = _next_opponent_of(career, id)
	var prefer = AILearn.pit_prefer(Workshop.weapon_class_of(reg, fielded_def(reg, career, next).build)) if next != null else null
	var left := Pit.ai_pit(reg, fielded_def(reg, career, id), conditions, Pit.pit_window(reg, fixture), prefer).map(func(c): return Pit.prune_fresh(c))
	if J.some(left, func(c): return not c.is_empty()): career.wear[id] = left
	else: career.wear.erase(id)

## What a season keeps of a fight.
static func compact_result(r: Dictionary, damage: Dictionary, by: String) -> Dictionary:
	return {
		"winnerId": r.winnerId, "loserId": r.get("loserId"), "method": r.get("method"), "cause": r.get("cause"),
		"elapsedS": J.rnd(J.g(r, "elapsedS", 0.0)), "decision": r.get("decision"), "votes": r.get("votes"),
		"damage": damage, "by": by,
	}

## Run the season on until the player has a fight to fight. When the season
## ends it is closed - prize money, movement, history - and the career waits
## for start_next_season(), so the end-of-season screen can be shown.
## Returns every fight resolved, in order.
static func advance_career(reg: Registry, career: Dictionary) -> Array:
	if career.season.done: return []
	var out_log := Season.advance(career.season, reg.league, {
		"resolve": func(a, b, f): return resolve_fixture(reg, career, a, b, f),
		"playerId": career.playerId,
	})
	if career.season.done:
		close_season(reg, career)
		career.seasonOver = true
	return out_log

## Robots the player sold (market.gd) join the field: each buying team races
## it from now on in place of its own robot - or, if that robot has gone
## since, in place of the weakest robot in the same league.
static func _deliver_sales(reg: Registry, career: Dictionary, report: Dictionary) -> void:
	for sale in career.get("robotSales", []):
		if sale.status != "pending": continue
		var old_id = sale.buyerId if career.membership.has(sale.buyerId) else null
		if old_id == null:
			var lg = reg.league.leagues[0]
			var ids := []
			for id in career.membership:
				if id != career.playerId and career.membership[id] == lg: ids.append(id)
			ids = J.sorted(ids, func(a, b):
				return float(J.path(career, ["evolution", a, "rating"], reg.robot(a).rating)) - float(J.path(career, ["evolution", b, "rating"], reg.robot(b).rating)))
			if ids.size() > 0: old_id = ids[0]
		if old_id == null: continue
		var team = reg.robot(old_id).get("team")
		var old_name: String = reg.robot(old_id).name
		var def := Field.adopt_robot(reg, career, old_id, sale.def, career.season, report, "replaced by %s, bought from you" % sale.def.name)
		report.newRobots.append({"id": def.id, "name": def.name, "team": team, "league": career.membership[def.id], "replaces": old_name, "replacesId": old_id, "formerPlayer": true})
		sale.status = "fielded"
		sale.newId = def.id
		sale.team = team
		career.notices.append({"kind": "rivalry", "text": "%s, the robot you sold, now races for %s in the %s league." % [def.name, team, league_name(career.membership[def.id])]})

## Open the next season once the player has seen how the last one ended.
##   progress: optional Callable(done, total) - the off-season is thousands of
##   trial fights.
static func start_next_season(reg: Registry, career: Dictionary, progress: Callable = Callable()) -> void:
	assert(career.season.done, "the season is still running")
	# The off-season: every other team works on its robot.
	var report := Evolution.evolve_field(reg, career, career.season, func(id): return fielded_def(reg, career, id), progress)
	career.offseason = report
	var rebuilt: Array = report.moves.filter(func(m): return J.some(m.notes, func(n): return n.begins_with("rebuilt")))
	var upgraded: Array = report.moves.filter(func(m): return J.some(m.notes, func(n): return not n.begins_with("driver") and not n.begins_with("rebuilt")))
	if report.moves.size() > 0:
		career.notices.append({"kind": "offseason", "text": "Off-season: %d teams upgraded their robots%s. See Results." % [upgraded.size(), ", %d rebuilt from scratch" % rebuilt.size() if rebuilt.size() > 0 else ""]})
	# The field moves on: drivers age and retire, robots are replaced, new
	# teams come up through Rookie, every league back to 30 (field.gd).
	var field_report := Field.age_field(reg, career, career.season)
	report.field = field_report
	var r := field_report
	if r.retiredDrivers.size() > 0 or r.newRobots.size() > 0:
		var bits := []
		if r.retiredDrivers.size() > 0:
			var first: Array = r.retiredDrivers.slice(0, 3).map(func(d): return "%s after %s seasons" % [d.name, J.num(d.years)])
			bits.append("%d driver%s retired (%s%s)" % [r.retiredDrivers.size(), "s" if r.retiredDrivers.size() > 1 else "", ", ".join(first), "..." if r.retiredDrivers.size() > 3 else ""])
		var new_teams: int = r.newRobots.filter(func(x): return J.truthy(x.get("newTeam"))).size()
		if new_teams > 0: bits.append("%d new team%s joined Rookie" % [new_teams, "s" if new_teams > 1 else ""])
		var replaced: int = r.newRobots.filter(func(x): return J.truthy(x.get("replaces"))).size()
		if replaced > 0: bits.append("%d robot%s replaced by new designs" % [replaced, "s" if replaced > 1 else ""])
		career.notices.append({"kind": "offseason", "text": "The field: %s." % "; ".join(bits)})
	# Robots the player sold join their new teams (market.gd).
	_deliver_sales(reg, career, field_report)
	# Feuds outlive robots: a team's new robot inherits the grudge (rivalry.gd).
	for c in Rivalry.carry_rivalries(reg, career, field_report, func(id): return reg.robot(id).name):
		career.notices.append({"kind": "rivalry", "text": "%s replaces %s - and its team has not forgotten you." % [c.name, c.from]})
	Rivalry.cool_rivalries(reg, career)
	_offseason_rebuild(reg, career)
	career.seasonOver = false
	_start_season(reg, career)

## The player's next fight, with the opponent's scouting card data.
static func next_fight(reg: Registry, career: Dictionary):
	# A booked grudge match comes first: it is fought before the next fixture.
	var grudge = null
	var g = career.get("grudge")
	if not J.truthy(career.get("seasonOver")) and g != null and career.membership.has(g.oppId):
		grudge = Rivalry.grudge_fixture(career, func(id): return career.membership[id])
	var f = grudge if grudge != null else Season.player_fixture(career.season, career.playerId)
	if f == null: return null
	var opp_id = f.b if f.a == career.playerId else f.a
	var prep := _opponent_prep(reg, career, f, opp_id)
	# A grudge match is staged in the bigger of the two robots' venues.
	var order: Array = reg.league.leagues
	var venue_league = order[maxi(order.find(player_league(career)), order.find(career.membership[opp_id]))] if grudge != null else player_league(career)
	var my_wear = wear_of(reg, career, career.playerId)
	return {
		"fixture": f, "oppId": opp_id, "opp": prep.def, "oppChanges": prep.changes, "seed": fixture_seed(career, f), "grudge": grudge != null,
		# Where: the league's venue (the Giant Nut's in a Giant Nut season) and
		# a hazard layout from its rotation, fixed by the fixture.
		"arena": Arenas.career_arena(reg, {"seasonKind": "league" if grudge != null else career.season.kind, "league": venue_league, "fixtureId": f.id}),
		# Both robots as they will turn up: whatever the pits did not fix.
		"myCondition": my_wear[0] if my_wear != null else {},
		"myPartnerCondition": my_wear[1] if (my_wear != null and my_wear.size() > 1) else null,
		"oppCondition": wear_of(reg, career, opp_id),
	}

## The player's opponent sets its robot up for the player: it TESTS its
## options in trial fights against the player's robot as it stands (damage
## and all) - how many is the difficulty - and drives with what it has
## learned against the player's weapon, at the difficulty's skill. Worked out
## once per fixture and kept (career.prep), and again if the player changes
## their robot or the difficulty.
static func _opponent_prep(reg: Registry, career: Dictionary, f: Dictionary, opp_id) -> Dictionary:
	var diff := career_difficulty(reg, career)
	var me := fielded_def(reg, career, career.playerId)
	var sig := "%s|%s|%d|%s|%s|%s" % [f.id, diff.level, Rivalry.level_of(reg, Rivalry.rival_of(career, opp_id)).level,
		JSON.stringify(me.build), JSON.stringify(me.get("body")), JSON.stringify(J.path(me, ["partner", "build"]))]
	if J.path(career, ["prep", "sig"]) == sig: return career.prep
	# A rival studies you harder, and its driver is fired up (rivalry.gd).
	var adapt_options: float = _z(diff.get("adaptOptions"))
	var rv := Rivalry.rival_prep(reg, career, opp_id, adapt_options != 0.0)
	var skill_bonus := J.rnd((_z(diff.get("skillBonus")) + rv.skill) * 1000.0) / 1000.0
	var base := fielded_def(reg, career, opp_id)
	base.skillBonus = skill_bonus
	var cond := {career.playerId: wear_of(reg, career, career.playerId), opp_id: wear_of(reg, career, opp_id)}
	var depth: int = int(minf(10.0, adapt_options + rv.extraOptions))
	var fights: float = _z(diff.get("adaptFights"))
	var p := AILearn.prepare_for(reg, career, opp_id, base, me, {"depth": depth, "fights": fights if fights != 0.0 else 12, "salt": f.id, "cond": cond, "explore": 0.0 if adapt_options != 0.0 else 0.15})
	var d: Dictionary = p.def.duplicate()
	d.skillBonus = skill_bonus
	career.prep = {"sig": sig, "fixtureId": f.id, "oppId": opp_id, "def": d, "changes": p.changes}
	return career.prep

static func _z(v) -> float:
	return 0.0 if v == null else float(v)

## Record the player's fight.
##   result  { winnerId, method, cause, elapsedS, decision, votes, damage: { id: n } }
##   condition  the player's fitting condition after the fight (a Dictionary,
##              or [main, partner] for a multibot); it stays on the robot
##              until the pit
##   opp_condition  the opponent's units' condition after it (the arena)
##   opp_learned    what the opponent's driver learned in the fight (the arena)
## Returns the fight summary the results screen shows.
static func apply_player_result(reg: Registry, career: Dictionary, fixture_id, result: Dictionary, condition = null, opp_condition = null, opp_learned = null) -> Dictionary:
	var nf = next_fight(reg, career)
	assert(nf != null and nf.fixture.id == fixture_id, "no pending fight %s" % str(fixture_id))
	var f: Dictionary = nf.fixture
	# A grudge match is outside the standings: it goes in the rivalry's book.
	var grudge: bool = f.stage == "grudge"
	if not grudge: Season.record_result(career.season, f, result)
	Scouting.record_tape(reg, career, career.season, f, result)
	# A call-out nobody answered lapses when the next fight is fought.
	career.challenge = null

	var me = career.playerId
	var won: bool = result.winnerId == me
	var ko: bool = result.get("method") == "ko" or result.get("method") == "tapout"
	var my_damage: float = J.path(result, ["damage", me], 0.0)
	var s: Dictionary = career.stats
	s.fights += 1
	if won: s.wins += 1
	else: s.losses += 1
	if won and ko: s.kos += 1
	if not won and ko: s.koLosses += 1
	s.damageDealt += my_damage
	# Records, for the Hall of Fame.
	s.streak = _z(s.get("streak")) + 1 if won else 0
	s.bestStreak = maxf(_z(s.get("bestStreak")), s.streak)
	if won and result.get("method") == "ko" and (s.get("fastestKoS") == null or result.elapsedS < s.fastestKoS): s.fastestKoS = result.elapsedS
	s.mostDamage = maxf(_z(s.get("mostDamage")), my_damage)
	var g := Garage.garage_of(reg, career)
	if g.get("record") == null: g.record = {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": career.seasonIndex}
	var rec: Dictionary = g.record
	rec.fights += 1
	if won: rec.wins += 1
	if won and ko: rec.kos += 1

	# The opponent remembers the fight (ailearn.gd).
	AILearn.learn_from_fight(career, nf.oppId, {
		"oppClass": Workshop.weapon_class_of(reg, fielded_def(reg, career, me).build), "won": not won, "method": result.get("method"), "cause": result.get("cause"),
		"learned": opp_learned, "learnRate": J.g(career_difficulty(reg, career), "learnRate", 0.7),
	})
	career.prep = null

	# Purses, scaled by the difficulty.
	var econ: Dictionary = reg.economy
	var gn: bool = career.season.kind == "giantNut" and not grudge
	var scale: float = J.g(career_difficulty(reg, career), "purse", 1.0)
	var order: Array = reg.league.leagues
	var opp_league = J.g(career.membership, nf.oppId, player_league(career))
	var bigger = order[maxi(order.find(player_league(career)), order.find(opp_league))]
	var base: Dictionary
	if grudge: base = Rivalry.grudge_purse(reg, career, nf.oppId, econ.league[bigger])
	elif gn: base = econ.giantNut
	else: base = econ.league[player_league(career)]
	var purse := {}
	for k in base:
		var v = base[k]
		purse[k] = J.rnd(v * scale) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else v
	var before: float = career.cash
	var ledger_start: int = career.ledger.size()
	# The promoters pay extra for a rivalry, as it stood coming in.
	var gate := 0.0 if grudge else Rivalry.rival_gate(reg, career, nf.oppId, purse.appearance)
	if grudge:
		Ledger.pay(career, purse.appearance, "Grudge match appearance fee")
		if won: Ledger.pay(career, purse.win, "Grudge match purse")
		if won and ko: Ledger.pay(career, purse.koBonus, "Knockout bonus")
	else:
		Ledger.pay(career, purse.appearance, "Giant Nut appearance fee" if gn else "Appearance fee")
		if gate != 0.0: Ledger.pay(career, gate, "%s gate bonus" % Rivalry.level_of(reg, Rivalry.rival_of(career, nf.oppId)).name)
		if won:
			var win_amount = purse.get("groupWin") if (gn and f.stage == "group") else (0 if gn else purse.get("win"))
			Ledger.pay(career, win_amount, "Giant Nut group win" if gn else "Win purse")
			if ko: Ledger.pay(career, purse.get("koBonus"), "Knockout bonus")
			if not gn:
				for id in career.sponsors:
					var sp = _sponsor(reg, id)
					if sp != null and J.truthy(sp.get("perWin")): Ledger.pay(career, sp.perWin, "%s win bonus" % sp.name)

	# The rivalry: another page in the book (rivalry.gd).
	var bracket = null
	if f.stage == "final":
		bracket = career.season.giantNut.bracket if f.league == "giantNut" else J.path(career.season, ["leagues", f.league, "finals"])
	var stage_name = null
	if bracket != null:
		stage_name = "%s%s" % ["Giant Nut " if f.league == "giantNut" else "%s " % league_name(f.league), Tournament.round_name(bracket, f.bracketRound).to_lower()]
	var meeting := Rivalry.record_meeting(reg, career, nf.oppId, {
		"won": won, "result": result, "fixture": f, "grudge": grudge,
		"titleFight": bracket != null and f.bracketRound == bracket.rounds.size() - 1,
		"stageName": stage_name,
		"eliminated": bracket != null,
		"myTier": order.find(player_league(career)), "oppTier": order.find(opp_league),
		"driver": J.path(career, ["drivers", nf.oppId, "name"]),
	})
	var opp_name: String = reg.robot(nf.oppId).name
	if meeting.levelUp != null:
		var lv: int = Rivalry.level_of(reg, meeting.entry).level
		var txt: String
		if lv == 1: txt = "A rivalry is born: you and %s." % opp_name
		elif lv == 2: txt = "It is getting bitter between you and %s." % opp_name
		else: txt = "%s is your nemesis now." % opp_name
		career.notices.append({"kind": "rivalry", "text": txt})
	if grudge:
		if career.get("grudgeLog") == null: career.grudgeLog = []
		career.grudgeLog.append({"season": career.seasonIndex, "oppId": nf.oppId, "asked": J.path(career, ["grudge", "asked"]), "won": won, "method": result.get("method")})
		career.grudge = null
	# Beat a rival and it may call you out.
	if won: Rivalry.maybe_call_out(reg, career, nf.oppId, fixture_id, func(id): return reg.robot(id).name)

	# The damage stays on the robot: the pit is where it gets fixed.
	# A multibot reports both units: [main, partner].
	if condition != null:
		var mc = condition[0] if condition is Array else condition
		var pcd = (condition[1] if condition.size() > 1 else null) if condition is Array else null
		g.condition = Pit.prune_fresh(mc)
		if g.get("partner") != null and pcd != null: g.partnerCondition = Pit.prune_fresh(pcd)
	if opp_condition != null: _after_fight(reg, career, nf.oppId, opp_condition, f)
	var repair := repair_cost(reg, career, g.get("condition"), g.get("partnerCondition") if g.get("partner") != null else null)
	career.pit = {"fixtureId": fixture_id, "stage": f.stage, "league": f.get("league"), "window": Pit.pit_window(reg, f)}

	career.lastFight = {
		"season": career.seasonIndex, "fixtureId": fixture_id, "oppId": nf.oppId, "stage": f.stage, "league": f.get("league"), "grudge": grudge,
		"rivalry": {"gain": meeting.gain, "levelUp": meeting.levelUp, "level": Rivalry.level_of(reg, meeting.entry).level},
		"result": result, "won": won, "earned": career.cash - before, "repair": repair, "net": career.cash - before,
		"lines": career.ledger.slice(ledger_start),
	}
	_check_sponsors(reg, career)
	return career.lastFight

## Simulate the player's fight with the resolver (the "let the AI fight it" button).
static func simulate_player_fight(reg: Registry, career: Dictionary):
	var nf = next_fight(reg, career)
	if nf == null: return null
	var f: Dictionary = nf.fixture
	# The opponent as it set itself up for you (next_fight), at the difficulty.
	var defs := {career.playerId: fielded_def(reg, career, career.playerId), nf.oppId: nf.opp}
	var r := Resolver.resolve_fight(reg, defs[f.a], defs[f.b], {
		"seed": nf.seed, "conditionA": wear_of(reg, career, f.a), "conditionB": wear_of(reg, career, f.b),
	})
	var result := compact_result(r, {f.a: r.sides[f.a].damageScore, f.b: r.sides[f.b].damageScore}, "sim")
	var mine: Array = r.sides[career.playerId].condition
	return apply_player_result(reg, career, f.id, result, mine, r.sides[nf.oppId].condition)

## What it would cost to put this damage right in full, after any parts
## discount (an estimate: the pit decides).
static func repair_cost(reg: Registry, career: Dictionary, condition, partner_condition = null) -> Dictionary:
	var c_empty: bool = condition == null
	var p_empty: bool = partner_condition == null
	if c_empty and p_empty: return {"total": 0, "lines": []}
	var def := Garage.player_def(reg, career)
	var a := Build.assemble_robot(reg, def)
	if condition is Dictionary:
		for k in condition: a.condition[k] = condition[k]
	var lines := []
	for r in Condition.condition_report(a, reg.rules):
		if r.repairCost > 0: lines.append({"key": r.key, "name": r.name, "condition": r.condition, "cost": r.repairCost})
	if def.get("partner") != null and partner_condition is Dictionary:
		var p = Build.assemble_partner(reg, def)
		for k in partner_condition: p.condition[k] = partner_condition[k]
		for r in Condition.condition_report(p, reg.rules):
			if r.repairCost > 0: lines.append({"key": "p.%s" % r.key, "name": "%s: %s" % [def.partner.name, r.name], "condition": r.condition, "cost": r.repairCost})
	var discount := parts_discount(reg, career)
	var bill := 0.0
	for l in lines: bill += l.cost
	var gross: float = bill * J.path(reg.economy, ["repairs", "labourMultiplier"], 1.0)
	return {"lines": lines, "gross": J.rnd(gross), "discount": discount, "total": J.rnd(gross * (1.0 - discount))}

## The best parts discount the player has right now (sponsors and Giant Nut deals).
static func parts_discount(reg: Registry, career: Dictionary) -> float:
	return Garage.discount_of(reg, career)

## Does the player meet a league sponsor's terms? Terms are per season - wins
## and KOs this season, and the league the player is in - so a sponsor can be
## won and lost again.
static func _meets_terms(reg: Registry, career: Dictionary, sp: Dictionary, league = null) -> bool:
	if league == null: league = player_league(career)
	var order: Array = reg.league.leagues
	var q: Dictionary = J.g(sp, "requires", {})
	var rec := record_of(career.season, career.playerId)
	return (q.get("wins") == null or rec.wins >= q.wins) \
		and (q.get("kos") == null or rec.kos >= q.kos) \
		and (q.get("league") == null or order.find(league) >= order.find(q.league))

## Sign any league sponsor whose terms the player now meets.
static func _check_sponsors(reg: Registry, career: Dictionary) -> void:
	if career.season.kind != "league": return
	for sp in reg.economy.sponsors:
		if sp.kind != "league" or career.sponsors.has(sp.id): continue
		if _meets_terms(reg, career, sp):
			career.sponsors.append(sp.id)
			career.notices.append({"kind": "sponsor", "text": "%s signs on: $%s a season%s." % [sp.name, J.commas(sp.retainer), ", $%s a win" % J.commas(sp.perWin) if J.truthy(sp.get("perWin")) else ""]})

## At the end of a league season, sponsors whose terms were not met walk.
static func _review_sponsors(reg: Registry, career: Dictionary, next_league) -> void:
	var kept := []
	for id in career.sponsors:
		var sp = _sponsor(reg, id)
		if sp == null: continue
		# A sponsor signed for reaching a league stays while you are in it;
		# one signed for results wants them again this season.
		if _meets_terms(reg, career, sp, next_league): kept.append(id)
		else: career.notices.append({"kind": "relegation", "text": "%s did not renew your sponsorship." % sp.name})
	career.sponsors = kept

## Close a finished season: prize money, trophies, movement, history.
static func close_season(reg: Registry, career: Dictionary) -> void:
	var s: Dictionary = career.season
	var me = career.playerId
	var econ: Dictionary = reg.economy
	var fin := Season.robot_finish(s, me)
	var entry := {"season": s.index, "kind": s.kind, "cashBefore": null}

	if s.kind == "league":
		var lg = player_league(career)
		var l: Dictionary = s.leagues[lg]
		var pos: int = l.ranking.find(me) + 1
		var purse: Dictionary = econ.league[lg]
		if fin.stage == "final":
			Ledger.pay(career, purse.finals[mini(int(fin.finish), purse.finals.size() - 1)], "League champion!" if fin.finish >= fin.rounds else "Finals prize money")
		var up: bool = l.movement.promoted.has(me)
		var down: bool = l.movement.relegated.has(me)
		if up: Ledger.pay(career, purse.promotionBonus, "Promotion bonus")
		if l.get("champion") == me:
			var g := Garage.garage_of(reg, career)
			career.trophies.append({"season": s.index, "league": lg, "title": "%s Champion" % league_name(lg), "robot": g.name})
			if g.get("record") != null: g.record.titles += 1
		var champions := {}
		for k in s.leagues: champions[k] = s.leagues[k].get("champion")
		entry.league = lg
		entry.position = pos
		entry.finish = fin
		entry.promoted = up
		entry.relegated = down
		entry.champions = champions
		entry.record = record_of(s, me)
		_check_sponsors(reg, career)
		var next_m := Season.next_membership(s, career.membership, reg.league)
		_review_sponsors(reg, career, next_m[me])
		career.membership = next_m
		entry.nextLeague = player_league(career)
		if up: career.notices.append({"kind": "promotion", "text": "Promoted to the %s league!" % league_name(entry.nextLeague)})
		if down: career.notices.append({"kind": "relegation", "text": "Relegated to the %s league." % league_name(entry.nextLeague)})
	else:
		var gn: Dictionary = s.giantNut
		var g: Dictionary = econ.giantNut
		var idx: int = int(fin.finish) + 1 if fin.stage == "final" else 0
		if gn.get("champion") == me: Ledger.pay(career, g.champion, "GIANT NUT CHAMPION!")
		else: Ledger.pay(career, g.rounds[mini(idx, g.rounds.size() - 1)], "Giant Nut bracket prize" if fin.stage == "final" else "Giant Nut participation")
		# Giant Nut sponsors: deals for how far the player got.
		var reached := idx
		for sp in econ.sponsors:
			if sp.kind != "giantNut": continue
			if reached >= J.path(sp, ["requires", "giantNutRound"], 99):
				Ledger.pay(career, sp.get("bonus"), "%s Giant Nut deal" % sp.name)
				if J.truthy(sp.get("partsDiscount")): career.perks.append({"id": sp.id, "partsDiscount": sp.partsDiscount, "until": s.index + 1})
				if J.truthy(sp.get("unlock")) and not career.unlocks.has(sp.unlock): career.unlocks.append(sp.unlock)
				career.notices.append({"kind": "sponsor", "text": "%s: %s" % [sp.name, sp.get("blurb")]})
		var rec := {"season": s.index, "champion": gn.get("champion"), "finish": fin, "record": record_of(s, me), "position": gn.ranking.find(me) + 1}
		career.giantNutHistory.append(rec)
		entry.merge(rec, true)
	career.history.append(entry)
	if career.notices.size() > 20: career.notices = career.notices.slice(career.notices.size() - 20)

## A robot's record in a season: { wins, losses, kos }.
static func record_of(season: Dictionary, id) -> Dictionary:
	var fights := 0
	var wins := 0
	var kos := 0
	var all: Array = season.fixtures + season.get("finalsLog", [])
	for f in all:
		var r = f.get("result")
		if r == null or not (f.a == id or f.b == id): continue
		fights += 1
		if r.winnerId == id:
			wins += 1
			if r.get("method") == "ko" or r.get("method") == "tapout": kos += 1
	return {"wins": wins, "losses": fights - wins, "kos": kos}

## The player's group table this season.
static func player_group(career: Dictionary):
	var s: Dictionary = career.season
	var me = career.playerId
	var comp = player_league(career) if s.kind == "league" else "giantNut"
	var groups: Array = s.leagues[comp].groups if s.kind == "league" else s.giantNut.groups
	for g in groups:
		if g.ids.has(me): return {"comp": comp, "name": g.name, "rows": Season.group_tables(s)[comp][g.name]}
	return null

# ---------------------------------------------------------------- the pit

## The pit crew: base size from economy.json, plus whoever the player has hired.
static func crew_config(reg: Registry) -> Dictionary:
	return J.merge({"base": 2, "max": 6, "hireFee": [2500, 4000, 6500, 9500], "salaryPerSeason": 1800}, J.g(reg.economy, "crew", {}))

static func crew_size(reg: Registry, career: Dictionary) -> int:
	return int(J.path(career, ["crew", "size"], crew_config(reg).base))

## Hire one more crew member: a signing fee now, a salary every season.
static func hire_crew(reg: Registry, career: Dictionary) -> Dictionary:
	var cfg := crew_config(reg)
	var n := crew_size(reg, career)
	if n >= cfg.max: return {"ok": false, "reason": "The pit is full - that is the biggest crew allowed."}
	var fee: float = cfg.hireFee[mini(cfg.hireFee.size() - 1, n - int(cfg.base))]
	if career.cash < fee: return {"ok": false, "reason": "Signing a crew member costs $%s." % J.commas(fee)}
	Ledger.pay(career, -fee, "Signed a pit crew member")
	var crew: Dictionary = J.g(career, "crew", {}).duplicate()
	crew.size = n + 1
	career.crew = crew
	return {"ok": true, "fee": fee}

## Let one crew member go (no refund; it saves the salary).
static func release_crew(reg: Registry, career: Dictionary) -> Dictionary:
	var n := crew_size(reg, career)
	if n <= crew_config(reg).base: return {"ok": false}
	var crew: Dictionary = J.g(career, "crew", {}).duplicate()
	crew.size = n - 1
	career.crew = crew
	return {"ok": true}

## Pricing for the player's pit: their spares, the shop's prices, their discount.
static func _pit_ctx(reg: Registry, career: Dictionary) -> Dictionary:
	return {"spares": Garage.spares(reg, career), "price": func(id): return Garage.price_of(reg, career, id), "discount": Garage.discount_of(reg, career)}

## The pit as it stands: the robot's damage and every way of fixing it, the
## window (minutes until the next fight) and the crew-minutes it gives.
static func pit_state(reg: Registry, career: Dictionary) -> Dictionary:
	var units := _player_units(reg, career)
	var window: float = J.path(career, ["pit", "window"], Pit.pit_window(reg, null))
	var crew := crew_size(reg, career)
	var ctx := _pit_ctx(reg, career)
	# A multibot's second unit's parts are keyed "p.<fitting>".
	var report := []
	for u in units:
		for r in Pit.pit_report(reg, u.a, ctx):
			var o: Dictionary = r.duplicate()
			o.key = u.prefix + r.key
			o.unit = u.name if u.prefix != "" else null
			report.append(o)
	return {"open": career.get("pit") != null, "window": window, "crew": crew, "crewMinutes": INF, "assembled": units[0].a, "units": units, "report": report}

## The player's units with their damage: [{ prefix, a, name }] (one, or two for a multibot).
static func _player_units(reg: Registry, career: Dictionary) -> Array:
	var g := Garage.garage_of(reg, career)
	var def := Garage.player_def(reg, career)
	var main := Build.assemble_robot(reg, def)
	var gc: Dictionary = J.g(g, "condition", {})
	for k in gc: main.condition[k] = gc[k]
	var units := [{"prefix": "", "a": main, "name": g.name}]
	if def.get("partner") != null:
		var p = Build.assemble_partner(reg, def)
		var pc: Dictionary = J.g(g, "partnerCondition", {})
		for k in pc: p.condition[k] = pc[k]
		units.append({"prefix": "p.", "a": p, "name": def.partner.name})
	return units

## Plan totals across both units, the spares shared between them.
static func _unit_totals(reg: Registry, career: Dictionary, plan: Dictionary) -> Dictionary:
	var units := _player_units(reg, career)
	var ctx := _pit_ctx(reg, career)
	var spares: Dictionary = ctx.spares.duplicate()
	var out := {"cost": 0.0, "salvage": 0.0, "minutes": 0.0, "condition": {}, "partnerCondition": {}, "replaced": [], "sparesUsed": {}, "bought": {}, "lines": []}
	for u in units:
		var prefix: String = u.prefix
		var sub := {}
		for k in plan:
			if prefix != "":
				if k.begins_with(prefix): sub[k.substr(prefix.length())] = plan[k]
			elif not k.begins_with("p."): sub[k] = plan[k]
		var uctx := ctx.duplicate()
		uctx.spares = spares
		var t := Pit.plan_totals(reg, u.a, sub, uctx)
		out.cost += t.cost
		out.salvage += t.salvage
		out.minutes += t.minutes
		if prefix != "": out.partnerCondition = t.condition
		else: out.condition = t.condition
		out.replaced.append_array(t.replaced)
		for id in t.sparesUsed:
			out.sparesUsed[id] = out.sparesUsed.get(id, 0) + t.sparesUsed[id]
			spares[id] = spares.get(id, 0) - t.sparesUsed[id]
		for id in t.bought: out.bought[id] = out.bought.get(id, 0) + t.bought[id]
		for l in t.lines:
			var nl: Dictionary = l.duplicate()
			nl.key = prefix + l.key
			nl.name = "%s: %s" % [u.name, l.name] if prefix != "" else l.name
			out.lines.append(nl)
	out.net = out.cost - out.salvage
	return out

## What a plan ({ fittingKey: "patch" | "repair" | "replace" }) would come to,
## and whether it is allowed.
static func pit_quote(reg: Registry, career: Dictionary, plan: Dictionary) -> Dictionary:
	var st := pit_state(reg, career)
	var t := _unit_totals(reg, career, plan)
	var problems := []
	if t.cost > career.cash: problems.append("That costs $%s; you have $%s." % [J.commas(t.cost), J.commas(J.rnd(career.cash))])
	t.crewMinutes = st.crewMinutes
	t.problems = problems
	t.ok = problems.size() == 0
	return t

## The crew's own best plan for the time and money there is.
static func pit_auto_plan(reg: Registry, career: Dictionary) -> Dictionary:
	var st := pit_state(reg, career)
	var ctx := _pit_ctx(reg, career)
	# The main unit first, then the second with whatever time and money is left.
	var plan := {}
	var minutes: float = st.crewMinutes
	var cash: float = maxf(0.0, career.cash)
	for u in st.units:
		var p := Pit.auto_plan(reg, u.a, {"crewMinutes": minutes, "cash": cash, "ctx": ctx})
		var t := Pit.plan_totals(reg, u.a, p, ctx)
		minutes -= t.minutes
		cash -= t.cost
		for k in p: plan[u.prefix + k] = p[k]
	return plan

## Do the work and send the robot out: pay for it, take the salvage, swap in
## spares or new parts, and close the pit. Anything not in the plan stays
## broken for the next fight.
static func do_pit(reg: Registry, career: Dictionary, plan: Dictionary) -> Dictionary:
	var q := pit_quote(reg, career, plan)
	if not q.ok: return {"ok": false, "errors": q.problems}
	var g := Garage.garage_of(reg, career)
	var repair_lines: Array = q.lines.filter(func(l): return l.how != "replace")
	var repairs := 0.0
	for l in repair_lines: repairs += l.cost
	if repairs != 0.0: Ledger.pay(career, -repairs, "Pit: %d repair%s" % [repair_lines.size(), "s" if q.lines.size() > 1 else ""])
	for id in q.bought:
		var n: float = q.bought[id]
		Ledger.pay(career, -Garage.price_of(reg, career, id) * n, "Pit: new %s%s" % [reg.part(id).name, " x%s" % J.num(n) if n > 1 else ""])
	# A replacement uses a spare if there is one; either way the old part is scrapped.
	for id in q.sparesUsed: g.owned[id] = maxf(0.0, g.owned.get(id, 0) - q.sparesUsed[id])
	if q.salvage != 0.0: Ledger.pay(career, q.salvage, "Pit: scrap salvage")
	g.condition = Pit.prune_fresh(q.condition)
	if g.get("partner") != null: g.partnerCondition = Pit.prune_fresh(q.partnerCondition)
	career.pit = null
	q.ok = true
	return q

## Close the pit without doing anything (the damage goes into the next fight).
static func skip_pit(career: Dictionary) -> void:
	career.pit = null

## Between seasons everyone rebuilds: AI robots come back fresh, and the
## player's damage is put right at the off-season rate (no pit clock, no
## overtime). Crew salaries are paid.
static func _offseason_rebuild(reg: Registry, career: Dictionary) -> void:
	var g := Garage.garage_of(reg, career)
	var est := repair_cost(reg, career, g.get("condition"), g.get("partnerCondition") if g.get("partner") != null else null)
	var rate: float = Pit.pit_config(reg).offseasonRepairRate
	if est.total > 0: Ledger.pay(career, -J.rnd(est.total * rate), "Off-season rebuild")
	g.condition = {}
	g.partnerCondition = {}
	career.wear = {}
	career.pit = null

# ---------------------------------------------------------------- retirement

## Retire the robot: its name, versions and record go to the garage's museum,
## and a new robot (version 1.0, under `new_name`) starts from the same parts.
static func retire_robot(reg: Registry, career: Dictionary, new_name) -> Dictionary:
	var g := Garage.garage_of(reg, career)
	var rec: Dictionary = J.g(g, "record", {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": career.seasonIndex})
	if g.get("museum") == null: g.museum = []
	var piece := {"name": g.name, "version": g.get("version"), "from": rec.get("since"), "to": career.seasonIndex}
	piece.merge(rec, true)
	piece.weapon = reg.part(g.build.weapon).name if J.truthy(g.build.get("weapon")) else "None"
	piece.livery = g.get("livery")
	g.museum.append(piece)
	var nm := str(new_name if new_name != null else "").strip_edges().substr(0, 28)
	g.name = nm if nm != "" else "%s II" % g.name
	g.version = "1.0"
	g.log = []
	g.record = {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": career.seasonIndex}
	return piece

# ---------------------------------------------------------------- the save file

## The career as a save string. Versioned: deserialize() migrates old saves.
static func serialize(career: Dictionary) -> String:
	return J.to_json(career)

## A career from a save string, migrated to the current version.
## Returns { ok, career, error }.
static func deserialize(text: String) -> Dictionary:
	return from_data(J.parse_json(text))

## The same, from already-parsed data.
static func from_data(c) -> Dictionary:
	if not (c is Dictionary) or c.get("schema") != CAREER_SCHEMA: return {"ok": false, "career": null, "error": "not a ROBO LEAGUE career save"}
	if c.get("version", 1) > CAREER_VERSION: return {"ok": false, "career": null, "error": "this save is from a newer version (%s)" % J.num(c.version)}
	# Migrations, oldest first.
	# 2: the garage. garage_of() makes it on first use.
	if c.get("version", 1) < 2:
		c.garage = null
		c.version = 2
	# 3: damage carries over; from here on the career starts every robot fresh.
	if c.version < 3:
		c.wear = {}
		c.crew = {"size": null}
		c.pit = null
		var st := {"streak": 0, "bestStreak": 0, "fastestKoS": null, "mostDamage": 0}
		st.merge(c.get("stats", {}), true)
		c.stats = st
		c.version = 3
	# 4: the living field. Drivers are seeded on the next off-season.
	if c.version < 4:
		for k in ["drivers", "robotLife", "newcomers", "ai"]:
			if c.get(k) == null: c[k] = {}
		if c.get("retired") == null: c.retired = []
		if not J.truthy(c.get("difficulty")): c.difficulty = "medium"
		c.version = 4
	# 5: rivalries. The history starts from here.
	if c.version < 5:
		if c.get("rivals") == null: c.rivals = {}
		if not c.has("grudge"): c.grudge = null
		if not c.has("challenge"): c.challenge = null
		if c.get("grudgeLog") == null: c.grudgeLog = []
		c.version = 5
	# 6: loans and trading. Nothing owed, nothing sold yet.
	if c.version < 6:
		if c.get("loans") == null: c.loans = []
		c.market = null
		if c.get("robotSales") == null: c.robotSales = []
		if c.get("tape") == null: c.tape = {}
		c.version = 6
	for k in ["notices", "perks", "unlocks"]:
		if c.get(k) == null: c[k] = []
	if c.get("evolution") == null: c.evolution = {}
	return {"ok": true, "career": c, "error": ""}

## A short, stable random draw for UI flavour that must not touch game seeds.
static func flavour_rng(career: Dictionary, tag) -> Rng:
	return Rng.new(Rng.hash_seed("%s:flavour:%s" % [J.s(career.seed), J.s(tag)]))
