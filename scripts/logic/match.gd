## match.gd - the match state machine: clock, referee count, pinning rule,
## tap-outs and the result.
##
## Pure logic, advanced by a dt the caller supplies. It never reads the
## physics world: the referee (sim/referee.gd) pushes facts in each step.
##
## A match ends one of three ways, as on the show:
##   KO        a robot cannot drive under its own power for the count
##   tap-out   a team concedes
##   decision  time runs out and three judges score it (logic/judging.gd)
class_name Match
extends RefCounted

const IDLE := "idle"
const COUNTDOWN := "countdown"
const LIVE := "live"
const PAUSED := "paused"
const ENDED := "ended"

const KO := "ko"
const TAPOUT := "tapout"
const DECISION := "decision"

# Accumulating a float dt for ten seconds lands a hair under the boundary, so
# compare with a slack of one microsecond.
const TIME_EPS := 1e-6

## Referee config; rules.json `match` overrides any of it.
static func ref_config(rules: Dictionary) -> Dictionary:
	var m: Dictionary = rules.get("match", {})
	return {
		"durationS": J.g(m, "durationS", 180.0),
		"countdownS": J.g(m, "countdownS", 3.0),
		"countS": J.g(m, "immobilizationCountS", 10.0),
		# How long a robot has to look stuck before the count STARTS.
		"countGraceS": J.g(m, "countGraceS", 1.0),
		# Showing controlled movement for this long stops the count.
		"recoverS": J.g(m, "recoverS", 0.4),
		"pinLimitS": J.g(m, "pinLimitS", 10.0),
		"pinReleaseS": J.g(m, "pinReleaseS", 3.0),
		"tapOutAllowed": m.get("tapOutAllowed") != false,
		"separateAfterS": J.g(m, "separateAfterS", 6.0),
	}

var config: Dictionary
var scorebook: Judging
var bus: Bus
var bot_ids: Array
var seed_value = 1

var phase: String = IDLE
var clockS: float
var countdownS: float
var elapsedS := 0.0
var result = null
var pin = null            # { pinnerId, pinnedId, heldS, warned, sinceWarnS }
var _bots := {}

func _init(rules: Dictionary, event_bus: Bus = null, opts: Dictionary = {}) -> void:
	config = ref_config(rules)
	bus = event_bus
	bot_ids = opts.get("botIds", [])
	seed_value = opts.get("seed", 1)
	scorebook = Judging.new(rules, bot_ids.slice(0, 2))
	clockS = config.durationS
	countdownS = config.countdownS
	for id in bot_ids: _bots[id] = _fresh_bot(id)

static func make(rules: Dictionary, event_bus: Bus = null, opts: Dictionary = {}) -> Match:
	return Match.new(rules, event_bus, opts)

static func _fresh_bot(id) -> Dictionary:
	return {
		"id": id,
		# `stuckS` is how long it has looked stuck; the count proper is
		# stuckS minus the grace.
		"stuckS": 0.0, "countS": 0.0, "lastAnnounced": 0, "recoverS": 0.0,
		"countedOut": false, "tappedOut": false, "cause": null,
	}

func other(id):
	for b in bot_ids:
		if b != id: return b
	return null

func bot(id): return _bots.get(id)
func bots() -> Array: return _bots.values()

func _emit(type: String, payload) -> void:
	if bus != null: bus.emit(type, payload)

func _emit_state() -> void:
	_emit(Bus.MATCH_STATE, {"phase": phase, "clockS": clockS, "countdownS": countdownS})

func _end(res: Dictionary) -> void:
	if phase == ENDED: return
	phase = ENDED
	res.elapsedS = elapsedS
	res.clockS = clockS
	res.tally = scorebook.raw()
	result = res
	_emit(Bus.MATCH_END, result)
	_emit_state()

func _decide() -> void:
	var j := scorebook.judge(seed_value)
	_end({
		"method": DECISION, "reason": "time",
		"winnerId": j.winnerId, "loserId": j.loserId,
		"decision": j.decision, "cards": j.cards, "votes": j.votes,
	})

## `countdown` false goes straight to live (headless bouts).
func start(countdown := true) -> void:
	phase = COUNTDOWN if countdown else LIVE
	clockS = config.durationS
	countdownS = config.countdownS if countdown else 0.0
	elapsedS = 0.0
	result = null
	pin = null
	for id in bot_ids: _bots[id] = _fresh_bot(id)
	scorebook.reset()
	_emit_state()

func toggle_pause() -> void:
	if phase == LIVE: phase = PAUSED
	elif phase == PAUSED: phase = LIVE
	else: return
	_emit_state()

## The referee's read on one robot this step.
##   m.able     it physically CAN drive: upright, wheels down, drive alive
##   m.trying   its driver is asking it to move
##   m.moving   it is translating or turning
##   m.pinned   held down by the opponent - no count while pinned
##   m.engaged  in contact with the opponent: a shoving match is a fight
## The count runs when a robot cannot drive, or is trying and getting nowhere.
## A robot sitting still by its driver's choice is NOT counted.
func report_mobility(bot_id, m: Dictionary, dt: float) -> void:
	var b = _bots.get(bot_id)
	if b == null or phase != LIVE or b.countedOut: return
	# Some things need no count - down the pit is out.
	if J.truthy(m.get("out")):
		b.cause = J.g(m, "cause", "pitted")
		b.countedOut = true
		_emit(Bus.KO, {"botId": bot_id})
		_end({"method": KO, "reason": "ko", "cause": b.cause, "winnerId": other(bot_id), "loserId": bot_id})
		return
	var able := J.truthy(m.get("able"))
	var trying := J.truthy(m.get("trying"))
	var moving := J.truthy(m.get("moving"))
	var pinned := J.truthy(m.get("pinned"))
	var engaged := J.truthy(m.get("engaged"))
	var stuck := (not pinned) and ((not able) or (trying and not moving and not engaged))
	if stuck: b.cause = "stuck" if able else J.g(m, "cause", "disabled")
	var showing_movement := able and moving

	if stuck:
		b.stuckS += dt
		b.recoverS = 0.0
	elif showing_movement or not trying:
		# Controlled movement - or simply not trying while able - ends a
		# count, after a beat so a single twitch does not.
		b.recoverS += dt
		if b.recoverS >= config.recoverS or b.countS == 0:
			b.stuckS = 0.0; b.countS = 0.0; b.lastAnnounced = 0
	b.countS = maxf(0.0, b.stuckS - config.countGraceS)

	var n := int(floor(b.countS + TIME_EPS))
	if n > b.lastAnnounced:
		b.lastAnnounced = n
		_emit(Bus.REF_COUNT, {"botId": bot_id, "count": n, "of": config.countS})
	if b.countS >= config.countS - TIME_EPS:
		b.countedOut = true
		_emit(Bus.KO, {"botId": bot_id})
		_end({"method": KO, "reason": "ko", "cause": b.cause if b.cause != null else "disabled", "winnerId": other(bot_id), "loserId": bot_id})

## Who, if anyone, is pinning whom this step. After `pinLimitS` the pinner is
## told to release; if it is still holding `pinReleaseS` later it loses
## control points, and is told again.
func report_pin(pinner_id, pinned_id, dt: float) -> void:
	if phase != LIVE: return
	if pinner_id == null:
		pin = null
		return
	var p = pin
	if p == null or p.pinnerId != pinner_id or p.pinnedId != pinned_id:
		pin = {"pinnerId": pinner_id, "pinnedId": pinned_id, "heldS": 0.0, "warned": false, "sinceWarnS": 0.0}
		return
	p.heldS += dt
	if not p.warned and p.heldS >= config.pinLimitS:
		p.warned = true; p.sinceWarnS = 0.0
		_emit(Bus.PIN_WARNING, {"botId": pinner_id, "pinnedId": pinned_id})
	elif p.warned:
		p.sinceWarnS += dt
		if p.sinceWarnS >= config.pinReleaseS:
			scorebook.record_pin_penalty(pinner_id)
			_emit(Bus.PIN_PENALTY, {"botId": pinner_id, "pinnedId": pinned_id})
			p.sinceWarnS = 0.0

## A team concedes.
func tap_out(bot_id) -> bool:
	if not config.tapOutAllowed or phase != LIVE: return false
	var b = _bots.get(bot_id)
	if b == null: return false
	b.tappedOut = true
	_emit(Bus.TAP_OUT, {"botId": bot_id})
	_end({"method": TAPOUT, "reason": "tapout", "winnerId": other(bot_id), "loserId": bot_id})
	return true

## Advance the clock. Returns the phase after the step.
func update(dt: float) -> String:
	if phase == COUNTDOWN:
		countdownS -= dt
		if countdownS <= 0:
			countdownS = 0.0
			phase = LIVE
		_emit_state()
		return phase

	if phase != LIVE: return phase

	clockS -= dt
	elapsedS += dt
	if clockS <= TIME_EPS:
		clockS = 0.0
		_decide()
		return phase
	_emit_state()
	return phase
