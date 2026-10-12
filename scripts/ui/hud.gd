## hud.gd - the fight's on-screen overlay.
##
## A fight-night broadcast package: a scoreboard clock in amber, a slim card
## for each robot (health, weapon, the worst damaged parts), tale-of-the-tape
## intro cards, the referee's count, banners and the result. It only ever
## READS state - it never changes the match or a robot.
class_name Hud
extends Control

const CAUSE := {"pitted": "went down the pit", "flipped": "flipped and could not recover", "beached": "stranded with its wheels off the floor",
	"disabled": "could not drive", "stuck": "stuck and unable to move"}

## Touch screen: the words for the controls change.
static var touch := false

var fight: Fight
var cam: CameraRig
var corners := {}              # bot id -> { corner, assembled, driver }
var two_player := false

var _clock: Label
var _phase: Label
var _cam_tag: Label
var _me: Dictionary
var _opp: Dictionary
var _ready_card: Control
var _banner: Control
var _banner_text: Label
var _count: Control
var _count_n: Label
var _count_who: Label
var _intro: Control
var _results: Plate
var _results_box: VBoxContainer
var _replay: Control
var _scrub: Meter
var _banner_t := 0.0
var _cam_t := 0.0
var _count_t := 0.0
var _dmg_t := 0.0
var _last_phase := "idle"
var _show_damage := true
var _offs := []

## opts: { corners, where: { venue, layout }, story, twoPlayer, tag: { title, sub } }
func _init(the_fight: Fight, camera: CameraRig, opts: Dictionary = {}) -> void:
	name = "Hud"
	fight = the_fight
	cam = camera
	corners = opts.get("corners", {})
	two_player = J.truthy(opts.get("twoPlayer"))
	theme = UI.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build(opts)
	var bus := fight.bus
	_offs.append(bus.on(Bus.CAMERA_CHANGED, func(_e): _show_cam()))
	_offs.append(bus.on(Bus.CONTROL_CHANGED, func(e): banner("AI HAS CONTROL" if e.pilot == "ai" else "DRIVER HAS CONTROL")))
	_offs.append(bus.on(Bus.REF_COUNT, _on_count))
	_offs.append(bus.on(Bus.KO, func(e): banner("%s IS KNOCKED OUT" % _name_of(e.botId).to_upper(), 2.5)))
	_offs.append(bus.on(Bus.TAP_OUT, func(e): banner("%s TAPS OUT" % _name_of(e.botId).to_upper(), 2.5)))
	_offs.append(bus.on(Bus.PIN_WARNING, func(e): banner("%s: RELEASE!" % _name_of(e.botId).to_upper(), 2.0)))
	_offs.append(bus.on(Bus.SEPARATE, func(_e): banner("ROBOTS LOCKED - THE REFEREE SEPARATES THEM", 2.0)))
	_offs.append(bus.on(Bus.PIN_PENALTY, func(e): banner("PINNING - %s LOSES CONTROL POINTS" % _name_of(e.botId).to_upper(), 2.0)))
	# Hazards firing get no words on screen: the arena's sound tells you.
	_offs.append(bus.on(Bus.PART_FAILED, func(e): banner("%s DESTROYED" % str(e.get("name", "")).to_upper(), 2.0)))
	_offs.append(bus.on(Bus.HIT, func(e):
		# Robot on robot only: a screw or a pulverizer biting is heard, not captioned.
		if e.kind == "hazard": return
		if e.severity == "heavy" or e.severity == "catastrophic": banner("HUGE HIT!" if e.severity == "catastrophic" else "BIG HIT!", 1.2)))

func _exit_tree() -> void:
	for off in _offs:
		if (off as Callable).is_valid(): off.call()

func _name_of(id) -> String:
	return str(corners[id].assembled.name) if corners.has(id) else str(id)

func _corner_of(id) -> String:
	return corners[id].corner if corners.has(id) else ""

static func _corner_color(corner: String) -> Color:
	return UI.RED_SOFT if corner == "red" else (UI.BLUE_SOFT if corner == "blue" else UI.TEXT)

## What starts the match, in the words of this build's controls.
static func start_hint() -> String:
	return "TAP START" if touch else "ENTER START · ESC PAUSE & KEYS"

## Every control, for the card before the bell and the pause screen.
static func controls_bbcode(twop := false) -> String:
	if touch:
		if twop: return "\n".join([
			"[color=#e5281f]RED[/color]  left edge: a thumb anywhere there drives, [b]WEAPON[/b] and [b]BRAKE[/b] beside it",
			"[color=#2e86ff]BLUE[/color]  right edge: the same, the other way round",
			"Drive: slide up to go forward, down to reverse, sideways to turn",
			"[b]❚❚[/b] pause & settings   [b]CAM[/b] next camera"])
		return UI.keys("\n".join([
			"[DRIVE]  put a thumb anywhere on the left half and slide it: up goes forward, down reverses, sideways turns",
			"[WEAPON]  hold to spin up / fire   [BRAKE]  hold to stop dead",
			"[❚❚] pause & settings   [CAM] next camera",
			"The pause menu also hands your robot to the AI, taps out, or quits."]))
	if twop: return UI.keys("\n".join([
		"RED   [W A S D] drive   [Space] weapon   [Shift] brake   [T T] tap out",
		"BLUE   [arrows] drive   [/] or [Ctrl] weapon   [.] brake   [⌫ ⌫] tap out",
		"[Tab] red to AI   [\\] blue to AI",
		"[C] next camera   [1-7] pick   [P] highlights",
		"[Enter] start   [Esc] pause   [M] menu   [N] sound",
		"Gamepads go to red, then blue."]))
	return UI.keys("\n".join([
		"[W A S D] / arrows drive   [Space] weapon (spin / fire)   [Shift] brake",
		"[C] next camera   [1-7] pick   [Tab] hand over to AI",
		"[Enter] start   [Esc] pause   [P] highlights (after the bell)",
		"[R] reset bot   [T T] tap out   [O] next opponent",
		"[M] back to menu   [N] sound on/off"]))

# ---------------------------------------------------------------- building

func _anchor(c: Control, preset: int, offset := Vector2.ZERO) -> Control:
	add_child(c)
	c.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE)
	c.position += offset
	return c

func _build(opts: Dictionary) -> void:
	# ---- the scoreboard clock
	var top := UI.vbox(6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var clock_plate := Plate.new(34, 2)
	clock_plate.top_color = Color("121316")
	clock_plate.bottom_color = Color("060708")
	clock_plate.border_color = Color("2b2e33")
	clock_plate.bolts = false
	clock_plate.cut = 14
	clock_plate.cut_all = false
	_clock = UI.label("3:00", {"kind": "display", "size": 64, "weight": 600, "color": Color("ffb21e"), "align": "center", "ls": 0.06})
	_phase = UI.label(start_hint(), {"kind": "cond", "size": 12, "weight": 700, "color": Color("a49f94"), "align": "center", "ls": 0.3})
	var cv := UI.vbox(-6, [_clock, _phase, UI.spacer(0, 10), HazardStrip.new(5, 8)])
	clock_plate.add_child(cv)
	top.add_child(clock_plate)
	_cam_tag = UI.label("", {"kind": "cond", "size": 11, "weight": 700, "ls": 0.24, "align": "center"})
	_cam_tag.modulate.a = 0.0
	top.add_child(_cam_tag)
	var tag = opts.get("tag")
	if tag is Dictionary:
		var tp := PanelContainer.new()
		tp.add_theme_stylebox_override("panel", UI.box(Color(0.04, 0.047, 0.063, 0.78), {"left_bar": Color("f0c419"), "pad": [12, 4]}))
		var tv := UI.vbox(0, [UI.label(str(tag.title), {"kind": "cond", "size": 14, "weight": 700, "ls": 0.12, "color": Color("f0c419"), "align": "center"})])
		if J.truthy(tag.get("sub")): tv.add_child(UI.label(str(tag.sub), {"kind": "cond", "size": 13, "color": Color("c8cfda"), "align": "center"}))
		tp.add_child(tv)
		top.add_child(tp)
	add_child(top)
	UI.pin(top, Vector2(0.5, 0.0), Vector2(0, 14))

	# ---- the two robot cards
	_me = _card(fight.red.assembled, "me")
	add_child(_me.root)
	UI.pin(_me.root, Vector2(0.0, 0.0), Vector2(14, 14))
	_opp = _card(fight.blue.assembled, "opp")
	add_child(_opp.root)
	UI.pin(_opp.root, Vector2(1.0, 0.0), Vector2(-14, 14))

	# ---- before the bell: how to start, and the controls
	var rp := Plate.new(22, 16)
	rp.cut = 14
	rp.bar_top = UI.ACCENT
	rp.custom_minimum_size = Vector2(620, 0)
	var go_text := "TAP [color=#111][bgcolor=#ffc81e] START [/bgcolor][/color] TO FIGHT" if touch else "PRESS [color=#111][bgcolor=#ffc81e] ENTER [/bgcolor][/color] TO START"
	var go := UI.rich(go_text, {"kind": "display", "size": 44, "weight": 600, "italic": true, "align": "center", "ls": 0.05, "wrap": false})
	var note := "Pause (❚❚) shows these again, with the settings, any time." if touch else "Esc pauses the fight and shows these again, with the settings."
	rp.add_child(UI.vbox(8, [
		go,
		UI.label("CONTROLS", {"kind": "cond", "size": 12, "weight": 700, "ls": 0.3, "color": UI.DIM, "align": "center"}),
		UI.rich(controls_bbcode(two_player), {"kind": "cond", "size": 14, "weight": 500, "color": UI.DIM, "align": "center"}),
		UI.label(note, {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "align": "center"}),
	]))
	_ready_card = _centered(rp, 0.5)

	# ---- banner
	_banner_text = UI.label("", {"kind": "display", "size": 64, "weight": 700, "italic": true, "color": UI.ACCENT, "align": "center", "ls": 0.06, "shadow": true})
	var bp := PanelContainer.new()
	bp.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.72), {"pad": [44, 0]}))
	bp.add_child(UI.vbox(2, [HazardStrip.new(4, 8), _banner_text, HazardStrip.new(4, 8)]))
	bp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner = _centered(bp, 0.42)
	_banner.modulate.a = 0.0

	# ---- the referee's count
	_count_n = UI.label("", {"kind": "display", "size": 150, "weight": 700, "italic": true, "align": "center", "shadow": true})
	_count_who = UI.label("", {"kind": "cond", "size": 16, "weight": 700, "ls": 0.24, "align": "center"})
	_count = _centered(UI.vbox(-30, [_count_n, _count_who]), 0.3)
	_count.modulate.a = 0.0

	# ---- tale of the tape
	_intro = _centered(_build_intro(opts), 0.38)
	_intro.visible = false

	# ---- the result
	_results = Plate.new(34, 24)
	_results.cut = 16
	_results.bar_top = UI.ACCENT
	_results.bar_w = 6
	_results_box = UI.vbox(6)
	_results.add_child(_results_box)
	var rc := _centered(_results, 0.5)
	rc.visible = false
	_results.set_meta("holder", rc)

	# ---- replay pill
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", UI.box(Color(0.1, 0.11, 0.13, 0.88), {"border": UI.EDGE, "pad": [16, 7], "skew": 0.2}))
	_scrub = Meter.new(3, 110)
	_scrub.ease_rate = 0.0
	_scrub.from = UI.ACCENT
	_scrub.to = UI.ACCENT
	_scrub.value = 0.0
	_scrub.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.add_child(UI.hbox(9, [UI.label("●", {"size": 12, "color": UI.BAD}), UI.label("REPLAY", {"kind": "cond", "size": 13, "weight": 700, "ls": 0.3}), _scrub]))
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(pill)
	UI.pin(pill, Vector2(0.5, 1.0), Vector2(0, -20))
	pill.visible = false
	_replay = pill

# A control held at the middle of the screen, `at` of the way down.
func _centered(c: Control, at: float) -> Control:
	var holder := CenterContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.anchor_left = 0.0
	holder.anchor_right = 1.0
	holder.anchor_top = at
	holder.anchor_bottom = at
	holder.grow_vertical = Control.GROW_DIRECTION_BOTH
	holder.add_child(c)
	add_child(holder)
	return holder

func _card(a: Dictionary, side: String) -> Dictionary:
	var p := Plate.new(12, 7)
	p.cut = 10
	p.custom_minimum_size = Vector2(230, 0)
	if side == "me": p.bar_left = UI.RED
	else: p.bar_right = UI.BLUE
	var title_col := UI.HOT if side == "me" else Color("6eaaff")
	var name_l := UI.label(str(a.name).to_upper(), {"kind": "cond", "size": 12, "weight": 700, "ls": 0.2, "color": title_col, "clip": true, "expand": true})
	var num := UI.label("#%s" % J.s(a.get("number", "")), {"kind": "mono", "size": 11, "weight": 700, "color": UI.ACCENT})
	var tag := UI.label("", {"kind": "cond", "size": 10, "weight": 700, "ls": 0.1, "color": UI.INK})
	var tag_bg := PanelContainer.new()
	tag_bg.add_theme_stylebox_override("panel", UI.box(UI.ACCENT, {"pad": [5, 0]}))
	tag_bg.add_child(tag)
	tag_bg.visible = false
	var title := UI.hbox(6, [tag_bg, num, name_l] if side == "opp" else [name_l, num, tag_bg])
	if side == "opp": name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var hp := Meter.new(7)
	hp.set_colors(Color("3fbf6a"), Color("8be05a"))
	var hp_pct := UI.label("100%", {"kind": "mono", "size": 11, "weight": 500, "align": "right"})
	hp_pct.custom_minimum_size.x = 54
	var spin := Meter.new(7)
	spin.ease_rate = 0.0
	spin.set_colors(Color("f0a63c"), Color("ff5a52"))
	spin.value = 0.0
	var wstate := UI.label("-", {"kind": "mono", "size": 11, "weight": 500, "align": "right"})
	wstate.custom_minimum_size.x = 54
	var hl := UI.label("HEALTH", {"kind": "cond", "size": 12, "weight": 600, "ls": 0.16, "color": UI.DIM})
	hl.custom_minimum_size.x = 52
	var wl := UI.label("WEAPON", {"kind": "cond", "size": 12, "weight": 600, "ls": 0.16, "color": UI.DIM})
	wl.custom_minimum_size.x = 52
	var wrow := UI.hbox(6, [wl, spin, wstate])
	# A wedge has no weapon to report.
	wrow.visible = Weapon.family_of(J.path(a, ["stats", "weapon", "class"])) != Weapon.NONE
	var damage := UI.vbox(2)
	damage.visible = false
	p.add_child(UI.vbox(3, [title, UI.hbox(6, [hl, hp, hp_pct]), wrow, damage]))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return {"root": p, "tag": tag, "tag_bg": tag_bg, "hp": hp, "hp_pct": hp_pct, "wrow": wrow, "spin": spin, "wstate": wstate, "damage": damage}

func _build_intro(opts: Dictionary) -> Control:
	var row := UI.hbox(0)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var ids := [fight.red.id, fight.blue.id]
	for i in 2:
		var c: Dictionary = corners.get(ids[i], {"corner": "red" if i == 0 else "blue", "assembled": fight.units[i].assembled, "driver": ""})
		var a: Dictionary = c.assembled
		var red: bool = c.corner == "red"
		var p := Plate.new(26, 16)
		p.bar_top = UI.RED if red else UI.BLUE
		p.bar_w = 6
		p.top_color = Color(0.118, 0.129, 0.149, 0.94).lerp(UI.RED if red else UI.BLUE, 0.12)
		p.bottom_color = Color(0.055, 0.059, 0.071, 0.96)
		p.border_color = Color(0, 0, 0, 0)
		var al := "left" if red else "right"
		var weapon_name: String = a.parts.weapon.name if a.parts.get("weapon") != null else "no weapon"
		p.add_child(UI.vbox(2, [
			UI.label("%s CORNER" % c.corner.to_upper(), {"kind": "cond", "size": 13, "weight": 700, "ls": 0.3, "color": _corner_color(c.corner), "align": al}),
			UI.label("%s  #%s" % [str(a.name).to_upper(), J.s(a.get("number", ""))], {"kind": "display", "size": 44, "weight": 600, "italic": true, "shadow": true, "align": al}),
			UI.label("%s · %s" % [str(a.get("archetype", "")).replace("_", " ").capitalize(), weapon_name], {"kind": "cond", "size": 15, "weight": 500, "align": al}),
			UI.label("%s lb · %s mph" % [J.fixed(a.weightLb, 0), J.fixed(a.stats.topSpeedMph, 1)], {"kind": "cond", "size": 15, "weight": 500, "align": al}),
			UI.label("driver: %s" % c.get("driver", ""), {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM, "align": al}),
		]))
		row.add_child(p)
		if i == 0:
			var vs := UI.label(" VS ", {"kind": "display", "size": 92, "weight": 700, "italic": true, "shadow": true})
			UI.gradient_text(vs, [Color.WHITE, Color("ffd84a"), Color("ff7a1a"), Color("9b2a0a")])
			row.add_child(vs)
	var col := UI.vbox(10)
	var story = opts.get("story")
	if story is Dictionary and (J.truthy(story.get("grudge")) or J.truthy(story.get("level")) or story.get("series") != null):
		var grudge: bool = J.truthy(story.get("grudge"))
		var t: String = "GRUDGE MATCH" if grudge else (str(story.get("name", "")).to_upper() if J.truthy(story.get("level")) else "REMATCH")
		if story.get("series") != null: t += "    series %s-%s" % [J.s(story.series.w), J.s(story.series.l)]
		col.add_child(UI.label(t, {"kind": "display", "size": 28, "weight": 600, "italic": true, "ls": 0.14, "align": "center", "shadow": true,
			"color": Color("ff5a44") if (grudge or J.g(story, "level", 0) >= 2) else Color("ffb070")}))
	col.add_child(row)
	var where = opts.get("where")
	if where is Dictionary:
		col.add_child(UI.label("%s  ·  %s" % [str(where.get("venue", "")).to_upper(), str(where.get("layout", "")).to_upper()],
			{"kind": "cond", "size": 16, "weight": 700, "ls": 0.3, "align": "center", "shadow": true, "color": Color("e8ecf2")}))
	return col

# ---------------------------------------------------------------- events

func _show_cam() -> void:
	var list := cam.list()
	for i in list.size():
		if list[i].id == cam.cam_id():
			_cam_tag.text = "%d  %s" % [i + 1, str(list[i].label).to_upper()]
			_cam_tag.modulate.a = 1.0
			_cam_t = 1.6

## A line across the middle of the screen for a moment.
func banner(text: String, seconds := 1.6) -> void:
	_banner_text.text = text
	_banner.modulate.a = 1.0
	_banner_t = seconds

func _on_count(e: Dictionary) -> void:
	_count_n.text = J.s(e.count)
	_count_n.add_theme_color_override("font_color", Color("ff3b2e") if e.count >= e.of - 2 else Color.WHITE)
	_count_who.text = _name_of(e.botId).to_upper()
	_count_who.add_theme_color_override("font_color", _corner_color(_corner_of(e.botId)))
	_count.modulate.a = 1.0
	_count_t = 1.3

func hide_results() -> void:
	(_results.get_meta("holder") as Control).visible = false

func results_showing() -> bool:
	return (_results.get_meta("holder") as Control).visible

## The result card. `keys_text`: what the keys do from here.
func show_results(r, keys_text := "") -> void:
	if r == null: return
	if keys_text == "": keys_text = "[Enter] rematch   [P] highlights   [O] next opponent   [M] menu"
	UI.clear(_results_box)
	var a = fight.red.id
	var b = fight.blue.id
	var how := ""
	if r.method == "ko": how = "KNOCKOUT  [color=#8f939a]· %s %s[/color]" % [_name_of(r.loserId).to_upper(), str(CAUSE.get(r.get("cause"), "was counted out")).to_upper()]
	elif r.method == "tapout": how = "TAP OUT  [color=#8f939a]· %s CONCEDED[/color]" % _name_of(r.loserId).to_upper()
	else: how = "%s DECISION" % ("UNANIMOUS" if r.get("decision") == "unanimous" else "SPLIT")
	if r.method != "decision": how += " AT %s" % U.format_clock(r.elapsedS)
	_results_box.add_child(UI.label("WINNER", {"kind": "cond", "size": 14, "weight": 700, "ls": 0.4, "color": UI.HOT, "align": "center"}))
	_results_box.add_child(UI.label(_name_of(r.winnerId).to_upper(), {"kind": "display", "size": 74, "weight": 600, "italic": true, "shadow": true,
		"align": "center", "color": _corner_color(_corner_of(r.winnerId))}))
	_results_box.add_child(UI.rich(how, {"kind": "cond", "size": 18, "weight": 600, "ls": 0.1, "align": "center", "wrap": false}))
	var cards = r.get("cards")
	if cards is Array and not cards.is_empty():
		var grid := GridContainer.new()
		grid.columns = 1 + cards.size() * 2
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 4)
		grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		var head := {"kind": "cond", "size": 12, "weight": 600, "ls": 0.16, "color": UI.DIM, "align": "center"}
		grid.add_child(UI.spacer())
		for c in cards:
			grid.add_child(UI.label("JUDGE %s" % J.s(c.judge), head))
			grid.add_child(UI.spacer())
		grid.add_child(UI.spacer())
		for c in cards:
			for id in [a, b]:
				var n := _name_of(id)
				grid.add_child(UI.label((n.substr(0, 9) + "." if n.length() > 10 else n).to_upper(),
					{"kind": "cond", "size": 12, "weight": 600, "ls": 0.1, "color": _corner_color(_corner_of(id)), "align": "center"}))
		for cat in [["Damage", "damage"], ["Aggression", "aggression"], ["Control", "control"]]:
			grid.add_child(UI.label(cat[0], {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM}))
			for c in cards:
				for id in [a, b]:
					grid.add_child(UI.label(J.s(c.scores[id][cat[1]]), {"kind": "mono", "size": 13, "weight": 500, "align": "center", "color": _corner_color(_corner_of(id))}))
		grid.add_child(UI.label("Total", {"kind": "cond", "size": 15, "weight": 700}))
		for c in cards:
			for id in [a, b]:
				grid.add_child(UI.label(J.s(c.scores[id].total), {"kind": "mono", "size": 13, "weight": 700, "align": "center",
					"color": UI.ACCENT if c.get("winnerId") == id else UI.TEXT}))
		_results_box.add_child(UI.spacer(0, 6))
		_results_box.add_child(grid)
	_results_box.add_child(UI.spacer(0, 8))
	_results_box.add_child(UI.rich(UI.keys(keys_text), {"kind": "cond", "size": 13, "weight": 500, "color": UI.DIM, "align": "center", "wrap": false}))
	(_results.get_meta("holder") as Control).visible = true

## Settings -> Damage readout.
func set_show_damage(on: bool) -> void:
	_show_damage = on
	for c in [_me, _opp]: c.damage.visible = on and c.damage.get_child_count() > 0

# ---------------------------------------------------------------- per frame

static func _short_name(r: Dictionary) -> String:
	var key: String = r.key
	if key.begins_with("armor."): return "armour %s" % key.split(".")[1]
	return key.capitalize().to_lower()

# The parts that are actually hurt, worst first - nothing while it is all
# fresh. The full list is the pit's job.
func _fill_health(c: Dictionary, a: Dictionary) -> void:
	var report := Condition.condition_report(a, fight.rules)
	var left := 0.0
	var full := 0.0
	for r in report:
		left += r.hpRemaining
		full += r.hpFull
	var h := left / full if full > 0.0 else 1.0
	c.hp.value = h
	if h < 0.25: c.hp.set_colors(Color("c4161c"), Color("ff5a4f"))
	elif h < 0.5: c.hp.set_colors(Color("e0a020"), Color("f0c419"))
	else: c.hp.set_colors(Color("3fbf6a"), Color("8be05a"))
	c.hp_pct.text = "%d%%" % int(round(h * 100.0))
	var rows := Condition.worst_first(report).filter(func(r): return r.condition < 0.995).slice(0, 3)
	var box: VBoxContainer = c.damage
	while box.get_child_count() > rows.size():
		var last := box.get_child(box.get_child_count() - 1)
		box.remove_child(last)
		last.queue_free()
	while box.get_child_count() < rows.size():
		var nm := UI.label("", {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "clip": true})
		nm.custom_minimum_size.x = 62
		var bar := Meter.new(4, 40)
		var pct := UI.label("", {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "align": "right"})
		pct.custom_minimum_size.x = 30
		box.add_child(UI.hbox(6, [nm, bar, pct]))
	for i in rows.size():
		var r: Dictionary = rows[i]
		var row := box.get_child(i)
		var col := UI.OK
		var name_col := UI.DIM
		match r.status:
			"impaired": col = UI.WARN; name_col = UI.WARN
			"critical": col = UI.BAD; name_col = UI.BAD
			"failed": col = Color("555555"); name_col = Color("666666")
		(row.get_child(0) as Label).text = _short_name(r).capitalize()
		(row.get_child(0) as Label).add_theme_color_override("font_color", name_col)
		var bar: Meter = row.get_child(1)
		bar.set_colors(col, col)
		bar.value = r.condition
		(row.get_child(2) as Label).text = "%d%%" % int(round(r.condition * 100.0))
	box.visible = _show_damage and not rows.is_empty()

func _fill_card(c: Dictionary, u: Dictionary, tag_text: String) -> void:
	c.tag.text = tag_text
	c.tag_bg.visible = tag_text != ""
	if not c.wrow.visible: return
	var w: Weapon = u.weapon
	var dead: bool = J.truthy(J.path(u.sim.effective(), ["weapon", "dead"]))
	c.wstate.text = "DEAD" if dead else w.phase.to_upper()
	c.wstate.add_theme_color_override("font_color", UI.BAD if dead else UI.TEXT)
	c.spin.value = w.spinPct
	if w.spinPct > 0.98: c.spin.set_colors(Color("4ad07a"), Color("f0c419"))
	else: c.spin.set_colors(Color("f0a63c"), Color("ff5a52"))

## Called once per rendered frame.
func update(dt: float) -> void:
	var bout := fight.bout
	var phase := bout.phase
	_clock.text = U.format_clock(bout.clockS)
	_clock.add_theme_color_override("font_color", Color("ff3b2e") if (phase == Match.LIVE and bout.clockS <= 30.0) else Color("ffb21e"))
	match phase:
		Match.IDLE: _phase.text = start_hint()
		Match.COUNTDOWN: _phase.text = "%d" % int(ceil(bout.countdownS)) if bout.countdownS > 0.05 else "FIGHT!"
		Match.PAUSED: _phase.text = "PAUSED"
		Match.ENDED: _phase.text = "FINAL"
		_: _phase.text = "LIVE"
	var replaying := fight.replay.playing
	# Before the bell: how to start, and the controls.
	_ready_card.visible = phase == Match.IDLE and not replaying
	# Intro cards from the moment the match is called until the bell, then a
	# beat of FIGHT!
	_intro.visible = phase == Match.COUNTDOWN
	if _last_phase == Match.COUNTDOWN and phase == Match.LIVE: banner("FIGHT!", 1.0)
	_last_phase = phase

	if _count_t > 0.0:
		_count_t -= dt
		if _count_t <= 0.0 or phase != Match.LIVE: _count.modulate.a = 0.0
	if _banner_t > 0.0:
		_banner_t -= dt
		if _banner_t <= 0.0: _banner.modulate.a = 0.0
	if _cam_t > 0.0:
		_cam_t -= dt
		if _cam_t <= 0.0: _cam_tag.modulate.a = 0.0

	# The two cards: tags and weapons every frame, health a few times a second.
	_fill_card(_me, fight.red, "P1" if two_player else ("AI" if fight.pilot.mode == Pilot.AI_DRIVER else ""))
	_fill_card(_opp, fight.blue, ("P2" if fight.p2_human else "AI") if two_player else "")
	_dmg_t -= dt
	if _dmg_t <= 0.0:
		_fill_health(_me, fight.red.assembled)
		_fill_health(_opp, fight.blue.assembled)
		_dmg_t = 0.25

	_replay.visible = replaying
	if replaying: _scrub.value = fight.replay.progress()
