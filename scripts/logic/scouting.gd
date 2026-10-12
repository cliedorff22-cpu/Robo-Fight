## scouting.gd - the career's scouting reports: how an opponent has been
## fighting (its form, how it wins, how it loses, what it does against each
## kind of weapon) and the tape of its last fight, to watch in the arena.
##
## The robot's spec sheet - weapon, armour gaps, speed - is Catalog.scouting();
## this is its record. Pure logic over the career save:
##   career.tape = { robotId: { season, id, a, b, stage, label, result, arena } }
## is every robot's last fight, kept across seasons, recorded by career.gd.
class_name Scouting

const LEAGUES := {"rookie": "Rookie", "pro": "Pro", "elite": "Elite", "world": "World Championship"}
const METHOD := {"ko": "knockout", "tapout": "tap out", "decision": "decision"}
const CLASS_WORDS := {"spinner_h": "horizontal spinners", "spinner_v": "vertical spinners", "drum": "drums", "hammer": "hammers", "flipper": "flippers", "lifter": "lifters", "crusher": "crushers", "static": "wedges and pushers", "none": "robots with no weapon"}
const CAUSE_WORDS := {"flipped": "flipped over", "beached": "beached", "disabled": "disabled", "stuck": "stuck", "pitted": "shoved down the pit"}

static func clock(s: float) -> String:
	return "%d:%02d" % [int(floor(s / 60.0)), int(J.rnd(fmod(s, 60.0)))]

## Keep a fight as the last one for both robots in it.
static func record_tape(reg: Registry, career: Dictionary, season: Dictionary, f: Dictionary, result: Dictionary) -> void:
	if career.get("tape") == null: career.tape = {}
	var bracket = null
	if f.stage == "final":
		bracket = J.path(season, ["giantNut", "bracket"]) if f.get("league") == "giantNut" else J.path(season, ["leagues", f.get("league"), "finals"])
	var where := ""
	if f.get("league") == "giantNut": where = "Giant Nut "
	elif f.stage == "final": where = "%s " % LEAGUES.get(f.get("league"), f.get("league"))
	var label = null
	if f.stage == "grudge": label = "a grudge match"
	elif f.stage == "group": label = "%sGroup %s · round %d" % [where, f.get("group"), int(f.round) + 1]
	elif bracket != null: label = "%s%s" % [where, Tournament.round_name(bracket, f.bracketRound)]
	var entry := {
		"season": season.index, "id": f.id, "a": f.a, "b": f.b, "stage": f.stage, "league": f.get("league"), "label": label,
		"result": {"winnerId": result.winnerId, "method": result.get("method"), "cause": result.get("cause"), "elapsedS": J.rnd(J.g(result, "elapsedS", 0.0)), "decision": result.get("decision")},
		"arena": Arenas.career_arena(reg, {"seasonKind": "giantNut" if f.get("league") == "giantNut" else "league", "league": f.get("league"), "fixtureId": f.id}),
	}
	career.tape[f.a] = entry
	career.tape[f.b] = entry

## Every fight a robot has had this season, in order.
static func season_fights(career: Dictionary, id) -> Array:
	var s = career.get("season")
	if s == null: return []
	var groups := J.sorted(s.fixtures.filter(func(f): return f.get("result") != null and (f.a == id or f.b == id)), func(x, y): return x.round - y.round)
	groups.append_array(s.get("finalsLog", []).filter(func(f): return f.a == id or f.b == id))
	return groups

static func _camel_words(s: String) -> String:
	var out := ""
	for i in s.length():
		var ch := s[i]
		if ch >= "A" and ch <= "Z": out += " " + ch.to_lower()
		else: out += ch
	return out

static func _plural(n, word := "s") -> String:
	return word if n > 1 else ""

## The scouting file on a robot: its record this season and how it gets it.
## Returns { record: { w, l }, form: [{ won, method, oppId }], lines: [text],
##           vs: [{ cls, w, l, name }], tape, tapeText }
##   name_of: Callable(id) -> name; my_class: the player's weapon class
static func scout_report(reg: Registry, career: Dictionary, id, name_of: Callable = Callable(), my_class = null) -> Dictionary:
	var fights := []
	for f in season_fights(career, id):
		var r: Dictionary = f.result
		var other = f.b if f.a == id else f.a
		fights.append({"oppId": other, "won": r.winnerId == id, "method": r.get("method"), "cause": r.get("cause"), "elapsedS": J.g(r, "elapsedS", 180.0),
			"dealt": J.path(r, ["damage", id], 0.0), "taken": J.path(r, ["damage", other], 0.0)})
	var wins := fights.filter(func(x): return x.won)
	var losses := fights.filter(func(x): return not x.won)
	var ko_wins := wins.filter(func(x): return x.method == "ko" or x.method == "tapout")
	var ko_losses := losses.filter(func(x): return x.method == "ko" or x.method == "tapout")
	var lines := []
	if fights.size() > 0:
		if wins.size() > 0:
			if ko_wins.size() >= ceili(wins.size() / 2.0):
				var avg := J.sum(ko_wins, func(x): return x.elapsedS) / ko_wins.size()
				lines.append("A finisher: %d of its %d win%s by knockout, on average at %s." % [ko_wins.size(), wins.size(), _plural(wins.size()), clock(avg)])
			else:
				lines.append("Wins on points: %d of its %d win%s went to the judges." % [wins.size() - ko_wins.size(), wins.size(), _plural(wins.size())])
		if ko_losses.size() > 0:
			var causes := {}
			for x in ko_losses:
				if J.truthy(x.cause): causes[x.cause] = causes.get(x.cause, 0) + 1
			var pairs := []
			for c in causes: pairs.append([c, causes[c]])
			pairs = J.sorted(pairs, func(a, b): return b[1] - a[1])
			var tail := ""
			if pairs.size() > 0:
				var top: Array = pairs[0]
				tail = ", %s%s" % ["mostly " if top[1] > 1 else "", CAUSE_WORDS.get(top[0], "with its %s wrecked" % _camel_words(str(top[0])).to_lower())]
			lines.append("Knocked out %d time%s this season%s." % [ko_losses.size(), _plural(ko_losses.size()), tail])
		elif losses.size() > 0:
			lines.append("Never knocked out this season: it loses on points if it loses.")
		var dealt := J.sum(fights, func(x): return x.dealt) / fights.size()
		var taken := J.sum(fights, func(x): return x.taken) / fights.size()
		if dealt > 0 or taken > 0:
			if dealt > taken * 1.4: lines.append("Does far more damage than it takes (%d to %d a fight on the judges' cards)." % [J.rndi(dealt), J.rndi(taken)])
			elif taken > dealt * 1.4: lines.append("Takes more damage than it deals (%d to %d a fight): it can be hurt." % [J.rndi(taken), J.rndi(dealt)])
			else: lines.append("Trades evenly: about %d damage dealt and %d taken a fight." % [J.rndi(dealt), J.rndi(taken)])
		var streak := 0
		var last_won: bool = fights[fights.size() - 1].won
		for i in range(fights.size() - 1, -1, -1):
			if fights[i].won != last_won: break
			streak += 1
		if streak >= 3: lines.append("%s: %d %s in a row." % ["On a run" if last_won else "Out of form", streak, "wins" if last_won else "losses"])
	# What it has learned against each kind of weapon (ailearn.gd), most fought first.
	var vs := []
	var mem_vs: Dictionary = J.path(career, ["ai", id, "vs"], {})
	for cls in mem_vs:
		var v: Dictionary = mem_vs[cls]
		if v.f > 0: vs.append({"cls": cls, "w": v.w, "l": v.f - v.w, "name": CLASS_WORDS.get(cls, cls)})
	vs = J.sorted(vs, func(a, b): return (b.w + b.l) - (a.w + a.l)).slice(0, 3)
	var mine = mem_vs.get(my_class) if my_class != null else null
	if mine != null and mine.f >= 2:
		var share: float = float(mine.w) / mine.f
		var note := ""
		if share >= 0.65: note = " - it knows how to beat your kind"
		elif share <= 0.35: note = " - your kind of weapon troubles it"
		lines.append("Against %s like yours: %s-%s%s." % [CLASS_WORDS.get(my_class, my_class), J.num(mine.w), J.num(mine.f - mine.w), note])
	var tape = tape_of(career, id)
	return {
		"record": {"w": wins.size(), "l": losses.size()},
		"form": J.slice(fights, -5).map(func(x): return {"won": x.won, "method": x.method, "oppId": x.oppId}),
		"lines": lines, "vs": vs, "tape": tape,
		"tapeText": tape_line(tape, id, name_of) if tape != null else null,
	}

## A robot's last fight, if it has had one in this career.
static func tape_of(career: Dictionary, id):
	return J.path(career, ["tape", id])

## "Season 2, Group B · round 3: beat Gyrator by knockout at 1:12."
static func tape_line(tape: Dictionary, id, name_of: Callable = Callable()) -> String:
	var r: Dictionary = tape.result
	var other = tape.b if tape.a == id else tape.a
	var won: bool = r.winnerId == id
	var how: String
	if r.get("method") == "decision": how = ("on a %s decision" % J.g(r, "decision", "")).replace("  ", " ")
	else: how = "by %s at %s" % [METHOD.get(r.get("method"), r.get("method")), clock(J.g(r, "elapsedS", 0.0))]
	var other_name = name_of.call(other) if name_of.is_valid() else other
	return "Season %s%s: %s %s %s." % [J.num(tape.season), ", %s" % tape.label if J.truthy(tape.get("label")) else "", "beat" if won else "lost to", other_name, how]
