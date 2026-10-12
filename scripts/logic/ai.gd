## ai.gd - the AI driver.
##
## Pure logic. It reads a plain PERCEPTION of the fight (built by
## sim/ai_bridge.gd from the physics state) and writes the same DriveInput a
## keyboard does - { throttle, steer, brake, weapon } - so the AI and the
## human are interchangeable mid-match.
##
## Who it is comes from the robot file:
##   personality   aggressive | defensive | opportunistic  - WHAT it tries to do
##   rating/league                                          - HOW WELL it does it
##
## Skill is not a cheat dial. A low-rated AI sees the opponent late, aims with
## a wandering error, reads hazards poorly, mistimes its weapon and fumbles. A
## world-class AI leads its target, flanks spinners, waits for a full spool
## and pushes you into the pulverizer.
##
## Positions in a perception are Vector2 on the floor plane: (x, z) held as
## (x, y). Bot forward is local +X; heading = (cos yaw, -sin yaw).
class_name AI
extends RefCounted

const SPOOL := "spool"          # kinetic weapon not up to speed: stay away and spin
const ENGAGE := "engage"        # drive at the attack point
const BACKOFF := "backoff"      # just traded a hit: open the gap and reset
const CIRCLE := "circle"        # hold a standoff and wait for an opening
const UNSTICK := "unstick"      # pinned or wedged: reverse out

## Personality: the shape of the plan. All numbers 0..1 or seconds.
const PERSONALITY := {
	"aggressive": {
		"spoolThreshold": 0.55, "backoffS": 0.35, "standoffM": 1.6, "flankBias": 0.25, "herdBias": 0.45,
		"patienceS": 0.6, "riskTolerance": 0.75, "shoveS": 2.6, "tapOutHealth": 0.1,
	},
	"defensive": {
		"spoolThreshold": 0.95, "backoffS": 1.4, "standoffM": 3.0, "flankBias": 0.7, "herdBias": 0.35,
		"patienceS": 3.5, "riskTolerance": 0.2, "shoveS": 0.9, "tapOutHealth": 0.32,
	},
	"opportunistic": {
		"spoolThreshold": 0.8, "backoffS": 0.8, "standoffM": 2.3, "flankBias": 0.9, "herdBias": 0.9,
		"patienceS": 1.8, "riskTolerance": 0.45, "shoveS": 1.5, "tapOutHealth": 0.22,
	},
}

## What the weapon asks of the driver, on top of the personality.
const PLAYBOOK := {
	"wedge": {"herdBias": 0.95, "shoveMul": 2.2, "backoffMul": 0.5, "flankBias": 0.8},
	"lifter": {"herdBias": 0.6, "shoveMul": 1.2},
	"crusher": {"herdBias": 0.7, "shoveMul": 1.4},
}

## League floor and ceiling on skill, so a 45-rated world bot is still a pro.
const LEAGUE_BAND := {
	"rookie": [0.15, 0.55],
	"pro": [0.35, 0.72],
	"elite": [0.55, 0.88],
	"world": [0.7, 1.0],
}

static func _num(d, k, def := 0.0) -> float:
	var v = d.get(k) if d is Dictionary else null
	return def if v == null else float(v)

## Turn a robot's personality, rating and league into concrete driving numbers.
static func ai_profile(robot = null) -> Dictionary:
	var r: Dictionary = robot if robot is Dictionary else {}
	var personality = J.g(r, "personality", "opportunistic")
	var rating: float = J.g(r, "rating", 50.0)
	var league = J.g(r, "league", "rookie")
	var archetype = r.get("archetype")
	var skill_bonus: float = J.g(r, "skillBonus", 0.0)
	var t: Dictionary = J.g(r, "tactics", {})

	var pers: Dictionary = PERSONALITY.get(personality, PERSONALITY.opportunistic)
	var pb: Dictionary = PLAYBOOK.get(archetype, {}) if archetype != null else {}
	var t_aggr := _num(t, "aggression")
	var out := pers.duplicate()
	out.herdBias = clampf(maxf(pers.herdBias, _num(pb, "herdBias")) + _num(t, "herd"), 0.0, 1.0)
	out.flankBias = clampf(maxf(pers.flankBias, _num(pb, "flankBias")) + _num(t, "flank"), 0.0, 1.0)
	out.shoveS = pers.shoveS * _num(pb, "shoveMul", 1.0) * (1.0 + t_aggr)
	out.backoffS = pers.backoffS * _num(pb, "backoffMul", 1.0) * clampf(1.0 - t_aggr, 0.3, 2.0)
	out.spoolThreshold = clampf(pers.spoolThreshold - t_aggr * 0.3, 0.3, 0.98)

	var band: Array = LEAGUE_BAND.get(league, LEAGUE_BAND.rookie)
	var lo: float = band[0]
	var hi: float = band[1]
	# `skillBonus` is the difficulty setting, in fights against the player.
	var skill := clampf(lo + (hi - lo) * clampf(rating / 100.0, 0.0, 1.0) + skill_bonus, 0.0, 1.0)
	out.personality = personality if PERSONALITY.has(personality) else "opportunistic"
	out.skill = skill
	# How stale its picture of the opponent is.
	out.reactionS = lerpf(0.38, 0.05, skill)
	# Slowly wandering heading error, radians.
	out.aimNoiseRad = lerpf(0.32, 0.03, skill)
	# How far ahead it predicts the opponent's motion. Rookies chase where you WERE.
	out.lead = lerpf(0.0, 0.9, skill)
	# Steering sharpness. Too low overshoots; rookies also saw-tooth.
	out.steerGain = lerpf(1.15, 2.4, skill)
	# How strongly it reads and respects hazards (and uses them on you).
	out.hazardSense = lerpf(0.15, 1.0, skill)
	# Weapon timing error, seconds early/late on a discrete weapon.
	out.triggerJitterS = lerpf(0.22, 0.02, skill)
	# Chance per second of a brief fumble (a wrong-way twitch).
	out.fumblePerS = lerpf(0.35, 0.0, skill)
	# Whether it will deliberately come at a spinner from the side.
	out.flanks = skill > 0.45 or _num(t, "flank") > 0.15
	return out

# ---------------------------------------------------------------- the driver

var base: Dictionary          # who the driver is
var prof: Dictionary          # the profile as adjusted for the scorecard this step
var rng: Rng
var state: String = ENGAGE

var _live := {"flank": 0.0, "aggression": 0.0, "exchanges": 0, "landed": 0, "took": 0}
var _lr := 0.0
var _state_t := 0.0
var _clock := 0.0
var _aim_err := 0.0             # current wandering aim error, radians
var _fumble_t := 0.0            # seconds of fumble remaining
var _fumble_steer := 0.0
var _stuck_t := 0.0
var _unstick_dir := 1.0
var _circle_dir := 1.0
var _trigger_plan_t = null      # discrete weapon: when to fire
var _my_family := "none"
var _my_archetype = null
var _last_throttle := 0.0       # its own last commands, for stuck detection
var _last_steer := 0.0
var _shove_t := 0.0             # seconds in a pushing match going nowhere
var _outgun_t := 0.0            # seconds spent declining a losing exchange
var _tap_check_t := 0.0
var _tapped_out := false
var _history := []              # [{ t, pos, vel }] of the opponent, for lag

## opts: { robot, rng, learnRate }
func _init(opts: Dictionary) -> void:
	var robot: Dictionary = opts.robot
	rng = opts.rng
	var learn_rate: float = opts.get("learnRate", J.g(robot, "learnRate", 0.7))
	base = ai_profile(robot)
	prof = base
	# Learning in the fight: every exchange teaches it whether its approach
	# is working. A better driver, and a harder difficulty, learns faster.
	_lr = clampf(learn_rate * (0.4 + base.skill), 0.0, 2.0) * 0.06
	_circle_dir = 1.0 if rng.bool_p() else -1.0

static func make(opts: Dictionary) -> AI:
	return AI.new(opts)

var profile: Dictionary:
	get: return base

## The profile as the scorecard has bent it this step.
var tactics_now: Dictionary:
	get: return prof

## What it has learned so far this fight (the career keeps it, ailearn.gd).
var learned: Dictionary:
	get: return {"flank": _live.flank, "aggression": _live.aggression, "landed": _live.landed, "took": _live.took}

func _set_state(s: String) -> void:
	if s != state:
		state = s
		_state_t = 0.0

## One exchange's lesson. The approach it was using gets the credit or the blame.
func _learn(ev: Dictionary) -> void:
	_live.exchanges += 1
	var flanking: bool = state == CIRCLE or (prof.flanks and prof.flankBias + _live.flank > 0.5)
	if J.truthy(ev.get("took")):
		_live.took += 1
		# Hurt coming straight in: go round. Hurt while circling: commit.
		if flanking: _live.aggression += _lr * 0.6
		else: _live.flank += _lr
	if J.truthy(ev.get("landed")):
		_live.landed += 1
		_live.aggression += _lr * 0.5
		if flanking: _live.flank += _lr * 0.3
		else: _live.flank -= _lr * 0.3
	_live.flank = clampf(_live.flank, -0.35, 0.45)
	_live.aggression = clampf(_live.aggression, -0.35, 0.45)

## The profile with this fight's lessons applied.
func _adjusted(pr: Dictionary) -> Dictionary:
	if _live.exchanges == 0: return pr
	var o := pr.duplicate()
	o.flankBias = clampf(pr.flankBias + _live.flank, 0.0, 1.0)
	o.flanks = pr.flanks or _live.flank > 0.15
	o.backoffS = pr.backoffS * clampf(1.0 - _live.aggression, 0.3, 2.0)
	o.spoolThreshold = clampf(pr.spoolThreshold - _live.aggression * 0.3, 0.3, 0.98)
	o.patienceS = pr.patienceS * clampf(1.0 - _live.aggression, 0.3, 2.0)
	return o

## The opponent as this AI perceives it: `reactionS` old.
func _perceived_opponent(opp: Dictionary) -> Dictionary:
	_history.append({"t": _clock, "pos": opp.pos, "vel": opp.vel})
	while _history.size() > 2 and _history[1].t <= _clock - prof.reactionS:
		_history.pop_front()
	var h: Dictionary = _history[0]
	# Dead-reckon the stale sample forward by how stale it is.
	var age: float = _clock - h.t
	var k: float = prof.skill
	var o := opp.duplicate()
	o.pos = h.pos + h.vel * (age * k)
	o.vel = h.vel
	return o

## Tell the AI something happened to it. Combat events feed this.
func notify(event: Dictionary) -> void:
	# Told to let go of a pin: let go, and come again from the other side.
	if event.get("type") == "pinWarning":
		_circle_dir = -_circle_dir
		_set_state(BACKOFF)
		return
	var landed := J.truthy(event.get("landed"))
	var took := J.truthy(event.get("took"))
	if event.get("type") == "hit" and (landed or took):
		# Only weapon hits teach it about its approach.
		if event.get("kind") == null or event.get("kind") == "weapon": _learn(event)
		# A crusher that has bitten, or a lifter with its forks under
		# something, hangs on and carries it.
		var holding: bool = landed and (_my_family == "crusher" or _my_archetype == "lifter")
		# Traded blows: reset, unless this personality never lets up.
		if prof.backoffS > 0.01 and not holding: _set_state(BACKOFF)
		if took: _circle_dir = -_circle_dir

func reset() -> void:
	_live = {"flank": 0.0, "aggression": 0.0, "exchanges": 0, "landed": 0, "took": 0}
	state = ENGAGE; _state_t = 0.0; _clock = 0.0; _aim_err = 0.0
	_fumble_t = 0.0; _stuck_t = 0.0; _trigger_plan_t = null; _history.clear()
	_last_throttle = 0.0; _last_steer = 0.0; _shove_t = 0.0; _outgun_t = 0.0
	_tap_check_t = 0.0; _tapped_out = false; prof = base

## One decision. `p` is a perception - see sim/ai_bridge.gd for the shape.
## Returns a DriveInput dictionary.
func drive(p: Dictionary, dt: float) -> Dictionary:
	var me: Dictionary = p.me
	_my_family = me.family
	_my_archetype = me.get("archetype")
	_clock += dt
	_state_t += dt
	prof = _adjusted(tactics(base, p))
	var opp := _perceived_opponent(p.opponent)

	# ---- flipped. A bot that can right itself does that before anything else.
	if J.g(me, "upright", 1.0) < 0.4 and not J.truthy(me.get("inverted")) and J.truthy(me.get("canSelfRight")):
		_last_throttle = 0.0; _last_steer = 0.0
		return {"throttle": 0.0, "steer": 0.0, "brake": false, "weapon": 0.0, "selfRight": true, "tapOut": false}

	# ---- noise processes. An Ornstein-Uhlenbeck wander for aim, so the error
	# drifts like a hand on a stick instead of jittering per frame.
	_aim_err += (-_aim_err * 1.6 + (rng.next() - 0.5) * 2.0 * prof.aimNoiseRad * 4.0) * dt
	if _fumble_t > 0: _fumble_t -= dt
	elif rng.next() < prof.fumblePerS * dt:
		_fumble_t = 0.12 + rng.next() * 0.25
		_fumble_steer = 1.0 if rng.bool_p() else -1.0

	var my_pos: Vector2 = me.pos
	var to_opp: Vector2 = opp.pos - my_pos
	var dist := to_opp.length()
	var contact_dist: float = me.halfLenM + opp.halfLenM
	var gap := maxf(0.0, dist - contact_dist)

	# ---- stuck detection: asking for drive or a turn and getting neither.
	var asking := absf(_last_throttle) > 0.4 or absf(_last_steer) > 0.6
	var going: bool = me.speed > 0.2 or absf(J.g(me, "yawRate", 1.0)) > 0.35
	if state != UNSTICK and asking and not going and gap > 0.2:
		_stuck_t += dt
	elif state != UNSTICK:
		_stuck_t = maxf(0.0, _stuck_t - dt * 2.0)
	if _stuck_t > lerpf(1.3, 0.5, prof.skill):
		_set_state(UNSTICK)
		_unstick_dir = -1.0 if _last_throttle > 0 else 1.0
		_stuck_t = 0.0

	# ---- stalled pushing match: nose to nose, nobody moving. Break off and
	# come again from a new angle - a pro sooner than a rookie.
	if state == ENGAGE and gap < 0.2 and me.speed < 0.3 and opp.speed < 0.3: _shove_t += dt
	else: _shove_t = maxf(0.0, _shove_t - dt)
	if _shove_t > prof.shoveS * lerpf(1.4, 0.7, prof.skill):
		_shove_t = 0.0
		_circle_dir = -_circle_dir
		_set_state(BACKOFF)

	# ---- choose the state.
	var kinetic: bool = me.family == "kinetic"
	# Spinner-on-spinner, whoever has more energy in the rotor at contact wins
	# the exchange. A thinking driver does not trade hits while outgunned, and
	# pounces the moment the other rotor is spent.
	var ratio: float = (opp.energyJ + 1.0) / (me.energyJ + 1.0) if (opp.family == "kinetic" and kinetic) else 0.0
	var reads_energy: bool = prof.skill > 0.45
	var outgunned: bool = reads_energy and ratio > (1.9 if prof.personality == "aggressive" else 1.2) \
		and me.spinPct < 0.97 and _outgun_t < lerpf(3.0, 7.0, prof.skill)
	_outgun_t = _outgun_t + dt if outgunned else maxf(0.0, _outgun_t - dt * 0.5)
	var pounce: bool = reads_energy and ratio > 0 and ratio < 0.45 and me.spinPct > 0.35
	var spooled: bool = (not kinetic) or J.truthy(me.get("weaponDead")) or pounce \
		or (me.spinPct >= prof.spoolThreshold and not outgunned)
	match state:
		UNSTICK:
			if _state_t > 1.2 or (_state_t > 0.5 and me.speed > 0.4): _set_state(ENGAGE)
		BACKOFF:
			if _state_t > prof.backoffS or (pounce and _state_t > 0.2): _set_state(ENGAGE if spooled else SPOOL)
		SPOOL:
			if spooled: _set_state(ENGAGE)
		CIRCLE:
			# Strike when the opening shows, or when patience runs out.
			if not spooled: _set_state(SPOOL)
			elif pounce or _opening(me, opp) or _state_t > prof.patienceS: _set_state(ENGAGE)
		_:
			if not spooled: _set_state(SPOOL)
			# Don't charge a live spinner's face unless you win the exchange.
			elif opp.family == "kinetic" and opp.spinPct > 0.5 and not pounce \
					and (prof.flankBias > 0.6 or prof.skill > 0.6) and not (ratio > 0 and ratio < 0.8) \
					and _facing(opp, me) and gap > 0.8 and gap < prof.standoffM + 1.5 and _state_t > 0.5:
				_set_state(CIRCLE)

	# ---- where it wants to go.
	var want := Vector2.ZERO
	var throttle_cap := 1.0
	var reverse := false
	match state:
		UNSTICK:
			# Back out turning. If it is beached with wheels in the air, rock
			# it - forward, back, forward - which is how drivers shake free.
			var beached: bool = J.g(me, "wheelsDown", 4) < 3
			var dir := _unstick_dir
			if beached and int(floor(_state_t / 0.3)) % 2 == 1: dir = -_unstick_dir
			_last_throttle = dir
			_last_steer = 0.8 * _circle_dir
			return {
				"throttle": dir, "steer": _last_steer, "brake": false,
				"weapon": _weapon_demand(me, opp, gap, 0.0),
				"tapOut": _consider_tap_out(p, dt),
			}
		SPOOL, BACKOFF:
			# Away from the opponent, curving round so it does not run itself
			# into a wall. Faster away when the opponent is close.
			var away := _norm(-to_opp)
			var side := Vector2(-away.y * _circle_dir, away.x * _circle_dir)
			var keep: float = prof.standoffM + 1.5 if state == SPOOL else prof.standoffM
			var k := clampf((keep - gap) / keep, 0.0, 1.0)
			want = _norm(away * k + side * (1.0 - k * 0.5))
			throttle_cap = 1.0 if state == BACKOFF else lerpf(0.45, 0.85, k)
			# Fresh off a hit, just reverse out rather than turning round.
			if state == BACKOFF and _state_t < minf(0.45, prof.backoffS): reverse = true
		CIRCLE:
			# Orbit at the standoff distance, drifting toward the opponent's flank.
			var n := _norm(to_opp)
			var tangent := Vector2(-n.y * _circle_dir, n.x * _circle_dir)
			var radial := clampf((gap - prof.standoffM) / prof.standoffM, -1.0, 1.0)
			want = _norm(tangent + n * (radial * 1.5))
			throttle_cap = 0.75
		_:
			# Never aim at a point the bot cannot physically reach: a target
			# tight to the wall is driven at as if it were a little inboard.
			var ap := _attack_point(me, opp, gap, p)
			var lim_x: float = p.arena.halfX - me.halfLenM - 0.15
			var lim_z: float = p.arena.halfZ - me.halfLenM - 0.15
			ap.x = clampf(ap.x, -lim_x, lim_x)
			ap.y = clampf(ap.y, -lim_z, lim_z)
			want = _norm(ap - my_pos)

	# ---- hazards and walls bend the path.
	var avoid := _hazard_avoidance(me, p, prof, gap if state == ENGAGE else INF)
	want = _norm(want + avoid)

	# ---- steer to it, with the wandering aim error on top.
	var bearing := bearing_to(me.yaw, want) + _aim_err
	if reverse: bearing = _wrap_pi(bearing + PI)   # aim the TAIL down the path
	var steer := clampf(-bearing * prof.steerGain, -1.0, 1.0)
	# Turn first when far off line, then drive.
	var align := cos(bearing)
	var throttle := (align if align > 0 else align * 0.3) * throttle_cap
	if absf(bearing) > lerpf(1.0, 1.35, prof.skill): throttle *= 0.15
	if reverse: throttle = -absf(throttle if throttle != 0.0 else 0.8)

	# ---- don't drive into the wall at full speed. Look ahead along the nose.
	var ahead := lerpf(0.35, 0.9, prof.skill)
	var hx := cos(me.yaw)
	var hz := -sin(me.yaw)
	var sgn := 1.0 if throttle >= 0 else -1.0
	var reach_x: float = my_pos.x + hx * sgn * (me.halfLenM + me.speed * ahead)
	var reach_z: float = my_pos.y + hz * sgn * (me.halfLenM + me.speed * ahead)
	var over := maxf(absf(reach_x) - p.arena.halfX, absf(reach_z) - p.arena.halfZ)
	# ...unless it is pinning the opponent there, which is the point.
	if over > -0.2 and not (state == ENGAGE and gap < 0.5):
		throttle *= clampf(-over / 0.6, 0.15, 1.0)
	# ...and never over the edge of an open pit.
	for h in p.hazards:
		if h.get("kind") != "pit" or h.danger < 0.9: continue
		var edge: float = dist_to_zone(Vector2(reach_x, reach_z), h).dist
		if edge < 0.35: throttle *= clampf(edge / 0.35, 0.0, 1.0)

	if _fumble_t > 0: steer = _fumble_steer
	_last_throttle = clampf(throttle, -1.0, 1.0)
	_last_steer = steer

	return {
		"throttle": _last_throttle, "steer": steer, "brake": false,
		"weapon": _weapon_demand(me, opp, gap, bearing_to(me.yaw, _norm(to_opp))),
		"tapOut": _consider_tap_out(p, dt),
	}

## Concede? Only when losing, badly hurt, against an opponent that is still
## dangerous, and with enough time left that hanging on would cost more.
func _consider_tap_out(p: Dictionary, dt: float) -> bool:
	if _tapped_out: return true
	_tap_check_t += dt
	if _tap_check_t < 1: return false
	_tap_check_t = 0.0
	var me: Dictionary = p.me
	var opp: Dictionary = p.opponent
	var hurt: bool = J.g(me, "health", 1.0) < base.tapOutHealth
	var losing: bool = J.g(p, "lead", 0.0) < -0.1
	var they_can_hurt_me: bool = not J.truthy(opp.get("weaponDead")) and opp.family != "none"
	var time_left: bool = J.g(p, "remainingS", 0.0) > 20
	var outclassed: bool = J.g(opp, "health", 1.0) > J.g(me, "health", 1.0) + 0.25
	if hurt and losing and they_can_hurt_me and time_left and outclassed: _tapped_out = true
	return _tapped_out

## How hard to run the weapon.
func _weapon_demand(me: Dictionary, _opp: Dictionary, gap: float, bearing_to_opp: float) -> float:
	if me.family == "kinetic": return 1.0               # always spooling
	if me.family == "none" or J.truthy(me.get("weaponDead")): return 0.0
	var reach_m: float = J.g(me, "reachM", 0.0)
	var in_reach := gap < reach_m + 0.08 and absf(bearing_to_opp) < 0.45
	if me.family == "crusher":
		# Close as it comes into the jaw, and keep it shut on a robot it holds.
		var near := gap < reach_m + 0.08 and absf(bearing_to_opp) < 0.6
		var wp = me.get("weaponPhase")
		var holding: bool = (wp == "closed" or wp == "striking") and gap < reach_m + 0.3
		return 1.0 if (near or holding) else 0.0
	# Discrete: plan a trigger time when the opponent comes into reach, with a
	# timing error that shrinks with skill. A rookie fires early and whiffs.
	if not J.truthy(me.get("weaponReady")):
		_trigger_plan_t = null
		return 0.0
	var closing_in := gap < reach_m + 0.6 and absf(bearing_to_opp) < 0.6
	if closing_in and _trigger_plan_t == null:
		_trigger_plan_t = _clock + maxf(0.0, (rng.next() - 0.5) * 2.0 * prof.triggerJitterS)
	if not closing_in: _trigger_plan_t = null
	if _trigger_plan_t != null and _clock >= _trigger_plan_t and (in_reach or rng.next() < 0.5 - prof.skill * 0.5):
		_trigger_plan_t = null
		return 1.0
	return 0.0

## The point it actually drives at. Starts as the opponent, then leads a
## moving target (skill), swings round to a flank against a front-weapon bot
## (personality x skill), and picks an angle that shoves the opponent toward
## a live hazard (herding).
func _attack_point(me: Dictionary, opp: Dictionary, gap: float, p: Dictionary) -> Vector2:
	var close_t: float = gap / maxf(1.0, me.topSpeed * 0.8)
	var lead := minf(1.0, close_t * prof.lead)
	var opp_pos: Vector2 = opp.pos
	var opp_vel: Vector2 = opp.vel
	var target := opp_pos + opp_vel * lead

	# Flanking.
	var opp_fwd := Vector2(cos(opp.yaw), -sin(opp.yaw))
	var front_danger: float = (opp.spinPct if opp.family == "kinetic" else 0.5) * (1.0 if J.truthy(opp.get("frontWeapon")) else 0.3)
	if prof.flanks and gap > 0.6 and front_danger > 0.3:
		# Which flank is nearer to us.
		var rel: Vector2 = me.pos - opp_pos
		var side_sign := 1.0 if opp_fwd.x * rel.y - opp_fwd.y * rel.x > 0 else -1.0
		var flank_dir := Vector2(-opp_fwd.y * side_sign, opp_fwd.x * side_sign)
		var bias: float = maxf(prof.flankBias, lerpf(0.4, 0.85, (prof.skill - 0.6) / 0.4) if prof.skill > 0.6 else 0.0)
		var wide := clampf(gap / 3.0, 0.0, 1.0) * bias * front_danger
		# Aim between its side and its rear, further out while far away.
		var off: float = (opp.halfLenM + 0.9) * wide
		target += (flank_dir - opp_fwd * 0.6) * off

	# Herding: come at it from the side opposite a live hazard, so the shove
	# carries it in. Only once it is close enough that a shove is coming.
	if gap < 3.0 and prof.herdBias * prof.hazardSense > 0.25:
		var h = _best_herd_target(opp, p.hazards)
		if h != null:
			var push := _norm(h - opp_pos)
			# Stand-off point behind the opponent along the push line.
			var contact: float = me.halfLenM + opp.halfLenM
			var behind := opp_pos - push * (contact + 0.4)
			var w: float = prof.herdBias * prof.hazardSense * clampf((3.0 - gap) / 2.0, 0.0, 1.0)
			# Once lined up behind it, drive THROUGH it toward the hazard.
			var lined: bool = _norm(opp_pos - me.pos).dot(push) > 0.85
			var goal := opp_pos + push if lined else behind
			target = target.lerp(goal, w)
	return target

## Bend the profile to the scorecard. Behind on points in the closing minute,
## any driver takes more risk; ahead late, the cautious personalities protect
## the lead. Skill decides how well it reads the scorecard at all.
static func tactics(b: Dictionary, p: Dictionary) -> Dictionary:
	var remaining: float = J.g(p, "remainingS", INF)
	var lead: float = J.g(p, "lead", 0.0) * clampf(b.skill * 1.4, 0.3, 1.0)
	if remaining > 60: return b
	var late := clampf((60.0 - remaining) / 60.0, 0.0, 1.0)
	if lead < -0.08:
		var u := clampf(late * 0.7 + 0.3, 0.0, 1.0) * clampf(-lead * 4.0, 0.0, 1.0)
		var o := b.duplicate()
		o.spoolThreshold = b.spoolThreshold - 0.3 * u
		o.backoffS = b.backoffS * (1.0 - 0.6 * u)
		o.patienceS = b.patienceS * (1.0 - 0.7 * u)
		o.riskTolerance = clampf(b.riskTolerance + 0.35 * u, 0.0, 1.0)
		o.shoveS = b.shoveS * (1.0 + u)
		o.urgency = u
		return o
	if lead > 0.12 and b.personality != "aggressive":
		var u := late * clampf(lead * 3.0, 0.0, 1.0)
		var o := b.duplicate()
		o.spoolThreshold = minf(0.98, b.spoolThreshold + 0.1 * u)
		o.backoffS = b.backoffS * (1.0 + 0.5 * u)
		o.patienceS = b.patienceS * (1.0 + u)
		o.riskTolerance = b.riskTolerance * (1.0 - 0.5 * u)
		o.urgency = -u
		return o
	return b

## Is `a` pointing its front at `b`?
static func _facing(a: Dictionary, b: Dictionary) -> bool:
	var f := Vector2(cos(a.yaw), -sin(a.yaw))
	return f.dot(_norm(b.pos - a.pos)) > 0.6

## A moment worth attacking: it is facing away, stuck, or its weapon is down.
static func _opening(me: Dictionary, opp: Dictionary) -> bool:
	if not _facing(opp, me): return true
	if opp.speed < 0.15: return true
	if opp.family == "kinetic" and opp.spinPct < 0.35: return true
	if opp.family == "discrete" and not J.truthy(opp.get("weaponReady")): return true
	return false

## Steering push away from hazards and walls. Each danger zone is a circle or
## a capsule from the perception; danger 0..1 scales it.
static func _hazard_avoidance(me: Dictionary, p: Dictionary, pr: Dictionary, gap_to_opp: float) -> Vector2:
	var out := Vector2.ZERO
	# A risk-taker with the opponent right there will take a hazard on.
	var urgency: float = pr.riskTolerance if gap_to_opp < 1.2 else 0.0
	var sense: float = pr.hazardSense * (1.0 - urgency * 0.7)
	var hx := cos(me.yaw)
	var hz := -sin(me.yaw)
	var pos: Vector2 = me.pos
	for h in p.hazards:
		var d := dist_to_zone(pos, h)
		# An open pit ends the fight: nobody is too green to see a hole in the
		# floor, and it also steers round it on whichever side it is pointing.
		var lethal: bool = h.get("kind") == "pit"
		var reach: float = h.radius + me.halfLenM + (1.6 if lethal else 1.2)
		if d.dist > reach: continue
		var s: float = maxf(0.65, pr.hazardSense) if lethal else sense
		var k: float = pow((reach - d.dist) / reach, 2.0) * h.danger * s * (6.0 if lethal else 3.0)
		var away: Vector2 = d.away
		out += away * k
		if lethal:
			var side := 1.0 if (-away.y * hx + away.x * hz) >= 0 else -1.0
			out.x += -away.y * side * k * 0.9
			out.y += away.x * side * k * 0.9
	# Walls: a gentle push inward near them, so it does not grind the kickplate.
	var m: float = 1.1 + me.halfLenM
	var ax: float = p.arena.halfX
	var az: float = p.arena.halfZ
	if pos.x > ax - m: out.x -= ((pos.x - (ax - m)) / m) * 1.5
	if pos.x < -ax + m: out.x += ((-ax + m - pos.x) / m) * 1.5
	if pos.y > az - m: out.y -= ((pos.y - (az - m)) / m) * 1.5
	if pos.y < -az + m: out.y += ((-az + m - pos.y) / m) * 1.5
	return out

## The hazard this opponent is best shoved into, if any is close enough.
## Returns its centre (Vector2) or null.
static func _best_herd_target(opp: Dictionary, hazards: Array):
	var best = null
	var best_score := 0.0
	for h in hazards:
		if h.danger < 0.5: continue
		var d: float = dist_to_zone(opp.pos, h).dist
		if d > 4.0: continue
		# A pit ends the fight on the spot; a pulverizer hits harder than the rest.
		var kind = h.get("kind")
		var score: float = h.danger * (1.0 - d / 4.0) * (1.8 if kind == "pit" else (1.4 if kind == "pulverizer" else 1.0))
		if score > best_score:
			best_score = score
			best = h.center
	return best

## Distance from a point to a hazard zone (circle, or capsule for screws).
## Returns { dist, away }.
static func dist_to_zone(pt: Vector2, h: Dictionary) -> Dictionary:
	var c: Vector2
	var seg = h.get("segment")
	if seg != null:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var ab := b - a
		var t := clampf((pt - a).dot(ab) / maxf(1e-6, ab.dot(ab)), 0.0, 1.0)
		c = a + ab * t
	else:
		c = h.center
	var v := pt - c
	var l := v.length()
	return {"dist": maxf(0.0, l - h.radius), "away": v / l if l > 1e-6 else Vector2(1, 0)}

## Signed angle from the bot's heading to a direction. Bot forward is local +X.
static func bearing_to(yaw: float, dir: Vector2) -> float:
	var hx := cos(yaw)
	var hz := -sin(yaw)
	return atan2(hx * dir.y - hz * dir.x, hx * dir.x + hz * dir.y)

static func _wrap_pi(a: float) -> float:
	return atan2(sin(a), cos(a))

static func _norm(v: Vector2) -> Vector2:
	var l := v.length()
	return v / l if l > 1e-9 else Vector2.ZERO
