## menu.gd - the front end: main menu, Quick Fight, Settings, Credits,
## Career, Tournament and the Hall of Fame.
##
## One screen at a time, each named by a route ("quick", "career",
## "career/workshop"...) and kept in a history, so the back and forward
## arrows work like a browser's. The fight itself is its own scene; Quick
## Fight, the career and the tournament hand over to it through Game.
class_name Menu
extends Control

const MENU := [
	{"id": "career", "title": "Career", "desc": "Climb four leagues, chase the Giant Nut, keep the lights on."},
	{"id": "quick", "title": "Quick Fight", "desc": "Pick any two robots in the field and put them in the box. Two players on one keyboard, too."},
	{"id": "tournament", "title": "Tournament", "desc": "A one-off knockout, groups or the Giant Nut - for you, your friends, or the AI."},
	{"id": "halloffame", "title": "Hall of Fame", "desc": "Retired careers, legendary robots and the all-time records."},
	{"id": "settings", "title": "Settings", "desc": "Difficulty, graphics, display and controls."},
	{"id": "credits", "title": "Credits", "desc": "Who made this, and with what."},
	{"id": "quit", "title": "Quit", "desc": "Close the game. Everything is saved as you go."},
]

var reg: Registry
## Every robot there is, for the pickers (logic/catalog.gd).
var entries: Array = []
var by_id := {}

var _holder: Control
var _screen: Control = null
var _route := "main"
var _menu_index := 1                 # Quick Fight
var _menu_items := []
var _glow_tex: GradientTexture2D
var _career: Control = null          # kept between visits, so the career stays loaded
var _tournament: Control = null

func _ready() -> void:
	reg = Game.reg
	theme = UI.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh_catalog()
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	_glow_tex = GradientTexture2D.new()
	_glow_tex.gradient = g
	_glow_tex.fill = GradientTexture2D.FILL_RADIAL
	_glow_tex.fill_from = Vector2(0.5, 0.5)
	_glow_tex.fill_to = Vector2(1.0, 0.5)
	_glow_tex.width = 256
	_glow_tex.height = 256
	_holder = Control.new()
	_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_holder)
	resized.connect(queue_redraw)
	# Where to open: where the last fight said to come back to, or where the
	# history was left.
	var nav: Dictionary = Game.nav
	var want: String = str((Game.request as Dictionary).get("screen", "")) if Game.request is Dictionary else ""
	Game.request = {}
	if want != "":
		if nav.stack.is_empty() or _base(nav.stack[nav.idx]) != want:
			nav.stack = nav.stack.slice(0, nav.idx + 1)
			nav.stack.append(want)
			nav.idx = nav.stack.size() - 1
	if nav.stack.is_empty():
		nav.stack = ["main"]
		nav.idx = 0
	_open(nav.stack[nav.idx])

static func _base(route: String) -> String:
	return route.split("/")[0]

## The catalog again (a career adds robots to the field).
func refresh_catalog() -> void:
	entries = Catalog.catalog(reg)
	by_id.clear()
	for e in entries: by_id[e.id] = e

# ---------------------------------------------------------------- the backdrop

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UI.BG)
	# Deck plate: fine diagonals both ways.
	var step := 16.0
	var n := int((size.x + size.y) / step) + 2
	for i in n:
		var x := i * step
		draw_line(Vector2(x, 0), Vector2(x - size.y, size.y), Color(0, 0, 0, 0.3), 2.0)
		draw_line(Vector2(x - size.y, 0), Vector2(x, size.y), Color(1, 1, 1, 0.025), 2.0)
	# A warm glow up right, the red and blue corners low down.
	for g in [[Vector2(0.72, 0.18), Vector2(1100, 620), Color(1, 0.55, 0.1, 0.13)], [Vector2(0.0, 1.0), Vector2(900, 600), Color(0.9, 0.16, 0.12, 0.10)],
			[Vector2(1.0, 1.0), Vector2(900, 600), Color(0.18, 0.53, 1.0, 0.10)]]:
		var c: Vector2 = Vector2(g[0].x * size.x, g[0].y * size.y)
		var r: Vector2 = g[1]
		draw_texture_rect(_glow_tex, Rect2(c - r, r * 2.0), false, g[2])
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.3))

# ---------------------------------------------------------------- routing

## Open a screen: a new history entry, drawn straight away.
func go(route: String) -> void:
	var nav: Dictionary = Game.nav
	if nav.stack[nav.idx] == route: return
	nav.stack = nav.stack.slice(0, nav.idx + 1)
	nav.stack.append(route)
	nav.idx = nav.stack.size() - 1
	_open(route)

func back() -> void:
	var nav: Dictionary = Game.nav
	if nav.idx <= 0: return
	nav.idx -= 1
	_open(nav.stack[nav.idx])

func forward() -> void:
	var nav: Dictionary = Game.nav
	if nav.idx >= nav.stack.size() - 1: return
	nav.idx += 1
	_open(nav.stack[nav.idx])

func current_route() -> String:
	return _route

func _open(route: String) -> void:
	_route = route
	if _screen != null:
		_holder.remove_child(_screen)
		# The career and the tournament keep their state between visits.
		if not is_same(_screen, _career) and not is_same(_screen, _tournament): _screen.queue_free()
		_screen = null
	var parts := route.split("/")
	var sub := parts[1] if parts.size() > 1 else ""
	match parts[0]:
		"quick": _screen = QuickScreen.new(self)
		"settings": _screen = _settings_screen()
		"credits": _screen = _credits_screen()
		"halloffame": _screen = _hall_screen()
		"career":
			if _career == null or not is_instance_valid(_career): _career = CareerScreen.new(self)
			_screen = _career
			_career.call("open", sub)
		"tournament":
			if _tournament == null or not is_instance_valid(_tournament): _tournament = TournamentScreen.new(self)
			_screen = _tournament
			_tournament.call("open", sub)
		_: _screen = _main_screen()
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_holder.add_child(_screen)

## The career and the tournament again from the saves (after an import, or
## when another career is opened). `career`: the one now being played, if the
## caller has it loaded.
func reload_saves(career = null) -> void:
	for s in [_career, _tournament]:
		if s != null and is_instance_valid(s) and not is_same(s, _screen): s.queue_free()
	if not is_same(_screen, _career): _career = null
	if not is_same(_screen, _tournament): _tournament = null
	reset_field(career)

## The field as the data files have it, plus the robots of the career being
## played (`career`, or the one saved) and of the tournament.
func reset_field(career = null) -> void:
	reg.reset_robots()
	Field.register_career_robots(reg, career if career != null else Store.read_json(Store.career_key()))
	var c := Cup.from_data(Store.read_json(Store.TOURNAMENT))
	if c.ok: Cup.register_cup_robots(reg, c.cup)
	refresh_catalog()

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed: return
	var e := event as InputEventKey
	var screen := _base(_route)
	# Alt + arrows: the back and forward arrows, from anywhere.
	if e.alt_pressed and (e.keycode == KEY_LEFT or e.keycode == KEY_RIGHT):
		if e.keycode == KEY_LEFT: back()
		else: forward()
		accept_event()
		return
	if e.keycode == KEY_ESCAPE and not e.echo:
		# The career's own screens (the workshop) step back to the hub first.
		if _screen != null and _screen.has_method("step_back") and _screen.call("step_back"):
			accept_event()
			return
		if screen != "main":
			go("main")
			accept_event()
			return
	if screen == "main": _main_keys(e)
	elif _screen != null and _screen.has_method("keys") and _screen.call("keys", e): accept_event()

func _exit_tree() -> void:
	# The screens kept between visits have no parent unless showing, so nothing
	# else frees them. The one showing goes with the tree - and it may be the
	# one that asked for the fight, still in the middle of its own call, so it
	# must not be freed here.
	for s in [_career, _tournament]:
		if s != null and is_instance_valid(s) and s.get_parent() == null: s.queue_free()

# ---------------------------------------------------------------- shared parts

## A screen's top bar: the back and forward arrows, a way back, its title
## and a hint. `extra`: controls for its right-hand end.
func bar(title: String, hint := "", back_label := "MENU", back_to := "main", extra: Array = []) -> Control:
	var nav: Dictionary = Game.nav
	var b := UI.button("‹", "back")
	UI.style(b, {"kind": "cond", "size": 24, "weight": 700})
	b.tooltip_text = "Back (Alt+←)"
	b.disabled = nav.idx <= 0
	b.pressed.connect(back)
	var f := UI.button("›", "back")
	UI.style(f, {"kind": "cond", "size": 24, "weight": 700})
	f.tooltip_text = "Forward (Alt+→)"
	f.disabled = nav.idx >= nav.stack.size() - 1
	f.pressed.connect(forward)
	var home := UI.button(back_label, "back")
	home.pressed.connect(func(): go(back_to))
	var row := UI.hbox(14, [UI.hbox(4, [b, f]), home,
		UI.label(title.to_upper(), {"kind": "display", "size": 32, "weight": 600, "italic": true, "ls": 0.06, "color": Color("f1efe8")})])
	row.add_child(UI.spacer(0, 0, true))
	for x in extra: row.add_child(x)
	if hint != "": row.add_child(UI.rich(UI.keys(hint), {"kind": "cond", "size": 13, "weight": 500, "color": UI.DIM, "wrap": false, "ls": 0.1}))
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("1d2024")
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(row)
	return UI.vbox(0, [panel, HazardStrip.new(4, 10)])

## A plain page under a top bar: `body` scrolls in the middle.
func page(title: String, body: Control, hint := "[Esc] back") -> Control:
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_child(body)
	var sc := UI.scroll(UI.margin(center, 20, 40))
	return UI.vbox(0, [bar(title, hint), sc])

## A turntable for a robot (ui/preview_stage.gd).
func stage(opts: Dictionary = {}) -> PreviewStage:
	return PreviewStage.new(opts)

func logo(size_px: int) -> Control:
	var a := UI.label("ROBO", {"kind": "display", "size": size_px, "weight": 700, "italic": true, "shadow": true})
	UI.gradient_text(a, [Color.WHITE, Color("c9ccd2"), Color("6d727a"), Color("e3e5e8")])
	var b := UI.label("LEAGUE", {"kind": "display", "size": size_px, "weight": 700, "italic": true, "shadow": true})
	UI.gradient_text(b, [Color("fff2a8"), UI.ACCENT, Color("d68a00"), Color("ffd84a")])
	return UI.hbox(int(size_px * 0.12), [a, b])

static func money(n: float) -> String:
	return "$" + J.commas(J.rndi(n))

# ---------------------------------------------------------------- main menu

func _main_screen() -> Control:
	var featured := entries.filter(func(e): return e.league != "exhibition" and not e.isPlayer)
	var feat: Dictionary = featured[int(Time.get_unix_time_from_system() / 8.0) % featured.size()]
	_menu_items.clear()
	var items := UI.vbox(6)
	for i in MENU.size():
		var item := MenuItem.new(MENU[i].title, MENU[i].desc)
		item.set_selected(i == _menu_index)
		item.chosen.connect(func(): _choose(MENU[i].id))
		# A browser tab or a phone app has no quit.
		if MENU[i].id == "quit" and (OS.has_feature("web") or Game.touch): item.visible = false
		item.hovered.connect(func(): _set_menu(i))
		items.add_child(item)
		_menu_items.append(item)
	var left := UI.vbox(0, [
		logo(118),
		UI.margin(HazardStrip.new(9, 10), 4, 0, 60, 0),
		UI.spacer(0, 18),
		UI.label("HEAVYWEIGHT COMBAT ROBOTICS · 250 LB · THREE MINUTES", {"kind": "cond", "size": 15, "weight": 600, "ls": 0.22, "color": Color("b5b2a9")}),
		UI.spacer(0, 34),
		items,
		UI.spacer(0, 0, true),
		UI.label("TAP TO CHOOSE" if Game.touch else "↑ ↓ TO CHOOSE · ENTER TO SELECT · F11 FULL SCREEN", {"kind": "cond", "size": 12, "weight": 600, "ls": 0.14, "color": UI.DIM}),
	])
	left.custom_minimum_size.x = 600
	var st := stage()
	st.show_bot(feat.id)
	var caption := UI.vbox(0, [
		UI.label("IN THE FIELD", {"kind": "cond", "size": 13, "weight": 600, "ls": 0.3, "color": UI.HOT, "align": "right"}),
		UI.label(str(feat.name).to_upper(), {"kind": "display", "size": 46, "weight": 600, "italic": true, "shadow": true, "align": "right"}),
		UI.label(("%s · %s" % [Catalog.LEAGUE_NAMES.get(feat.league, feat.league), feat.team]).to_upper(), {"kind": "cond", "size": 14, "weight": 500, "ls": 0.12, "color": UI.DIM, "align": "right"}),
	])
	var right := Control.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(st)
	st.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	right.add_child(caption)
	UI.pin(caption, Vector2(1.0, 1.0), Vector2(-90, -60))
	var row := UI.hbox(0, [UI.margin(left, 110, 80, 0, 54), right])
	return row

func _choose(id: String) -> void:
	if id == "quit": get_tree().quit()
	else: go(id)

func _set_menu(i: int) -> void:
	_menu_index = (i + MENU.size()) % MENU.size()
	if not (_menu_items[_menu_index] as Control).visible: _menu_index = 0
	for k in _menu_items.size(): (_menu_items[k] as MenuItem).set_selected(k == _menu_index)

func _main_keys(e: InputEventKey) -> void:
	if e.keycode == KEY_DOWN: _set_menu(_menu_index + 1)
	elif e.keycode == KEY_UP: _set_menu(_menu_index - 1)
	elif (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and not e.echo: _choose(MENU[_menu_index].id)
	else: return
	accept_event()

# One line of the main menu.
class MenuItem:
	extends PanelContainer
	signal chosen
	signal hovered
	var _title: Label
	var _sel := false

	func _init(title: String, desc: String) -> void:
		var sb := StyleBoxEmpty.new()
		sb.content_margin_left = 26
		sb.content_margin_right = 22
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		add_theme_stylebox_override("panel", sb)
		_title = UI.label(title.to_upper(), {"kind": "display", "size": 40, "weight": 600, "italic": true, "ls": 0.04, "color": Color("d6d4cd")})
		add_child(UI.vbox(-8, [_title, UI.label(desc, {"kind": "cond", "size": 15, "weight": 500, "ls": 0.04, "color": UI.DIM})]))
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func(): hovered.emit())

	func set_selected(on: bool) -> void:
		if _sel == on: return
		_sel = on
		_title.add_theme_color_override("font_color", UI.ACCENT if on else Color("d6d4cd"))
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _draw() -> void:
		if not _sel: return
		var w := size.x
		var h := size.y
		draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w - 14, h), Vector2(0, h)]),
			PackedColorArray([Color(1, 0.78, 0.12, 0.18), Color(1, 0.48, 0.1, 0.0), Color(1, 0.48, 0.1, 0.0), Color(1, 0.78, 0.12, 0.18)]))
		# The hazard-striped tab down its left edge.
		draw_rect(Rect2(0, 0, 8, h), UI.INK)
		var y := -8.0
		while y < h + 8.0:
			draw_colored_polygon(PackedVector2Array([Vector2(0, y + 8), Vector2(8, y), Vector2(8, y + 8), Vector2(0, y + 16)]), UI.ACCENT)
			y += 16.0

# ---------------------------------------------------------------- settings, credits

func _settings_screen() -> Control:
	var body := UI.vbox(18)
	body.custom_minimum_size.x = 720
	# Export and import: the career, the Hall of Fame, a tournament and the settings.
	body.add_child(SavesPanel.new(func():
		Game.settings = Game.load_settings()
		Game.apply_settings()
		reload_saves()
		_open(_route)))
	var card := Plate.new(26, 18)
	card.add_child(SettingsPanel.new(null, "Saved on this computer. Change them here, in your career (Settings tab), or in a fight (Esc)."))
	body.add_child(card)
	return page("Settings", body)

func _credits_screen() -> Control:
	var parodies := entries.filter(func(e): return e.origin == "parody").size()
	var originals := entries.filter(func(e): return e.origin == "original" and e.league != "exhibition").size()
	var body := UI.vbox(18)
	body.custom_minimum_size.x = 620
	var lg := logo(40)
	(lg as BoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(lg)
	for pair in [["Game design & direction", "Collin"], ["Programming", "Built with Claude Code"], ["Engine & rendering", "Godot Engine"],
			["Physics", "Jolt Physics"], ["The field", "%d robots - %d parodies, %d originals" % [reg.roster().size(), parodies, originals]]]:
		body.add_child(UI.vbox(0, [
			UI.label(str(pair[0]).to_upper(), {"kind": "cond", "size": 14, "weight": 700, "ls": 0.16, "color": UI.HOT, "align": "center"}),
			UI.label(str(pair[1]).to_upper(), {"kind": "display", "size": 28, "weight": 600, "italic": true, "align": "center"}),
		]))
	body.add_child(UI.label("Inspired by the sport of robot combat. Parody robots are affectionate nods with their own names and designs; this game is not affiliated with BattleBots or any team.",
		{"kind": "body", "size": 12, "weight": 400, "color": UI.DIM, "align": "center", "wrap": true}))
	return page("Credits", body)

# ---------------------------------------------------------------- hall of fame

func _hall_screen() -> Control:
	var hall := HallOfFame.from_data(Store.read_json(Store.HALL))
	if (hall.careers as Array).is_empty():
		var card := Plate.new(32, 28)
		card.custom_minimum_size.x = 640
		card.add_child(UI.vbox(12, [
			UI.label("THE HALL OF FAME IS EMPTY", {"kind": "display", "size": 44, "weight": 600, "italic": true}),
			UI.label("Retire from a career (Career → Trophies) and your team goes in here, with every robot it built, its titles and its records - and the AI robots that became legends while you were racing.",
				{"kind": "body", "size": 15, "weight": 400, "wrap": true}),
		]))
		return page("Hall of Fame", card)
	var left := UI.vbox(12, [UI.label("RETIRED CAREERS", {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT})])
	left.custom_minimum_size.x = 620
	for i in hall.careers.size():
		var c: Dictionary = hall.careers[i]
		var card := Plate.new(18, 14)
		var best: Dictionary = c.get("best", {})
		var rec: Dictionary = c.get("record", {})
		var line := "%s season%s · %s-%s%s · best: %s%s · earned %s" % [J.s(c.seasons), "s" if c.seasons > 1 else "", J.s(rec.get("wins", 0)), J.s(rec.get("losses", 0)),
			", %s KO" % J.s(rec.kos) if J.truthy(rec.get("kos")) else "", Catalog.LEAGUE_NAMES.get(best.get("league"), best.get("league", "")),
			" · Giant Nut: %s" % best.giantNut if J.truthy(best.get("giantNut")) else "", money(c.get("earned", 0.0))]
		var v := UI.vbox(4, [
			UI.hbox(12, [UI.label("#%d" % (i + 1), {"kind": "display", "size": 40, "weight": 700, "italic": true, "color": UI.ACCENT}),
				UI.label(str(c.team).to_upper(), {"kind": "display", "size": 30, "weight": 600, "italic": true})]),
			UI.label(line, {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM, "wrap": true}),
		])
		if J.truthy(c.get("giantNuts")): v.add_child(UI.label("%s Giant Nut%s" % [J.s(c.giantNuts), "s" if c.giantNuts > 1 else ""], {"kind": "cond", "size": 17, "weight": 700, "color": UI.ACCENT}))
		for t in c.get("titles", []):
			v.add_child(UI.label("★ %s   S%s%s" % [t.title, J.s(t.season), " · %s" % t.robot if J.truthy(t.get("robot")) else ""], {"kind": "cond", "size": 17, "weight": 500}))
		var robots := HFlowContainer.new()
		for r in c.get("robots", []):
			var chip := UI.button("%s v%s · %s-%s" % [r.name, J.s(r.version), J.s(r.wins), J.s(r.fights - r.wins)], "chip")
			chip.disabled = true
			robots.add_child(chip)
		v.add_child(robots)
		var nem = c.get("nemesis")
		if nem is Dictionary: v.add_child(UI.label("Nemesis: %s · %s-%s in %s meetings" % [nem.name, J.s(nem.w), J.s(nem.l), J.s(nem.fights)], {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM}))
		card.add_child(v)
		left.add_child(card)
	var right := UI.vbox(8, [UI.label("RECORDS", {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT})])
	right.custom_minimum_size.x = 460
	var rec: Dictionary = hall.get("records", {})
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 18)
	for spec in [["Most titles", "mostTitles", ""], ["Most Giant Nuts", "mostGiantNuts", ""], ["Most wins", "mostWins", ""], ["Longest win streak", "bestStreak", ""],
			["Fastest KO", "fastestKoS", "clock"], ["Most damage in a fight", "mostDamage", ""], ["Longest career", "longestCareer", "seasons"]]:
		var r = rec.get(spec[1])
		if not (r is Dictionary): continue
		var val := J.s(r.value)
		if spec[2] == "clock": val = U.format_clock(r.value)
		elif spec[2] == "seasons": val = "%s seasons" % J.s(r.value)
		grid.add_child(UI.label(spec[0], {"kind": "cond", "size": 15, "weight": 500}))
		grid.add_child(UI.label(val, {"kind": "mono", "size": 14, "weight": 700}))
		grid.add_child(UI.label(str(r.get("team", "")), {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM}))
	right.add_child(grid)
	right.add_child(UI.spacer(0, 10))
	right.add_child(UI.label("LEGENDS OF THE FIELD", {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}))
	if (hall.get("legends", []) as Array).is_empty():
		right.add_child(UI.label("An AI robot becomes a legend with three World titles, two Giant Nuts, or two Worlds and a Giant Nut in one career.",
			{"kind": "body", "size": 13, "weight": 400, "color": UI.DIM, "wrap": true}))
	for l in hall.get("legends", []):
		var what := []
		if J.truthy(l.get("worldTitles")): what.append("%sx World" % J.s(l.worldTitles))
		if J.truthy(l.get("giantNuts")): what.append("%sx Giant Nut" % J.s(l.giantNuts))
		right.add_child(UI.hbox(12, [UI.label(str(l.name), {"kind": "cond", "size": 16, "weight": 700}),
			UI.label(" · ".join(what), {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM}),
			UI.label("in %s's era" % l.get("era", ""), {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM})]))
	var cols := UI.hbox(30, [left, right])
	return page("Hall of Fame", cols)
