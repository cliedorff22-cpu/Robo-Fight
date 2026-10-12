## commentary.gd - two commentators call the fight.
##
## Pure: facts in (the bus's events, the clock, the story so far), lines out.
## The play-by-play voice ("pbp") calls what happens; the colour voice
## ("color") says what it means. Who speaks them, and whether they appear as
## captions, is render/commentary_view.gd and the audio layer.
##
## Every line carries a priority (0 chatter .. 3 must-say) so the booth never
## talks over a knockout with a remark about the weather, and `hazard: true`
## on anything about the arena's hazards - those are spoken, never captioned
## (no hazard words on screen).
class_name Commentary
extends RefCounted

const PICK_MEMORY := 6    # don't repeat any of the last few lines of a kind
const SEV := {"scratch": 0, "glance": 1, "hit": 2, "heavy": 3, "catastrophic": 4}

var names: Dictionary        # { botId: name }
var corners: Dictionary      # { botId: "red" | "blue" }
var weapons: Dictionary      # { botId: weapon description, e.g. "vertical disc" }
var story = null             # the career's story so far, or null
var player_id = null         # the player's bot - the story is from their side
var where = null             # { venue, layout } names
var rng: Rng
var duration_s := 180.0

var _recent := {}            # template set -> recent picks
var _damage := {}            # botId -> damage taken, as the booth has seen it
var _since_action := 0.0
var _last_big_hit_t := -99.0
var _called_clock := {}
var _counting := {}
var _first_blood := false
var _lulls_said := 0

## opts: { names, corners, weapons, story, playerId, where, rng, durationS }
func _init(opts: Dictionary = {}) -> void:
	names = J.g(opts, "names", {})
	corners = J.g(opts, "corners", {})
	weapons = J.g(opts, "weapons", {})
	story = opts.get("story")
	player_id = opts.get("playerId")
	where = opts.get("where")
	rng = opts.get("rng") if opts.get("rng") != null else Rng.new(1)
	duration_s = J.g(opts, "durationS", 180.0)

static func make(opts: Dictionary = {}) -> Commentary:
	return Commentary.new(opts)

func _nm(id) -> String:
	var n = names.get(id) if id != null else null
	return n if J.truthy(n) else "the robot"

func _other(id):
	for x in names:
		if x != id and J.truthy(corners.get(x)) and corners.get(x) != corners.get(id): return x
	return null

func _pick(set_name: String, list: Array) -> String:
	var seen: Array = _recent.get(set_name, [])
	var fresh := list.filter(func(x): return not seen.has(x))
	var pool: Array = fresh if fresh.size() > 0 else list
	var t: String = pool[int(floor(rng.next() * pool.size()))]
	seen.append(t)
	if seen.size() > mini(PICK_MEMORY, list.size() - 1): seen.pop_front()
	_recent[set_name] = seen
	return t

static func _fill(t: String, v: Dictionary) -> String:
	var out := t
	for k in v: out = out.replace("{%s}" % k, str(v[k]))
	return out

func _line(who: String, set_name: String, list: Array, vars: Dictionary = {}, pri := 1, hazard := false) -> Dictionary:
	var o := {"who": who, "text": J.cap(_fill(_pick(set_name, list), vars)), "pri": pri}
	if hazard: o.hazard = true
	return o

# ---------------------------------------------------------------- before the bell

func intro() -> Array:
	var red = null
	var blue = null
	for x in corners:
		if red == null and corners[x] == "red": red = x
		if blue == null and corners[x] == "blue": blue = x
	var out := []
	out.append(_line("pbp", "welcome", [
		"Welcome to {venue}! In the red square, {red}. In the blue square, {blue}.",
		"Live from {venue}! {red} in red, {blue} in blue - and this one should be good.",
		"Good evening from {venue}. It's {red} against {blue}.",
	], {"venue": J.g(where, "venue", "the box"), "red": _nm(red), "blue": _nm(blue)}, 2))
	var wr = weapons.get(red) if red != null else null
	var wb = weapons.get(blue) if blue != null else null
	if J.truthy(wr) and J.truthy(wb):
		var lines: Array
		if wr == wb: lines = [
			"Two {w}s. Somebody's leaving in pieces.",
			"{w} against {w}. Whoever spins up first wins this.",
		]
		else: lines = [
			"{rw} against {bw}. That's a fascinating matchup.",
			"The {rw} of {red} against the {bw} of {blue}. Watch the first exchange.",
			"Can the {bw} handle that {rw}? We're about to find out.",
		]
		out.append(_line("color", "matchup", lines, {"w": wr, "rw": wr, "bw": wb, "red": _nm(red), "blue": _nm(blue)}, 1))
	if story != null:
		if J.truthy(story.get("grudge")):
			out.append({"who": "color", "text": "This is a grudge match - %s called them out, and there is no love lost." % _nm(blue) if story.get("asked") == "them" else "A grudge match! %s asked for this one." % _nm(red), "pri": 2})
		elif J.g(story, "level", 0) >= 3: out.append({"who": "color", "text": "%s is %s's nemesis. The crowd knows it." % [_nm(blue), _nm(red)], "pri": 2})
		elif J.g(story, "level", 0) >= 1: out.append({"who": "color", "text": "These two have history - the fans are calling it a rivalry.", "pri": 2})
		var series = story.get("series")
		if series != null and J.truthy(series.get("fights")):
			var w: float = series.w
			var l: float = series.l
			var txt: String
			if w == l: txt = "The series is level at %s apiece." % J.num(w)
			elif w > l: txt = "%s leads the series %s to %s." % [_nm(red), J.num(w), J.num(l)]
			else: txt = "%s leads the series %s to %s." % [_nm(blue), J.num(l), J.num(w)]
			out.append({"who": "pbp", "text": txt, "pri": 1})
		var last = story.get("last")
		if last != null and not J.truthy(last.get("won")):
			out.append({"who": "color", "text": "%s won the last one%s. %s wants revenge." % [_nm(blue), " by knockout" if last.get("method") == "ko" else "", _nm(red)], "pri": 1})
	return out

# ---------------------------------------------------------------- the fight

func _hit(e: Dictionary, t: float) -> Array:
	var sev: int = SEV.get(e.get("severity"), 1)
	_counting.clear()          # a count that is still running would have ended in a KO
	var a := _nm(e.get("attackerId"))
	var d := _nm(e.get("defenderId"))
	var def_id = e.get("defenderId")
	var atk_id = e.get("attackerId")
	_damage[def_id] = _damage.get(def_id, 0.0) + J.g(e, "deliveredJ", 0.0)
	var out := []
	var kind = e.get("kind")
	if kind == "hazard":
		# Spoken only - never a caption.
		if sev < 2: return out
		var ht = e.get("hazardType")
		var H: Array = {
			"pulverizer": ["The hammer comes down on {d}!", "Pulverized! {d} takes the hammer!", "Right under the hammer - ouch!"],
			"screw": ["The screws grab {d}!", "{d} is chewed up by the screws!"],
			"killsaw": ["Up come the saws under {d}!", "Killsaws! {d} gets launched!"],
		}.get(ht, ["{d} finds a hazard!"])
		out.append(_line("pbp", "haz:%s" % str(ht), H, {"d": d}, 2 if sev >= 3 else 1, true))
		_since_action = 0.0
		return out
	if sev < 2: return out
	_since_action = 0.0
	if not _first_blood and sev >= 2 and kind == "weapon":
		_first_blood = true
		out.append(_line("pbp", "first", ["First real contact goes to {a}!", "{a} draws first blood!", "And {a} lands the first big one!"], {"a": a, "d": d}, 2))
		return out
	if kind == "ram":
		if sev < 3: return out
		out.append(_line("pbp", "ram", ["{a} slams into {d}!", "Big shove from {a}!", "{a} drives {d} across the box!", "{a} bulldozes straight through {d}!"], {"a": a, "d": d}, 1))
		return out
	if sev >= 4:
		out.append(_line("pbp", "huge", ["OH! What a hit from {a}!", "MASSIVE hit! {d} goes flying!", "{a} absolutely destroys {d} with that one!", "Did you SEE that?! {a} nearly cut {d} in half!"], {"a": a, "d": d}, 3))
		_last_big_hit_t = t
		if rng.next() < 0.7: out.append(_line("color", "hugeC", ["You can't take many of those.", "That's going to be an expensive night in the pit.", "The whole building felt that one.", "That's what that weapon was built for."], {"a": a, "d": d}, 1))
	elif sev >= 3:
		out.append(_line("pbp", "heavy", ["Big hit from {a}!", "{a} connects - hard!", "Huge shot on {d}!", "{a} finds the mark!", "Clean hit on {d}!"], {"a": a, "d": d}, 2))
		_last_big_hit_t = t
	elif rng.next() < 0.35:
		out.append(_line("pbp", "hit", ["{a} gets a piece of {d}.", "Contact from {a}.", "{a} chips away at {d}.", "Good bite from {a}."], {"a": a, "d": d}, 0))
	# Who is winning the damage war.
	var gap: float = _damage.get(def_id, 0.0) - _damage.get(atk_id, 0.0)
	if sev >= 3 and gap > 30000 and rng.next() < 0.4:
		out.append(_line("color", "beating", ["{d} is taking a real beating.", "This is getting one-sided.", "{d} needs something to happen, and fast."], {"d": d}, 1))
	return out

func _failed(e: Dictionary) -> Array:
	var d := _nm(e.get("botId"))
	var cat = e.get("category")
	var L = {
		"armor": ["There goes a chunk of {d}'s armour!", "Armour off {d}! That panel is in the stands!", "{d} is shedding parts!"],
		"chassis": ["{d}'s frame is buckled!", "That's cracked {d}'s chassis!"],
		"weapon": ["{d}'s weapon is gone!", "The weapon's dead on {d}!", "{d} has lost its weapon - it's a pusher now!"],
		"weaponMotor": ["{d}'s weapon is slowing down - that motor's hurt!", "No more spin from {d}!"],
		"wheel": ["{d} has lost a wheel!", "Wheel off! {d} is limping!"],
		"drive": ["{d}'s drive is failing!", "{d} is limping now - that's the drivetrain!"],
		"motor": ["{d}'s drive motor is smoking!", "Smoke from {d}! That's a motor gone!"],
		"battery": ["{d} is on fire! That's the battery!", "Fire! {d}'s battery has gone up!"],
		"electronics": ["{d} is twitching - the electronics are fried!", "Sparks from inside {d}!"],
	}.get(cat)
	if L == null: return []
	_since_action = 0.0
	return [_line("pbp", "fail:%s" % cat, L, {"d": d}, 3 if (cat == "battery" or cat == "weapon") else 2)]

func _count(e: Dictionary) -> Array:
	var d := _nm(e.get("botId"))
	_since_action = 0.0
	if e.count == 1:
		_counting[e.botId] = true
		return [_line("pbp", "count", ["{d} isn't moving! The referee is counting!", "Is {d} stuck? Here comes the count!", "{d} is in trouble - the count is on!"], {"d": d}, 3)]
	if e.count == e.of - 3: return [_line("color", "countLate", ["{d} has to move, NOW!", "Come on {d}, wiggle out of it!"], {"d": d}, 2)]
	return []

## The story, finished: who won the series, revenge, a streak.
func _story_end(winner_id) -> Array:
	if story == null or not J.truthy(player_id): return []
	var won: bool = winner_id == player_id
	var s: Dictionary = J.g(story, "series", {"w": 0, "l": 0})
	var w: float = J.g(s, "w", 0) + (1 if won else 0)
	var l: float = J.g(s, "l", 0) + (0 if won else 1)
	var me := _nm(player_id)
	var them := _nm(_other(player_id))
	var out := []
	var last = story.get("last")
	if last != null and not J.truthy(last.get("won")) and won: out.append({"who": "color", "text": "Revenge for %s!" % me, "pri": 2})
	if J.truthy(story.get("grudge")): out.append({"who": "color", "text": "%s settles the grudge." % me if won else "%s wins the grudge match. That'll sting." % them, "pri": 1})
	if J.truthy(s.get("fights")):
		var txt: String
		if w == l: txt = "That levels the series at %s apiece." % J.num(w)
		elif w > l: txt = "%s goes up %s to %s in the series." % [me, J.num(w), J.num(l)]
		else: txt = "%s goes up %s to %s in the series." % [them, J.num(l), J.num(w)]
		out.append({"who": "pbp", "text": txt, "pri": 1})
	return out

func _end(r: Dictionary) -> Array:
	var W := _nm(r.get("winnerId"))
	var L := _nm(r.get("loserId"))
	var out := []
	if r.get("method") == "ko":
		out.append(_line("pbp", "ko", ["It's over! {l} is knocked out! {w} wins!", "KNOCKOUT! {w} takes it!", "{l} is done! The winner, by knockout, {w}!"], {"w": W, "l": L}, 3))
	elif r.get("method") == "tapout":
		out.append(_line("pbp", "tap", ["{l} taps out! {w} wins!", "And that's the towel - {l} taps out!"], {"w": W, "l": L}, 3))
	else:
		out.append(_line("pbp", "bell", ["That's the bell! We go to the judges.", "Time! This one goes to the judges."], {}, 3))
		var how := "On the judges' cards"
		if r.get("decision") == "split": how = "On a split decision"
		elif r.get("decision") == "unanimous": how = "By unanimous decision"
		out.append({"who": "pbp", "text": "%s... %s!" % [how, W], "pri": 3})
		if r.get("decision") == "split": out.append(_line("color", "split", ["That could have gone either way.", "{l}'s team won't like that one.", "Close. Very close."], {"l": L}, 1))
	out.append_array(_story_end(r.get("winnerId")))
	return out

## One bus event. `t` is match time in seconds (since the bell).
## Returns [{ who, text, pri, hazard? }]
func event(type: String, e = null, t: float = 0.0) -> Array:
	if e == null: e = {}
	match type:
		"countdown": return [_line("pbp", "ready", ["Robots ready...", "Drivers ready...", "Here we go..."], {}, 3)]
		"live": return [_line("pbp", "fight", ["FIGHT!", "Activate! FIGHT!", "And they're off!"], {}, 3)]
		"hit": return _hit(e, t)
		"failed": return _failed(e)
		"count": return _count(e)
		"recovered":
			_counting.erase(e.get("botId"))
			return [_line("color", "free", ["{d} gets free!", "And {d} is moving again!"], {"d": _nm(e.get("botId"))}, 2)]
		"pin": return [_line("pbp", "pin", ["{a} has {d} pinned - the referee wants a release!", "{a} needs to let go!"], {"a": _nm(e.get("botId")), "d": _nm(e.get("pinnedId"))}, 2)]
		"separate": return [_line("color", "sep", ["They're locked together. The referee pulls them apart.", "Tangled up - and separated."], {}, 1)]
		"hazard":
			if e.get("type") == "pit": return [_line("pbp", "pitopen", ["The pit is open!", "Down goes the floor - the pit is open!"], {}, 2, true)]
			if e.get("type") == "killsaw":
				if rng.next() < 0.25: return [_line("color", "saws", ["Watch the floor - the saws are coming up!"], {}, 0, true)]
			return []
		"end": return _end(e)
	return []      # (a KO is called by the "end" line)

## Once per frame while the fight is live: clock calls and the chatter that
## fills a lull. `clock_s` is the time remaining.
func tick(clock_s: float, live: bool, dt: float = 0.0) -> Array:
	if not live: return []
	_since_action += dt
	var out := []
	for c in [[60, "One minute left!"], [30, "Thirty seconds!"], [10, "Ten seconds to go!"]]:
		if c[0] < duration_s and clock_s <= c[0] and not _called_clock.has(c[0]):
			_called_clock[c[0]] = true
			out.append({"who": "pbp", "text": c[1], "pri": 2})
	if _since_action > 11 and _lulls_said < 6 and _counting.is_empty():
		_since_action = 0.0
		_lulls_said += 1
		var ids := corners.keys()
		var x = ids[int(floor(rng.next() * ids.size()))] if ids.size() > 0 else null
		out.append(_line("color" if rng.next() < 0.5 else "pbp", "lull", [
			"Neither driver wants to commit.", "{x} is circling, looking for an opening.", "Cagey stuff. Somebody has to go in.",
			"The crowd wants action!", "{x} is waiting for a mistake.", "A bit of a standoff here.",
		], {"x": _nm(x)}, 0))
	return out

## Between rematches: forget the fight, keep the voice.
func reset() -> void:
	_since_action = 0.0
	_last_big_hit_t = -99.0
	_called_clock = {}
	_counting = {}
	_first_blood = false
	_lulls_said = 0
	_damage.clear()
