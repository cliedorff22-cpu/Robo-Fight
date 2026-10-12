## pit_screen.gd - the pit: between fights, choose what to fix.
##
## After every fight the robot comes back with whatever it took. The crew has
## the pit window (minutes until the next fight) times its size in
## crew-minutes; each damaged part can be left, patched, repaired or replaced,
## each with a price and a time. What is not fixed goes into the next fight -
## the panel on the left shows what the robot will be able to do. The rules
## are logic/pit.gd and career.gd; this only shows them.
class_name PitScreen
extends VBoxContainer

const HOW := [["", "Leave"], ["patch", "Patch"], ["repair", "Repair"], ["replace", "Replace"]]
const STATUS_NAMES := {"ok": "OK", "impaired": "worn", "critical": "critical", "failed": "destroyed"}

var cs: CareerScreen
var reg: Registry
var plan := {}
var note := ""

func _init(career_screen: CareerScreen) -> void:
	cs = career_screen
	reg = cs.reg
	add_theme_constant_override("separation", 0)
	plan = Career.pit_auto_plan(reg, cs.career)       # start from the crew's own plan
	_render()

static func money(n: float) -> String:
	return Market.money(n)

func _done() -> void:
	cs.menu.go("career")

func _render() -> void:
	UI.clear(self)
	var c: Dictionary = cs.career
	var st := Career.pit_state(reg, c)
	var q := Career.pit_quote(reg, c, plan)
	var damaged: Array = (st.report as Array).filter(func(r): return J.truthy(r.get("damaged")))
	var nf = null if J.truthy(c.get("seasonOver")) else Career.next_fight(reg, c)
	var g := Garage.garage_of(reg, c)
	var cfg := Career.crew_config(reg)
	var n := Career.crew_size(reg, c)
	var fee: float = cfg.hireFee[mini(cfg.hireFee.size() - 1, n - int(cfg.base))]
	add_child(cs.menu.bar("The pit", "", "CAREER", "career", [
		UI.label(("%s minutes until %s · crew of %d" % [J.s(st.window), "the next fight" if nf != null else "you are called", n]).to_upper(),
			{"kind": "cond", "size": 13, "weight": 500, "ls": 0.1, "color": UI.DIM}),
		UI.label(money(c.cash), {"kind": "mono", "size": 16, "weight": 700, "color": UI.ACCENT})]))

	# ---- left: the robot as it stands, damage showing, and what it can do.
	var left := Plate.new(16, 12)
	left.custom_minimum_size.x = 560
	var stage := cs.menu.stage({"angle": 0.75})
	stage.custom_minimum_size.y = 300
	stage.show_def(Garage.player_def(reg, c), [(g.get("condition", {}) as Dictionary).duplicate()])
	var lv := Doc.new(4)
	lv.add(stage)
	lv.add(UI.label(str(g.name).to_upper(), {"kind": "display", "size": 40, "weight": 600, "italic": true, "shadow": true}))
	lv.add(UI.label(("%d part%s damaged" % [damaged.size(), "s" if damaged.size() > 1 else ""] if not damaged.is_empty() else "Not a scratch on it").to_upper(),
		{"kind": "cond", "size": 14, "weight": 500, "ls": 0.12, "color": UI.DIM}))
	_effect(lv, st, q)
	left.add_child(lv)

	# ---- right: every damaged part and what to do about it.
	var rd := Doc.new(6)
	if damaged.is_empty(): rd.p("Nothing to fix. Send it out.", {"tone": "muted"})
	else:
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 10)
		var head := {"kind": "cond", "size": 13, "weight": 600, "ls": 0.12, "color": UI.DIM}
		for h in ["PART", "CONDITION", "WORK"]: grid.add_child(UI.label(h, head))
		for r in damaged: _row(grid, r)
		rd.add(grid)
	rd.gap(8)
	rd.p("[b]Pit crew: %d[/b]  %s" % [n, Doc.muted("(%s free%s)" % [J.s(cfg.base), ", %d on %s a season each" % [n - int(cfg.base), money(cfg.salaryPerSeason)] if n > cfg.base else ""])])
	rd.p("Each crew member adds %s crew-minutes to every pit stop." % J.s(st.window), {"tone": "muted", "size": 12})
	var hire := UI.button("CREW IS FULL" if n >= cfg.max else "HIRE ONE (%s + %s/SEASON)" % [money(fee), money(cfg.salaryPerSeason)], "ghost", {"size": 11})
	hire.disabled = n >= cfg.max
	hire.pressed.connect(func():
		var r := Career.hire_crew(reg, cs.career)
		note = "Signed a crew member for %s." % money(r.fee) if J.truthy(r.get("ok")) else str(J.g(r, "reason", ""))
		cs.save()
		_render())
	var release := UI.button("LET ONE GO", "ghost", {"size": 11})
	release.disabled = n <= cfg.base
	release.pressed.connect(func():
		Career.release_crew(reg, cs.career)
		cs.save()
		_render())
	rd.row([hire, release])
	var right := Plate.new(16, 12)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(UI.scroll(rd))
	var main := UI.hbox(14, [left, right])
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(UI.margin(main, 18, 12, 18, 10))

	# ---- foot: the time and the money, and the buttons.
	var over: bool = q.minutes > st.crewMinutes
	var meter := Meter.new(10, 260)
	meter.ease_rate = 0.0
	meter.set_colors(Color(Doc.NEG) if over else UI.OK, Color(Doc.NEG) if over else UI.ACCENT)
	meter.value = minf(1.0, q.minutes / maxf(1.0, st.crewMinutes))
	meter.size_flags_horizontal = Control.SIZE_FILL
	var foot := UI.hbox(16, [
		UI.vbox(2, [meter, UI.label("%s / %s crew-min" % [J.s(q.minutes), J.s(st.crewMinutes)], {"kind": "mono", "size": 13, "weight": 700})]),
		Doc.text("Work %s%s · [b]net %s[/b]" % [money(q.cost), " · salvage +%s" % money(q.salvage) if J.truthy(q.get("salvage")) else "", money(q.net)], {"kind": "mono", "size": 14, "bold_kind": "mono", "wrap": false}),
	])
	foot.add_child(UI.spacer(0, 0, true))
	var problems: Array = q.get("problems", [])
	if not problems.is_empty(): foot.add_child(UI.label(str(problems[0]), {"kind": "body", "size": 12, "weight": 400, "color": Color(Doc.NEG)}))
	elif note != "": foot.add_child(UI.label(note, {"kind": "body", "size": 12, "weight": 400}))
	var auto := UI.button("CREW'S PLAN", "ghost")
	auto.pressed.connect(func():
		plan = Career.pit_auto_plan(reg, cs.career)
		note = "The crew's plan: what stops it driving first, then the weapon, then armour."
		_render())
	var skip := UI.button("LEAVE IT ALL", "ghost")
	skip.pressed.connect(func():
		Career.skip_pit(cs.career)
		cs.save()
		_done())
	var go := UI.button("SEND IT OUT", "fight", {"small": true})
	go.disabled = not J.truthy(q.get("ok"))
	go.pressed.connect(func():
		var r := Career.do_pit(reg, cs.career, plan)
		if not J.truthy(r.get("ok")):
			note = str(r.errors[0])
			_render()
			return
		cs.save()
		_done())
	for b in [auto, skip, go]: foot.add_child(b)
	var fp := PanelContainer.new()
	fp.add_theme_stylebox_override("panel", UI.box(Color("1d2024"), {"pad": [22, 10]}))
	fp.add_child(foot)
	add_child(fp)

func _row(grid: GridContainer, r: Dictionary) -> void:
	var pct := int(round(r.condition * 100.0))
	var sub := Doc.muted(Doc.esc(r.key))
	if J.truthy(r.get("totaled")): sub += " · " + Doc.neg("totaled - replace it")
	elif J.truthy(r.get("replaceCheaper")): sub += " · " + Doc.pos("replacing is cheaper")
	var name_cell := Doc.text("%s%s\n%s" % [Doc.muted("%s: " % Doc.esc(r.unit)) if J.truthy(r.get("unit")) else "", Doc.esc(r.name), Doc.small(sub)], {"wrap": false})
	name_cell.custom_minimum_size.x = 250
	grid.add_child(name_cell)
	var col := UI.OK
	match r.status:
		"impaired": col = UI.WARN
		"critical": col = UI.BAD
		"failed": col = Color("555555")
	var bar := Meter.new(10, 110)
	bar.ease_rate = 0.0
	bar.set_colors(col, col)
	bar.value = r.condition
	grid.add_child(UI.vbox(2, [bar, UI.label("%d%% · %s" % [pct, STATUS_NAMES.get(r.status, r.status)], {"kind": "body", "size": 12, "weight": 400})]))
	var opts := UI.hbox(4)
	for h in HOW:
		var how: String = h[0]
		var o = {"cost": 0.0, "minutes": 0.0} if how == "" else (r.options as Dictionary).get(how)
		if o == null: continue
		var sub_text := "fight with it"
		if how == "replace": sub_text = "%s · %sm" % ["spare" if J.truthy(o.get("spare")) else money(o.cost), J.s(o.minutes)]
		elif how != "": sub_text = "%s · %sm" % [money(o.cost), J.s(o.minutes)]
		var b := UI.button("", "choice")
		b.custom_minimum_size = Vector2(104, 44)
		var v := UI.vbox(-3, [UI.label(str(h[1]).to_upper(), {"kind": "cond", "size": 14, "weight": 700, "ls": 0.06}), UI.label(sub_text, {"kind": "body", "size": 11, "weight": 400, "color": UI.DIM})])
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(UI.margin(v, 8, 3))
		b.button_pressed = plan.get(r.key, "") == how
		b.pressed.connect(func():
			plan = plan.duplicate()
			if how != "": plan[r.key] = how
			else: plan.erase(r.key)
			_render())
		opts.add_child(b)
	grid.add_child(opts)

# What the robot will be like in the next fight: as it is, and after this plan.
func _effect(d: Doc, st: Dictionary, q: Dictionary) -> void:
	var c: Dictionary = cs.career
	var as_is: Dictionary = st.assembled
	var after := Build.assemble_robot(reg, Garage.player_def(reg, c))
	after.condition.merge(q.get("condition", {}), true)
	var e0 := Condition.effective_stats(as_is, reg.rules)
	var e1 := Condition.effective_stats(after, reg.rules)
	var rated: Dictionary = as_is.stats
	var armour := func(a: Dictionary) -> int:
		var t := 0.0
		for f in a.fittings:
			if f.part.category == "armor": t += f.part.hp * J.g(a.condition, f.key, 1.0)
		return int(round(t))
	var pct := func(x: float, of_what: float) -> String:
		return "%d%%" % int(round(x / of_what * 100.0)) if of_what > 0.0 else "-"
	var rated_force: float = rated.forcePerWheelN * rated.drivenWheels
	var w_rated: float = J.g(rated.weapon, "energyJ", 0.0)
	var rows := [
		["", Doc.muted("as it is"), Doc.muted("after this work")],
		["Top speed", "%.1f mph" % U.mps_to_mph(e0.topSpeedMps), "[b]%.1f mph[/b]" % U.mps_to_mph(e1.topSpeedMps)],
		["Drive force", pct.call(e0.tractiveForceN, rated_force), "[b]%s[/b]" % pct.call(e1.tractiveForceN, rated_force)],
		["Weapon", pct.call(e0.weapon.energyJ, w_rated) if w_rated > 0.0 else "-", "[b]%s[/b]" % (pct.call(e1.weapon.energyJ, w_rated) if w_rated > 0.0 else "-")],
		["Armour", "%d hp" % armour.call(as_is), "[b]%d hp[/b]" % armour.call(after)],
	]
	d.sub("In the next fight")
	d.table(3, rows, {"right": [1, 2]})
	if J.truthy(e1.get("immobile")):
		var what := "drive"
		if J.truthy(e1.get("chassisGone")): what = "chassis"
		elif J.truthy(e1.get("electronicsGone")): what = "electronics"
		elif e1.get("wheelCount", 1) <= 0: what = "wheels"
		d.p("It cannot drive like this: the next fight is lost before it starts. Fix the %s." % what, {"tone": "neg", "size": 13})
	elif J.truthy(e1.weapon.get("dead")) and w_rated > 0.0:
		d.p("The weapon is dead for the next fight.", {"color": UI.WARN, "size": 13})
