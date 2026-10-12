## career_screen.gd - the Career screens: new career, the hub between fights,
## and the end-of-season summary.
##
## All the rules are in logic/career.gd; this file only shows the career and
## calls into it. The career is saved after everything that changes it (the
## save IS the career dictionary).
##
## A fight in the arena is handed over through Game: the hub says which
## fixture it is and both robots as they stand (Game.start_fight), the arena
## leaves the result in Game.result when the bell goes, and the hub picks it
## up next time it is shown.
##
## There are several saves (Store.CAREER_SLOTS), each its own career. Career
## opens on the list of them until one is opened; after that it goes straight
## to that one, and the hub's CAREERS button comes back to the list.
class_name CareerScreen
extends VBoxContainer

const TABS := [["standings", "Standings"], ["bracket", "Bracket"], ["results", "Results"], ["rivals", "Rivals"], ["money", "Money"], ["market", "Market"], ["trophies", "Trophies"], ["settings", "Settings"]]
const DIFF_BLURB := {
	"easy": "Forgiving drivers who rarely adapt; bigger purses.",
	"medium": "Drivers who learn and set up for you a little.",
	"hard": "Sharp drivers who test their setup against you.",
	"ultimate": "The best drivers in the sport, adapting every fight.",
}
const METHOD := {"ko": "KO", "tapout": "tap out", "decision": "decision"}
const CATEGORY := {"weaponMotor": "weapon motor", "armor": "armour", "srimech": "self-righter", "electronics": "electronics", "motor": "drive motors", "wheel": "wheels"}

var menu: Menu
var reg: Registry
var career = null
var tab := "standings"
var summary = null               # the last fight's summary, shown until dismissed
var view := "hub"                # "hub", "workshop", "pit", "saves" or "new" - the route says which
var slot := 1                    # which save `career` is
var market_msg = null            # what the last Market action did, shown once

var _workshop: WorkshopScreen = null
var _pit: PitScreen = null
var _fight_btn: Button = null
var _new_cash := 0.0
var _new_slot := 0               # the save a new career will go in

func _init(owner_menu: Menu) -> void:
	menu = owner_menu
	reg = menu.reg
	add_theme_constant_override("separation", 0)
	slot = Store.career_slot()
	# Back from a fight, or back to the career opened earlier.
	if Game.career_open: _load()

# The career being played, from its save.
func _load() -> void:
	_drop_screens()
	career = null
	slot = Store.career_slot()
	var c := Career.from_data(Store.read_json(Store.career_key(slot)))
	if c.ok: career = c.career
	# The field is this career's: the robots that joined it during the career
	# live in the save, and another career's must not linger.
	menu.reload_saves(career if career != null else {})
	# A save from before the living field: give its drivers their careers now.
	if career != null and (career.get("drivers", {}) as Dictionary).is_empty(): Field.seed_drivers(reg, career)

# The workshop holds a draft of one career's robot: gone when the career changes.
func _drop_screens() -> void:
	if _workshop != null and is_instance_valid(_workshop):
		if _workshop.get_parent() != null: _workshop.get_parent().remove_child(_workshop)
		_workshop.queue_free()
	_workshop = null
	summary = null
	market_msg = null

func save() -> void:
	if career != null: Store.write(Store.career_key(slot), Career.serialize(career))

# The career in a save, or null if it is empty; a String if it cannot be read.
func _saved(n: int):
	if n == slot and career != null: return career
	var raw = Store.read(Store.career_key(n))
	if raw == null or raw == "": return null
	var c := Career.deserialize(raw)
	return c.career if c.ok else J.cap(str(c.error))

func _used(n: int) -> bool:
	return (n == slot and career != null) or Store.has(Store.career_key(n))

func _free_slot() -> int:
	for n in range(1, Store.CAREER_SLOTS + 1):
		if not _used(n): return n
	return 0

func _any_saved() -> bool:
	for n in range(1, Store.CAREER_SLOTS + 1):
		if _used(n): return true
	return false

static func money(n: float) -> String:
	return Market.money(n)

static func fmt(s: float) -> String:
	return "%d:%02d" % [int(floor(s / 60.0)), int(round(fmod(s, 60.0)))]

static func ordinal(n: int) -> String:
	var v := n % 100
	if v >= 11 and v <= 13: return "%dth" % n
	return "%d%s" % [n, ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]]

static func finish_name(fin: Dictionary, size: int) -> String:
	if fin.finish >= fin.rounds: return "won the title"
	var left := int(fin.rounds - fin.finish)
	if left == 1: return "lost in the final"
	if left == 2: return "lost in the semifinals"
	if left == 3: return "lost in the quarterfinals"
	return "lost in the round of %d" % (size >> int(fin.finish))

# The player's robot is called whatever they named it in the workshop.
func rname(id) -> String:
	if career != null and id == career.playerId: return str(Garage.garage_of(reg, career).name)
	var d = reg.robot(id)
	return str(d.name) if d != null else str(id)

func name_of(id) -> String:
	return "%s (you)" % rname(id) if (career != null and id == career.playerId) else rname(id)

func is_me(id) -> bool:
	return career != null and id == career.playerId

func _notification(what: int) -> void:
	# The workshop is kept between visits, out of the tree.
	if what == NOTIFICATION_PREDELETE and _workshop != null and is_instance_valid(_workshop) and not _workshop.is_inside_tree(): _workshop.free()

# ---------------------------------------------------------------- routing

## The router (menu.gd): "career" (the career that is open, or the list of
## saves), "career/workshop", "career/pit", "career/saves" or "career/new".
func open(sub := "") -> void:
	if sub == "saves" or sub == "new": view = sub
	elif career == null: view = "saves"
	elif sub == "workshop": view = "workshop"
	elif career.get("pit") != null and sub == "pit": view = "pit"
	else: view = "hub"
	show_screen()

## Esc: step back out of the workshop or the pit, or from a new career to the
## list of saves. True if it did.
func step_back() -> bool:
	if view == "new" and menu.current_route() == "career/new" and _any_saved():
		menu.go("career/saves")
		return true
	if view != "workshop" and view != "pit": return false
	menu.go("career")
	return true

# To the hub of the career that is open.
func _show_hub() -> void:
	view = "hub"
	if menu.current_route() == "career": show_screen()
	else: menu.go("career")

# To the list of saves (or a new career, when nothing is saved).
func _show_saves() -> void:
	view = "saves"
	if menu.current_route() == "career" or menu.current_route() == "career/saves": show_screen()
	else: menu.go("career/saves")

func keys(e: InputEventKey) -> bool:
	if e.echo: return false
	# Enter on the list of saves: carry on with the one last played.
	if view == "saves" and (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and _saved(Store.career_slot()) is Dictionary:
		do_open(Store.career_slot())
		return true
	if view != "hub": return false
	if (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and _fight_btn != null and is_instance_valid(_fight_btn) and career != null:
		do_fight()
		return true
	return false

# The difficulty is a setting, changeable any time: the career follows it.
func _sync_settings() -> void:
	var level: String = Game.settings.get("difficulty", "medium")
	if career != null and career.get("difficulty") != level:
		career.difficulty = level
		career.prep = null
		save()

# Pick up a fight result the arena left for us, if it is for the pending fight.
func _collect_result() -> void:
	var handed = Game.result
	if not (handed is Dictionary) or handed.get("kind") != "career": return
	Game.result = null
	var nf = Career.next_fight(reg, career)
	if nf == null or nf.fixture.id != handed.get("fixtureId"): return
	var mine = [handed.condition, handed.partnerCondition] if handed.get("partnerCondition") != null else handed.get("condition")
	summary = Career.apply_player_result(reg, career, handed.fixtureId, handed.result, mine, handed.get("oppCondition"), handed.get("oppLearned"))
	save()

func show_screen() -> void:
	# The workshop keeps its draft between visits: lift it out before clearing.
	if _workshop != null and is_instance_valid(_workshop) and _workshop.get_parent() == self: remove_child(_workshop)
	UI.clear(self)
	_fight_btn = null
	# No career open: the saves, or a new career when nothing is saved.
	if career == null and view != "new": view = "saves"
	if view == "saves" and not _any_saved(): view = "new"
	if view == "new":
		if _new_slot == 0 or _used(_new_slot): _new_slot = _free_slot()
		if _new_slot == 0: view = "saves"
	if view == "saves":
		_saves_view()
		return
	if view == "new":
		_new_view()
		return
	_sync_settings()
	if view == "workshop":
		if _workshop == null or not is_instance_valid(_workshop): _workshop = WorkshopScreen.new(self)
		add_child(_workshop)
		_workshop.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_workshop.open()
		return
	if view == "pit":
		_pit = PitScreen.new(self)
		add_child(_pit)
		_pit.size_flags_vertical = Control.SIZE_EXPAND_FILL
		return
	_collect_result()
	if not J.truthy(career.get("seasonOver")):
		Career.advance_career(reg, career)
		save()
	_hub()

# ---------------------------------------------------------------- the saves

# One line on where a career stands.
func _save_line(c: Dictionary) -> String:
	var s = c.get("season")
	var lg = Career.player_league(c)
	var where: String = "Giant Nut" if (s is Dictionary and s.get("kind") == "giantNut") else "%s league" % Career.LEAGUE_TITLES.get(lg, str(lg))
	var st: Dictionary = c.get("stats", {})
	var titles: int = (c.get("trophies", []) as Array).size()
	return "Season %s · %s · %s-%s%s · %s" % [J.s(s.index) if s is Dictionary else J.s(J.g(c, "seasonIndex", 0) + 1), where, J.s(st.get("wins", 0)), J.s(st.get("losses", 0)),
		" · %d title%s" % [titles, "" if titles == 1 else "s"] if titles > 0 else "", money(J.g(c, "cash", 0.0))]

func _saves_view() -> void:
	add_child(menu.bar("Career", "[Enter] continue · [Esc] menu"))
	var st := menu.stage()
	var cap_name := UI.label("", {"kind": "display", "size": 46, "weight": 600, "italic": true, "shadow": true, "align": "right"})
	var cap_line := UI.label("", {"kind": "cond", "size": 14, "weight": 500, "ls": 0.12, "color": UI.DIM, "align": "right"})
	# The robot of the save under the mouse, on the turntable.
	var shown := [0]
	var put := func(n: int, c: Dictionary):
		if shown[0] == n: return
		shown[0] = n
		st.show_def(Garage.player_def(reg, c))
		cap_name.text = str(J.path(c, ["garage", "name"], "")).to_upper()
		cap_line.text = ("%s · SAVE %d" % [c.get("team", ""), n]).to_upper()
	var list := UI.vbox(10)
	list.custom_minimum_size.x = 700
	list.add_child(UI.label("YOUR CAREERS", {"kind": "display", "size": 44, "weight": 600, "italic": true}))
	list.add_child(UI.label("Each save is its own career: its own team, robot, money and field. Everything is saved as you go.", {"kind": "cond", "size": 14, "weight": 500, "color": UI.DIM, "wrap": true}))
	var current := Store.career_slot()
	var first = null
	for n in range(1, Store.CAREER_SLOTS + 1):
		var c = _saved(n)
		var card := Plate.new(18, 12)
		var tag := UI.label("SAVE %d" % n, {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT})
		if c is Dictionary:
			if first == null or n == current: first = [n, c]
			if n == current: card.ring = UI.ACCENT
			var text := UI.vbox(-2, [
				UI.hbox(10, [tag, UI.label("LAST PLAYED" if n == current else "", {"kind": "cond", "size": 12, "weight": 700, "ls": 0.2, "color": UI.ACCENT})]),
				UI.label(str(c.get("team", "")).to_upper(), {"kind": "display", "size": 32, "weight": 600, "italic": true}),
				UI.label("%s · %s" % [J.path(c, ["garage", "name"], "your robot"), _save_line(c)], {"kind": "cond", "size": 15, "weight": 500, "color": Color("b9c1cd")}),
			])
			text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var btns := UI.vbox(4, [
				_btn("CONTINUE", "fight", func(): do_open(n), {"small": true}),
				UI.hbox(4, [
					_btn("RESTART…", "ghost", func():
						UI.confirm(self, "Restart %s from the beginning? The team starts again in the Rookie league with a stock robot and its starting money. Everything in this save is lost, and this cannot be undone." % c.get("team", "this career"),
							func(): do_restart(n), "Restart this career?"), {"size": 11}),
					_btn("DELETE…", "ghost", func():
						UI.confirm(self, "Delete the career of %s? This cannot be undone." % c.get("team", "this team"), func(): do_delete(n), "Delete this career?"), {"size": 11}),
				]),
			])
			card.add_child(UI.hbox(16, [text, btns]))
			card.mouse_entered.connect(func(): put.call(n, c))
		elif c is String:
			# A file that is there but is not a career this game can open.
			var text := UI.vbox(0, [tag, UI.label("This save cannot be opened: %s." % c, {"kind": "cond", "size": 15, "weight": 500, "color": UI.BAD, "wrap": true})])
			text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.add_child(UI.hbox(16, [text, _btn("DELETE…", "ghost", func():
				UI.confirm(self, "Delete save %d? This cannot be undone." % n, func(): do_delete(n), "Delete this save?"), {"size": 11})]))
		else:
			var text := UI.vbox(0, [tag, UI.label("EMPTY", {"kind": "display", "size": 26, "weight": 600, "italic": true, "color": UI.DIM})])
			text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.add_child(UI.hbox(16, [text, _btn("NEW CAREER", "ghost", func(): do_new(n))]))
		list.add_child(card)
	if first != null: put.call(first[0], first[1])
	var right := Control.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(st)
	st.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var cap := UI.vbox(0, [cap_name, cap_line])
	right.add_child(cap)
	UI.pin(cap, Vector2(1.0, 1.0), Vector2(-60, -40))
	var left := UI.scroll(UI.margin(list, 50, 24, 20, 24))
	left.size_flags_horizontal = Control.SIZE_FILL
	left.custom_minimum_size.x = 780
	var body := UI.hbox(0, [left, right])
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)

# ---------------------------------------------------------------- new career

func _new_view() -> void:
	var me: Dictionary = reg.robot(reg.playerId)
	var cash_cfg: Dictionary = reg.economy.get("startingCashOptions", {"options": [["standard", reg.economy.startingCash, "Standard"]], "customMin": 2000, "customMax": 500000})
	_new_cash = reg.economy.startingCash
	var others := _any_saved()
	add_child(menu.bar("New career · Save %d" % _new_slot, "[Esc] back", "CAREERS" if others else "MENU", "career/saves" if others else "main"))
	var d := Doc.new(8)
	d.custom_minimum_size.x = 640
	d.add(UI.label("START IN ROOKIE. FINISH WITH THE GIANT NUT.", {"kind": "display", "size": 44, "weight": 600, "italic": true, "wrap": true}))
	for line in [
		"Four leagues of 30: Rookie, Pro, Elite and the World Championship. You start at the bottom.",
		"Each season: six groups of five, then a 16-robot playoff. The top four go up, the bottom four go down.",
		"Every third season is the Giant Nut: all 120 robots, ten mixed groups, a 64-robot bracket and the biggest purse in the sport.",
		"Appearance fees, win purses and knockout bonuses pay the bills. Every hit you take comes back as a repair bill.",
		"Sponsors sign on as you win. Fight each bout yourself in the arena, or let your AI driver take it.",
	]: d.p("•  " + line, {"kind": "body", "size": 14, "weight": 400})
	var head := {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}
	d.gap(4)
	d.add(UI.label("TEAM NAME", head))
	var team := LineEdit.new()
	team.text = "Your Team"
	team.max_length = 28
	team.custom_minimum_size.x = 320
	team.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	d.add(team)
	d.add(UI.label("STARTING MONEY", head))
	var cash_row := HFlowContainer.new()
	cash_row.add_theme_constant_override("h_separation", 6)
	var cash_btns := []
	var custom := LineEdit.new()
	custom.placeholder_text = "custom $"
	custom.custom_minimum_size.x = 120
	for o in cash_cfg.options:
		var b := _choice("$%s" % J.commas(J.rndi(o[1])), str(o[2]))
		b.button_pressed = o[0] == "standard"
		b.pressed.connect(func():
			_new_cash = o[1]
			custom.text = ""
			for x in cash_btns: (x as Button).button_pressed = is_same(x, b))
		cash_btns.append(b)
		cash_row.add_child(b)
	custom.text_changed.connect(func(t: String):
		var v := t.to_float()
		if v > 0.0:
			_new_cash = clampf(v, cash_cfg.customMin, cash_cfg.customMax)
			for x in cash_btns: (x as Button).button_pressed = false)
	cash_row.add_child(custom)
	d.add(cash_row)
	d.add(Doc.text("[color=#ff7a1a]DIFFICULTY[/color]  " + Doc.muted(Doc.small("(change it any time in Settings)")), {"size": 13, "weight": 700, "ls": 0.2}))
	var diff_row := HFlowContainer.new()
	diff_row.add_theme_constant_override("h_separation", 6)
	var diff_btns := {}
	for lv in ["easy", "medium", "hard", "ultimate"]:
		var b := _choice(str(Settings.difficulty_of(reg, lv).get("label", lv)), DIFF_BLURB[lv])
		b.button_pressed = Game.settings.get("difficulty") == lv
		b.pressed.connect(func():
			Game.set_setting("difficulty", lv)
			for k in diff_btns: (diff_btns[k] as Button).button_pressed = k == lv)
		diff_btns[lv] = b
		diff_row.add_child(b)
	d.add(diff_row)
	d.gap(6)
	var start := UI.button("START CAREER", "fight")
	start.pressed.connect(func(): do_start(team.text, _new_cash))
	var imp := UI.button("IMPORT A SAVE FILE…", "ghost")
	# A save file from elsewhere becomes this save.
	var into := _new_slot
	var saves := SavesPanel.new(func(): do_open(into))
	saves.slot = into
	saves.visible = false
	imp.pressed.connect(func(): saves._do_import())
	d.row([start, imp], 14)
	d.add(saves)
	d.p("You start with %s. Rebuild it in the workshop between fights - buy parts, change the weapon, paint it, and ask the build advisor if you want a second opinion." % Doc.esc(me.name),
		{"tone": "muted", "size": 13})
	var st := menu.stage()
	st.show_bot(reg.playerId)
	var right := Control.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(st)
	st.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var cap := UI.vbox(0, [
		UI.label(str(me.name).to_upper(), {"kind": "display", "size": 46, "weight": 600, "italic": true, "shadow": true, "align": "right"}),
		UI.label("ROOKIE LEAGUE · $%s IN THE BANK" % J.commas(J.rndi(reg.economy.startingCash)), {"kind": "cond", "size": 14, "weight": 500, "ls": 0.12, "color": UI.DIM, "align": "right"}),
	])
	right.add_child(cap)
	UI.pin(cap, Vector2(1.0, 1.0), Vector2(-60, -40))
	var left := UI.scroll(UI.margin(d, 50, 30, 20, 30))
	left.size_flags_horizontal = Control.SIZE_FILL
	left.custom_minimum_size.x = 720
	var body := UI.hbox(0, [left, right])
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)

# A two-line choice button: a headline and what it means.
func _choice(big: String, small_text: String) -> Button:
	var b := UI.button("", "choice")
	b.custom_minimum_size = Vector2(150, 58)
	var v := UI.vbox(-2, [UI.label(big.to_upper(), {"kind": "display", "size": 22, "weight": 600, "italic": true, "ls": 0.04}),
		UI.label(small_text, {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "wrap": true})])
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.custom_minimum_size.x = 136
	b.add_child(UI.margin(v, 8, 4))
	b.custom_minimum_size.y = 62
	return b

# ---------------------------------------------------------------- actions
# Everything a button does, in one place.

## A new career, in the save the form is for (or the first empty one).
func do_start(team: String, starting_cash = null, career_seed = null) -> void:
	var n := _new_slot if (_new_slot > 0 and not _used(_new_slot)) else _free_slot()
	if n > 0: _begin(n, team, starting_cash, career_seed)

# A career from the beginning, in save `n` (replacing what is there).
func _begin(n: int, team: String, starting_cash = null, career_seed = null) -> void:
	if career_seed == null: career_seed = maxi(1, int(Time.get_unix_time_from_system()) & 0x7fffffff)
	if starting_cash == null: starting_cash = reg.economy.startingCash
	var name_text := team.strip_edges()
	_drop_screens()
	career = null
	slot = n
	Store.set_career_slot(n)
	Game.career_open = true
	Game.result = null
	# It starts from the field as the data files have it.
	menu.reload_saves({})
	career = Career.new_career(reg, {"seed": career_seed, "team": name_text if name_text != "" else "Your Team", "startingCash": starting_cash,
		"difficulty": Game.settings.get("difficulty", "medium")})
	# Kept so the career can be restarted as it began.
	career.startingCash = starting_cash
	Career.advance_career(reg, career)
	save()
	menu.refresh_catalog()
	_show_hub()

## Open a save and carry on with it.
func do_open(n: int) -> void:
	Store.set_career_slot(n)
	Game.career_open = true
	Game.result = null
	_load()
	_show_hub()

## The form for a new career in save `n`.
func do_new(n: int) -> void:
	_new_slot = n
	view = "new"
	if menu.current_route() == "career/new": show_screen()
	else: menu.go("career/new")

## Start a save's career again from the beginning: the same team name and
## starting money, a fresh field and a new draw.
func do_restart(n: int) -> void:
	var c = _saved(n)
	if not (c is Dictionary): return
	_begin(n, str(c.get("team", "")), J.g(c, "startingCash", reg.economy.startingCash))

func do_delete(n: int) -> void:
	Store.remove(Store.career_key(n))
	if n == slot: _close()
	# The one last played is gone: the next save there is takes its place.
	if n == Store.career_slot():
		for k in range(1, Store.CAREER_SLOTS + 1):
			if _used(k):
				Store.set_career_slot(k)
				slot = k
				break
	_show_saves()

# The career that was open is no more (deleted, or retired to the Hall of Fame).
func _close() -> void:
	_drop_screens()
	career = null
	Game.career_open = false
	menu.reload_saves({})

func do_simulate() -> void:
	summary = Career.simulate_player_fight(reg, career)
	save()
	show_screen()

# After a fight's result: to the pit, if there is anything to fix.
func do_continue() -> void:
	summary = null
	if career.get("pit") != null: menu.go("career/pit")
	else: show_screen()

func do_fight() -> void:
	var nf = Career.next_fight(reg, career)
	if nf != null and career.get("pit") == null: _arena_fight(nf)

func do_next_season() -> void:
	# The off-season takes a while (every team tests its upgrades): it runs
	# behind a card that says so.
	var c: Dictionary = career
	menu.add_child(JobOverlay.new("The off-season", "The teams are rebuilding their robots and testing them against the field...",
		func(progress: Callable):
			Career.start_next_season(reg, c, progress)
			return true,
		func(_r):
			summary = null
			Career.advance_career(reg, career)
			save()
			menu.refresh_catalog()
			show_screen()))

func reload_and_show() -> void:
	_load()
	view = "hub"
	show_screen()

# After a Market action: save, say what happened, show the tab again.
func _market_done(r: Dictionary, say: Callable) -> void:
	market_msg = {"ok": J.truthy(r.get("ok")), "text": say.call(r) if J.truthy(r.get("ok")) else str(J.g(r, "reason", "That did not work."))}
	if J.truthy(r.get("ok")): save()
	tab = "market"
	show_screen()

# ---------------------------------------------------------------- the arena

func _stage_label(f: Dictionary) -> String:
	var s: Dictionary = career.season
	if f.stage == "grudge": return "Outside the standings"
	if f.stage == "group": return "%sGroup %s · round %d" % ["Giant Nut " if f.league == "giantNut" else "", f.group, int(f.round) + 1]
	var b: Dictionary = s.giantNut.bracket if f.league == "giantNut" else s.leagues[f.league].finals
	return "%s%s" % ["Giant Nut " if f.league == "giantNut" else "%s " % Career.LEAGUE_TITLES[f.league], Tournament.round_name(b, f.bracketRound)]

# What the fight screen needs to know about the rivalry.
func _story_of(nf: Dictionary) -> Dictionary:
	var e = Rivalry.rival_of(career, nf.oppId)
	var lv := Rivalry.level_of(reg, e)
	var grudge: bool = J.truthy(nf.get("grudge"))
	return {
		"grudge": grudge, "asked": J.path(career, ["grudge", "asked"]) if grudge else null,
		"level": lv.level, "name": lv.name,
		"series": {"w": e.w, "l": e.l, "fights": e.fights, "koFor": e.koFor, "koAgainst": e.koAgainst} if e != null else null,
		"last": {"won": e.last.won, "method": e.last.method, "season": e.last.season, "stageName": e.last.get("stageName")} if (e != null and e.get("last") != null) else null,
		"lines": Rivalry.storyline(reg, career, nf.oppId, {"names": {"them": rname(nf.oppId), "me": rname(career.playerId)},
			"driver": J.path(career, ["drivers", nf.oppId, "name"]), "grudge": career.get("grudge") if grudge else null}),
		"stage": _stage_label(nf.fixture),
	}

static func _pick(d: Dictionary, keys: Array) -> Dictionary:
	var out := {}
	for k in keys:
		if d.has(k): out[k] = d[k]
	return out

func _arena_fight(nf: Dictionary) -> void:
	save()
	var o: Dictionary = nf.opp
	var handoff := {
		"fixtureId": nf.fixture.id, "oppId": nf.oppId,
		# The opponent as it is now, and as it has set itself up for you:
		# build, body, tactics and the difficulty's edge.
		"oppDef": {"build": o.build, "body": o.get("body"), "rating": o.get("rating"), "league": o.get("league"), "archetype": o.get("archetype"),
			"version": o.get("version"), "personality": o.get("personality"), "tactics": o.get("tactics"),
			"skillBonus": J.g(o, "skillBonus", 0), "learnRate": J.g(o, "learnRate", 0.7)},
		# And you, as built in the workshop.
		"meId": career.playerId,
		# The damage both robots carry in (the pits did not fix everything).
		"meCondition": J.g(nf, "myCondition", {}),
		"oppCondition": nf.get("oppCondition"),
		"meDef": _pick(Career.fielded_def(reg, career, career.playerId), ["name", "body", "build", "livery", "personality", "archetype", "league", "partner"]),
		"mePartnerCondition": nf.get("myPartnerCondition"),
		# Where it is: venue and hazard layout.
		"arena": nf.get("arena"),
		# The story so far, for the commentary and the intro (rivalry.gd).
		"story": _story_of(nf),
	}
	Game.start_fight({"mode": "career", "red": career.playerId, "blue": nf.oppId, "seed": int(nf.seed) & 0xffff, "career": handoff.duplicate(true)})

# The opponent's last fight, re-run in the arena with the robots as they are now.
func _watch_tape(nf: Dictionary) -> void:
	var rep := Scouting.scout_report(reg, career, nf.oppId, rname)
	var tape = rep.get("tape")
	if tape == null: return
	save()
	var other = tape.b if tape.a == nf.oppId else tape.a
	var def_of := func(id) -> Dictionary:
		var d: Dictionary = nf.opp if id == nf.oppId else Career.fielded_def(reg, career, id)
		return _pick(d, ["name", "body", "build", "livery", "personality", "archetype", "league", "partner", "rating", "tactics"])
	var label := "SCOUTING TAPE · %s v %s · %s" % [rname(nf.oppId), rname(other), tape.label if J.truthy(tape.get("label")) else "season %s" % J.s(tape.season)]
	Game.start_fight({"mode": "scout", "red": nf.oppId, "blue": other, "driver": "ai", "seed": Rng.hash_seed(str(tape.id)) & 0xffff,
		"venue": J.path(tape, ["arena", "venue"], "rookie"), "layout": J.path(tape, ["arena", "layout"], "random"),
		"scout": {"red": {"id": nf.oppId, "def": def_of.call(nf.oppId)}, "blue": {"id": other, "def": def_of.call(other)}, "label": label,
			"real": rep.get("tapeText", "")}.duplicate(true)})

# ---------------------------------------------------------------- the hub

func _hub() -> void:
	var s: Dictionary = career.season
	var over: bool = J.truthy(career.get("seasonOver"))
	var nf = null if over else Career.next_fight(reg, career)
	var lg = Career.player_league(career)
	var where: String = "Giant Nut" if s.kind == "giantNut" else "%s league" % Career.LEAGUE_TITLES[lg]
	var round_label := "season over" if J.truthy(s.get("done")) else ("group round %d of %d" % [int(s.round) + 1, int(s.groupRounds)] if s.round < s.groupRounds else "finals")
	var cash_lbl := UI.label(money(career.cash), {"kind": "mono", "size": 16, "weight": 700, "color": Color(Doc.NEG) if career.cash < 0 else UI.ACCENT})
	var careers := UI.button("CAREERS", "back")
	careers.tooltip_text = "Your saves: switch career, start another, restart or delete one"
	careers.pressed.connect(func(): menu.go("career/saves"))
	add_child(menu.bar("Career · Season %s · %s" % [J.s(s.index), where], "", "MENU", "main",
		[careers, UI.label(round_label.to_upper(), {"kind": "cond", "size": 13, "weight": 500, "ls": 0.1, "color": UI.DIM}), cash_lbl]))
	# Notices: what happened while you were away.
	var notices: Array = career.get("notices", [])
	if not notices.is_empty():
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 8)
		for n in notices.slice(-4):
			var pc := PanelContainer.new()
			var good: bool = n.get("kind") == "good"
			pc.add_theme_stylebox_override("panel", UI.box(Color(0.29, 0.82, 0.48, 0.14) if good else (Color(1, 0.35, 0.32, 0.14) if n.get("kind") == "bad" else Color(1, 1, 1, 0.06)),
				{"pad": [14, 5], "skew": 0.1}))
			pc.add_child(UI.label(str(n.text), {"kind": "cond", "size": 15, "weight": 500}))
			row.add_child(pc)
		var dismiss := UI.button("DISMISS", "ghost", {"size": 11})
		dismiss.pressed.connect(func():
			career.notices = []
			save()
			show_screen())
		row.add_child(dismiss)
		add_child(UI.margin(row, 18, 8, 18, 0))

	var left := Doc.new(10)
	if summary != null: _result_panel(left, summary)
	elif over: _season_over_panel(left)
	elif nf != null: _next_panel(left, nf)
	else:
		var p := Plate.new()
		p.add_child(UI.label("Waiting on the other fights...", {"kind": "cond", "size": 16}))
		left.add(p)
	var left_scroll := UI.scroll(left)
	left_scroll.size_flags_stretch_ratio = 1.15

	var tabs := UI.hbox(0)
	for t in TABS:
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
	_tab_body(body)
	var right_plate := Plate.new(0, 0)
	right_plate.bolts = false
	right_plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rv := UI.vbox(0, [tab_bar, UI.scroll(UI.margin(body, 16, 12))])
	right_plate.add_child(rv)
	var main := UI.hbox(14, [left_scroll, right_plate])
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(UI.margin(main, 18, 12, 18, 16))

# ---------------------------------------------------------------- left column

func _btn(text: String, kind: String, fn: Callable, opts: Dictionary = {}) -> Button:
	var b := UI.button(text, kind, opts)
	b.pressed.connect(fn)
	return b

func _call_out_box(d: Doc) -> void:
	var c: Dictionary = career.challenge
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UI.box(Color(1, 0.23, 0.18, 0.1), {"left_bar": Color("ff3b2e"), "left_bar_w": 6, "pad": [14, 8]}))
	var v := Doc.new(6)
	v.p(Doc.esc(c.text), {"size": 16})
	v.row([_btn("ACCEPT THE GRUDGE MATCH", "fight", func():
		Rivalry.answer_challenge(reg, career, true, rname)
		save()
		show_screen(), {"small": true}),
		_btn("TURN THEM DOWN", "ghost", func():
			Rivalry.answer_challenge(reg, career, false, rname)
			save()
			show_screen())])
	box.add_child(v)
	d.add(box)

# The purse and the rules for a grudge match.
func _grudge_terms(nf: Dictionary) -> String:
	var order: Array = reg.league.leagues
	var lg = order[maxi(order.find(Career.player_league(career)), order.find(nf.opp.get("league")))]
	var scale: float = J.g(Settings.difficulty_of(reg, career.get("difficulty", "medium")), "purse", 1.0)
	var p := Rivalry.grudge_purse(reg, career, nf.oppId, reg.economy.league[lg])
	return "Not in the standings. %s to turn up, %s to win%s. The damage is real: the pit is after it, as usual." % [money(p.appearance * scale), money(p.win * scale),
		", %s more for a KO" % money(p.koBonus * scale) if J.truthy(p.get("koBonus")) else ""]

func _my_class() -> String:
	var w = Garage.player_def(reg, career).build.get("weapon")
	return str(reg.part(w).spec["class"]) if J.truthy(w) else "none"

func _next_panel(d: Doc, nf: Dictionary) -> void:
	# A call-out still waiting for an answer.
	if career.get("challenge") != null:
		var cp := Plate.new()
		var cd := Doc.new(6)
		_call_out_box(cd)
		cd.p("Unanswered, it lapses when you fight your next fight.", {"tone": "muted", "size": 12})
		cp.add_child(cd)
		d.add(cp)
	var sc := Catalog.scouting(reg, nf.opp)
	var grudge: bool = J.truthy(nf.get("grudge"))
	var panel := Plate.new(18, 14)
	if grudge: panel.ring = Color("ff3b2e")
	var v := Doc.new(6)
	if grudge:
		v.add(UI.label("GRUDGE MATCH%s" % (" · THEY CALLED YOU OUT" if J.path(career, ["grudge", "asked"]) == "them" else " · YOU ASKED FOR IT"),
			{"kind": "display", "size": 28, "weight": 700, "italic": true, "ls": 0.12, "color": Color("ff3b2e")}))
	var arena = nf.get("arena")
	var stage_text := _stage_label(nf.fixture).to_upper()
	if arena is Dictionary: stage_text += "  ·  %s  ·  %s" % [str(J.g(Arenas.venue_of(reg, arena.venue), "name", "")).to_upper(), str(J.g(Arenas.layout_of(reg, arena.layout), "name", "")).to_upper()]
	v.add(UI.label(stage_text, {"kind": "cond", "size": 14, "weight": 700, "ls": 0.22, "color": UI.HOT}))
	var ver := Career.version_of(career, nf.oppId)
	v.add(Doc.text("[color=#ff4a3d]%s[/color]  [color=#ffc81e][font_size=26]VS[/font_size][/color]  [color=#4a9bff]%s[/color]%s" % [
		Doc.esc(rname(career.playerId).to_upper()), Doc.esc(str(sc.name).to_upper()), "  [font_size=16]v%s[/font_size]" % ver if ver != "1.0" else ""],
		{"kind": "display", "size": 44, "weight": 600, "italic": true}))

	# The opponent on its turntable, beside the scouting report.
	var st := menu.stage()
	st.custom_minimum_size = Vector2(300, 250)
	st.size_flags_horizontal = Control.SIZE_FILL
	st.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	st.show_def(nf.opp, nf.get("oppCondition"))
	var sd := Doc.new(3)
	sd.add(UI.label("SCOUTING REPORT", {"kind": "cond", "size": 15, "weight": 700, "ls": 0.2}))
	var rec := Career.record_of(career.season, nf.oppId)
	sd.p("%s · %s · %s driver, rated %s%s" % [Doc.esc(sc.team), Career.LEAGUE_TITLES.get(nf.opp.get("league"), ""), Doc.esc(sc.driver.personality), J.s(sc.driver.rating),
		" · %s-%s this season" % [J.s(rec.wins), J.s(rec.losses)] if (rec.wins + rec.losses) > 0 else ""], {"size": 14, "color": Color("b9c1cd")})
	var drv = J.path(career, ["drivers", nf.oppId])
	if drv is Dictionary:
		var nth := int(drv.years) + 1
		var stage_frac: float = drv.years / maxf(1.0, drv.span)
		sd.p("Driven by %s, in their %s season%s%s." % [Doc.esc(drv.name), ordinal(nth),
			" - a veteran near the end" if stage_frac > 0.8 else (" - a rookie at the sticks" if nth <= 2 else ""),
			" (the robot's %s driver)" % ordinal(int(drv.gen)) if J.g(drv, "gen", 1) > 1 else ""], {"size": 14, "color": Color("b9c1cd")})
	sd.add(UI.label(("%s%s" % [sc.weapon, " + %s (%s)" % [sc.partner.name, sc.partner.weapon] if sc.get("partner") is Dictionary else ""]).to_upper(),
		{"kind": "cond", "size": 15, "weight": 700, "ls": 0.08, "color": UI.ACCENT}))
	var bits := [["WEAPON", str(sc.weaponClass)], ["WEIGHT", "%s lb" % J.s(sc.weightLb)], ["TOP SPEED", "%s mph" % J.s(sc.topSpeedMph)],
		["ARMOUR", "%s hp" % J.s(sc.armourHp)], ["PUSH", "%s×" % J.s(sc.pushRatio)]]
	if J.truthy(sc.get("weaponEnergyKJ")): bits.append(["ENERGY", "%s kJ" % J.s(sc.weaponEnergyKJ)])
	var stats := HFlowContainer.new()
	stats.add_theme_constant_override("h_separation", 14)
	for b in bits:
		stats.add_child(UI.hbox(5, [UI.label(b[0], {"kind": "cond", "size": 12, "weight": 600, "ls": 0.08, "color": UI.DIM}), UI.label(b[1], {"kind": "mono", "size": 13, "weight": 700})]))
	sd.add(stats)
	_bullets(sd, "Watch for", sc.get("notes", []))
	_bullets(sd, "Weak points", sc.get("weak", []))
	_bullets(sd, "Set up for you", nf.get("oppChanges", []))
	# What it has learned about robots like yours (ailearn.gd).
	var mem = J.path(career, ["ai", nf.oppId, "vs", _my_class()])
	if mem is Dictionary and J.g(mem, "f", 0) >= 2:
		var how := ""
		var best := 0.0
		for k in (mem.get("lossBy", {}) as Dictionary):
			if mem.lossBy[k] > best:
				best = mem.lossBy[k]
				how = k
		sd.p("Has fought %s robots with your kind of weapon and won %s%s. It remembers." % [J.s(mem.f), J.s(mem.w),
			" - lost mostly by %s" % how.replace("ko:", "being ") if how != "" else ""], {"size": 14, "color": Color("b9c1cd")})
	# The scouts' notes: its form this season, how it wins and loses, and the tape.
	var rep := Scouting.scout_report(reg, career, nf.oppId, rname, _my_class())
	var chips := ""
	for x in rep.get("form", []):
		chips += " [color=%s][b]%s%s[/b][/color]" % [Doc.POS if x.won else Doc.NEG, "W" if x.won else "L", "·KO" if (x.method == "ko" or x.method == "tapout") else ""]
	sd.sub("Form", chips)
	if (rep.get("lines", []) as Array).is_empty(): sd.p("No fights yet this season.", {"tone": "muted", "size": 12})
	else:
		for l in rep.lines: sd.p("•  " + Doc.esc(l), {"kind": "body", "size": 13, "weight": 400})
	if not (rep.get("vs", []) as Array).is_empty():
		var parts := []
		for x in rep.vs: parts.append("%s %s-%s" % [Doc.esc(x.name), J.s(x.w), J.s(x.l)])
		sd.p("Its record against %s." % ", ".join(parts), {"size": 14, "color": Color("b9c1cd")})
	if rep.get("tape") != null:
		sd.p(Doc.esc(rep.get("tapeText", "")), {"size": 12})
		sd.row([_btn("WATCH THE TAPE", "ghost", func(): _watch_tape(nf), {"size": 11})])
		sd.p("A re-run in the arena with both robots as they are now - it may not end the same way.", {"tone": "muted", "size": 12})
	# The story so far.
	var story := Rivalry.storyline(reg, career, nf.oppId, {"names": {"them": rname(nf.oppId)}, "driver": J.path(career, ["drivers", nf.oppId, "name"]),
		"grudge": career.get("grudge") if grudge else null})
	if not story.is_empty():
		var lv := Rivalry.level_of(reg, Rivalry.rival_of(career, nf.oppId))
		sd.sub("History", "[color=#ff5a44][b]%s[/b][/color]" % Doc.esc(str(lv.name).to_upper()) if J.truthy(lv.level) else "")
		for l in story: sd.p("•  " + Doc.esc(l), {"kind": "body", "size": 13, "weight": 400})
		if J.truthy(lv.level) and not grudge: sd.p("A rival studies you harder and drives fired up; the promoters pay a gate bonus.", {"size": 14, "color": Color("b9c1cd")})
	if arena is Dictionary:
		sd.sub("The arena")
		sd.p(Doc.esc(J.g(Arenas.layout_of(reg, arena.layout), "blurb", "")), {"kind": "body", "size": 13, "weight": 400})
	var evo = J.path(career, ["evolution", nf.oppId])
	if evo is Dictionary and not (evo.get("log", []) as Array).is_empty():
		var changes: Array = (evo.log as Array).slice(-2)
		changes.reverse()
		sd.sub("Off-season work")
		for c in changes:
			for n in c.notes: sd.p("•  %s %s" % [Doc.muted("S%s:" % J.s(c.season)), Doc.esc(n)], {"kind": "body", "size": 13, "weight": 400})
	if J.truthy(sc.get("inspiredBy")): sd.p("[i]a nod to %s[/i]" % Doc.esc(sc.inspiredBy), {"tone": "muted", "size": 12})
	v.add(UI.hbox(14, [st, sd]))

	# Both robots' damage as they will turn up for the fight.
	var mine := Build.assemble_robot(reg, Garage.player_def(reg, career))
	mine.condition.merge(J.g(nf, "myCondition", {}), true)
	var theirs := Build.assemble_robot(reg, nf.opp)
	var oc = nf.get("oppCondition")
	if oc is Array and oc.size() > 0 and oc[0] is Dictionary: theirs.condition.merge(oc[0], true)
	v.p("%s %s   ·   %s %s" % [Doc.muted("You:"), _damage_line(mine), Doc.muted("%s:" % Doc.esc(nf.opp.name)), _damage_line(theirs)], {"size": 14})

	if career.get("pit") != null:
		v.row([_btn("TO THE PIT", "fight", func(): menu.go("career/pit"))])
		v.p("Your robot is still in the pit from the last fight. Fix what you can, then send it out.", {"tone": "muted", "size": 12})
	else:
		_fight_btn = _btn("FIGHT!", "fight", do_fight)
		var acts := [_fight_btn, _btn("LET YOUR AI DRIVER FIGHT IT", "ghost", do_simulate)]
		if grudge: acts.append(_btn("CALL IT OFF", "ghost", func():
			UI.confirm(self, "Call off the grudge match? Their fans will say you ducked it.", func():
				Rivalry.cancel_grudge(reg, career, rname)
				career.prep = null
				save()
				show_screen()), {"size": 11}))
		v.row(acts, 12)
	if grudge: v.p(_grudge_terms(nf), {"tone": "muted", "size": 12})
	var g := Garage.garage_of(reg, career)
	var links := [_btn("WORKSHOP", "ghost", func(): menu.go("career/workshop"))]
	if J.truthy(Game.settings.get("advisor", true)):
		links.append(_btn("ASK THE ADVISOR FOR A GAME PLAN", "ghost", func():
			menu.go("career/workshop")
			if _workshop != null: _workshop.ask("fight")))
	links.append(UI.label("%s v%s · %s driver" % [rname(career.playerId), J.s(g.version), g.personality], {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM}))
	v.row(links, 10)
	var disc := Career.parts_discount(reg, career)
	v.p("Damage stays on your robot until you fix it in the pit%s; everyone else's does too." % (" (%d%% parts discount)" % int(round(disc * 100.0)) if disc > 0.0 else ""), {"tone": "muted", "size": 12})
	panel.add_child(v)
	d.add(panel)

func _bullets(d: Doc, title: String, lines) -> void:
	if not (lines is Array) or lines.is_empty(): return
	d.sub(title)
	for l in lines: d.p("•  " + Doc.esc(l), {"kind": "body", "size": 13, "weight": 400})

func _damage_line(a: Dictionary) -> String:
	var ds := Pit.damage_summary(reg, a)
	if J.truthy(ds.get("fresh")): return "fresh"
	var parts := []
	for x in ds.worst: parts.append("%s %d%%" % [Doc.esc(x.name), int(round(x.c * 100.0))])
	return ", ".join(parts) + (" +%d more" % (int(ds.count) - 3) if ds.count > 3 else "")

func _result_panel(d: Doc, sum: Dictionary) -> void:
	var r: Dictionary = sum.result
	var won: bool = J.truthy(sum.get("won"))
	var how := ""
	if r.method == "decision": how = "%s decision" % ("unanimous" if r.get("decision") == "unanimous" else "split")
	else: how = "%s%s at %s" % [METHOD.get(r.method, r.method), " (%s)" % r.cause if (r.method == "ko" and J.truthy(r.get("cause"))) else "", fmt(r.get("elapsedS", 0.0))]
	var panel := Plate.new(18, 14)
	var v := Doc.new(6)
	v.add(UI.label("WIN" if won else "LOSS", {"kind": "display", "size": 86, "weight": 700, "italic": true, "shadow": true, "color": Color("45e06a") if won else Color("ff4a3d")}))
	v.p("vs %s · %s%s" % [Doc.esc(rname(sum.oppId)), how, " · fought by your AI driver" if r.get("by") == "sim" else ""], {"size": 17})
	var lines: Array = J.path(sum, ["repair", "lines"], [])
	if lines.is_empty(): v.p("Not a scratch on it.", {"tone": "muted"})
	else:
		v.sub("Damage")
		var rows := []
		for l in lines: rows.append([Doc.esc(l.name), Doc.muted("%d%%" % int(round(l.condition * 100.0))), Doc.muted(money(l.cost))])
		rows.append(["[b]To put it all right[/b]", "", "[b]%s[/b]" % money(sum.repair.total)])
		v.ledger(rows)
		v.p("Nothing is paid yet: the pit is next, and you choose what gets fixed.", {"tone": "muted", "size": 12})
	v.sub("Money")
	var mrows := []
	for l in sum.get("lines", []): mrows.append([Doc.esc(l.label), "", Doc.cash(l.amount)])
	mrows.append(["[b]This fight[/b]", "", "[b]%s[/b]" % Doc.cash(sum.get("net", 0.0))])
	v.ledger(mrows)
	# After the fight: the rivalry, a rematch to ask for, a call-out to answer.
	var e = Rivalry.rival_of(career, sum.oppId)
	if e != null:
		var lv := Rivalry.level_of(reg, e)
		v.sub("Rivalry")
		v.p("Head to head: %s-%s%s%s%s" % [J.s(e.w), J.s(e.l), " in %s meetings" % J.s(e.fights) if e.fights > 1 else "",
			" · [color=#ff5a44][b]%s[/b][/color]" % Doc.esc(lv.name) if J.truthy(lv.level) else "", " - new!" if J.truthy(J.path(sum, ["rivalry", "levelUp"])) else ""], {"size": 13})
		if J.path(career, ["challenge", "fixtureId"]) == sum.get("fixtureId") and career.get("challenge") != null: _call_out_box(v)
		var rm = sum.get("rematch")
		var can := Rivalry.can_ask_rematch(reg, career)
		if rm is Dictionary:
			v.p("Rematch accepted: the grudge match is before your next fight." if J.truthy(rm.get("accepted")) else "They turned your rematch down.",
				{"tone": "pos" if J.truthy(rm.get("accepted")) else "muted", "size": 13})
		elif J.truthy(can.get("ok")):
			v.row([_btn("DEMAND A REMATCH", "ghost", func():
				var lf = career.get("lastFight")
				var rr := Rivalry.ask_rematch(reg, career, rname, str(Career.fielded_def(reg, career, lf.oppId).get("personality", "")) if lf != null else "")
				if summary != null: summary.rematch = rr
				save()
				show_screen()),
				UI.label("a grudge match before your next fight, outside the standings - they may say no", {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM})])
		elif J.truthy(can.get("reason")): v.p(Doc.esc(can.reason), {"tone": "muted", "size": 12})
	v.gap(4)
	v.row([_btn("TO THE PIT" if not lines.is_empty() else "CONTINUE", "fight", do_continue, {"small": true})])
	panel.add_child(v)
	d.add(panel)

func _season_over_panel(d: Doc) -> void:
	var h: Dictionary = career.history[career.history.size() - 1]
	var next_idx := int(career.seasonIndex) + 1
	var next_kind: String = reg.league.cycle[(next_idx - 1) % reg.league.cycle.size()]
	var panel := Plate.new(18, 14)
	var v := Doc.new(6)
	v.add(UI.label("SEASON %s IS OVER" % J.s(h.season), {"kind": "cond", "size": 14, "weight": 700, "ls": 0.22, "color": UI.HOT}))
	var rec: Dictionary = h.record
	var rec_text := "%s-%s%s" % [J.s(rec.wins), J.s(rec.losses), ", %s KO" % J.s(rec.kos) if J.truthy(rec.get("kos")) else ""]
	if h.kind == "league":
		var fin: String = finish_name(h.finish, 16) if h.finish.stage == "final" else "did not make the finals"
		var big := "PROMOTED" if J.truthy(h.get("promoted")) else ("RELEGATED" if J.truthy(h.get("relegated")) else "#%s" % J.s(h.position))
		v.add(UI.label(big, {"kind": "display", "size": 86, "weight": 700, "italic": true, "shadow": true,
			"color": Color("45e06a") if J.truthy(h.get("promoted")) else (Color("ff4a3d") if J.truthy(h.get("relegated")) else UI.TEXT)}))
		v.p("%s league · %s · %s · finished %s of 30" % [Career.LEAGUE_TITLES[h.league], rec_text, fin, ordinal(int(h.position))], {"size": 17})
		v.sub("Champions")
		var rows := []
		var lgs: Array = (reg.league.leagues as Array).duplicate()
		lgs.reverse()
		for lg in lgs: rows.append([Career.LEAGUE_TITLES[lg], "", Doc.pos(Doc.esc(name_of(h.champions[lg]))) if is_me(h.champions[lg]) else Doc.esc(name_of(h.champions[lg]))])
		v.ledger(rows)
		v.p("Next season you %s the [b]%s[/b] league." % ["fight in" if (J.truthy(h.get("promoted")) or J.truthy(h.get("relegated"))) else "stay in", Career.LEAGUE_TITLES[h.nextLeague]])
	else:
		var fin: String = finish_name(h.finish, 64) if h.finish.stage == "final" else "out in the group stage"
		v.add(UI.label("GIANT NUT CHAMPION" if is_me(h.champion) else "GIANT NUT", {"kind": "display", "size": 76, "weight": 700, "italic": true, "shadow": true, "color": UI.ACCENT}))
		v.p("%s · %s" % [rec_text, fin], {"size": 17})
		v.sub("The Giant Nut goes to")
		v.add(UI.label(name_of(h.champion).to_upper(), {"kind": "display", "size": 34, "weight": 600, "italic": true}))
		v.p("Everyone goes back to their league. You are back in the [b]%s[/b] league." % Career.LEAGUE_TITLES[Career.player_league(career)])
	if career.get("grudge") != null:
		v.p("Grudge match booked: you against [b]%s[/b], before your first fight of season %d." % [Doc.esc(rname(career.grudge.oppId)), next_idx])
	v.gap(4)
	v.row([_btn("START SEASON %d%s" % [next_idx, ": THE GIANT NUT" if next_kind == "giantNut" else ""], "fight", do_next_season, {"small": true}),
		_btn("WORKSHOP", "ghost", func(): menu.go("career/workshop"))], 12)
	panel.add_child(v)
	d.add(panel)

# ---------------------------------------------------------------- tabs

func _tab_body(d: Doc) -> void:
	match tab:
		"standings": _standings(d)
		"bracket": _bracket(d)
		"results": _results(d)
		"money": _money(d)
		"rivals": _rivals(d)
		"market": _market(d)
		"settings":
			save()
			d.add(SavesPanel.new(func(): reload_and_show(), ["career"], "Back up this career"))
			d.sub("This save", Doc.muted("· save %d of %d" % [slot, Store.CAREER_SLOTS]))
			_save_buttons(d)
			d.add(SettingsPanel.new(null, "These are the game's settings - the same as on the main menu. Difficulty applies to your career from the next fight.",
				func(_s, id):
					if id == "difficulty":
						_sync_settings()
						show_screen()))
		_: _trophies(d)

func _standings(d: Doc) -> void:
	var s: Dictionary = career.season
	var comp: String = Career.player_league(career) if s.kind == "league" else "giantNut"
	var tables: Dictionary = Season.group_tables(s)[comp]
	var pg = Career.player_group(career)
	var mine = pg.name if pg != null else null
	var names: Array = tables.keys()
	names.sort()
	if mine != null and names.has(mine):
		names.erase(mine)
		names.push_front(mine)
	var cut: int = int(reg.league.league.finals.perGroup) if s.kind == "league" else int(reg.league.giantNut.advance)
	var wild: Array = s.leagues[comp].get("wildCards", []) if s.kind == "league" else []
	d.p("%s Ranked by wins, then knockouts, then damage." % ("Top %d of each group and the 4 best of the rest go to the finals." % cut if s.kind == "league" else "Top %d of each group go to the 64-robot bracket." % cut),
		{"tone": "muted", "size": 12})
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 12)
	for g in names:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.22), {"border": UI.ACCENT if g == mine else UI.LINE, "border_w": 2 if g == mine else 1, "pad": [10, 6]}))
		card.custom_minimum_size.x = 330
		var t := Doc.new(2)
		var rows := []
		var tones := []
		var rows_in: Array = tables[g]
		for i in rows_in.size():
			var r: Dictionary = rows_in[i]
			var mark := Doc.pos("●") if i < cut else (Doc.accent("●") if wild.has(r.id) else Doc.muted("·"))
			rows.append(["%s %d  %s" % [mark, i + 1, Doc.esc(rname(r.id))], J.s(r.wins), J.s(r.losses), J.s(r.kos), "%d" % int(round(r.damage))])
			tones.append("me" if is_me(r.id) else "")
		t.add(UI.label("GROUP %s" % g, {"kind": "display", "size": 22, "weight": 600, "italic": true, "ls": 0.06, "color": UI.ACCENT}))
		t.table(5, rows, {"head": ["", "W", "L", "KO", "Dmg"], "right": [1, 2, 3, 4], "tones": tones, "hsep": 10})
		card.add_child(t)
		flow.add_child(card)
	d.add(flow)

func _bracket(d: Doc) -> void:
	var s: Dictionary = career.season
	var comp: String = Career.player_league(career) if s.kind == "league" else "giantNut"
	var b = s.leagues[comp].get("finals") if s.kind == "league" else s.giantNut.get("bracket")
	if b == null:
		d.p("The %s drawn when the group stage ends." % ("16-robot finals are" if s.kind == "league" else "64-robot bracket is"), {"tone": "muted"})
		return
	var cols := UI.hbox(12)
	for r in b.rounds.size():
		var col := UI.vbox(6, [UI.label(Tournament.round_name(b, r).to_upper(), {"kind": "display", "size": 18, "weight": 600, "italic": true, "color": UI.HOT})])
		col.custom_minimum_size.x = 190
		for m in b.rounds[r]:
			var mine: bool = (m.get("a") != null and is_me(m.a)) or (m.get("b") != null and is_me(m.b))
			var box := PanelContainer.new()
			box.add_theme_stylebox_override("panel", UI.box(Color("121418"), {"border": UI.ACCENT if mine else UI.LINE, "pad": [8, 4]}))
			var v := UI.vbox(0)
			for side in ["a", "b"]:
				var id = m.get(side)
				var text := "bye" if (J.truthy(m.get("bye")) and id == null) else (rname(id) if id != null else "—")
				var col_c := UI.DIM if id == null else (UI.ACCENT if is_me(id) else (UI.TEXT if m.get("winner") == id else Color("9aa0a8")))
				v.add_child(UI.label(text, {"kind": "cond", "size": 14, "weight": 700 if (id != null and m.get("winner") == id) else 500, "color": col_c, "clip": true}))
			var res = m.get("result")
			if res is Dictionary:
				v.add_child(UI.label("%s%s" % [METHOD.get(res.method, res.method), "" if res.method == "decision" else " %s" % fmt(res.get("elapsedS", 0.0))],
					{"kind": "body", "size": 11, "weight": 400, "color": UI.DIM}))
			box.add_child(v)
			col.add_child(box)
		cols.add_child(col)
	var sc := ScrollContainer.new()
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(cols)
	sc.custom_minimum_size.y = cols.get_combined_minimum_size().y + 16
	d.add(sc)

func _results(d: Doc) -> void:
	var s: Dictionary = career.season
	var me = career.playerId
	var comp: String = Career.player_league(career) if s.kind == "league" else "giantNut"
	var all := []
	for f in (s.fixtures as Array) + (s.get("finalsLog", []) as Array):
		if f.get("result") != null and f.get("league") == comp: all.append(f)
	var mine := all.filter(func(f): return f.a == me or f.b == me)
	var rest: Array = all.filter(func(f): return f.a != me and f.b != me).slice(-24)
	rest.reverse()
	var row := func(f: Dictionary) -> Array:
		var r: Dictionary = f.result
		var a := Doc.esc(rname(f.a))
		var b := Doc.esc(rname(f.b))
		return ["[b]%s[/b]" % a if r.winnerId == f.a else a, "[b]%s[/b]" % b if r.winnerId == f.b else b,
			Doc.muted("%s%s" % [METHOD.get(r.method, r.method), " %s" % fmt(r.get("elapsedS", 0.0)) if r.method != "decision" else ""]),
			Doc.muted("Grp %s" % f.group if f.stage == "group" else "Finals")]
	d.sub("Your fights")
	if mine.is_empty(): d.p("No fights yet this season.", {"tone": "muted"})
	else: d.table(4, mine.map(row), {"expand": 1, "tones": mine.map(func(f): return "won" if f.result.winnerId == me else "lost")})
	d.sub("Around the %s" % ("Giant Nut" if comp == "giantNut" else "league"))
	if rest.is_empty(): d.p("Nothing yet.", {"tone": "muted"})
	else: d.table(4, rest.map(row), {"expand": 1})
	var off = career.get("offseason")
	var fr = off.get("field") if off is Dictionary else null
	if fr is Dictionary:
		d.sub("The field moves on (before season %d)" % (int(off.season) + 1))
		var rows := []
		for x in fr.get("retiredDrivers", []): rows.append([Doc.esc(x.name), Doc.muted("retired after %s seasons driving %s" % [J.s(x.years), Doc.esc(x.robot)])])
		for x in fr.get("newDrivers", []): rows.append([Doc.esc(x.name), Doc.muted("takes over %s from %s" % [Doc.esc(x.robot), Doc.esc(x.follows)])])
		for x in fr.get("retiredRobots", []): rows.append([Doc.esc(x.name), Doc.muted("retired: %s" % Doc.esc(x.why))])
		for x in fr.get("newRobots", []): rows.append([Doc.esc(x.name), Doc.muted("new team %s joins Rookie" % Doc.esc(x.team) if J.truthy(x.get("newTeam")) else "%s's new robot (replaces %s)" % [Doc.esc(x.team), Doc.esc(x.replaces)])])
		for x in fr.get("promoted", []): rows.append([Doc.esc(x.name), Doc.muted("moves up to %s to fill a place" % Career.LEAGUE_TITLES.get(x.to, x.to))])
		if not rows.is_empty(): d.table(2, rows, {"expand": 1})
	if off is Dictionary and not (off.get("moves", []) as Array).is_empty():
		var rows := []
		for m in off.moves:
			var real: bool = false
			for n in m.notes:
				if not str(n).begins_with("driver"): real = true
			if real and rows.size() < 40: rows.append(["%s %s" % [Doc.esc(rname(m.id)), Doc.muted("v%s" % J.s(m.version))], Doc.muted(Doc.esc("; ".join(m.notes)))])
		if not rows.is_empty():
			d.sub("Off-season before season %d" % (int(off.season) + 1))
			d.table(2, rows, {"expand": 1})

func _rivals(d: Doc) -> void:
	var list := Rivalry.rivals_list(reg, career)
	var gone: Array = Rivalry.rivals_list(reg, career, false).filter(func(r): return J.truthy(r.get("retired")) or not career.membership.has(r.id)).slice(0, 8)
	var grudges: Array = (career.get("grudgeLog", []) as Array).slice(-8)
	grudges.reverse()
	d.p("Every robot you have fought keeps a record against you. Knockouts, playoff fights, split decisions, revenge and upsets heat a rivalry up; it cools between seasons. A rival studies you harder, drives fired up and draws a gate bonus. After any fight you can demand a rematch - a grudge match, outside the standings - and a rival you beat may call you out.",
		{"tone": "muted", "size": 12})
	if career.get("grudge") != null: d.p("[b]Booked:[/b] a grudge match against %s, before your next fight." % Doc.esc(rname(career.grudge.oppId)))
	if list.is_empty(): d.p("No history yet: fight someone.", {"tone": "muted"})
	else:
		var rows := []
		for r in list:
			var last_note := ""
			var moments: Array = r.get("moments", [])
			if not moments.is_empty(): last_note = str(moments[moments.size() - 1].get("text", ""))
			elif r.get("last") != null: last_note = "Last met in season %s." % J.s(r.last.season)
			rows.append(["[b]%s[/b]%s\n%s" % [Doc.esc(rname(r.id)), "  [color=#ff5a44]%s[/color]" % Doc.esc(str(r.name).to_upper()) if J.truthy(r.get("level")) else "", Doc.muted(Doc.small(Doc.esc(last_note)))],
				"%s-%s" % [J.s(r.w), J.s(r.l)], Doc.muted("KO %s-%s" % [J.s(r.koFor), J.s(r.koAgainst)] if (J.truthy(r.get("koFor")) or J.truthy(r.get("koAgainst"))) else ""),
				Doc.muted(Career.LEAGUE_TITLES.get(career.membership.get(r.id), ""))])
		d.table(4, rows, {"head": ["Robot", "W-L", "", ""]})
	if not grudges.is_empty():
		d.sub("Grudge matches")
		d.table(4, grudges.map(func(g): return [Doc.esc(rname(g.oppId)), "won" if g.won else "lost", Doc.muted(METHOD.get(g.method, g.method)),
			Doc.muted("S%s%s" % [J.s(g.season), " · they called you out" if g.get("asked") == "them" else " · you asked"])]),
			{"tones": grudges.map(func(g): return "won" if g.won else "lost")})
	if not gone.is_empty():
		d.sub("Retired rivals")
		d.table(3, gone.map(func(r): return [Doc.esc(rname(r.id)), "%s-%s" % [J.s(r.w), J.s(r.l)], Doc.muted("retired S%s" % J.s(r.retired) if J.truthy(r.get("retired")) else "")]))

func _money(d: Doc) -> void:
	var disc := Career.parts_discount(reg, career)
	d.add(UI.label(money(career.cash), {"kind": "mono", "size": 46, "weight": 700, "color": Color(Doc.NEG) if career.cash < 0 else UI.ACCENT}))
	if career.cash < 0: d.p("You are in debt. Win some purses before the repair bills bury you - or see the bank on the Market tab.", {"tone": "neg", "size": 12})
	var owed := Market.debt(career)
	if owed > 0.0: d.p("Loans: [b]%s[/b] owed (Market tab)." % Doc.neg(money(owed)), {"size": 13})
	d.sub("Sponsors")
	var signed := []
	var open := []
	for sp in reg.economy.sponsors:
		if (career.sponsors as Array).has(sp.id): signed.append(sp)
		elif sp.get("kind") == "league": open.append(sp)
	if signed.is_empty(): d.p("No sponsors yet.", {"tone": "muted"})
	else: d.ledger(signed.map(func(sp): return ["[b]%s[/b]\n%s" % [Doc.esc(sp.name), Doc.muted(Doc.small(Doc.esc(sp.blurb)))], "%s/season" % money(sp.retainer),
		"%s/win" % money(sp.perWin) if J.truthy(sp.get("perWin")) else ""]))
	if not open.is_empty():
		var wants := []
		for sp in open:
			var q: Dictionary = sp.get("requires", {})
			var bits := []
			if J.truthy(q.get("wins")): bits.append("%s wins" % J.s(q.wins))
			if J.truthy(q.get("kos")): bits.append("%s knockouts" % J.s(q.kos))
			if J.truthy(q.get("league")): bits.append("reach the %s league" % Career.LEAGUE_TITLES.get(q.league, q.league))
			wants.append("%s (%s)" % [", ".join(bits), Doc.esc(sp.name)])
		d.p("Interested if you %s." % "; ".join(wants), {"tone": "muted", "size": 12})
	if disc > 0.0: d.p("Parts discount: [b]%d%%[/b]" % int(round(disc * 100.0)))
	if not (career.get("unlocks", []) as Array).is_empty(): d.p("Unlocked: %s" % Doc.esc(", ".join(career.unlocks)))
	d.sub("Ledger")
	var led: Array = (career.ledger as Array).slice(-30)
	led.reverse()
	if led.is_empty(): d.p("Nothing yet.", {"tone": "muted"})
	else: d.ledger(led.map(func(l): return [Doc.esc(l.label), Doc.muted("S%s" % J.s(l.season)), Doc.cash(l.amount)]))

func _trophies(d: Doc) -> void:
	var st: Dictionary = career.stats
	d.sub("Career")
	d.p("%s fights · %s wins · %s losses · %s knockouts · %s damage dealt" % [J.s(st.fights), J.s(st.wins), J.s(st.losses), J.s(st.kos), J.commas(J.rndi(st.damageDealt))])
	d.sub("League titles")
	if (career.trophies as Array).is_empty(): d.p("None yet.", {"tone": "muted"})
	for t in career.trophies: d.p("★ %s  %s" % [Doc.esc(t.title), Doc.muted("season %s" % J.s(t.season))], {"size": 17})
	d.sub("Giant Nut")
	if (career.giantNutHistory as Array).is_empty(): d.p("The first Giant Nut is season 3.", {"tone": "muted"})
	else: d.ledger((career.giantNutHistory as Array).map(func(g): return ["Season %s" % J.s(g.season),
		Doc.accent("CHAMPION") if is_me(g.champion) else (finish_name(g.finish, 64) if g.finish.stage == "final" else "group stage"), Doc.muted("won by %s" % Doc.esc(name_of(g.champion)))]))
	d.sub("Seasons")
	if (career.history as Array).is_empty(): d.p("Your first season is under way.", {"tone": "muted"})
	else: d.ledger((career.history as Array).map(func(h): return ["Season %s" % J.s(h.season),
		"%s · %s%s" % [Career.LEAGUE_TITLES[h.league], ordinal(int(h.position)), " · promoted" if J.truthy(h.get("promoted")) else (" · relegated" if J.truthy(h.get("relegated")) else "")] if h.kind == "league" else "Giant Nut",
		Doc.muted("%s-%s" % [J.s(h.record.wins), J.s(h.record.losses)])]))
	# The player's robots, retired and current, with their records.
	d.sub("Your robots")
	var g := Garage.garage_of(reg, career)
	var cur: Dictionary = g.get("record") if g.get("record") is Dictionary else {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": 1}
	var rows := []
	for m in g.get("museum", []):
		rows.append(["[b]%s[/b] %s" % [Doc.esc(m.name), Doc.muted("v%s · S%s-%s" % [J.s(m.version), J.s(m.from), J.s(m.to)])],
			Doc.muted("%s-%s%s%s" % [J.s(m.wins), J.s(m.fights - m.wins), ", %s KO" % J.s(m.kos) if J.truthy(m.get("kos")) else "", " · %s title%s" % [J.s(m.titles), "s" if m.titles > 1 else ""] if J.truthy(m.get("titles")) else ""]),
			"sold to %s" % Doc.esc(m.sold.team) if m.get("sold") is Dictionary else "retired"])
	rows.append(["[b]%s[/b] %s" % [Doc.esc(g.name), Doc.muted("v%s · S%s-now" % [J.s(g.version), J.s(cur.get("since", 1))])],
		Doc.muted("%s-%s%s%s" % [J.s(cur.wins), J.s(cur.fights - cur.wins), ", %s KO" % J.s(cur.kos) if J.truthy(cur.get("kos")) else "", " · %s title%s" % [J.s(cur.titles), "s" if cur.titles > 1 else ""] if J.truthy(cur.get("titles")) else ""]), "racing"])
	d.ledger(rows)
	d.gap(6)
	d.row([
		_btn("RETIRE %s…" % rname(career.playerId).to_upper(), "ghost", func():
			UI.prompt(self, "Retire this robot to the museum and build a new one. Name the new robot:", "", func(new_name: String):
				Career.retire_robot(reg, career, new_name)
				save()
				show_screen()), {"size": 11}),
		_btn("RETIRE FROM THE CAREER (HALL OF FAME)…", "ghost", func():
			UI.confirm(self, "Retire from the career? Your team goes into the Hall of Fame and this career ends.", func():
				var hall := HallOfFame.induct(reg, HallOfFame.from_data(Store.read_json(Store.HALL)), career)
				Store.write_json(Store.HALL, hall)
				Store.remove(Store.career_key(slot))
				_close()
				view = "saves"
				menu.go("halloffame")), {"size": 11}),
	])
	_save_buttons(d)

# Starting this career again, or deleting it (Trophies and Settings).
func _save_buttons(d: Doc) -> void:
	d.row([
		_btn("RESTART THIS CAREER…", "ghost", func():
			UI.confirm(self, "Restart %s from the beginning? The team starts again in the Rookie league with a stock robot and its starting money. Everything in this career is lost, and this cannot be undone." % career.team,
				func(): do_restart(slot), "Restart this career?"), {"size": 11}),
		_btn("DELETE THIS CAREER…", "ghost", func():
			UI.confirm(self, "Delete this career? This cannot be undone.", func(): do_delete(slot), "Delete this career?"), {"size": 11}),
		_btn("ALL CAREERS", "ghost", func(): menu.go("career/saves"), {"size": 11}),
	])

# ---------------------------------------------------------------- the Market tab
# The bank, the paddock market and selling your robot. All the rules are
# logic/market.gd; this only shows them.

func _market(d: Doc) -> void:
	if market_msg != null:
		var box := PanelContainer.new()
		box.add_theme_stylebox_override("panel", UI.box(Color(1, 1, 1, 0.05), {"left_bar": Color(Doc.POS) if market_msg.ok else Color(Doc.NEG), "left_bar_w": 6, "pad": [14, 8]}))
		box.add_child(Doc.text(Doc.esc(market_msg.text)))
		d.add(box)
		market_msg = null
	var owed := Market.debt(career)
	d.sub("The bank", Doc.muted("· you owe %s" % money(owed)) if owed > 0.0 else "")
	d.p("Interest is added at the start of every season and a payment taken then, so a loan is paid off over its term. Pay any of it off early with no penalty. Limits go up with your league.", {"tone": "muted", "size": 12})
	var rows := []
	for l in Market.loan_offers(reg, career):
		var amt := LineEdit.new()
		amt.placeholder_text = "amount"
		amt.custom_minimum_size.x = 90
		var borrow := _btn("BORROW", "ghost", func():
			var a := amt.text.to_float()
			_market_done(Market.borrow(reg, career, l.id, a), func(_r): return "Borrowed %s." % money(a)), {"size": 11})
		borrow.disabled = not (l.available > 0)
		var repay := _btn("PAY OFF", "ghost", func():
			var a := amt.text.to_float()
			if not (a > 0.0): a = minf(l.owed, maxf(0.0, floorf(career.cash)))
			_market_done(Market.repay(reg, career, l.id, a), func(r): return "Paid off %s%s." % [money(r.paid), "; %s still owed" % money(Market.debt(career)) if Market.debt(career) > 0.0 else " - debt free"]),
			{"size": 11})
		repay.disabled = not (l.owed > 0)
		rows.append(["[b]%s[/b]\n%s" % [Doc.esc(l.name), Doc.muted(Doc.small("%s %d%% a season, over %s seasons." % [Doc.esc(l.blurb), int(round(l.rate * 100.0)), J.s(l.seasons)]))],
			Doc.muted(Doc.small("%s\nup to %s more" % ["owe %s%s" % [money(l.owed), " · %s season%s left" % [J.s(l.seasonsLeft), "s" if l.seasonsLeft > 1 else ""] if J.truthy(l.get("seasonsLeft")) else ""] if l.owed > 0 else "nothing owed", money(l.available)])),
			UI.hbox(4, [amt, borrow, repay])])
	d.ledger(rows)

	d.sub("For sale in the paddock")
	d.p("Spare parts from other teams' pits, cheaper than the shop - and a team in a higher league may sell you a part the shop will not yet. New stock after every fight.", {"tone": "muted", "size": 12})
	var m := Market.market_of(reg, career)
	if (m.listings as Array).is_empty(): d.p("Nothing left today. Come back after your next fight.", {"tone": "muted"})
	else:
		rows = []
		for l in m.listings:
			var part: Dictionary = reg.part(l.partId)
			rows.append(["[b]%s[/b]%s\n%s" % [Doc.esc(part.name), "  [color=#ff5a44]not in your shop yet[/color]" if J.truthy(l.get("locked")) else "",
				Doc.muted(Doc.small("%s · from %s (%s, %s)" % [CATEGORY.get(part.category, part.category), Doc.esc(l.team), Doc.esc(l.robot), Career.LEAGUE_TITLES.get(l.league, l.league)]))],
				Doc.muted(Doc.small("list %s" % money(l.list))),
				UI.hbox(6, [UI.label(money(l.price), {"kind": "mono", "size": 14, "weight": 700}),
					_btn("BUY", "ghost", func(): _market_done(Market.buy_listing(reg, career, l.id),
						func(r): return "Bought: %s, for %s. It is in your spares - fit it in the workshop." % [reg.part(r.listing.partId).name, money(r.listing.price)]), {"size": 11})])])
		d.ledger(rows)

	d.sub("Your spares")
	var offers := Market.spares_offers(reg, career)
	if offers.is_empty(): d.p("No spares: everything you own is on the robot.", {"tone": "muted"})
	else:
		rows = []
		for o in offers:
			var btns := UI.hbox(4)
			if J.truthy(o.get("price")):
				btns.add_child(_btn("SELL TO %s" % str(o.team).to_upper(), "ghost", func(): _market_done(Market.sell_to_team(reg, career, o.partId),
					func(r): return "Sold to %s for %s." % [r.team, money(r.price)]), {"size": 11}))
			btns.add_child(_btn("SELL TO THE SHOP", "ghost", func():
				var r := Garage.sell_part(reg, career, o.partId)
				if not J.truthy(r.get("ok")): r.reason = "That part is not a spare."
				_market_done(r, func(x): return "Sold to the shop for %s." % money(x.refund)), {"size": 11}))
			rows.append(["[b]%s[/b]%s\n%s" % [Doc.esc(reg.part(o.partId).name), Doc.muted(" x%s" % J.s(o.count)) if o.count > 1 else "",
				Doc.muted(Doc.small("%s · the shop pays %s" % ["%s would pay %s" % [Doc.esc(o.team), money(o.price)] if J.truthy(o.get("price")) else "no team bidding today", money(o.resale)]))], "", btns])
		d.ledger(rows)

	d.sub("Sell %s" % rname(career.playerId))
	var ro := Market.robot_offer(reg, career)
	if ro.get("buyerId") == null: d.p(Doc.esc(J.g(ro, "reason", "")), {"tone": "muted"})
	else:
		d.p("%s (%s, %s) will buy your robot - parts, paint and name - and race it from next season in place of %s. You could meet it in the box." % [Doc.esc(ro.team), Doc.esc(ro.robot),
			Career.LEAGUE_TITLES.get(ro.league, ro.league), Doc.esc(ro.robot)], {"size": 13})
		rows = [["Its parts", "", Doc.pos(money(ro.parts))]]
		if J.truthy(ro.get("reputation")): rows.append(["Its record", "", Doc.pos(money(ro.reputation))])
		if J.truthy(ro.get("damage")): rows.append(["Less its damage", "", Doc.neg(money(-ro.damage))])
		rows.append(["[b]They pay[/b]", "", "[b]%s[/b]" % money(ro.price)])
		rows.append(["A stock kit to fight with (%s's parts%s)" % [Doc.esc(reg.robot(reg.playerId).name), "" if not (ro.kit.buy as Array).is_empty() else ", all from your spares"], "", Doc.neg(money(-ro.kit.cost))])
		rows.append(["[b]You end up with[/b]", "", "[b]%s[/b]" % Doc.cash(ro.net)])
		d.ledger(rows)
		if J.truthy(ro.get("ok")):
			var new_name := LineEdit.new()
			new_name.placeholder_text = "Name your new robot"
			new_name.max_length = 28
			new_name.custom_minimum_size.x = 240
			d.row([new_name, _btn("SELL IT", "ghost", func():
				UI.confirm(self, "Sell your robot? Its parts go with it, and you start again on a stock kit.", func():
					_market_done(Market.sell_robot(reg, career, new_name.text),
						func(r): return "%s bought it for %s. Meet %s, on a stock kit - the workshop is open." % [r.offer.team, money(r.offer.price), Garage.garage_of(reg, career).name])))])
		else: d.p(Doc.esc(J.g(ro, "reason", "")), {"tone": "muted", "size": 12})
	var sales: Array = career.get("robotSales", [])
	if not sales.is_empty():
		d.sub("Robots you have sold")
		d.ledger(sales.map(func(s): return ["[b]%s[/b] %s" % [Doc.esc(s.def.name), Doc.muted("v%s" % J.s(s.def.get("version", "")))],
			Doc.muted(Doc.small("to %s, season %s%s" % [Doc.esc(s.team), J.s(s.season),
				" · racing in %s" % Career.LEAGUE_TITLES.get(career.membership.get(s.get("newId")), "") if (s.get("status") == "fielded" and career.membership.has(s.get("newId"))) else (" · joins them next season" if s.get("status") == "pending" else " · retired")])),
			money(s.price)]))
