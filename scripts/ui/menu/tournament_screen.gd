## tournament_screen.gd - the Tournament screens: setting one up, and the hub
## that runs it (the next fight, the bracket, the groups, the results).
##
## All the rules are logic/cup.gd; this file only shows the cup and calls
## into it. The cup is saved after everything that changes it. A fight in the
## arena is handed over like a career fight: Game.start_fight says which
## fight, the arena leaves the result in Game.result when the bell goes, and
## the hub picks it up the next time it is shown.
class_name TournamentScreen
extends VBoxContainer

const SETUP_KEY := "robo-league.tournament.setup"
const METHOD := {"ko": "KO", "tapout": "tap out", "decision": "decision"}
const TABS := [["bracket", "Bracket"], ["groups", "Groups"], ["results", "Results"], ["players", "Players"]]

var menu: Menu
var reg: Registry
var cup = null
var tab := "bracket"
var last = null                  # the last person's fight, shown until the next is fought
var cfg: Dictionary
var entries: Array
var setup := {}

var _fight_btn: Button = null
var _error: Label = null

func _init(owner_menu: Menu) -> void:
	menu = owner_menu
	reg = menu.reg
	add_theme_constant_override("separation", 0)
	cfg = Cup.cup_config(reg)
	entries = menu.entries.filter(func(e): return not str(e.id).begins_with("cup_custom_"))
	var c := Cup.from_data(Store.read_json(Store.TOURNAMENT))
	if c.ok:
		cup = c.cup
		Cup.register_cup_robots(reg, cup)
	# The setup form, remembered between visits.
	setup = {"name": "Friday Night Cup", "format": "knockout", "size": 8, "fill": "random", "venue": "rounds", "layout": "random",
		"players": [{"name": "Player 1", "robot": reg.playerId}]}
	var saved = Store.read_json(SETUP_KEY)
	if saved is Dictionary: setup.merge(saved, true)
	setup.size = int(setup.size)

static func fmt(s: float) -> String:
	return "%d:%02d" % [int(floor(s / 60.0)), int(round(fmod(s, 60.0)))]

func save() -> void:
	if cup != null: Store.write(Store.TOURNAMENT, Cup.serialize_cup(cup))

func _save_setup() -> void:
	Store.write_json(SETUP_KEY, setup)

func name_of(id) -> String:
	return str(Cup.cup_def(reg, cup, id).name)

# "Ann (Hex Physician)" for a person's robot, the robot's name otherwise.
func who(id) -> String:
	var h = Cup.human_of(cup, id)
	if h != null: return "%s %s" % [Doc.esc(cup.players[int(h)].name), Doc.muted("(%s)" % Doc.esc(name_of(id)))]
	return Doc.esc(name_of(id))

# The player's career robot, if there is a career on this computer.
func _career_robot():
	var c := Career.from_data(Store.read_json(Store.career_key()))
	if not c.ok: return null
	Field.register_career_robots(reg, c.career)
	var d := Garage.player_def(reg, c.career)
	var out := {"name": d.name, "body": d.get("body"), "build": d.build, "livery": d.get("livery"), "personality": d.get("personality"), "archetype": d.get("archetype"),
		"rating": d.get("rating"), "schema": d.get("schema"), "number": d.get("number"), "origin": "original", "league": c.career.membership[c.career.playerId]}
	if d.get("partner") != null: out.partner = d.partner
	return out

# Pick up a fight result the arena left for us, if it is for the fight waiting.
func _collect_result() -> void:
	var handed = Game.result
	if not (handed is Dictionary) or handed.get("kind") != "tourney" or cup == null: return
	Game.result = null
	var f = Cup.next_cup_fight(cup)
	if f == null or f.id != handed.get("fixtureId"): return
	Cup.record_cup_result(reg, cup, f.id, handed.result)
	last = {"f": f, "result": handed.result}
	save()

func open(_sub := "") -> void:
	show_screen()

func show_screen() -> void:
	UI.clear(self)
	_fight_btn = null
	if cup == null:
		_setup_view()
		return
	_collect_result()
	Cup.advance_cup(reg, cup)
	save()
	_hub()

func keys(e: InputEventKey) -> bool:
	if e.echo or cup == null: return false
	if (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and _fight_btn != null and is_instance_valid(_fight_btn):
		do_fight()
		return true
	return false

# ---------------------------------------------------------------- setup

func _choice(big: String, small_text := "") -> Button:
	var b := UI.button("", "choice")
	var kids := [UI.label(big.to_upper(), {"kind": "display", "size": 22, "weight": 600, "italic": true, "ls": 0.04})]
	if small_text != "": kids.append(UI.label(small_text, {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "wrap": true}))
	var v := UI.vbox(-2, kids)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if small_text != "": v.custom_minimum_size.x = 190
	b.add_child(UI.margin(v, 10, 4))
	b.custom_minimum_size = Vector2(210 if small_text != "" else 70, 74 if small_text != "" else 40)
	return b

func _format_def() -> Dictionary:
	for f in cfg.formats:
		if f.id == setup.format: return f
	return cfg.formats[0]

func _setup_view() -> void:
	var fd := _format_def()
	var sizes: Array = fd.sizes.map(func(n): return int(n))
	if not sizes.has(int(setup.size)):
		setup.size = sizes[0]
		for n in sizes:
			if n >= setup.players.size():
				setup.size = n
				break
	var mine = _career_robot()
	var fills := [["random", "Random from the field"], ["top", "The best-rated"]]
	var lgs: Array = (reg.league.leagues as Array).duplicate()
	lgs.reverse()
	for lg in lgs: fills.append([lg, "%s first" % Catalog.LEAGUE_NAMES[lg]])
	add_child(menu.bar("Tournament", "[Esc] back"))
	var head := {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}

	var left := Doc.new(8)
	left.custom_minimum_size.x = 700
	left.add(UI.label("A ONE-OFF TOURNAMENT", {"kind": "display", "size": 44, "weight": 600, "italic": true}))
	left.p("Outside the career: no money, no damage carried - every robot is repaired between fights. Enter yourself, your friends, or nobody and watch it run.", {"tone": "muted"})
	left.add(UI.label("NAME", head))
	var name_edit := LineEdit.new()
	name_edit.text = str(setup.name)
	name_edit.max_length = 40
	name_edit.custom_minimum_size.x = 360
	name_edit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	name_edit.text_changed.connect(func(t: String):
		setup.name = t
		_save_setup())
	left.add(name_edit)
	left.add(UI.label("FORMAT", head))
	var frow := HFlowContainer.new()
	frow.add_theme_constant_override("h_separation", 6)
	for f in cfg.formats:
		var b := _choice(str(f.name), str(f.blurb))
		b.button_pressed = f.id == setup.format
		b.pressed.connect(func():
			setup.format = f.id
			_save_setup()
			show_screen())
		frow.add_child(b)
	left.add(frow)
	if sizes.size() > 1:
		left.add(UI.label("ROBOTS", head))
		var srow := UI.hbox(6)
		for n in sizes:
			var b := _choice(str(n))
			b.button_pressed = n == int(setup.size)
			b.pressed.connect(func():
				setup.size = n
				_save_setup()
				show_screen())
			srow.add_child(b)
		left.add(srow)
	if setup.format != "giantNut":
		left.add(UI.label("THE REST OF THE FIELD", head))
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 6)
		for f in fills:
			var b := UI.button(str(f[1]).to_upper(), "choice", {"size": 13})
			b.button_pressed = f[0] == setup.fill
			b.pressed.connect(func():
				setup.fill = f[0]
				_save_setup()
				show_screen())
			row.add_child(b)
		left.add(row)
	left.add(UI.label("WHERE", head))
	var venue := OptionButton.new()
	var venue_ids := ["rounds"] + Arenas.venue_ids(reg)
	venue.add_item("Up the venues, round by round")
	for id in Arenas.venue_ids(reg): venue.add_item(Arenas.venue_of(reg, id).name)
	venue.select(maxi(0, venue_ids.find(setup.venue)))
	venue.item_selected.connect(func(i: int):
		setup.venue = venue_ids[i]
		_save_setup())
	var layout := OptionButton.new()
	var layout_ids := ["random"] + Arenas.layout_ids(reg)
	layout.add_item("From the venue's rotation")
	for id in Arenas.layout_ids(reg): layout.add_item(Arenas.layout_of(reg, id).name)
	layout.select(maxi(0, layout_ids.find(setup.layout)))
	layout.item_selected.connect(func(i: int):
		setup.layout = layout_ids[i]
		_save_setup())
	left.row([UI.vbox(2, [UI.label("Venue", {"kind": "cond", "size": 13, "color": UI.DIM}), venue]), UI.vbox(2, [UI.label("Layout", {"kind": "cond", "size": 13, "color": UI.DIM}), layout])], 14)

	var right := Doc.new(8)
	right.custom_minimum_size.x = 560
	right.add(UI.label("PEOPLE (%d)" % setup.players.size(), head))
	if (setup.players as Array).is_empty(): right.p("Nobody: the AI fights every fight and you watch the bracket fill.", {"tone": "muted"})
	# The robots a person can pick, league by league.
	var robot_ids := []
	var robot_names := []
	if mine != null:
		robot_ids.append("career")
		robot_names.append("%s - your career robot" % mine.name)
	for lg in ["world", "elite", "pro", "rookie", "exhibition"]:
		for e in entries:
			if e.league == lg:
				robot_ids.append(e.id)
				robot_names.append("%s  ·  %s" % [e.name, Catalog.LEAGUE_NAMES[lg]])
	for i in setup.players.size():
		var p: Dictionary = setup.players[i]
		var pname := LineEdit.new()
		pname.text = str(p.name)
		pname.max_length = 20
		pname.custom_minimum_size.x = 150
		pname.text_changed.connect(func(t: String):
			setup.players[i].name = t
			_save_setup())
		var robot := OptionButton.new()
		robot.custom_minimum_size.x = 300
		robot.fit_to_longest_item = false
		for n in robot_names: robot.add_item(n)
		robot.select(maxi(0, robot_ids.find(p.get("robot"))))
		robot.item_selected.connect(func(k: int):
			setup.players[i].robot = robot_ids[k]
			_save_setup())
		var rm := UI.button("✕", "ghost", {"size": 11})
		rm.pressed.connect(func():
			setup.players.remove_at(i)
			_save_setup()
			show_screen())
		right.row([pname, robot, rm], 6)
	if setup.players.size() < int(cfg.maxPlayers):
		var add := UI.button("+ ADD A PERSON", "ghost")
		add.pressed.connect(func():
			add_player()
			show_screen())
		right.row([add])
	right.p("When two people meet, they share the keyboard: red on W A S D and Space, blue on the arrows and /. A person can also hand any fight to the AI.", {"tone": "muted", "size": 12})
	_error = UI.label("", {"kind": "body", "size": 12, "weight": 400, "color": Color(Doc.NEG), "wrap": true})
	right.add(_error)
	var start := UI.button("START THE TOURNAMENT", "fight")
	start.pressed.connect(func(): do_start())
	right.row([start])
	var cols := UI.hbox(40, [left, right])
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_child(cols)
	add_child(UI.scroll(UI.margin(center, 20, 30)))

# ---------------------------------------------------------------- actions

func add_player(robot = null) -> void:
	var used := {}
	for p in setup.players: used[p.get("robot")] = true
	var free = null
	for e in entries:
		if e.league != "exhibition" and not used.has(e.id):
			free = e.id
			break
	setup.players.append({"name": "Player %d" % (setup.players.size() + 1), "robot": robot if robot != null else free})
	_save_setup()

## Start the cup from the setup form.
func do_start(cup_seed = null) -> bool:
	if cup_seed == null: cup_seed = maxi(1, int(Time.get_unix_time_from_system()) & 0x7fffffff)
	var mine = null
	var players := []
	for p in setup.players:
		if p.get("robot") == "career":
			if mine == null: mine = _career_robot()
			players.append({"name": p.name, "def": mine})
		else: players.append({"name": p.name, "robot": p.get("robot")})
	var o := setup.duplicate(true)
	o.players = players
	o.seed = cup_seed
	var r := Cup.make_cup(reg, o)
	if not r.ok:
		if _error != null and is_instance_valid(_error): _error.text = J.cap(str(r.error))
		return false
	cup = r.cup
	Cup.register_cup_robots(reg, cup)
	last = null
	tab = "groups" if cup.get("groups") != null else "bracket"
	Cup.advance_cup(reg, cup)
	save()
	show_screen()
	return true

func do_fight() -> void:
	var f = Cup.next_cup_fight(cup)
	if f == null: return
	save()
	var arena := Cup.cup_arena(reg, cup, f)
	var ha = Cup.human_of(cup, f.a)
	var hb = Cup.human_of(cup, f.b)
	var custom := {}
	for id in [f.a, f.b]:
		# People's own robots are not in the data files: the arena registers them.
		if (cup.get("custom", {}) as Dictionary).has(id): custom[id] = cup.custom[id]
	var names := {}
	if ha != null: names.red = cup.players[int(ha)].name
	if hb != null: names.blue = cup.players[int(hb)].name
	var req := {"mode": "tourney", "red": f.a, "blue": f.b, "seed": Cup.cup_seed(cup, f) & 0xffff, "venue": arena.venue, "layout": arena.layout,
		"tourney": {"fixtureId": f.id, "red": f.a, "blue": f.b, "names": names, "custom": custom, "stage": "%s · %s" % [cup.name, Cup.cup_stage_label(cup, f)]}.duplicate(true)}
	if ha == null: req.driver = "ai"
	if hb != null: req.p2 = true
	Game.start_fight(req)

func do_simulate() -> void:
	var f = Cup.next_cup_fight(cup)
	if f == null: return
	last = {"f": f, "result": Cup.simulate_cup_fight(reg, cup, f.id)}
	save()
	show_screen()

func do_abandon() -> void:
	cup = null
	last = null
	Store.remove(Store.TOURNAMENT)
	show_screen()

# ---------------------------------------------------------------- the hub

func _hub() -> void:
	var done: bool = J.truthy(cup.get("done"))
	var f = null if done else Cup.next_cup_fight(cup)
	var fd: Dictionary = {}
	for x in cfg.formats:
		if x.id == cup.format: fd = x
	var round_label := "finished"
	if not done:
		round_label = "group round %d of %d" % [int(cup.round) + 1, int(cup.groupRounds)] if cup.round < cup.groupRounds else Tournament.round_name(cup.bracket, cup.round - cup.groupRounds).to_lower()
	add_child(menu.bar("Tournament · %s" % cup.name, "", "MENU", "main",
		[UI.label(("%s · %d robots · %s" % [fd.get("name", ""), cup.entrants.size(), round_label]).to_upper(), {"kind": "cond", "size": 13, "weight": 500, "ls": 0.1, "color": UI.DIM})]))
	var left := Doc.new(10)
	if last != null: _last_panel(left)
	if done: _champion_panel(left)
	elif f != null: _next_panel(left, f)
	else:
		var p := Plate.new()
		p.add_child(UI.label("Waiting on the other fights...", {"kind": "cond", "size": 16}))
		left.add(p)
	var abandon := UI.button("NEW TOURNAMENT" if done else "ABANDON THE TOURNAMENT", "ghost", {"size": 11})
	abandon.pressed.connect(func():
		if J.truthy(cup.get("done")): do_abandon()
		else: UI.confirm(self, "Abandon this tournament? It cannot be finished later.", do_abandon))
	left.row([abandon])
	var left_scroll := UI.scroll(left)

	var tabs := UI.hbox(0)
	for t in TABS:
		if t[0] == "groups" and cup.get("groups") == null: continue
		var b := UI.button(str(t[1]).to_upper(), "tab")
		b.button_pressed = tab == t[0]
		b.pressed.connect(func():
			tab = t[0]
			show_screen())
		tabs.add_child(b)
	var tab_bar := PanelContainer.new()
	tab_bar.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.35), {"pad": [0, 0]}))
	tab_bar.add_child(tabs)
	var body := Doc.new(6)
	if tab == "groups" and cup.get("groups") != null: _groups(body)
	elif tab == "results": _results(body)
	elif tab == "players": _players(body)
	else: _bracket(body)
	var right := Plate.new(0, 0)
	right.bolts = false
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(UI.vbox(0, [tab_bar, UI.scroll(UI.margin(body, 16, 12))]))
	var main := UI.hbox(14, [left_scroll, right])
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(UI.margin(main, 18, 12, 18, 16))

func _next_panel(d: Doc, f: Dictionary) -> void:
	var arena := Cup.cup_arena(reg, cup, f)
	var ha = Cup.human_of(cup, f.a)
	var hb = Cup.human_of(cup, f.b)
	var panel := Plate.new(18, 14)
	var v := Doc.new(6)
	v.add(UI.label(("%s  ·  %s  ·  %s" % [Cup.cup_stage_label(cup, f), J.g(Arenas.venue_of(reg, arena.venue), "name", ""), J.g(Arenas.layout_of(reg, arena.layout), "name", "")]).to_upper(),
		{"kind": "cond", "size": 14, "weight": 700, "ls": 0.22, "color": UI.HOT}))
	v.add(Doc.text("[color=#ff4a3d]%s[/color]  [color=#ffc81e][font_size=26]VS[/font_size][/color]  [color=#4a9bff]%s[/color]" % [who(f.a).to_upper(), who(f.b).to_upper()],
		{"kind": "display", "size": 40, "weight": 600, "italic": true}))
	var pair := UI.hbox(10)
	for id in [f.a, f.b]:
		var st := menu.stage()
		st.custom_minimum_size = Vector2(0, 260)
		st.show_def(Cup.cup_def(reg, cup, id))
		pair.add_child(st)
	v.add(pair)
	if ha != null and hb != null:
		v.p("%s (red: W A S D, Space) against %s (blue: arrows, /) on one keyboard." % [Doc.esc(cup.players[int(ha)].name), Doc.esc(cup.players[int(hb)].name)], {"size": 13})
	elif ha != null or hb != null:
		v.p("%s drives %s; the AI drives the other corner." % [Doc.esc(cup.players[int(ha if ha != null else hb)].name), "red" if ha != null else "blue"], {"size": 13})
	_fight_btn = UI.button("FIGHT!", "fight")
	_fight_btn.pressed.connect(do_fight)
	var sim := UI.button("LET THE AI FIGHT IT", "ghost")
	sim.pressed.connect(do_simulate)
	v.row([_fight_btn, sim], 12)
	panel.add_child(v)
	d.add(panel)

func _last_panel(d: Doc) -> void:
	var f: Dictionary = last.f
	var r: Dictionary = last.result
	var how := "%s decision" % ("split" if r.get("decision") == "split" else "unanimous") if r.method == "decision" else "%s at %s" % [METHOD.get(r.method, r.method), fmt(r.get("elapsedS", 0.0))]
	var panel := Plate.new(18, 10)
	panel.bar_left = Color(Doc.POS) if Cup.human_of(cup, r.winnerId) != null else UI.DIM
	panel.add_child(Doc.text("[b]%s[/b] beat %s · %s%s" % [who(r.winnerId), who(f.b if r.winnerId == f.a else f.a), how, " · fought by the AI" if r.get("by") == "sim" else ""], {"size": 17}))
	d.add(panel)

func _champion_panel(d: Doc) -> void:
	var h = Cup.human_of(cup, cup.champion)
	var panel := Plate.new(18, 14)
	var v := Doc.new(6)
	v.add(UI.label("%s IS OVER" % str(cup.name).to_upper(), {"kind": "cond", "size": 14, "weight": 700, "ls": 0.22, "color": UI.HOT}))
	v.add(UI.label("%s WINS" % str(cup.players[int(h)].name).to_upper() if h != null else "CHAMPION", {"kind": "display", "size": 76, "weight": 700, "italic": true, "shadow": true, "color": UI.ACCENT}))
	v.add(UI.label(name_of(cup.champion).to_upper(), {"kind": "display", "size": 34, "weight": 600, "italic": true}))
	var st := menu.stage()
	st.custom_minimum_size = Vector2(0, 300)
	st.show_def(Cup.cup_def(reg, cup, cup.champion))
	v.add(st)
	var lg: Array = cup.get("log", [])
	if not lg.is_empty():
		var fin: Dictionary = lg[lg.size() - 1]
		v.p("The final: %s beat %s by %s." % [who(fin.result.winnerId), who(fin.b if fin.result.winnerId == fin.a else fin.a), METHOD.get(fin.result.method, fin.result.method)], {"tone": "muted"})
	panel.add_child(v)
	d.add(panel)

func _bracket(d: Doc) -> void:
	var b = cup.get("bracket")
	if b == null:
		d.p("The %s-robot bracket is drawn when the groups are done." % J.s(cup.get("bracketSize", "")), {"tone": "muted"})
		return
	var cols := UI.hbox(12)
	for r in b.rounds.size():
		var col := UI.vbox(6, [UI.label(Tournament.round_name(b, r).to_upper(), {"kind": "display", "size": 18, "weight": 600, "italic": true, "color": UI.HOT})])
		col.custom_minimum_size.x = 190
		for m in b.rounds[r]:
			var person: bool = (m.get("a") != null and Cup.human_of(cup, m.a) != null) or (m.get("b") != null and Cup.human_of(cup, m.b) != null)
			var box := PanelContainer.new()
			box.add_theme_stylebox_override("panel", UI.box(Color("121418"), {"border": UI.ACCENT if person else UI.LINE, "pad": [8, 4]}))
			var v := UI.vbox(0)
			for side in ["a", "b"]:
				var id = m.get(side)
				var text := "bye" if (J.truthy(m.get("bye")) and id == null) else (name_of(id) if id != null else "—")
				var col_c := UI.DIM if id == null else (UI.ACCENT if Cup.human_of(cup, id) != null else (UI.TEXT if m.get("winner") == id else Color("9aa0a8")))
				v.add_child(UI.label(text, {"kind": "cond", "size": 14, "weight": 700 if (id != null and m.get("winner") == id) else 500, "color": col_c, "clip": true}))
			var res = m.get("result")
			if res is Dictionary:
				v.add_child(UI.label("%s%s" % [METHOD.get(res.method, ""), "" if res.method == "decision" else " %s" % fmt(res.get("elapsedS", 0.0))], {"kind": "body", "size": 11, "weight": 400, "color": UI.DIM}))
			box.add_child(v)
			col.add_child(box)
		cols.add_child(col)
	var sc := ScrollContainer.new()
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(cols)
	sc.custom_minimum_size.y = cols.get_combined_minimum_size().y + 16
	d.add(sc)

func _groups(d: Doc) -> void:
	var tables := Cup.cup_tables(cup)
	var advance := int(cup.advance)
	d.p("Top %d of each group go through. Ranked by wins, then knockouts, then damage." % advance, {"tone": "muted", "size": 12})
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 12)
	for g in cup.groups:
		var mine: bool = (g.ids as Array).any(func(id): return Cup.human_of(cup, id) != null)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.22), {"border": UI.ACCENT if mine else UI.LINE, "border_w": 2 if mine else 1, "pad": [10, 6]}))
		card.custom_minimum_size.x = 330
		var t := Doc.new(2)
		var rows := []
		var tones := []
		var rows_in: Array = tables[g.name]
		for i in rows_in.size():
			var r: Dictionary = rows_in[i]
			rows.append(["%s %d  %s" % [Doc.pos("●") if i < advance else Doc.muted("·"), i + 1, Doc.esc(name_of(r.id))], J.s(r.wins), J.s(r.losses), J.s(r.kos), "%d" % int(round(r.damage))])
			tones.append("me" if Cup.human_of(cup, r.id) != null else "")
		t.add(UI.label("GROUP %s" % g.name, {"kind": "display", "size": 22, "weight": 600, "italic": true, "ls": 0.06, "color": UI.ACCENT}))
		t.table(5, rows, {"head": ["", "W", "L", "KO", "Dmg"], "right": [1, 2, 3, 4], "tones": tones, "hsep": 10})
		card.add_child(t)
		flow.add_child(card)
	d.add(flow)

func _results(d: Doc) -> void:
	var lg: Array = cup.get("log", [])
	var people := lg.filter(func(x): return Cup.human_of(cup, x.a) != null or Cup.human_of(cup, x.b) != null)
	var rest: Array = lg.filter(func(x): return not people.has(x)).slice(-30)
	rest.reverse()
	var row := func(x: Dictionary) -> Array:
		var r: Dictionary = x.result
		return ["[b]%s[/b]" % who(x.a) if r.winnerId == x.a else who(x.a), "[b]%s[/b]" % who(x.b) if r.winnerId == x.b else who(x.b),
			Doc.muted("%s%s" % [METHOD.get(r.method, r.method), " %s" % fmt(r.get("elapsedS", 0.0)) if r.method != "decision" else ""]),
			Doc.muted("Grp %s" % x.group if x.stage == "group" else Tournament.round_name(cup.bracket, x.bracketRound))]
	if not (cup.players as Array).is_empty():
		d.sub("People's fights")
		if people.is_empty(): d.p("None yet.", {"tone": "muted"})
		else: d.table(4, people.map(row), {"expand": 1})
	d.sub("Around the tournament")
	if rest.is_empty(): d.p("Nothing yet.", {"tone": "muted"})
	else: d.table(4, rest.map(row), {"expand": 1})

func _players(d: Doc) -> void:
	if (cup.players as Array).is_empty():
		d.p("No people in this one: the AI fights it all.", {"tone": "muted"})
		return
	var rank := Cup.cup_ranking(cup)
	var rows := []
	for i in cup.players.size():
		var id = null
		for k in cup.humans:
			if int(cup.humans[k]) == i: id = k
		if id == null: continue
		var fights: Array = (cup.get("log", []) as Array).filter(func(x): return x.a == id or x.b == id)
		var w := fights.filter(func(x): return x.result.winnerId == id).size()
		var place := "in the groups"
		if cup.get("champion") == id: place = "champion"
		else:
			var r = null
			for x in rank:
				if x.id == id: r = x
			if r == null or r.finish < 0: place = "out in the groups" if cup.get("bracket") != null else "in the groups"
			else:
				var alive := false
				for ms in cup.bracket.rounds:
					for m in ms:
						if (m.get("a") == id or m.get("b") == id) and m.get("winner") == null: alive = true
				place = "%s the %s" % ["in" if alive else "out in", Tournament.round_name(cup.bracket, maxi(0, int(r.finish))).to_lower()]
		rows.append(["[b]%s[/b] %s" % [Doc.esc(cup.players[i].name), Doc.muted(Doc.esc(name_of(id)))], Doc.muted("%d-%d" % [w, fights.size() - w]), place])
	d.ledger(rows)
