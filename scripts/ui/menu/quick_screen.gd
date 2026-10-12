## quick_screen.gd - Quick Fight: pick any two robots in the field and put
## them in the box. Red is yours (or the AI's); blue is the AI's, or a second
## player's on the same keyboard.
class_name QuickScreen
extends VBoxContainer

const STORE_KEY := "robo-league.quickfight"
const CORNERS := ["red", "blue"]
const LEAGUE_CHIPS := [["all", "All"], ["world", "World"], ["elite", "Elite"], ["pro", "Pro"], ["rookie", "Rookie"], ["exhibition", "Exhibition"]]
const LEAGUE_TINT := {"world": Color("ffd54f"), "elite": Color("b39ddb"), "pro": Color("80cbc4")}

var menu: Menu
var pick := {}
var filters := {"red": {"league": "all", "query": ""}, "blue": {"league": "all", "query": ""}}
var active := "red"              # the corner the arrow keys drive

var _ui := {}                    # corner -> { plate, stage, card, list, scroll, rows, chips }
var _blurb: Label
var _p2_note: RichTextLabel
var _driver_btns := {}
var _blue_btns := {}

func _init(owner_menu: Menu) -> void:
	menu = owner_menu
	add_theme_constant_override("separation", 0)
	var reg := menu.reg
	var saved = Store.read_json(STORE_KEY)
	if not (saved is Dictionary): saved = {}
	pick = {
		"red": saved.get("red") if menu.by_id.has(saved.get("red")) else reg.playerId,
		"blue": saved.get("blue") if menu.by_id.has(saved.get("blue")) else ("spinner_test" if menu.by_id.has("spinner_test") else menu.entries[0].id),
		"driver": "ai" if saved.get("driver") == "ai" else "you",
		# Blue: the AI, or a second player on the same keyboard.
		"blueDriver": "p2" if saved.get("blueDriver") == "p2" else "ai",
		# Where: a venue and a hazard layout (data/arenas.json); "random"
		# layout draws one from the venue's pool.
		"venue": saved.get("venue") if Arenas.venue_of(reg, saved.get("venue")) != null else Arenas.DEFAULT_VENUE,
		"layout": saved.get("layout") if (saved.get("layout") == "random" or Arenas.layout_of(reg, saved.get("layout")) != null) else "random",
	}
	add_child(menu.bar("Quick Fight", "[← →] corner · [↑ ↓] robot · [Enter] fight · [Esc] back"))
	var grid := UI.hbox(14, [_corner("red"), _middle(), _corner("blue")])
	var body := UI.margin(grid, 18, 14, 18, 18)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)
	for c in CORNERS:
		_render_list(c)
		_render_card(c)
		_ui[c].stage.show_bot(pick[c])
	_set_active(active)
	_show_blurb()
	_show_p2_note()

func _save() -> void:
	Store.write_json(STORE_KEY, pick)

# ---------------------------------------------------------------- building

func _corner(c: String) -> Control:
	var red := c == "red"
	var tint := UI.RED if red else UI.BLUE
	var plate := Plate.new(0, 0)
	plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plate.bolts = false
	# Head: the corner's name on its colour, and who drives.
	var name_bg := PanelContainer.new()
	name_bg.add_theme_stylebox_override("panel", UI.box(tint, {"pad": [18, 6, 2], "skew": 0.0}))
	name_bg.add_child(UI.label("%s CORNER" % c.to_upper(), {"kind": "display", "size": 26, "weight": 600, "italic": true, "ls": 0.08, "color": Color.WHITE, "shadow": true}))
	name_bg.custom_minimum_size = Vector2(230, 40)
	var driver := UI.hbox(4, [UI.label("DRIVER", {"kind": "cond", "size": 12, "weight": 600, "ls": 0.1, "color": UI.DIM})])
	if red:
		for d in [["you", "YOU"], ["ai", "AI"]]:
			var b := UI.button(d[1], "seg")
			b.button_pressed = pick.driver == d[0]
			b.pressed.connect(func():
				pick.driver = d[0]
				_save()
				for k in _driver_btns: (_driver_btns[k] as Button).button_pressed = k == pick.driver
				_show_p2_note())
			_driver_btns[d[0]] = b
			driver.add_child(b)
	else:
		for d in [["ai", "AI"], ["p2", "PLAYER 2"]]:
			var b := UI.button(d[1], "seg")
			b.button_pressed = pick.blueDriver == d[0]
			if d[0] == "p2": b.tooltip_text = "Two players on one keyboard: red on W A S D + Space, blue on the arrows + /"
			b.pressed.connect(func():
				pick.blueDriver = d[0]
				_save()
				for k in _blue_btns: (_blue_btns[k] as Button).button_pressed = k == pick.blueDriver
				_show_p2_note())
			_blue_btns[d[0]] = b
			driver.add_child(b)
	var head := UI.hbox(8, [name_bg, UI.spacer(0, 0, true), driver, UI.spacer(8, 0)])
	# The robot on its turntable, with its card over the foot of it.
	var show := Control.new()
	show.custom_minimum_size.y = 330
	show.clip_contents = true
	var st := menu.stage()
	show.add_child(st)
	st.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var card := UI.vbox(1)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	show.add_child(card)
	card.anchor_left = 0.0
	card.anchor_right = 1.0
	card.anchor_top = 1.0
	card.anchor_bottom = 1.0
	card.offset_left = 14
	card.offset_right = -14
	card.offset_bottom = -8
	card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# The picker: search, league chips, the list.
	var search := LineEdit.new()
	search.placeholder_text = "Search robots, teams, weapons"
	search.clear_button_enabled = true
	search.text_changed.connect(func(t: String):
		filters[c].query = t
		_render_list(c))
	search.focus_entered.connect(func(): _set_active(c))
	var chips := UI.hbox(5)
	var chip_btns := {}
	for l in LEAGUE_CHIPS:
		var b := UI.button(str(l[1]).to_upper(), "chip")
		b.button_pressed = filters[c].league == l[0]
		b.pressed.connect(func():
			filters[c].league = l[0]
			for k in chip_btns: (chip_btns[k] as Button).button_pressed = k == l[0]
			_render_list(c)
			_set_active(c))
		chip_btns[l[0]] = b
		chips.add_child(b)
	var list := UI.vbox(0)
	var sc := UI.scroll(list)
	var picker := UI.vbox(6, [search, chips, sc])
	picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plate.add_child(UI.vbox(0, [head, show, UI.margin(picker, 12, 8, 12, 10)]))
	plate.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed: _set_active(c))
	_ui[c] = {"plate": plate, "stage": st, "card": card, "list": list, "scroll": sc, "rows": {}, "tint": tint}
	return plate

func _middle() -> Control:
	var reg := menu.reg
	var vs := UI.label("VS", {"kind": "display", "size": 120, "weight": 700, "italic": true, "align": "center", "shadow": true})
	UI.gradient_text(vs, [Color.WHITE, Color("ffd84a"), Color("ff7a1a"), Color("9b2a0a")])
	var fight := UI.button("FIGHT!", "fight")
	fight.pressed.connect(start_fight)
	var random := UI.button("RANDOM MATCHUP", "ghost")
	random.pressed.connect(func():
		var field := menu.entries.filter(func(e): return e.league != "exhibition")
		for c in CORNERS: choose(c, field[randi() % field.size()].id, true))
	var swap := UI.button("SWAP CORNERS", "ghost")
	swap.pressed.connect(func():
		var r = pick.red
		choose("red", pick.blue, true)
		choose("blue", r, true))
	var venue := OptionButton.new()
	var venue_ids := Arenas.venue_ids(reg)
	for i in venue_ids.size():
		venue.add_item(Arenas.venue_of(reg, venue_ids[i]).name)
		if venue_ids[i] == pick.venue: venue.select(i)
	venue.item_selected.connect(func(i: int):
		pick.venue = venue_ids[i]
		_save()
		_show_blurb())
	var layout := OptionButton.new()
	var layout_ids := ["random"]
	layout.add_item("Random")
	for id in Arenas.layout_ids(reg):
		layout_ids.append(id)
		layout.add_item(Arenas.layout_of(reg, id).name)
	layout.select(maxi(0, layout_ids.find(pick.layout)))
	layout.item_selected.connect(func(i: int):
		pick.layout = layout_ids[i]
		_save()
		_show_blurb())
	_blurb = UI.label("", {"kind": "body", "size": 11, "weight": 400, "color": UI.DIM, "wrap": true})
	_p2_note = UI.rich("", {"kind": "body", "size": 11, "weight": 400, "color": UI.DIM})
	var head := {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}
	var col := UI.vbox(10, [vs, fight, random, swap, HSeparator.new(), UI.label("VENUE", head), venue, UI.label("LAYOUT", head), layout, _blurb, _p2_note])
	col.custom_minimum_size.x = 200
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	return col

func _show_blurb() -> void:
	var v = Arenas.venue_of(menu.reg, pick.venue)
	var l = Arenas.layout_of(menu.reg, pick.layout)
	_blurb.text = "%s — %s" % [v.get("tagline", "") if v is Dictionary else "", l.get("blurb", "") if l is Dictionary else "a layout from this venue's rotation."]

# Under the FIGHT button: who drives what, when a second player is in.
func _show_p2_note() -> void:
	if pick.blueDriver != "p2": _p2_note.text = ""
	elif pick.driver == "you": _p2_note.text = "[b]Two players, one keyboard.[/b] Red: W A S D, Space weapon, Shift brake. Blue: arrows, / or Ctrl weapon, . brake."
	else: _p2_note.text = "[b]You drive blue[/b] (arrows or W A S D, Space weapon); the AI drives red."

# One robot in a list: its colours, its name, its league.
class Row:
	extends Button
	var entry: Dictionary
	func _init(e: Dictionary, tint: Color) -> void:
		entry = e
		text = "      %s%s" % [e.name, "   · yours" if e.isPlayer else ""]
		toggle_mode = true
		focus_mode = Control.FOCUS_NONE
		alignment = HORIZONTAL_ALIGNMENT_LEFT
		clip_text = true
		UI.style(self, {"kind": "cond", "size": 16, "weight": 500, "ls": 0.02})
		add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0), {"pad": [10, 3]}))
		add_theme_stylebox_override("hover", UI.box(Color(1, 1, 1, 0.06), {"pad": [10, 3]}))
		add_theme_stylebox_override("pressed", UI.box(Color(tint, 0.45), {"pad": [10, 3]}))
		add_theme_stylebox_override("hover_pressed", UI.box(Color(tint, 0.5), {"pad": [10, 3]}))
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		add_theme_color_override("font_pressed_color", Color.WHITE)
		add_theme_color_override("font_hover_pressed_color", Color.WHITE)
		add_theme_color_override("font_hover_color", UI.TEXT)
	func _draw() -> void:
		var lv: Dictionary = entry.get("livery", {})
		var r := Rect2(10, size.y / 2.0 - 7.0, 14, 14)
		draw_rect(r, CanvasRec.css(J.g(lv, "primary", "#888888")))
		draw_rect(r, CanvasRec.css(J.g(lv, "accent", "#444444")), false, 2.0)
		var lg: String = "EXH" if entry.league == "exhibition" else str(entry.league).to_upper()
		var f := UI.font("cond", 700)
		var w := f.get_string_size(lg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var col: Color = QuickScreen.LEAGUE_TINT.get(entry.league, UI.DIM)
		var box := Rect2(size.x - w - 20, size.y / 2.0 - 8.0, w + 10, 16)
		draw_rect(box, Color(col, 0.4), false, 1.0)
		draw_string(f, Vector2(box.position.x + 5, box.position.y + 12), lg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

func _shown(c: String) -> Array:
	return Catalog.filter_catalog(menu.entries, filters[c].league, filters[c].query)

func _render_list(c: String) -> void:
	var ui: Dictionary = _ui[c]
	var list: VBoxContainer = ui.list
	UI.clear(list)
	ui.rows = {}
	var letter := ""
	var shown := _shown(c)
	for e in shown:
		var L := str(e.name).substr(0, 1).to_upper()
		var head := L if (L >= "A" and L <= "Z") else "#"
		if head != letter:
			letter = head
			var hl := PanelContainer.new()
			hl.add_theme_stylebox_override("panel", UI.box(Color("1d2025"), {"pad": [10, 4, 0]}))
			hl.add_child(UI.label(head, {"kind": "display", "size": 18, "weight": 600, "italic": true, "color": UI.HOT}))
			list.add_child(hl)
		var row := Row.new(e, ui.tint)
		row.button_pressed = e.id == pick[c]
		row.pressed.connect(func():
			_set_active(c)
			choose(c, e.id))
		list.add_child(row)
		ui.rows[e.id] = row
	if shown.is_empty(): list.add_child(UI.label("No robots match.", {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM}))
	_scroll_soon(c)

# Once the new rows have been laid out.
func _scroll_soon(c: String) -> void:
	if not is_inside_tree(): await ready
	for i in 2:
		# The screen may have been left (a fight started) while this waited.
		if not is_inside_tree(): return
		await get_tree().process_frame
	if is_inside_tree(): _scroll_to_pick(c)

func choose(c: String, id, rerender_list := false) -> void:
	if not menu.by_id.has(id): return
	pick[c] = id
	_save()
	var ui: Dictionary = _ui[c]
	if rerender_list: _render_list(c)
	else:
		for k in ui.rows: (ui.rows[k] as Button).button_pressed = k == id
		_scroll_to_pick(c)
	_render_card(c)
	ui.stage.show_bot(id)

# Bring the pick into view in its list.
func _scroll_to_pick(c: String) -> void:
	var ui: Dictionary = _ui[c]
	var row = ui.rows.get(pick[c])
	if row != null and is_instance_valid(row) and (row as Control).is_inside_tree(): (ui.scroll as ScrollContainer).ensure_control_visible(row)

func _render_card(c: String) -> void:
	var card: VBoxContainer = _ui[c].card
	UI.clear(card)
	var s := Catalog.spec_card(menu.reg, pick[c])
	card.add_child(UI.label(str(s.name).to_upper(), {"kind": "display", "size": 44, "weight": 600, "italic": true, "shadow": true}))
	card.add_child(UI.spacer(0, 5))
	var meta := str(s.league)
	if J.truthy(s.get("team")): meta += " · %s" % s.team
	if s.get("rating") != null: meta += " · driver %s" % J.s(s.rating)
	if J.truthy(s.get("inspiredBy")): meta += "    a nod to %s" % s.inspiredBy
	card.add_child(UI.label(meta, {"kind": "cond", "size": 14, "weight": 500, "color": Color("b9c1cd"), "shadow": true}))
	card.add_child(UI.label(str(s.weapon).to_upper(), {"kind": "cond", "size": 15, "weight": 700, "ls": 0.08, "color": UI.ACCENT, "shadow": true}))
	var bits := [["WEAPON", str(s.weaponClass)], ["WEIGHT", "%s lb" % J.s(s.weightLb)], ["TOP SPEED", "%s mph" % J.s(s.topSpeedMph)],
		["ARMOUR", "%s hp" % J.s(s.armourHp)], ["PUSH", "%s×" % J.s(s.pushRatio)]]
	if J.truthy(s.get("weaponEnergyKJ")): bits.append(["ENERGY", "%s kJ" % J.s(s.weaponEnergyKJ)])
	var stats := HFlowContainer.new()
	stats.add_theme_constant_override("h_separation", 14)
	stats.add_theme_constant_override("v_separation", 0)
	for b in bits:
		stats.add_child(UI.hbox(5, [UI.label(b[0], {"kind": "cond", "size": 12, "weight": 600, "ls": 0.08, "color": UI.DIM, "shadow": true}),
			UI.label(b[1], {"kind": "mono", "size": 13, "weight": 700, "shadow": true})]))
	card.add_child(stats)
	var tags := []
	if J.truthy(s.get("invertible")): tags.append("INVERTIBLE")
	if J.truthy(s.get("selfRights")): tags.append("SELF-RIGHTS")
	if s.get("partner") is Dictionary: tags.append("MULTIBOT + %s" % str(s.partner.name).to_upper())
	if not tags.is_empty():
		var row := UI.hbox(6)
		for t in tags:
			var tag := PanelContainer.new()
			tag.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.35), {"border": Color(1, 0.78, 0.12, 0.5), "pad": [8, 1]}))
			tag.add_child(UI.label(t, {"kind": "cond", "size": 11, "weight": 700, "ls": 0.1, "color": UI.ACCENT}))
			row.add_child(tag)
		card.add_child(row)

func _set_active(c: String) -> void:
	active = c
	for k in CORNERS:
		var p: Plate = _ui[k].plate
		p.ring = _ui[k].tint if k == c else null
		p.bar_top = _ui[k].tint
		p.queue_redraw()

## Keys for this screen. Returns true if it used the key.
func keys(e: InputEventKey) -> bool:
	match e.keycode:
		KEY_LEFT: _set_active("red")
		KEY_RIGHT: _set_active("blue")
		KEY_DOWN, KEY_UP:
			var shown := _shown(active)
			if shown.is_empty(): return true
			var i := -1
			for k in shown.size():
				if shown[k].id == pick[active]: i = k
			var next := 0 if i < 0 else (i + (1 if e.keycode == KEY_DOWN else -1) + shown.size()) % shown.size()
			choose(active, shown[next].id)
		KEY_ENTER, KEY_KP_ENTER:
			if not e.echo: start_fight()
		_: return false
	return true

func start_fight() -> void:
	_save()
	var req := {"mode": "quick", "red": pick.red, "blue": pick.blue, "venue": pick.venue, "layout": pick.layout}
	if pick.driver == "ai": req.driver = "ai"
	if pick.blueDriver == "p2": req.p2 = true
	Game.start_fight(req)
