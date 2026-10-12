## judging.gd - the scorebook and the judges.
##
## The referee watches the fight and records facts here - hits, who was
## advancing, who was pushing whom, who was stuck - and when a match goes the
## distance three judges turn those facts into scorecards:
##   damage 5, aggression 3, control 3.
## Each judge has a small, seeded lean per category, so a close fight can come
## out a split decision. 11 points per card is odd, so a card cannot tie.
class_name Judging
extends RefCounted

const CATEGORIES := ["damage", "aggression", "control"]

const DEFAULTS := {
	"judges": 3,
	# How far one judge's read of a category can differ from the facts.
	"judgeLean": 0.06,
	# Damage points for a destroyed part, on top of the hp it cost.
	"failureBonusHp": 35,
	# Hazard damage counts for whoever put the robot into the hazard, if they
	# touched it within this many seconds.
	"hazardCreditS": 2.0,
}

static func judging_config(rules: Dictionary) -> Dictionary:
	var j: Dictionary = rules.get("judging", {})
	var points := {}
	for c in j.get("categories", []): points[c.id] = c.points
	var out := J.merge(DEFAULTS, j)
	out.points = {
		"damage": J.g(points, "damage", 5),
		"aggression": J.g(points, "aggression", 3),
		"control": J.g(points, "control", 3),
	}
	return out

static func blank_tally() -> Dictionary:
	return {
		"damage": 0.0,          # hp-equivalent dealt
		"hpDealt": 0.0, "failuresCaused": 0, "hazardHpCredited": 0.0,
		"advancingS": 0.0, "attacks": 0.0,
		"pushingS": 0.0, "oppDisabledS": 0.0, "ownDisabledS": 0.0, "selfHazardHits": 0, "pinPenalties": 0,
		"hitsLanded": 0, "biggestHitHp": 0.0,
	}

# ---- the scorebook: a running tally of the facts the judges score from

var cfg: Dictionary
var bot_ids: Array
var _tally := {}

func _init(rules: Dictionary, ids: Array) -> void:
	cfg = judging_config(rules)
	bot_ids = ids
	for id in bot_ids: _tally[id] = blank_tally()

static func make_scorebook(rules: Dictionary, ids: Array) -> Judging:
	return Judging.new(rules, ids)

func other(id):
	for b in bot_ids:
		if b != id: return b
	return null

func tally(id): return _tally.get(id)

func reset() -> void:
	for id in bot_ids: _tally[id] = blank_tally()

## A resolved hit. `creditTo` overrides who gets the damage - used for hazard
## hits when someone drove the victim in.
func record_hit(o: Dictionary) -> void:
	var kind = o.get("kind")
	var attacker_id = o.get("attackerId")
	var defender_id = o.get("defenderId")
	var hp: float = o.get("hp", 0.0)
	var failures: float = o.get("failures", 0)
	var credit_to = o.get("creditTo")
	var scorer = credit_to if credit_to != null else (null if kind == "hazard" else attacker_id)
	var victim = _tally.get(defender_id)
	if kind == "hazard" and victim != null and credit_to == null: victim.selfHazardHits += 1
	var t = _tally.get(scorer) if scorer != null else null
	if t == null or scorer == defender_id: return
	var pts: float = hp + failures * cfg.failureBonusHp
	t.damage += pts
	t.hpDealt += hp
	t.failuresCaused += failures
	if kind == "hazard":
		t.hazardHpCredited += hp
	else:
		t.hitsLanded += 1
		t.attacks += 1.0 if kind == "weapon" else 0.5
	t.biggestHitHp = maxf(t.biggestHitHp, hp)

## Per-step facts for one bot: { advancing, pushing, disabled }.
func record_step(id, facts: Dictionary, dt: float) -> void:
	var t = _tally.get(id)
	if t == null: return
	if J.truthy(facts.get("advancing")): t.advancingS += dt
	if J.truthy(facts.get("pushing")): t.pushingS += dt
	if J.truthy(facts.get("disabled")):
		t.ownDisabledS += dt
		var o = _tally.get(other(id))
		if o != null: o.oppDisabledS += dt

## The pinning rule was broken: a control deduction.
func record_pin_penalty(id) -> void:
	var t = _tally.get(id)
	if t != null: t.pinPenalties += 1

## Raw category scores (not points) per bot.
func raw() -> Dictionary:
	var out := {}
	for id in bot_ids:
		var t: Dictionary = _tally[id]
		var o = _tally.get(other(id))
		out[id] = {
			"damage": t.damage,
			"aggression": t.advancingS + t.attacks * 1.5,
			"control": maxf(0.0,
				t.pushingS + t.oppDisabledS * 0.8 + t.hazardHpCredited * 0.03 +
				(o.selfHazardHits if o != null else 0) * 0.6 -
				t.ownDisabledS * 0.5 - t.pinPenalties * 4.0),
		}
	return out

## Who is ahead right now, -1..1 from `id`'s point of view. For the AI.
func lead(id) -> float:
	var r := raw()
	var me = r.get(id)
	var them = r.get(other(id))
	if me == null or them == null: return 0.0
	var s := 0.0
	var w := 0.0
	for c in CATEGORIES:
		var tot: float = me[c] + them[c]
		if tot <= 1e-6: continue
		s += cfg.points[c] * (me[c] - them[c]) / tot
		w += cfg.points[c]
	return s / w if w != 0.0 else 0.0

## Turn the tally into judges' scorecards.
func judge(seed_value = 1) -> Dictionary:
	return judge_cards(raw(), bot_ids, cfg, seed_value)

## Score cards from raw category scores.
## Returns { cards: [{ judge, scores: { id: { damage, aggression, control, total } }, winnerId }],
##           winnerId, loserId, votes: { id: n }, decision: "unanimous" | "split" }
static func judge_cards(raw_scores: Dictionary, ids: Array, cfg_in: Dictionary, seed_value = 1) -> Dictionary:
	var a = ids[0]
	var b = ids[1]
	var cards := []
	for j in int(cfg_in.judges):
		var rng := Rng.new(Rng.hash_seed("judge:%d:%s" % [j, J.num(seed_value)]))
		var scores := {a: {"total": 0.0}, b: {"total": 0.0}}
		for c in CATEGORIES:
			var pts: float = cfg_in.points[c]
			var ra: float = raw_scores[a][c]
			var rb: float = raw_scores[b][c]
			var tot := ra + rb
			# Nothing to separate them: the judge splits it as evenly as an
			# odd number of points allows, by their lean.
			var share := ra / tot if tot > 1e-6 else 0.5
			share = clampf(share + (rng.next() - 0.5) * 2.0 * cfg_in.judgeLean, 0.0, 1.0)
			var pa := clampf(J.rnd(share * pts), 0.0, pts)
			scores[a][c] = pa
			scores[b][c] = pts - pa
			scores[a].total += pa
			scores[b].total += pts - pa
		cards.append({"judge": j + 1, "scores": scores, "winnerId": a if scores[a].total > scores[b].total else b})
	var votes := {a: 0, b: 0}
	for c in cards: votes[c.winnerId] += 1
	var winner_id = a if votes[a] > votes[b] else b
	return {
		"cards": cards, "votes": votes, "winnerId": winner_id,
		"loserId": b if winner_id == a else a,
		"decision": "unanimous" if votes[winner_id] == int(cfg_in.judges) else "split",
	}
