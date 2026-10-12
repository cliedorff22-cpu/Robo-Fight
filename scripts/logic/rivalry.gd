## rivalry.gd - robots with a history against you.
##
## Every robot the player has fought keeps a head-to-head record against them
## (career.rivals[id]), and every meeting adds HEAT: more for a knockout, a
## split decision, a playoff fight, a title fight, revenge, an upset or a
## grudge match. Heat cools between seasons. Enough of it and the two robots
## have a rivalry; more and it is bitter; the most of all and it is your
## nemesis.
##
## What a rivalry does: the scouting card and the commentary tell the story so
## far (storyline); a rival studies you harder and its driver is fired up
## (rival_prep); the promoters pay a gate bonus (rival_gate); and GRUDGE
## MATCHES - a rematch you demand, or a rival calling you out - are fought
## before your next fight, outside the standings, for their own purse.
##
## Pure logic over the career; numbers in data/league.json `rivalry`.
class_name Rivalry

const LEVEL_NAMES := ["", "Rivalry", "Bitter rivalry", "Nemesis"]

static func rivalry_config(reg: Registry) -> Dictionary:
	var cached = reg.cache_get("rivalryCfg")
	if cached != null: return cached
	var r: Dictionary = J.g(reg.league, "rivalry", {})
	var cfg := J.merge({
		"levels": [3, 6, 10],              # heat for rivalry, bitter, nemesis
		"decay": 0.6,                      # heat kept from one season to the next
		"heat": {"meet": 1, "ko": 1, "split": 1, "playoff": 1, "titleFight": 2, "revenge": 1, "streak": 1, "upset": 1, "giantNut": 0.5, "grudge": 1.5, "ducked": 1, "refused": 0.5},
		"upsetTiers": 1,                   # leagues apart that make the win an upset
		"prepOptions": 1,                  # extra setups a rival tests against you, per level
		"skillPerLevel": 0.02,             # its driver, fired up
		"gatePerLevel": 0.25,              # gate bonus: this much of the appearance fee per level
		"grudge": {"appearanceX": 2, "winX": 1.5, "koX": 1, "perLevel": 0.25, "maxPerSeason": 2},
		"accept": {"base": 0.3, "theyLost": 0.4, "perLevel": 0.12},
		"callOut": {"base": 0.25, "perLevel": 0.15},
		"moments": 8,
	}, r)
	reg.cache_set("rivalryCfg", cfg)
	return cfg

# ---------------------------------------------------------------- the record

## A robot's history against the player, or null if they have never met.
static func rival_of(career: Dictionary, id):
	return J.path(career, ["rivals", id])

## How hot a rivalry is: { level 0..3, name }. Level 0 with fights is just history.
static func level_of(reg: Registry, entry) -> Dictionary:
	if entry == null: return {"level": 0, "name": ""}
	var lv: Array = rivalry_config(reg).levels
	var level := 0
	if entry.heat >= lv[2]: level = 3
	elif entry.heat >= lv[1]: level = 2
	elif entry.heat >= lv[0]: level = 1
	return {"level": level, "name": LEVEL_NAMES[level]}

static func _blank(career: Dictionary) -> Dictionary:
	return {"fights": 0, "w": 0, "l": 0, "koFor": 0, "koAgainst": 0, "grudges": 0, "heat": 0.0, "first": career.seasonIndex, "last": null, "streak": 0, "moments": [], "peak": 0.0}

static func _round1(x: float) -> float: return J.rnd(x * 10.0) / 10.0
static func _round3(x: float) -> float: return J.rnd(x * 1000.0) / 1000.0
static func _z(v) -> float: return 0.0 if v == null else float(v)

static func _entry(career: Dictionary, opp_id) -> Dictionary:
	if career.get("rivals") == null: career.rivals = {}
	if career.rivals.get(opp_id) == null: career.rivals[opp_id] = _blank(career)
	return career.rivals[opp_id]

## One meeting between the player and `opp_id`, from the player's side.
##   m { won, result, fixture, grudge, titleFight, myTier, oppTier, stageName, eliminated, driver }
## Returns { gain, entry, levelUp } - levelUp is the new level's name if it rose.
static func record_meeting(reg: Registry, career: Dictionary, opp_id, m: Dictionary) -> Dictionary:
	var cfg := rivalry_config(reg)
	var e := _entry(career, opp_id)
	var before: int = level_of(reg, e).level
	var r: Dictionary = J.g(m, "result", {})
	var won: bool = J.truthy(m.get("won"))
	var is_grudge: bool = J.truthy(m.get("grudge"))
	var ko: bool = r.get("method") == "ko" or r.get("method") == "tapout"
	var split: bool = r.get("decision") == "split"
	var stage = J.path(m, ["fixture", "stage"])
	var league = J.path(m, ["fixture", "league"])
	var h: Dictionary = cfg.heat
	var gain: float = h.meet
	if ko: gain += h.ko
	if r.get("method") == "decision" and split: gain += h.split
	if stage == "final":
		gain += h.playoff
		if J.truthy(m.get("titleFight")): gain += h.titleFight
	if league == "giantNut": gain += h.giantNut
	if is_grudge: gain += h.grudge
	# Revenge: the loser last time won this one.
	var last = e.get("last")
	var revenge: bool = last != null and J.truthy(last.get("won")) != won
	if revenge: gain += h.revenge
	# The same side winning again and again.
	var streak: float = (_nz(e.get("streak"), 1) + 1) if (last != null and J.truthy(last.get("won")) == won) else 1.0
	if streak >= 3: gain += h.streak
	# An upset: a robot from a lower league beat one from a higher. `tier` is
	# the league's place in the order, bottom 0.
	var gap: float = _z(m.get("oppTier")) - _z(m.get("myTier"))
	var upset: bool = (won and gap >= cfg.upsetTiers) or (not won and -gap >= cfg.upsetTiers)
	if upset: gain += h.upset

	e.fights += 1
	if won: e.w += 1
	else: e.l += 1
	if ko and won: e.koFor += 1
	if ko and not won: e.koAgainst += 1
	if is_grudge: e.grudges += 1
	e.heat = _round1(e.heat + gain)
	e.peak = maxf(_z(e.get("peak")), e.heat)
	e.streak = streak
	e.last = {
		"season": career.seasonIndex, "won": won, "method": r.get("method"), "cause": r.get("cause"), "decision": r.get("decision"),
		"elapsedS": J.rnd(J.g(r, "elapsedS", 0.0)), "stage": stage, "league": league,
		"stageName": m.get("stageName") if J.truthy(m.get("stageName")) else null, "grudge": is_grudge,
		"driver": m.get("driver") if J.truthy(m.get("driver")) else null, "eliminated": J.truthy(m.get("eliminated")),
	}
	# The memorable ones go in the book.
	var big: bool = ko or stage == "final" or is_grudge or upset or revenge or split
	if big:
		var cause_txt := " (%s)" % r.cause if J.truthy(r.get("cause")) else ""
		var how: String
		if ko: how = ("you knocked them out" if won else "they knocked you out") + cause_txt
		else: how = "%s on %s" % ["you won" if won else "they won", "a split decision" if split else "the judges' decision"]
		var where: String
		if is_grudge: where = "the grudge match"
		elif J.truthy(m.get("stageName")): where = m.stageName
		else: where = "the playoffs" if stage == "final" else "the group stage"
		_add_moment(cfg, e, career, "%s in %s%s." % [J.cap(how), where, " - an upset" if upset else (" - revenge" if revenge else "")])
	var after := level_of(reg, e)
	return {"gain": gain, "entry": e, "levelUp": after.name if after.level > before else null}

static func _nz(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if f == 0.0 else f

static func _add_moment(cfg: Dictionary, e: Dictionary, career: Dictionary, text: String) -> void:
	e.moments.append({"season": career.seasonIndex, "text": text})
	if e.moments.size() > cfg.moments: e.moments = e.moments.slice(e.moments.size() - int(cfg.moments))

## Heat for something that happened off the floor (a refused rematch, a ducked call-out).
static func add_heat(reg: Registry, career: Dictionary, opp_id, kind: String, text = null):
	var cfg := rivalry_config(reg)
	var e := _entry(career, opp_id)
	var before: int = level_of(reg, e).level
	e.heat = _round1(e.heat + _z(cfg.heat.get(kind)))
	e.peak = maxf(_z(e.get("peak")), e.heat)
	if J.truthy(text): _add_moment(cfg, e, career, text)
	var after := level_of(reg, e)
	return after.name if after.level > before else null

## A new season: every rivalry cools off a little.
static func cool_rivalries(reg: Registry, career: Dictionary) -> void:
	var k: float = rivalry_config(reg).decay
	for e in career.get("rivals", {}).values(): e.heat = _round1(e.heat * k)

## The off-season moved the field on (field.gd report): a robot replaced by
## its team's new one hands the feud on, cooler; a robot whose team folded
## leaves its record in the book, retired. A grudge match booked against a
## robot that is gone is off.
static func carry_rivalries(reg: Registry, career: Dictionary, report, name_of: Callable = Callable()) -> Array:
	if career.get("rivals") == null: career.rivals = {}
	var rv: Dictionary = career.rivals
	var out := []
	if report == null: report = {}
	for nr in report.get("newRobots", []):
		var rid = nr.get("replacesId")
		if not J.truthy(rid) or rv.get(rid) == null: continue
		var old: Dictionary = rv[rid]
		if J.truthy(old.get("retired")): continue
		if level_of(reg, old).level >= 1:
			var ne := _blank(career)
			ne.heat = _round1(old.heat * 0.5)
			ne.carried = {"fromId": rid, "from": nr.get("replaces"), "w": old.w, "l": old.l}
			rv[nr.id] = ne
			_add_moment(rivalry_config(reg), ne, career, "%s built it to replace %s (%s-%s against you)." % [nr.get("team"), nr.get("replaces"), J.num(old.w), J.num(old.l)])
			out.append({"id": nr.id, "name": nr.name, "from": nr.get("replaces")})
		old.retired = career.seasonIndex
	for r in report.get("retiredRobots", []):
		if rv.get(r.id) != null and not J.truthy(rv[r.id].get("retired")): rv[r.id].retired = career.seasonIndex
	var g = career.get("grudge")
	if g != null and not career.membership.has(g.oppId):
		career.notices.append({"kind": "relegation", "text": "The grudge match with %s is off: it has retired." % (name_of.call(g.oppId) if name_of.is_valid() else g.oppId)})
		career.grudge = null
	var ch = career.get("challenge")
	if ch != null and not career.membership.has(ch.oppId): career.challenge = null
	return out

## Every robot with a history against the player, the hottest first.
static func rivals_list(reg: Registry, career: Dictionary, active := true) -> Array:
	var out := []
	var rv: Dictionary = J.g(career, "rivals", {})
	for id in rv:
		var e: Dictionary = rv[id]
		if not (e.fights > 0 or e.get("carried") != null): continue
		if active and (J.truthy(e.get("retired")) or not career.membership.has(id)): continue
		var o := {"id": id}
		o.merge(e, true)
		o.merge(level_of(reg, e), true)
		out.append(o)
	return J.sorted(out, func(a, b):
		var d: float = b.heat - a.heat
		return d if d != 0.0 else float(b.fights - a.fights))

## The player's nemesis over the whole career (for the Hall of Fame): most
## heat ever, then most fights.
static func nemesis_of(_reg: Registry, career: Dictionary):
	var all := []
	var rv: Dictionary = J.g(career, "rivals", {})
	for id in rv:
		if rv[id].fights >= 2: all.append([id, rv[id]])
	all = J.sorted(all, func(a, b):
		var d: float = _nz(b[1].get("peak"), b[1].heat) - _nz(a[1].get("peak"), a[1].heat)
		return d if d != 0.0 else float(b[1].fights - a[1].fights))
	if all.is_empty(): return null
	var o := {"id": all[0][0]}
	o.merge(all[0][1], true)
	return o

# ---------------------------------------------------------------- the story

## The story so far, as a few short lines for the scouting card and the
## commentary. opts: { names: { me, them }, driver, grudge }
static func storyline(reg: Registry, career: Dictionary, opp_id, opts: Dictionary = {}) -> Array:
	var names: Dictionary = J.g(opts, "names", {})
	var driver = opts.get("driver")
	var grudge = opts.get("grudge")
	var e = rival_of(career, opp_id)
	var them: String = names.them if J.truthy(names.get("them")) else "They"
	var out := []
	if grudge != null: out.append("%s called you out. This one is personal." % them if grudge.get("asked") == "them" else "You asked for this one.")
	if e == null: return out
	if e.get("carried") != null and e.fights == 0:
		out.append("%s is the robot that replaced %s, which went %s-%s against you. Same team, same grudge." % [them, e.carried.from, J.num(e.carried.l), J.num(e.carried.w)])
		return out
	if e.fights == 0: return out
	var n: int = int(e.fights) + 1
	var series: String
	if e.w == e.l: series = "The series is level at %s-%s." % [J.num(e.w), J.num(e.l)]
	elif e.w > e.l: series = "You lead the series %s-%s%s." % [J.num(e.w), J.num(e.l), " - %s has never beaten you" % them if e.l == 0 else ""]
	else: series = "%s leads the series %s-%s%s." % [them, J.num(e.l), J.num(e.w), " - you have never beaten it" if e.w == 0 else ""]
	out.append("%s. %s" % ["The rematch" if n == 2 else "Meeting number %d" % n, series])
	var L = e.get("last")
	if L != null:
		var when: String
		if L.season == career.seasonIndex: when = "earlier this season"
		elif L.season == career.seasonIndex - 1: when = "last season"
		else: when = "in season %s" % J.num(L.season)
		var cause_txt := " (%s)" % L.cause if J.truthy(L.get("cause")) else ""
		var how: String
		if L.get("method") == "ko" or L.get("method") == "tapout": how = ("you knocked it out" if L.won else "it knocked you out") + cause_txt
		else: how = "%s won on %s decision" % ["you" if L.won else "it", "a split" if L.get("decision") == "split" else "the judges'"]
		var where := ""
		if J.truthy(L.get("grudge")): where = " in a grudge match"
		elif J.truthy(L.get("stageName")): where = " in the %s" % L.stageName
		var elim := ""
		if J.truthy(L.get("eliminated")): elim = " - and that put it out" if L.won else " - and that put you out"
		out.append("Last time, %s: %s%s%s." % [when, how, where, elim])
		if not L.won: out.append("Revenge is on the table.")
		elif L.get("method") == "decision" and L.get("decision") == "split": out.append("%s thinks it won that one." % them)
	if e.koAgainst >= 2: out.append("It has knocked you out %s times." % J.num(e.koAgainst))
	elif e.koFor >= 2: out.append("You have knocked it out %s times." % J.num(e.koFor))
	if e.streak >= 3: out.append("You have won the last %s." % J.num(e.streak) if (L != null and L.won) else "It has won the last %s." % J.num(e.streak))
	if J.truthy(driver) and L != null and J.truthy(L.get("driver")) and driver != L.driver:
		out.append("A new driver since then: %s has taken over from %s." % [driver, L.driver])
	var lv := level_of(reg, e)
	if lv.level >= 1:
		out.append("Your nemesis. The crowd knows it." if lv.level == 3 else ("There is real bad blood here." if lv.level == 2 else "The fans are calling it a rivalry."))
	return out

# ---------------------------------------------------------------- what it does

## How much harder a rival works on you: extra setups to test and a fired-up driver.
static func rival_prep(reg: Registry, career: Dictionary, opp_id, testing := true) -> Dictionary:
	var cfg := rivalry_config(reg)
	var level: int = level_of(reg, rival_of(career, opp_id)).level
	var grudge := 1 if J.path(career, ["grudge", "oppId"]) == opp_id else 0
	return {"level": level, "extraOptions": (level + grudge) * cfg.prepOptions if testing else 0, "skill": _round3((level + grudge) * cfg.skillPerLevel)}

## The gate bonus the promoters pay for a rivalry fight (a share of the
## appearance fee per level).
static func rival_gate(reg: Registry, career: Dictionary, opp_id, appearance: float) -> float:
	var level: int = level_of(reg, rival_of(career, opp_id)).level
	return J.rnd(appearance * level * rivalry_config(reg).gatePerLevel) if level > 0 else 0.0

# ---------------------------------------------------------------- grudge matches

## A grudge match purse: the league's purses scaled up, more for a hotter rivalry.
static func grudge_purse(reg: Registry, career: Dictionary, opp_id, base: Dictionary) -> Dictionary:
	var g: Dictionary = rivalry_config(reg).grudge
	var level: int = level_of(reg, rival_of(career, opp_id)).level
	var k: float = 1.0 + level * g.perLevel
	return {
		"appearance": J.rnd(base.appearance * g.appearanceX * k),
		"win": J.rnd(base.win * g.winX * k),
		"koBonus": J.rnd(base.koBonus * g.koX * k),
	}

static func _grudges_this_season(career: Dictionary) -> int:
	var n := 0
	for x in career.get("grudgeLog", []):
		if x.season == career.seasonIndex: n += 1
	if J.path(career, ["grudge", "season"]) == career.seasonIndex: n += 1
	return n

## Can the player demand a rematch with the robot they just fought? Not if one
## is already booked or asked for, not if that robot is gone, and only so
## many a season. Returns { ok, reason? }.
static func can_ask_rematch(reg: Registry, career: Dictionary) -> Dictionary:
	var lf = career.get("lastFight")
	if lf == null or career.get("grudge") != null or career.get("challenge") != null: return {"ok": false}
	if lf.get("rematch") != null: return {"ok": false, "reason": "Booked." if lf.rematch.accepted else "They said no."}
	if not career.membership.has(lf.oppId): return {"ok": false}
	var mx: float = rivalry_config(reg).grudge.maxPerSeason
	if _grudges_this_season(career) >= mx: return {"ok": false, "reason": "No more than %s grudge matches a season." % J.num(mx)}
	return {"ok": true}

## Demand a rematch. The other team says yes or no - more likely yes if they
## lost (they want revenge) or the rivalry runs hot. Settled by the seed:
## asking again changes nothing. Returns { accepted, text }.
static func ask_rematch(reg: Registry, career: Dictionary, name_of: Callable = Callable(), personality: String = "") -> Dictionary:
	var can := can_ask_rematch(reg, career)
	if not can.ok: return {"accepted": false, "text": can.reason if J.truthy(can.get("reason")) else "Not now."}
	var lf: Dictionary = career.lastFight
	var cfg: Dictionary = rivalry_config(reg).accept
	var level: int = level_of(reg, rival_of(career, lf.oppId)).level
	var p: float = cfg.base + (cfg.theyLost if lf.won else 0.0) + level * cfg.perLevel + (0.1 if personality == "aggressive" else (-0.1 if personality == "defensive" else 0.0))
	var rng := Rng.new(Rng.hash_seed("%s:rematch:%s" % [J.s(career.seed), lf.fixtureId]))
	var accepted := rng.next() < p
	var them: String = str(name_of.call(lf.oppId)) if name_of.is_valid() else str(lf.oppId)
	if accepted:
		_book(career, lf.oppId, "you")
		lf.rematch = {"accepted": true}
		var text := "%s wants revenge: grudge match booked before your next fight." % them if lf.won else "%s accepts: grudge match booked before your next fight." % them
		career.notices.append({"kind": "rivalry", "text": text})
		return {"accepted": accepted, "text": text}
	lf.rematch = {"accepted": false}
	var level_up = add_heat(reg, career, lf.oppId, "refused", "%s turned down your rematch." % them)
	var txt := "%s turned you down. They are not ready to see you again." % them if lf.won else "%s turned you down: \"We already beat you.\"" % them
	career.notices.append({"kind": "rivalry", "text": txt + (" %s!" % level_up if level_up != null else "")})
	return {"accepted": accepted, "text": txt}

## After the player beats a rival, that rival may call them out. Settled by
## the seed. Leaves career.challenge for the hub to answer.
static func maybe_call_out(reg: Registry, career: Dictionary, opp_id, fixture_id, name_of: Callable = Callable()):
	if career.get("grudge") != null or career.get("challenge") != null: return null
	if not career.membership.has(opp_id): return null
	var level: int = level_of(reg, rival_of(career, opp_id)).level
	if level == 0: return null
	if _grudges_this_season(career) >= rivalry_config(reg).grudge.maxPerSeason: return null
	var cfg: Dictionary = rivalry_config(reg).callOut
	var rng := Rng.new(Rng.hash_seed("%s:callout:%s" % [J.s(career.seed), fixture_id]))
	if rng.next() >= cfg.base + level * cfg.perLevel: return null
	var nm: String = str(name_of.call(opp_id)) if name_of.is_valid() else str(opp_id)
	var lines := [
		"%s wants you back in the box. \"That was a fluke.\"" % nm,
		"%s's team is calling you out: a grudge match, before your next fight." % nm,
		"%s demands a rematch. \"Any time, any arena.\"" % nm,
	]
	career.challenge = {"oppId": opp_id, "fixtureId": fixture_id, "season": career.seasonIndex, "text": lines[int(floor(rng.next() * lines.size()))]}
	return career.challenge

## Answer a call-out: accept books the grudge match; ducking it costs you
## nothing but face (and adds heat).
static func answer_challenge(reg: Registry, career: Dictionary, accept: bool, name_of: Callable = Callable()):
	var c = career.get("challenge")
	if c == null: return null
	career.challenge = null
	var nm: String = str(name_of.call(c.oppId)) if name_of.is_valid() else str(c.oppId)
	if accept:
		_book(career, c.oppId, "them")
		career.notices.append({"kind": "rivalry", "text": "Grudge match on: you against %s, before your next fight." % nm})
		return {"accepted": true}
	var level_up = add_heat(reg, career, c.oppId, "ducked", "You turned down %s's call-out." % nm)
	career.notices.append({"kind": "rivalry", "text": "You turned %s down. Their fans say you ducked them.%s" % [nm, " %s!" % level_up if level_up != null else ""]})
	return {"accepted": false}

## Call off a booked grudge match (it counts as ducking it).
static func cancel_grudge(reg: Registry, career: Dictionary, name_of: Callable = Callable()):
	var g = career.get("grudge")
	if g == null: return null
	career.grudge = null
	var nm: String = str(name_of.call(g.oppId)) if name_of.is_valid() else str(g.oppId)
	add_heat(reg, career, g.oppId, "ducked", "You called off the grudge match with %s." % nm)
	return g

static func _book(career: Dictionary, opp_id, asked: String) -> void:
	var n: int = career.get("grudgeLog", []).size() + 1
	career.grudge = {"id": "g%s:%d:%s" % [J.s(career.seasonIndex), n, opp_id], "oppId": opp_id, "season": career.seasonIndex, "asked": asked}

## The booked grudge match as a fixture the fight screens understand.
static func grudge_fixture(career: Dictionary, league_of: Callable):
	var g = career.get("grudge")
	if g == null: return null
	return {"id": g.id, "stage": "grudge", "league": league_of.call(g.oppId), "a": career.playerId, "b": g.oppId, "grudge": true, "asked": g.asked, "result": null}
