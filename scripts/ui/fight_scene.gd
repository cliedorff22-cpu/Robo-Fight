## fight_scene.gd - the fight on screen: boot and the frame loop.
##
## The only file that knows about all the layers at once. Its job is wiring:
##
##   data   -> scripts/data     JSON in, indexed registry out
##   logic  -> scripts/logic    build stats, rule checks, match clock
##   sim    -> scripts/sim      physics bodies, the wheel model, hazards (Fight)
##   render -> scripts/render   the arena, the robots, cameras, effects
##   ui     -> scripts/ui       the HUD, the booth, the pause screen
##
## What to fight comes in Game.request:
##   red, blue          robot ids (red is the one you drive)
##   driver: "ai"       the AI drives red too
##   p2: true           two players on one keyboard - Player 2 drives blue
##   seed               fix the session seed, to reproduce a match exactly
##   venue, layout      where ("random" draws a layout from the venue's pool)
##   mode               "quick" (default), "career", "tourney" or "scout"
##   career / tourney / scout   that mode's hand-off (see the menus)
## and a career or tournament result goes back in Game.result.
class_name FightScene
extends Node3D

const DEFAULT_RED := "player_default"
const DEFAULT_OPPONENT := "spinner_test"
const REPLAY_SECONDS := 6.0
# Playback speed: the hit of the match in deep slow motion, the rest quicker
# so the reel stays around 20 s. P skips it.
const BEST_SPEED := 0.45
const REEL_SPEED := 0.7
const WEAPON_WORDS := {"spinner_v": "vertical spinner", "spinner_h": "horizontal spinner", "drum": "drum", "hammer": "hammer",
	"flipper": "flipper", "lifter": "lifter", "crusher": "crusher"}

var fight: Fight
var stage: Stage
var arena_view: ArenaView
var venue_view: Node3D = null
var cam: CameraRig
var effects: Effects
var marks: DeckMarks
var hud: Hud
var booth: Booth
var audio: GameAudio
var speech: Speech
var commentary: Commentary
var views := {}                # robot id -> RobotView

var _req: Dictionary
var _mode := "quick"
var _career = null             # the career's hand-off, or null
var _tourney = null
var _scout = null
var _player_id := DEFAULT_RED
var _opp_id := DEFAULT_OPPONENT
var _opp_def: Dictionary
var _two_player := false
var _ui: CanvasLayer
var _boot: Control
var _boot_status: Label
var _overlay: Control = null
var _overlay_open := false
var _ready_to_run := false
var _reported := false
var _results_at = null         # sim time to show the result at (after the reel)
var _reel_due := false
var _reel_queue = null
var _reel_total := 0
var _replay_speed := BEST_SPEED
var _cam_before_replay = null
var _tap_armed_until := -INF
var _p2_tap_armed_until := -INF
var _last_phase = null
var _last_count_n = null
var _weapon_phase := {}
var _intro_said := false
var _result_keys := ""
var _venue_energy := 0.4

func _ready() -> void:
	_req = Game.request if Game.request is Dictionary else {}
	_mode = _req.get("mode", "quick")
	_ui = CanvasLayer.new()
	_ui.layer = 5
	add_child(_ui)
	_show_boot()
	# Let the boot card paint before the long synchronous build.
	await get_tree().process_frame
	await get_tree().process_frame
	_build()

func _show_boot() -> void:
	_boot = ColorRect.new()
	(_boot as ColorRect).color = UI.BG
	_boot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var logo := UI.label("ROBO LEAGUE", {"kind": "display", "size": 92, "weight": 700, "italic": true, "color": Color("e9e7e1"), "align": "center"})
	_boot_status = UI.label("BUILDING THE ARENA...", {"kind": "cond", "size": 13, "weight": 600, "ls": 0.3, "color": UI.ACCENT, "align": "center"})
	var c := CenterContainer.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(UI.vbox(4, [logo, _boot_status]))
	_boot.add_child(c)
	_ui.add_child(_boot)

# ---------------------------------------------------------------- boot

func _build() -> void:
	var reg := Game.reg
	var settings := Game.settings
	_career = _req.get("career") if _mode == "career" else null
	_tourney = _req.get("tourney") if _mode == "tourney" else null
	_scout = _req.get("scout") if _mode == "scout" else null
	_two_player = J.truthy(_req.get("p2")) and _mode != "career"
	# A tournament fight: people's own robots are not in the data files.
	if _tourney is Dictionary:
		for def in (_tourney.get("custom", {}) as Dictionary).values(): reg.add_robot(def)

	_player_id = _req.red if reg.has_robot(str(_req.get("red", ""))) else DEFAULT_RED
	# In a career fight you fight the robot you built in the workshop, handed
	# over by the career screen with the fixture. Only if it builds.
	var player_def: Dictionary = reg.robot(_player_id)
	if _career is Dictionary and _career.get("meDef") is Dictionary and _career.get("meId") == _player_id:
		var mine := J.merge(player_def, _career.meDef)
		mine.id = _player_id
		if Build.can_assemble(reg, mine): player_def = mine
	# The scouting tape: both robots as the career has them now.
	if _scout is Dictionary and J.path(_scout, ["red", "id"]) == _player_id:
		var d := J.merge(player_def, _scout.red.def)
		d.id = _player_id
		if Build.can_assemble(reg, d): player_def = d

	# The opponent. Its driver - personality, rating, league - comes from its
	# robot file.
	_opp_id = _req.blue if reg.has_robot(str(_req.get("blue", ""))) else DEFAULT_OPPONENT
	_opp_def = (reg.robot(_opp_id) as Dictionary).duplicate()
	# A career opponent fights as its current version - the off-season's
	# upgrades and driver rating - handed over by the career screen.
	if _career is Dictionary and _career.get("oppId") == _opp_id and _career.get("oppDef") is Dictionary:
		var evolved := J.merge(_opp_def, _career.oppDef)
		evolved.id = _opp_id
		if Build.can_assemble(reg, evolved): _opp_def = evolved
	if _scout is Dictionary and J.path(_scout, ["blue", "id"]) == _opp_id:
		var d := J.merge(_opp_def, _scout.blue.def)
		d.id = _opp_id
		if Build.can_assemble(reg, d): _opp_def = d
	# Quick Fight: the opponent drives at the difficulty setting (a career
	# fight's opponent brings the career's, already set up for you). On the
	# scouting tape both drive as themselves.
	if _scout != null: _opp_def.skillBonus = 0
	elif _career == null or _opp_def.get("skillBonus") == null:
		var diff := Settings.difficulty_of(reg, settings.difficulty)
		_opp_def.skillBonus = diff.skillBonus
		_opp_def.learnRate = diff.learnRate

	# One seed per session drives every roll: damage, debris, the judges,
	# both AI drivers and which killsaws come up in the last minute.
	var match_seed: int = int(_req.seed) & 0xffffffff if _req.get("seed") != null else (Time.get_ticks_usec() + int(Time.get_unix_time_from_system())) & 0xffff
	print("[match] seed %d" % match_seed)

	# Where: a venue round the box and a hazard layout in it (data/arenas.json).
	var h_arena = _career.get("arena") if _career is Dictionary else null
	var venue = h_arena.get("venue") if h_arena is Dictionary else null
	if venue == null: venue = _req.get("venue")
	if venue == null: venue = Arenas.venue_for_league(reg, _opp_def.get("league")) if _career != null else Arenas.DEFAULT_VENUE
	if Arenas.venue_of(reg, venue) == null: venue = Arenas.venue_for_league(reg, venue)
	var layout = h_arena.get("layout") if h_arena is Dictionary else null
	if layout == null: layout = _req.get("layout", Arenas.DEFAULT_LAYOUT)
	if layout == "random" or Arenas.layout_of(reg, layout) == null: layout = Arenas.layout_for_fight(reg, venue, match_seed)
	var venue_def = Arenas.venue_of(reg, venue)
	_venue_energy = J.path(venue_def, ["crowd", "energy"], 0.4) if venue_def is Dictionary else 0.4

	# A career robot turns up with whatever damage its pit did not fix.
	var conditions := {}
	var mats := Mats.shared(reg.arena.get("style", {}))
	var red_ai: bool = _req.get("driver") == "ai" or _scout != null
	fight = Fight.new(reg, {"red": player_def, "blue": _opp_def, "seed": match_seed, "where": {"venue": venue, "layout": layout},
		"redAI": red_ai, "twoPlayer": _two_player, "conditions": conditions, "mats": mats})
	if _career is Dictionary:
		if _career.get("meId") == _player_id and _career.get("meCondition") is Dictionary: _carry_in(fight.red, _career.meCondition)
		var opp_cond = _career.get("oppCondition")
		if _career.get("oppId") == _opp_id and opp_cond is Array:
			if opp_cond.size() > 0 and opp_cond[0] is Dictionary: _carry_in(fight.blue, opp_cond[0])
			var bp := fight.partners_of("blue")
			if opp_cond.size() > 1 and opp_cond[1] is Dictionary and not bp.is_empty(): _carry_in(bp[0], opp_cond[1])
		var rp := fight.partners_of("red")
		if _career.get("mePartnerCondition") is Dictionary and not rp.is_empty(): _carry_in(rp[0], _career.mePartnerCondition)
	add_child(fight)
	fight.steering = float(settings.get("steering", "1"))
	print("[arena] %s · %s" % [venue_def.name if venue_def is Dictionary else venue, fight.arena.get("name", "")])

	# ---------------------------------------------------------- rendering
	stage = Stage.new(fight.arena, venue_def)
	add_child(stage)
	arena_view = ArenaView.new(fight.arena, fight.world, fight.hazards, mats)
	add_child(arena_view)
	# The building round the box: stands, crowd, lights and screens.
	if venue_def is Dictionary:
		venue_view = VenueView.new(venue_def, fight.arena, fight.bus, match_seed, {"red": fight.red.assembled.name, "blue": fight.blue.assembled.name})
		add_child(venue_view)
	for u in fight.units:
		var v := RobotView.new(u.assembled, u.sim.rig, mats)
		add_child(v)
		v.sync(u.sim.transform)
		views[u.id] = v
	_show_start_damage()
	# What metal reflects: the hall and the box as built, without the robots.
	# (Robots take the hall's bounced light but give none back.)
	for id in views:
		for n in (views[id] as Node).find_children("*", "GeometryInstance3D", true, false): (n as GeometryInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	stage.reflect([arena_view, venue_view] if venue_view != null else [arena_view], arena_view.moving_parts(), "%s|%s" % [venue, layout])
	cam = CameraRig.new(fight.arena, fight.bus)
	add_child(cam)
	# Sparks, dents and flying parts. Driven entirely off the bus, so the
	# logic layer has no idea it is being watched.
	effects = Effects.new(fight.bus, views, fight.debris, Rng.new(Rng.hash_seed("%d:fx" % match_seed)))
	add_child(effects)
	# What the fight leaves on the deck.
	marks = DeckMarks.new(fight.bus, views, Vector2(fight.world.dims.halfX, fight.world.dims.halfZ), Rng.new(Rng.hash_seed("%d:marks" % match_seed)))
	add_child(marks)

	# ---------------------------------------------------------- HUD, sound, commentary
	var story = _career.get("story") if (_career is Dictionary and _career.get("oppId") == _opp_id) else null
	var where_names := {"venue": venue_def.name if venue_def is Dictionary else "", "layout": fight.arena.get("name", "")}
	var names = _tourney.get("names", {}) if _tourney is Dictionary else {}
	var red_driver: String = names.get("red", "AI" if red_ai else ("player 1" if _two_player else "you"))
	var blue_driver: String = names.get("blue", "player 2" if _two_player else "%s · %s · %s" % [_opp_def.get("personality", ""), J.s(_opp_def.get("rating", "")), _opp_def.get("league", "")])
	var tag = null
	if _scout is Dictionary: tag = {"title": _scout.get("label", "SCOUTING TAPE"), "sub": "The real fight: %s" % _scout.real if J.truthy(_scout.get("real")) else ""}
	hud = Hud.new(fight, cam, {
		"corners": {fight.red.id: {"corner": "red", "assembled": fight.red.assembled, "driver": red_driver},
			fight.blue.id: {"corner": "blue", "assembled": fight.blue.assembled, "driver": blue_driver}},
		"where": where_names, "story": story, "twoPlayer": _two_player, "tag": tag})
	_ui.add_child(hud)
	speech = Speech.new()
	booth = Booth.new(speech, settings.get("commentary", "both"))
	_ui.add_child(booth)
	audio = GameAudio.new(fight.bus, settings)
	add_child(audio)
	var cnames := {}
	var cweapons := {}
	for u in fight.units:
		cnames[u.id] = u.assembled.name
		if u.main: cweapons[u.id] = WEAPON_WORDS.get(u.assembled.stats.weapon["class"], "wedge")
	commentary = Commentary.new({"names": cnames, "corners": {fight.red.id: "red", fight.blue.id: "blue"}, "weapons": cweapons, "story": story,
		# Two players: nobody is "you" - the booth calls it straight.
		"playerId": null if (_two_player or _scout != null) else fight.red.id,
		"where": where_names, "rng": Rng.new(Rng.hash_seed("%d:booth" % match_seed)), "durationS": J.path(reg.rules, ["match", "durationS"], 180.0)})
	var bus := fight.bus
	bus.on(Bus.HIT, func(e): booth.push(commentary.event("hit", e, _match_t())))
	bus.on(Bus.PART_FAILED, func(e): booth.push(commentary.event("failed", e, _match_t())))
	bus.on(Bus.REF_COUNT, func(e): booth.push(commentary.event("count", e, _match_t())))
	bus.on(Bus.PIN_WARNING, func(e): booth.push(commentary.event("pin", e, _match_t())))
	bus.on(Bus.SEPARATE, func(e): booth.push(commentary.event("separate", e, _match_t())))
	bus.on(Bus.HAZARD_FIRE, func(e): booth.push(commentary.event("hazard", e, _match_t())))
	bus.on(Bus.MATCH_END, _on_match_end)

	_result_keys = ""
	if _mode == "career": _result_keys = "[M] back to your career   [P] highlights"
	elif _mode == "tourney": _result_keys = "[M] back to the tournament   [P] highlights"
	elif _mode == "scout": _result_keys = "[Enter] run the tape again   [P] highlights   [M] back to your career"
	if Game.touch: _result_keys = "Pause (❚❚) for the menu"

	# ---------------------------------------------------------- settings
	var want_cam: String = settings.get("camera", "chase")
	var list := cam.list()
	for i in list.size():
		if str(list[i].label).to_lower().contains(want_cam) or str(list[i].id).to_lower().contains(want_cam):
			cam.select_index(i)
			break
	# Two players share the screen: a camera that keeps both robots in it.
	if _two_player: cam.select("versus")
	apply_settings("")
	if Game.touch: _ui.add_child(TouchControls.new(self, _two_player))

	_boot.queue_free()
	_boot = null
	_ready_to_run = true
	booth.push(commentary.intro())
	_intro_said = true

func _carry_in(u: Dictionary, condition: Dictionary) -> void:
	u.assembled.condition.merge(condition, true)
	fight._start_condition[u.id] = u.assembled.condition.duplicate()
	u.sim.invalidate()

# The damage a career robot carries in shows before the bell: dents, loose
# panels, a bent weapon, smoke.
func _show_start_damage() -> void:
	for u in fight.units:
		var v: RobotView = views[u.id]
		for key in u.assembled.condition:
			if u.assembled.condition[key] < 0.999: v.set_panel_condition(key, u.assembled.condition[key])
		v.apply_condition(u.assembled.condition)

func _match_t() -> float:
	return J.path(Game.reg.rules, ["match", "durationS"], 180.0) - fight.bout.clockS

## Everything on the Settings page that touches the fight applies the moment
## it changes - from the pause overlay as much as from the menus.
func apply_settings(changed: String) -> void:
	var s := Game.settings
	Stage.apply_viewport(get_viewport(), s)
	Mats.apply_settings(s)
	Parts.detailed = Gfx.on(s, "gfxModels")
	Dress.on = Gfx.on(s, "gfxHardware")
	stage.apply_settings(s)
	effects.apply_settings(s)
	marks.apply_settings(s)
	RobotFx.apply_settings(s)
	for id in views: (views[id] as RobotView).refresh_fx()
	if venue_view != null: venue_view.set("gpu_fire", effects.gpu())
	hud.set_show_damage(J.truthy(s.get("hudDamage", true)))
	audio.apply_settings(s)
	speech.set_volume(float(s.get("volume", 0.75)) if J.truthy(s.get("sound", true)) else 0.0)
	booth.set_mode(s.get("commentary", "both"))
	fight.steering = float(s.get("steering", "1"))
	if changed == "difficulty" and _career == null and _scout == null:
		# A new difficulty takes over the opponent's driving straight away.
		fight.set_difficulty(s.difficulty)
		hud.banner("DIFFICULTY: %s" % str(Settings.difficulty_of(Game.reg, s.difficulty).get("label", s.difficulty)).to_upper(), 1.5)

# ---------------------------------------------------------------- results

func _fix(id):
	return _opp_id if id == fight.blue.id else id

func _on_match_end(r: Dictionary) -> void:
	booth.push(commentary.event("end", r, _match_t()))
	# The sim keeps running past the bell, so a clip still waiting on its
	# aftermath is captured before the reel plays.
	_results_at = fight.sim_time + Fight.CLIP_TAIL_S + 0.1
	_reel_due = true
	if _reported: return
	if _mode == "career" and _career is Dictionary and _career.get("oppId") == _opp_id:
		# A career fight's result goes back to the career, once: the fixture
		# it was for, how it ended, the judges' damage scores and what is
		# left of your robot (the repair bill is worked out from that).
		_reported = true
		var rp := fight.partners_of("red")
		var opp_conditions := [fight.blue.assembled.condition.duplicate()]
		for p in fight.partners_of("blue"): opp_conditions.append(p.assembled.condition.duplicate())
		Game.result = {"kind": "career", "fixtureId": _career.get("fixtureId"), "result": _result_of(r, true),
			"condition": fight.red.assembled.condition.duplicate(),
			"partnerCondition": rp[0].assembled.condition.duplicate() if not rp.is_empty() else null,
			# What the opponent's driver learned in this fight (ailearn.gd keeps it).
			"oppLearned": fight.blue.brain.learned,
			# The opponent goes back to its own pit with what it took.
			"oppCondition": opp_conditions}
	elif _mode == "tourney" and _tourney is Dictionary and _tourney.get("red") == _player_id and _tourney.get("blue") == _opp_id:
		_reported = true
		Game.result = {"kind": "tourney", "fixtureId": _tourney.get("fixtureId"), "result": _result_of(r, false)}

func _result_of(r: Dictionary, votes: bool) -> Dictionary:
	var damage := {}
	for id in [fight.red.id, fight.blue.id]: damage[_fix(id)] = J.rndi(J.path(r, ["tally", id, "damage"], 0.0))
	var out := {"winnerId": _fix(r.get("winnerId")), "loserId": _fix(r.get("loserId")), "method": r.get("method"), "cause": r.get("cause"),
		"elapsedS": J.rndi(r.get("elapsedS", 0.0)), "decision": r.get("decision"), "damage": damage, "by": "played"}
	if votes: out.votes = r.get("votes")
	return out

# ---------------------------------------------------------------- replays

func _to_replay_cam() -> void:
	if _cam_before_replay == null: _cam_before_replay = cam.cam_id()
	cam.select("replay")
	fight.set_frozen(true)

func _from_replay_cam() -> void:
	if _cam_before_replay != null: cam.select(_cam_before_replay)
	_cam_before_replay = null
	if not _overlay_open: fight.set_frozen(false)

# The last few seconds of the ring - only outside a match (free driving).
func _start_replay(seconds: float) -> bool:
	if not fight.replay.play(seconds): return false
	_replay_speed = BEST_SPEED
	_to_replay_cam()
	return true

# Start the highlight reel from the top. False if there is nothing in it.
func _play_reel() -> bool:
	_reel_queue = J.sorted(fight.reel, func(a, b): return a.atS - b.atS)
	_reel_total = _reel_queue.size()
	return _play_next_in_reel()

func _play_next_in_reel() -> bool:
	while _reel_queue != null and not _reel_queue.is_empty():
		var item: Dictionary = _reel_queue.pop_front()
		if not fight.replay.play_clip(item.clip): continue
		_to_replay_cam()
		var best := true
		for x in fight.reel:
			if x.hp > item.hp: best = false
		_replay_speed = BEST_SPEED if best else REEL_SPEED
		var n: int = _reel_total - _reel_queue.size()
		var title := "HIT OF THE MATCH" if best else ("REPLAY %d / %d" % [n, _reel_total] if _reel_total > 1 else "REPLAY")
		hud.banner("%s · P TO SKIP" % title if (n == 1 and not Game.touch) else title, 1.6)
		return true
	_reel_queue = null
	return false

# Stop whatever is playing, skipping the rest of the reel.
func _stop_replay() -> void:
	fight.replay.stop()
	_reel_queue = null
	_from_replay_cam()
	fight.bus.emit(Bus.REPLAY_END)

# ---------------------------------------------------------------- the pause overlay

func _build_overlay() -> void:
	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(0.016, 0.024, 0.04, 0.72)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.theme = UI.theme()
	var card := Plate.new(22, 18)
	card.cut = 14
	card.top_color = Color("23262b")
	card.bottom_color = Color("121418")
	card.custom_minimum_size = Vector2(660, 0)
	var back := "back to your career" if _mode == "career" or _mode == "scout" else ("back to the tournament" if _mode == "tourney" else "menu")
	var head := UI.hbox(10, [
		UI.label("PAUSED", {"kind": "display", "size": 40, "weight": 600, "italic": true, "ls": 0.08, "color": UI.ACCENT, "expand": true}),
		UI.rich(UI.keys("[Esc] resume   [M] %s" % back), {"kind": "cond", "size": 13, "weight": 500, "color": UI.DIM, "wrap": false}),
	])
	var buttons := UI.hbox(8)
	var resume := UI.button("RESUME", "fight", {"small": true})
	resume.pressed.connect(func(): do_action("pause"))
	var quit := UI.button(back.to_upper(), "ghost")
	quit.pressed.connect(func(): do_action("menu"))
	var hand := UI.button("HAND OVER TO THE AI", "ghost")
	hand.pressed.connect(func(): do_action("handover"))
	var tap := UI.button("TAP OUT", "ghost")
	tap.pressed.connect(func():
		if fight.bout.phase == Match.PAUSED or fight.bout.phase == Match.LIVE:
			do_action("pause")
			fight.bout.tap_out(fight.red.id))
	for b in [resume, hand, tap, quit]: buttons.add_child(b)
	var controls := PanelContainer.new()
	controls.add_theme_stylebox_override("panel", UI.box(Color(1, 1, 1, 0.04), {"pad": [10, 8]}))
	controls.add_child(UI.rich(Hud.controls_bbcode(_two_player), {"kind": "cond", "size": 14, "weight": 500, "color": UI.DIM}))
	var body := UI.vbox(6, [
		UI.label("CONTROLS", {"kind": "cond", "size": 11, "weight": 700, "ls": 0.24, "color": UI.DIM}),
		controls,
		SettingsPanel.new(null, "Changes apply at once.", func(_s, id): apply_settings(id)),
	])
	var sc := UI.scroll(body)
	sc.custom_minimum_size = Vector2(0, 470)
	card.add_child(UI.vbox(10, [head, buttons, sc]))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.add_child(card)
	_overlay.add_child(center)
	var layer := CanvasLayer.new()
	layer.layer = 20
	layer.add_child(_overlay)
	add_child(layer)

# Esc pauses the fight and shows the settings.
func _toggle_overlay() -> void:
	if _overlay == null: _build_overlay()
	_overlay_open = not _overlay_open
	_overlay.visible = _overlay_open
	var phase := fight.bout.phase
	if (_overlay_open and phase == Match.LIVE) or (not _overlay_open and phase == Match.PAUSED): fight.bout.toggle_pause()
	if not fight.replay.playing: fight.set_frozen(_overlay_open)
	if _overlay_open: audio.hush()

# ---------------------------------------------------------------- keys

func _unhandled_key_input(event: InputEvent) -> void:
	if not _ready_to_run or not (event is InputEventKey) or not event.pressed or event.echo: return
	var key: int = (event as InputEventKey).physical_keycode
	# The key is marked as dealt with after acting on it - but M and O leave
	# the fight, and by then this scene is out of the tree and has no window
	# to tell. So the window is found first.
	var window := get_viewport()
	match key:
		KEY_ENTER, KEY_KP_ENTER: do_action("start")
		KEY_ESCAPE: do_action("pause")
		KEY_N: do_action("sound")
		KEY_M: do_action("menu")
		KEY_C: do_action("cam_prev" if (event as InputEventKey).shift_pressed else "cam_next")
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
			if not _overlay_open: cam.select_index(key - KEY_1)
		KEY_TAB: do_action("handover")
		KEY_T: do_action("tapout")
		KEY_BACKSPACE: do_action("tapout2")
		KEY_BACKSLASH: do_action("handover2")
		KEY_O: do_action("next_opponent")
		KEY_R: do_action("reset")
		KEY_P: do_action("replay")
		_: return
	window.set_input_as_handled()

## Everything a key (or an on-screen button) can ask for.
func do_action(action: String) -> void:
	if not _ready_to_run: return
	var bout := fight.bout
	if _overlay_open and action != "pause" and action != "menu" and action != "handover" and action != "sound": return
	match action:
		"start":
			if _mode == "career" and _reported:
				hud.banner("PRESS M TO RETURN TO YOUR CAREER", 2.0)
				return
			if _mode == "tourney" and _reported:
				hud.banner("PRESS M TO RETURN TO THE TOURNAMENT", 2.0)
				return
			if fight.replay.playing: _stop_replay()
			fight.start_match()
			for id in views: (views[id] as RobotView).reset_condition()
			_show_start_damage()
			_reel_queue = null
			_results_at = null
			_reel_due = false
			hud.hide_results()
			effects.clear()
			marks.clear()
			cam.reset_chase()
			commentary.reset()
			booth.clear()
		"pause": _toggle_overlay()
		"sound":
			# Sound on/off, remembered like any other setting.
			Game.set_setting("sound", not J.truthy(Game.settings.get("sound", true)))
			apply_settings("sound")
			hud.banner("SOUND ON" if Game.settings.sound else "SOUND OFF", 1.0)
		"menu":
			# Back to the menu, which remembers the matchup.
			fight.set_frozen(false)
			Game.to_menu("career" if (_mode == "career" or _mode == "scout") else ("tournament" if _mode == "tourney" else "quick"))
		"cam_next": cam.next_cam()
		"cam_prev": cam.prev_cam()
		"handover": fight.pilot.toggle(fight.red.id)
		"tapout":
			if bout.phase != Match.LIVE: return
			if fight.sim_time <= _tap_armed_until:
				bout.tap_out(fight.red.id)
				_tap_armed_until = -INF
			else:
				_tap_armed_until = fight.sim_time + 2.0
				hud.banner("RED: PRESS T AGAIN TO TAP OUT" if _two_player else "PRESS T AGAIN TO TAP OUT", 2.0)
		"tapout2":
			# Player 2's tap out, twice like T.
			if not fight.p2_human or bout.phase != Match.LIVE: return
			if fight.sim_time <= _p2_tap_armed_until:
				bout.tap_out(fight.blue.id)
				_p2_tap_armed_until = -INF
			else:
				_p2_tap_armed_until = fight.sim_time + 2.0
				hud.banner("BLUE: PRESS BACKSPACE AGAIN TO TAP OUT", 2.0)
		"handover2":
			# Player 2 hands blue to the AI, or takes it back.
			if not _two_player: return
			fight.p2_human = not fight.p2_human
			if not fight.p2_human: fight.blue.brain.reset()
			fight.bus.emit(Bus.CONTROL_CHANGED, {"botId": fight.blue.id, "pilot": Pilot.HUMAN if fight.p2_human else Pilot.AI_DRIVER})
			hud.banner("PLAYER 2 HAS BLUE" if fight.p2_human else "BLUE HANDED TO THE AI", 1.2)
		"next_opponent":
			# A career or tournament fight is the fight you were drawn.
			if _mode != "quick": return
			var ids := []
			for r in Game.reg.all_robots():
				if r.id != _player_id: ids.append(r.id)
			if ids.is_empty(): return
			var next_req := _req.duplicate()
			next_req.blue = ids[(ids.find(_opp_id) + 1) % ids.size()]
			fight.set_frozen(false)
			Game.start_fight(next_req)
		"reset":
			fight.reset_red()
			cam.reset_chase()
			hud.banner("BOT RESET", 1.0)
		"replay":
			if fight.replay.playing:
				# Skip: straight to the result card if the reel was showing.
				_stop_replay()
			elif bout.phase == Match.ENDED:
				# After the bell, P shows the highlight reel again.
				hud.hide_results()
				if _play_reel(): _results_at = 0.0
				else:
					hud.banner("NO BIG HITS TO REPLAY", 1.2)
					hud.show_results(bout.result, _result_keys)
			elif bout.phase != Match.IDLE:
				# Replays never interrupt a match.
				hud.banner("REPLAYS AFTER THE BELL", 1.2)
			elif not _start_replay(REPLAY_SECONDS):
				hud.banner("NOT ENOUGH FOOTAGE", 1.0)

# ---------------------------------------------------------------- the frame

func _process(dt: float) -> void:
	if not _ready_to_run: return
	# Cap dt so a hitch does not fling the cameras about.
	dt = minf(dt, 0.1)
	var bout := fight.bout
	var focus: Transform3D = fight.red.sim.global_transform
	var pair := [fight.red.sim.global_position, fight.blue.sim.global_position]
	var replaying := fight.replay.playing

	if replaying:
		# Physics is frozen; the scene is driven from recorded transforms.
		var poses = fight.replay.sample(dt, _replay_speed)
		if poses != null:
			for i in mini(poses.size(), fight.units.size()):
				(views[fight.units[i].id] as RobotView).transform = poses[i]
			focus = poses[0]
			if poses.size() > 1: pair = [poses[0].origin, poses[1].origin]
		else:
			fight.bus.emit(Bus.REPLAY_END)
			replaying = false
			# Straight on to the next clip of the reel, or back to the live camera.
			if not _play_next_in_reel(): _from_replay_cam()
			else: replaying = true
	if not replaying:
		for u in fight.units:
			var v: RobotView = views[u.id]
			v.sync(u.sim.global_transform)
			if not fight.frozen:
				v.update_weapon(u.weapon, dt)
				v.update_fx(dt)
		# The bell: the highlight reel, then the result.
		if _results_at != null and fight.sim_time >= _results_at:
			_results_at = null
			var want_reel := _reel_due
			_reel_due = false
			if want_reel and J.truthy(Game.settings.get("replays", true)) and _play_reel(): _results_at = 0.0
			else: hud.show_results(bout.result, _result_keys)

	var still := fight.frozen and not fight.replay.playing
	arena_view.update(0.0 if still else dt)
	if venue_view != null: venue_view.call("update", 0.0 if still else dt, bout)
	effects.set_paused(still)
	if not still:
		effects.update(dt)
		marks.update(dt)
	cam.update(dt, focus, fight.replay.playing, pair)
	# The lens: soft backgrounds for the intro and the replays, sharp for the fight.
	stage.focus(cam, focus.origin, fight.replay.playing or bout.phase == Match.IDLE or bout.phase == Match.COUNTDOWN, dt)
	# A camera outside the box looks through the near walls: they clear out of its way.
	arena_view.set_viewpoint(cam.global_position)
	_sound_frame(0.0 if (fight.replay.playing or still) else dt)
	hud.update(dt)

# The countdown's beeps, the horn and the booth's "FIGHT!", off the phase.
func _sound_frame(dt: float) -> void:
	var bout := fight.bout
	if bout.phase != _last_phase:
		if bout.phase == Match.COUNTDOWN:
			booth.push(commentary.event("countdown"))
			_last_count_n = null
		if bout.phase == Match.LIVE and _last_phase == Match.COUNTDOWN:
			booth.push(commentary.event("live"))
			audio.start_horn()
		_last_phase = bout.phase
	if bout.phase == Match.COUNTDOWN:
		var n := int(ceil(bout.countdownS))
		if n != _last_count_n and n > 0:
			audio.countdown_beep(n)
			_last_count_n = n
	var live := bout.phase == Match.LIVE
	if dt > 0.0: booth.push(commentary.tick(bout.clockS, live, dt))
	booth.update(maxf(dt, 0.0001) if dt > 0.0 else get_process_delta_time())
	if dt <= 0.0: return
	var bots := []
	for u in fight.units:
		var sim: RobotSim = u.sim
		var w: Weapon = u.weapon
		var fam := Weapon.family_of(u.assembled.stats.weapon["class"])
		if fam == Weapon.DISCRETE and w.phase == Weapon.STRIKING and _weapon_phase.get(u.id) != Weapon.STRIKING: audio.weapon_fired(sim.global_position)
		_weapon_phase[u.id] = w.phase
		var top: float = maxf(0.1, J.g(u.assembled.stats, "topSpeedMps", 6.0))
		bots.append({"id": u.id, "pos": sim.global_position, "family": fam, "out": J.truthy(sim.effective().get("immobile")),
			"speed": minf(1.0, sim.speed_mps() / top),
			"throttle": minf(1.0, absf(u.drive.get("throttle", 0.0)) + absf(u.drive.get("steer", 0.0)) * 0.5),
			"spin": w.spinPct if fam == Weapon.KINETIC else 0.0, "omega": w.omegaRadS})
	var pit_warning := 0.0
	for h in fight.hazards.all:
		if h.type == "pit": pit_warning = h.warning
	audio.update(dt, bots, live, pit_warning, _venue_energy)

func _exit_tree() -> void:
	if speech != null: speech.cancel()
