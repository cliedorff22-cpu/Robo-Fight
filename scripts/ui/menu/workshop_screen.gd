## workshop_screen.gd - the workshop: build your robot part by part on a 3D
## turntable, paint it, and (if you want) ask the build advisor.
##
## Everything here is presentation. The rules are logic: workshop.gd says
## what fits a slot and what a swap does to the numbers, garage.gd prices it
## and fits it, advisor.gd advises. Nothing is bought until "Buy & fit":
## until then the robot on the turntable is a DRAFT, so trying things is free.
##
## Part snapping: every slot has a marker on the 3D robot, placed from the
## chassis' attach points (parts.json `attach`) and the body's own geometry.
## Click a marker (or the part itself) to choose what goes there; drag a part
## card onto the robot and it snaps into the slot it belongs in, dropping
## into place on the turntable.
class_name WorkshopScreen
extends VBoxContainer

const PERSONALITIES := [
	["aggressive", "Aggressive - presses all fight, barely resets"],
	["opportunistic", "Opportunistic - flanks, herds, punishes mistakes"],
	["defensive", "Defensive - waits for openings, keeps its distance"],
]
const TABS := [["parts", "Parts"], ["body", "Body & paint"], ["advisor", "Advisor"], ["spares", "Spares"]]
## Short labels on the 3D markers.
const HOT := {"weapon": "Weapon", "weaponMotor": "W.motor", "wheel": "Wheels", "drive": "Drive", "motor": "Motors", "battery": "Battery",
	"electronics": "ESC", "srimech": "Srimech", "chassis": "Chassis"}

var cs: CareerScreen
var reg: Registry
var draft = null                 # the design being edited
var selected := "weapon"         # slot key
var tab := "parts"
var advice = null                # the advisor's last answer
var brief := ""
## A multibot is edited one unit at a time: "main" or "partner".
var unit := "main"

var _stage: PreviewStage
var _hot_layer: Control
var _hotspots := []              # [{ key, partKey, p: Vector3, label, armour, empty, btn }]
var _hover_key := ""
var _stats: Doc
var _tabs: HBoxContainer
var _body: Doc
var _foot: VBoxContainer
var _cash: Label
var _drop_note: Label
var _paint_timer := 0.0
var _paint_due := ""             # "" | "all" | "robot"
var _built := false

func _init(career_screen: CareerScreen) -> void:
	cs = career_screen
	reg = cs.reg
	add_theme_constant_override("separation", 0)

func _career() -> Dictionary:
	return cs.career

static func money(n: float) -> String:
	return Market.money(n)

func _garage_design() -> Dictionary:
	var g := Garage.garage_of(reg, _career())
	return {"name": g.name, "body": (g.body as Dictionary).duplicate(true), "build": (g.build as Dictionary).duplicate(true),
		"livery": (g.get("livery", {}) as Dictionary).duplicate(true) if g.get("livery") is Dictionary else {}, "personality": g.get("personality"),
		"partner": (g.partner as Dictionary).duplicate(true) if g.get("partner") is Dictionary else null}

func _def() -> Dictionary:
	var d := Workshop.def_of(reg, draft)
	d.league = _career().membership[_career().playerId]
	if draft.get("partner") != null: d.partner = draft.partner
	else: d.erase("partner")
	return d

func _on_partner() -> bool:
	return unit == "partner" and draft.get("partner") != null

# The unit being edited: { build, body }.
func _ub() -> Dictionary:
	return draft.partner if _on_partner() else draft

func _set_unit(build: Dictionary, body: Dictionary) -> void:
	draft = draft.duplicate()
	if _on_partner():
		var p: Dictionary = (draft.partner as Dictionary).duplicate()
		p.build = build
		p.body = body
		draft.partner = p
	else:
		draft.build = build
		draft.body = body

# ---------------------------------------------------------------- screen

## Open on the robot as it stands in the garage.
func open() -> void:
	draft = _garage_design()
	advice = null
	selected = "weapon"
	tab = "parts"
	unit = "main"
	if not _built: _build()
	_refresh(true, ["all"])

func _build() -> void:
	_built = true
	var c := _career()
	_cash = UI.label(money(c.cash), {"kind": "mono", "size": 16, "weight": 700, "color": UI.ACCENT})
	add_child(cs.menu.bar("Workshop", "", "CAREER", "career", [
		UI.label(("%s · shop tier %d" % [c.team, Garage.shop_tier(reg, c)]).to_upper(), {"kind": "cond", "size": 13, "weight": 500, "ls": 0.1, "color": UI.DIM}), _cash]))
	# ---- the turntable, its markers, and the numbers under it
	var wrap := Plate.new(0, 0)
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_stretch_ratio = 1.25
	wrap.clip_contents = true
	var inner := Control.new()
	inner.clip_contents = true
	wrap.add_child(inner)
	# Still, turned by hand, starting three-quarters on.
	_stage = cs.menu.stage({"spin": false, "interactive": true, "angle": 0.75})
	_stage.on_pick = _pick_part
	_stage.on_frame = _place_hotspots
	inner.add_child(_stage)
	_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage.offset_bottom = -150
	_hot_layer = Control.new()
	_hot_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(_hot_layer)
	_hot_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var help := UI.label("Drag to turn · click a part or a marker to change it · drag a part card onto the robot to fit it", {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM})
	inner.add_child(help)
	UI.pin(help, Vector2(0.0, 0.0), Vector2(16, 10))
	_drop_note = UI.label("DROP TO FIT", {"kind": "display", "size": 44, "weight": 700, "italic": true, "color": UI.ACCENT, "shadow": true})
	_drop_note.visible = false
	inner.add_child(_drop_note)
	UI.pin(_drop_note, Vector2(0.5, 0.3))
	_stats = Doc.new(4)
	var stats_bg := PanelContainer.new()
	stats_bg.add_theme_stylebox_override("panel", UI.box(Color(0.05, 0.055, 0.07, 0.82), {"pad": [16, 10]}))
	stats_bg.add_child(_stats)
	inner.add_child(stats_bg)
	stats_bg.anchor_left = 0.0
	stats_bg.anchor_right = 1.0
	stats_bg.anchor_top = 1.0
	stats_bg.anchor_bottom = 1.0
	stats_bg.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# A part card dropped on the robot goes into the slot it belongs in.
	_stage.set_drag_forwarding(Callable(), func(_at: Vector2, data) -> bool:
		var ok: bool = data is Dictionary and data.has("part") and reg.has_part(data.part)
		_drop_note.visible = ok
		return ok,
		func(_at: Vector2, data) -> void:
			_drop_note.visible = false
			var key = _slot_for(data.part)
			if key != null:
				selected = key
				_fit(key, data.part))
	# ---- the side panel: tabs, their body, and the foot
	_tabs = UI.hbox(0)
	var tab_bar := PanelContainer.new()
	tab_bar.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.35), {"pad": [0, 0]}))
	tab_bar.add_child(_tabs)
	_body = Doc.new(6)
	_foot = UI.vbox(6)
	var foot_bg := PanelContainer.new()
	foot_bg.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.3), {"pad": [16, 10]}))
	foot_bg.add_child(_foot)
	var side := Plate.new(0, 0)
	side.bolts = false
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(UI.vbox(0, [tab_bar, UI.scroll(UI.margin(_body, 16, 12)), foot_bg]))
	var main := UI.hbox(14, [wrap, side])
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(UI.margin(main, 18, 12, 18, 16))

func _process(dt: float) -> void:
	if _drop_note != null and _drop_note.visible and not get_viewport().gui_is_dragging(): _drop_note.visible = false
	# Colour pickers and sliders fire on every drag step: repaint a beat after
	# the last one.
	if _paint_due == "": return
	_paint_timer -= dt
	if _paint_timer > 0.0: return
	var what := _paint_due
	_paint_due = ""
	if what == "all": _refresh()
	else:
		_stage.show_def(_def())
		_build_hotspots()
		_foot_html()

func _repaint_soon(what: String) -> void:
	_paint_due = "all" if (what == "all" or _paint_due == "all") else "robot"
	_paint_timer = 0.14

# Redraw everything that depends on the draft; re-show the robot if it changed.
func _refresh(robot := true, snap = null) -> void:
	if robot:
		_stage.show_def(_def())
		if snap != null: _stage.snap(snap)
		_build_hotspots()
	_cash.text = money(_career().cash)
	# Settings -> Build advisor off hides it.
	var tabs := TABS.filter(func(t): return t[0] != "advisor" or J.truthy(Game.settings.get("advisor", true)))
	if not tabs.any(func(t): return t[0] == tab): tab = "parts"
	UI.clear(_tabs)
	for t in tabs:
		var b := UI.button(str(t[1]).to_upper(), "tab")
		b.button_pressed = tab == t[0]
		b.pressed.connect(func():
			tab = t[0]
			_refresh(false))
		_tabs.add_child(b)
	_stats_html()
	_body_html()
	_foot_html()

# ---------------------------------------------------------------- 3D markers

static func _centroid(pts: Array) -> Vector3:
	var c := Vector3.ZERO
	for p in pts: c += p
	return c / maxf(1.0, pts.size())

# Where an empty armour slot would be, for its marker.
static func _face_guess(face, index, dims: Dictionary) -> Vector3:
	var L: float = dims.lengthM / 2.0
	var H: float = dims.heightM / 2.0
	var W: float = dims.widthM / 2.0
	match face:
		"front": return Vector3(L, 0, 0)
		"rear": return Vector3(-L, 0, 0)
		"top": return Vector3(0, H, 0)
	return Vector3(0, 0, -W if J.truthy(index) else W)

# The fitting index ("armor.N") of the panel in an armour slot, or -1.
func _armour_index(slot_key: String) -> int:
	for s in Workshop.slots_of(reg, draft.build):
		if s.key == slot_key: return int(J.g(s, "fitIndex", -1))
	return -1

func _slot_label(key: String) -> String:
	for s in Workshop.slots_of(reg, _ub().build):
		if s.key == key: return str(s.label)
	return str(Workshop.SLOT_NAMES.get(key, key))

# Where each slot is on the robot, in its own frame.
func _build_hotspots() -> void:
	for h in _hotspots:
		if is_instance_valid(h.btn): h.btn.queue_free()
	_hotspots = []
	var def := _def()
	if not Build.can_assemble(reg, def): return
	var a := Build.assemble_robot(reg, def)
	var shape := Shape.build_shape(a)
	var attach := {}
	for x in a.parts.chassis.spec.get("attach", []): attach[x.id] = x
	var at := func(id: String):
		if not attach.has(id): return null
		var p: Array = attach[id].posIn
		return Vector3(U.in_to_m(p[0]), U.in_to_m(p[1]), U.in_to_m(p[2]))
	# The body's own top (not the weapon's - a disc stands well above it).
	var top := -INF
	for pc in shape.pieces:
		var id: String = pc.id
		if id == "core" or id.begins_with("body:") or id.begins_with("cheek") or id.begins_with("plate:top"):
			for q in pc.points: top = maxf(top, q.y)
	if top == -INF: top = a.dims.heightM / 2.0
	var wv = J.path(shape, ["weapon", "visual"])
	var wp = null
	if wv is Dictionary:
		if wv.get("center") is Vector3: wp = wv.center
		elif wv.get("pivot") is Vector3: wp = Vector3(wv.pivot.x + wv.reach, wv.pivot.y, 0)
	if J.truthy(draft.build.get("weapon")):
		if wp == null: wp = at.call("weapon_front")
		if wp == null: wp = Vector3(a.dims.lengthM / 2.0, 0, 0)
		_hotspots.append({"key": "weapon", "partKey": "weapon", "p": wp})
	# The weapon's motor, where its can (or its belt) shows on the robot.
	var motor_at = _drive_point(a)
	if motor_at != null and J.truthy(draft.build.get("weaponMotor")): _hotspots.append({"key": "weaponMotor", "partKey": "weaponMotor", "p": motor_at})
	var wheels: Array = WheelModel.wheel_layout(a).wheels
	var w0 = null
	for w in wheels:
		if w.anchor.z > 0 and w.anchor.x > 0: w0 = w
	if w0 == null and not wheels.is_empty(): w0 = wheels[0]
	if w0 != null: _hotspots.append({"key": "wheel", "partKey": "wheel", "p": Vector3(w0.anchor.x, w0.anchor.y - a.stats.wheelRadiusM * 0.3, w0.anchor.z + 0.03)})
	# The insides (drive, motors, battery, ESC) share one marker over the
	# power bay - the slot list has each of them; the self-righter its bay.
	var power = at.call("power_bay")
	if power == null: power = at.call("drive_bay")
	if power != null: _hotspots.append({"key": "motor", "label": "Internals", "partKey": "chassis", "p": Vector3(power.x, top + 0.02, power.z)})
	var sr = at.call("srimech_bay")
	if sr != null: _hotspots.append({"key": "srimech", "partKey": "chassis", "p": Vector3(sr.x - 0.06, top + 0.03, -a.dims.widthM * 0.25)})
	_hotspots.append({"key": "chassis", "partKey": "chassis", "p": Vector3(-a.dims.lengthM * 0.45, top * 0.5, a.dims.widthM * 0.3)})
	# Armour: the middle of each fitted panel's pieces.
	var routes := Shape.route_fittings(shape, a)
	for s in Workshop.slots_of(reg, draft.build):
		if s.category != "armor": continue
		var idx := _armour_index(s.key)
		var key := "armor.%d" % idx if idx >= 0 else ""
		var pts := []
		if key != "":
			for pc in shape.pieces:
				if routes.get(pc.id) == key: pts.append_array(pc.points)
		_hotspots.append({"key": s.key, "partKey": key, "p": _centroid(pts) if not pts.is_empty() else _face_guess(s.get("face"), s.get("index"), a.dims),
			"armour": true, "empty": not J.truthy(s.get("partId"))})
	for h in _hotspots:
		var label: String = h.get("label", "")
		if label == "": label = _slot_label(h.key).replace(" armour", "") if h.get("armour", false) else str(HOT.get(h.key, h.key))
		var b := Button.new()
		b.text = label.to_upper()
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = _slot_label(h.key)
		UI.style(b, {"kind": "cond", "size": 11, "weight": 700, "ls": 0.08})
		b.pressed.connect(func():
			unit = "main"
			_select_slot(h.key))
		b.mouse_entered.connect(func(): _stage.highlight(h.partKey))
		b.mouse_exited.connect(func(): _stage.highlight(_hover_key))
		_hot_layer.add_child(b)
		h.btn = b
	_style_hotspots()

# Where the weapon's drive is drawn on this build (render/dress.gd), or null.
func _drive_point(a: Dictionary):
	if not Dress.on or Parts.mobile: return null
	for item in Dress.plan(a, RobotRig.at_rest(a)).items:
		if not str(item.id).begins_with("drive"): continue
		# The motor itself is the first thing in it (the belt comes after).
		var pts := Kit.points_of((item.parts as Array).slice(0, 3))
		if pts.is_empty(): continue
		var box := AABB(pts[0], Vector3.ZERO)
		for q in pts: box = box.expand(q)
		return box.get_center() + Vector3(0, box.size.y * 0.5 + 0.03, 0)
	return null

func _style_hotspots() -> void:
	for h in _hotspots:
		var b: Button = h.btn
		var on: bool = h.key == selected
		var empty: bool = h.get("empty", false)
		var bg := UI.ACCENT if on else (Color(0.06, 0.07, 0.09, 0.82))
		b.add_theme_stylebox_override("normal", UI.box(bg, {"border": UI.ACCENT if not empty else Color(1, 1, 1, 0.35), "pad": [6, 1]}))
		b.add_theme_stylebox_override("hover", UI.box(UI.ACCENT, {"pad": [6, 1]}))
		b.add_theme_stylebox_override("pressed", UI.box(UI.ACCENT, {"pad": [6, 1]}))
		b.add_theme_color_override("font_color", UI.INK if on else (UI.TEXT if not empty else UI.DIM))
		b.add_theme_color_override("font_hover_color", UI.INK)

func _place_hotspots() -> void:
	for h in _hotspots:
		var b: Button = h.btn
		if not is_instance_valid(b): continue
		var q = _stage.project(h.p)
		if q == null: continue
		b.position = (q.pos as Vector2) + _stage.position - b.size / 2.0
		b.modulate.a = 1.0 if q.front else 0.35

# A click on the robot itself: find the slot that part fills.
func _pick_part(part_key: String) -> void:
	if part_key == "": return
	unit = "main"                # the markers and the picking are the main robot's
	if part_key == "weapon" or part_key == "wheel" or part_key == "weaponMotor":
		_select_slot(part_key)
		return
	if part_key.begins_with("armor."):
		var n := int(part_key.substr(6))
		for s in Workshop.slots_of(reg, draft.build):
			if s.category == "armor" and _armour_index(s.key) == n:
				_select_slot(s.key)
				return
	_select_slot("chassis")

func _select_slot(key: String) -> void:
	selected = key
	tab = "parts"
	_hover_key = ""
	for h in _hotspots:
		if h.key == key: _hover_key = h.partKey
	_stage.highlight(_hover_key)
	_style_hotspots()
	_refresh(false)

# ---------------------------------------------------------------- fitting parts

# Put a part in a slot of the draft and drop it into place on the robot.
func _fit(key: String, part_id) -> void:
	var u := _ub()
	var build := Workshop.set_slot(reg, u.build, key, part_id)
	_set_unit(build, Workshop.fit_body(reg, u.body, build))
	# The second unit has no markers of its own: the whole robot drops in.
	var snap_key := "chassis"
	if _on_partner() or key == "chassis": snap_key = "all"
	elif key == "weapon" or key == "wheel": snap_key = key
	elif key == "weaponMotor" and _drive_point(Build.assemble_robot(reg, _def())) != null: snap_key = key
	elif key.begins_with("armor:"): snap_key = "armor.%d" % maxi(0, _armour_index(key))
	_refresh(true, [snap_key])
	_hover_key = "" if snap_key == "all" else snap_key
	_stage.highlight(_hover_key)

# A part card dropped on the robot: the slot it belongs in.
func _slot_for(part_id):
	var p: Dictionary = reg.part(part_id)
	if p.category != "armor": return p.category
	var faces := Workshop.slots_of(reg, _ub().build).filter(func(s): return s.category == "armor" and s.get("face") == p.spec.get("slot"))
	for s in faces:
		if s.key == selected: return s.key
	for s in faces:
		if not J.truthy(s.get("partId")): return s.key
	return faces[0].key if not faces.is_empty() else null

# ---------------------------------------------------------------- panels

static func _stat(k: String, v: String) -> Control:
	return UI.hbox(5, [UI.label(k.to_upper(), {"kind": "cond", "size": 12, "weight": 600, "ls": 0.08, "color": UI.DIM}), UI.label(v, {"kind": "mono", "size": 13, "weight": 700})])

func _partner_summary():
	if draft.get("partner") == null: return null
	return Workshop.summarize(reg, Workshop.def_of(reg, {"build": draft.partner.build, "body": draft.partner.body}))

func _stats_html() -> void:
	UI.clear(_stats)
	var s = Workshop.summarize(reg, _def())
	if s == null:
		_stats.p("This design does not go together.", {"tone": "neg"})
		return
	var ps = _partner_summary()
	var weight: float = s.weightLb
	var errors: Array = (s.errors as Array).duplicate()
	if ps != null:
		# A multibot's units share the weight limit.
		weight = J.rnd((s.weightLb + ps.weightLb) * 10.0) / 10.0
		for e in ps.errors: errors.append("%s: %s" % [draft.partner.name, e])
		if weight > s.capLb: errors.append("Multibot overweight: %s lb." % J.s(weight))
	var over: bool = weight > s.capLb
	var bar := Meter.new(10, 200)
	bar.ease_rate = 0.0
	bar.set_colors(Color(Doc.NEG) if over else UI.OK, Color(Doc.NEG) if over else UI.ACCENT)
	bar.value = minf(1.0, weight / s.capLb)
	_stats.row([bar, Doc.text("[b]%s[/b] / %s lb  %s" % [J.s(weight), J.s(s.capLb), Doc.neg("%.1f over" % (weight - s.capLb)) if over else Doc.muted("%s spare" % J.s(J.rnd((s.capLb - weight) * 10.0) / 10.0))],
		{"kind": "mono", "bold_kind": "mono", "size": 14, "wrap": false})], 12)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16)
	flow.add_child(_stat("Speed", "%s mph" % J.s(s.topSpeedMph)))
	flow.add_child(_stat("Push", "%sx" % J.s(s.pushRatio)))
	flow.add_child(_stat("Turn", "%sx" % (J.s(s.pivot) if is_finite(s.pivot) else "∞")))
	flow.add_child(_stat("Armour", "%s hp" % J.s(s.armourHp)))
	if J.truthy(s.get("energyKJ")): flow.add_child(_stat("Weapon", "%s kJ" % J.s(s.energyKJ)))
	if s.get("spinUpS") != null and J.truthy(s.spinUpS): flow.add_child(_stat("Spin-up", "%s s" % J.s(s.spinUpS)))
	flow.add_child(_stat("Clearance", "%s\"" % J.s(s.clearanceIn)))
	_stats.add(flow)
	if ps != null:
		var pf := HFlowContainer.new()
		pf.add_theme_constant_override("h_separation", 16)
		pf.add_child(_stat(str(draft.partner.name), "%s lb" % J.s(ps.weightLb)))
		pf.add_child(_stat("Speed", "%s mph" % J.s(ps.topSpeedMph)))
		pf.add_child(_stat("Push", "%sx" % J.s(ps.pushRatio)))
		pf.add_child(_stat("Weapon", str(ps.weaponName)))
		_stats.add(pf)
	var chips := UI.hbox(6)
	var first := "Runs inverted" if J.truthy(s.get("invertible")) else ("Self-rights (%s)" % s.selfRight if s.selfRight != "none" else "Can't self-right")
	for c in [first, str(Catalog.WEAPON_NAMES.get(s.weaponClass, s.weaponClass))] + (["Multibot"] if ps != null else []):
		var chip := UI.button(str(c).to_upper(), "chip")
		chip.disabled = true
		chips.add_child(chip)
	_stats.add(chips)
	for e in errors: _stats.p(Doc.esc(e), {"tone": "neg", "size": 13})
	for w in (s.warnings as Array).slice(0, 2): _stats.p(Doc.esc(w), {"color": UI.WARN, "size": 13})

func _body_html() -> void:
	UI.clear(_body)
	match tab:
		"parts": _parts_html()
		"body": _paint_html()
		"advisor": _advisor_html()
		_: _spares_html()

# The multibot switch, and which unit the parts list is for.
func _multibot_html() -> void:
	if draft.get("partner") == null:
		var b := UI.button("MAKE IT A MULTIBOT (ADD A SECOND UNIT)", "ghost", {"size": 11})
		b.pressed.connect(func(): _set_multibot(true))
		_body.row([UI.label("One robot.", {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM}), b])
		return
	var row := UI.hbox(4)
	for u in [["main", str(draft.name)], ["partner", str(draft.partner.name)]]:
		var b := UI.button(str(u[1]).to_upper(), "choice")
		b.button_pressed = unit == u[0]
		b.pressed.connect(func():
			unit = "partner" if (u[0] == "partner" and draft.get("partner") != null) else "main"
			selected = "weapon"
			_refresh(false))
		row.add_child(b)
	var off := UI.button("BACK TO ONE ROBOT", "ghost", {"size": 11})
	off.pressed.connect(func(): _set_multibot(false))
	row.add_child(UI.spacer(8, 0))
	row.add_child(off)
	_body.add(row)

# Make it a multibot (a second unit, a minibot wedge to start) or back to one robot.
func _set_multibot(on: bool) -> void:
	draft = draft.duplicate()
	if on:
		var g := Garage.garage_of(reg, _career())
		var src = draft.get("partner")
		if src == null: src = g.get("partner")
		if src == null: src = Garage.DEFAULT_PARTNER
		draft.partner = (src as Dictionary).duplicate(true)
	else: draft.partner = null
	unit = "partner" if on else "main"
	selected = "weapon"
	_refresh(true, ["all"])

func _spec_line(p: Dictionary) -> String:
	var s: Dictionary = p.spec
	match p.category:
		"weapon":
			if s.get("class") == "static": return " · wedge"
			return " · %s%s" % [Catalog.WEAPON_NAMES.get(s.get("class"), s.get("class")), " %s\"" % J.s(s.radiusIn * 2) if J.truthy(s.get("radiusIn")) else ""]
		"armor": return " · %s %s\" · %s hp" % [str(s.get("material", "")).replace("_", " "), J.s(s.get("thicknessIn", "")), J.s(p.hp)]
		"weaponMotor": return " · %.1f kW" % (s.powerW / 1000.0)
		"motor": return " · %s motors" % J.s(s.count)
		"chassis": return " · %s\"" % "x".join((s.sizeIn as Array).map(func(v): return J.s(v)))
		"wheel": return " · %s\" x%s" % [J.s(s.get("diameterIn", "")), J.s(s.count)]
	return ""

static func _delta_chip(k: String, v, good: bool) -> String:
	if v == null or not J.truthy(v): return ""
	var up: bool = (v > 0) == good
	return "[color=%s]%s%s %s[/color]  " % [Doc.POS if up else Doc.NEG, "+" if v > 0 else "", J.s(J.rnd(v * 10.0) / 10.0), k]

func _parts_html() -> void:
	var u := _ub()
	var slots := Workshop.slots_of(reg, u.build)
	var g := Garage.garage_of(reg, _career())
	var garage_build = J.path(g, ["partner", "build"]) if _on_partner() else g.build
	var was := {}
	if garage_build is Dictionary:
		for s in Workshop.slots_of(reg, garage_build): was[s.key] = s.get("partId")
	if not slots.any(func(s): return s.key == selected): selected = "weapon"
	var slot: Dictionary = slots[0]
	for s in slots:
		if s.key == selected: slot = s
	_multibot_html()
	# Every slot, and what is in it.
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for s in slots:
		var b := UI.button("", "choice")
		b.custom_minimum_size = Vector2(176, 42)
		var changed: bool = s.get("partId") != was.get(s.key)
		var part_name: String = str(reg.part(s.partId).name) if J.truthy(s.get("partId")) else "empty"
		var v := UI.vbox(-3, [
			UI.label(str(s.label).to_upper() + (" •" if changed else ""), {"kind": "cond", "size": 12, "weight": 700, "ls": 0.12, "color": UI.HOT}),
			UI.label(part_name, {"kind": "cond", "size": 14, "weight": 500, "clip": true, "color": UI.TEXT if J.truthy(s.get("partId")) else UI.DIM})])
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.custom_minimum_size.x = 160
		b.add_child(UI.margin(v, 8, 3))
		b.button_pressed = s.key == selected
		b.pressed.connect(func(): _select_slot(s.key))
		flow.add_child(b)
	_body.add(flow)
	_body.sub("%s - pick one, or drag it onto the robot" % slot.label)
	if J.truthy(slot.get("optional")) and J.truthy(slot.get("partId")):
		var none := UI.button("LEAVE IT EMPTY", "ghost", {"size": 12})
		none.pressed.connect(func(): _fit(slot.key, null))
		_body.row([none])
	for x in Workshop.candidates(reg, _career(), u, selected, _on_partner()):
		var part: Dictionary = x.part
		var fitted: bool = J.truthy(x.get("fitted"))
		var locked: bool = J.truthy(x.get("locked"))
		var legal: bool = J.truthy(x.get("legal"))
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UI.box(Color(1, 0.78, 0.12, 0.12) if fitted else Color(1, 1, 1, 0.04), {"border": UI.ACCENT if fitted else UI.LINE, "pad": [12, 6]}))
		card.modulate.a = 0.5 if locked else 1.0
		var price := ""
		if J.truthy(x.get("owned")): price = Doc.pos("[b]owned%s[/b]" % (" x%s" % J.s(x.owned) if x.owned > 1 else ""))
		elif locked: price = Doc.neg(Doc.esc(J.g(x, "reason", "")))
		else: price = money(x.price)
		var deltas := ""
		if fitted: deltas = Doc.muted("fitted")
		elif x.get("delta") is Dictionary:
			var dl: Dictionary = x.delta
			deltas = _delta_chip("lb", dl.get("weightLb"), false) + _delta_chip("mph", dl.get("topSpeedMph"), true) + _delta_chip("push", dl.get("pushRatio"), true) + \
				_delta_chip("kJ", dl.get("energyKJ"), true) + _delta_chip("hp", dl.get("armourHp"), true)
		if not legal and x.get("after") is Dictionary:
			var errs: Array = x.after.get("errors", [])
			deltas += Doc.neg(Doc.esc(errs[0] if not errs.is_empty() else "illegal"))
		var text := Doc.text("%s  %s\n%s\n%s" % [Doc.esc(part.name), Doc.muted(Doc.small("T%s" % J.s(part.get("tier", 1)))),
			Doc.small("%s lb · %s%s" % [J.s(part.weight), price, Doc.muted(Doc.esc(_spec_line(part)))]), Doc.small(deltas)])
		card.add_child(text)
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		if not locked:
			card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			card.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT and not get_viewport().gui_is_dragging(): _fit(slot.key, part.id))
			card.set_drag_forwarding(func(_at: Vector2):
				var ghost := UI.label(str(part.name), {"kind": "cond", "size": 15, "weight": 700, "color": UI.ACCENT, "shadow": true})
				card.set_drag_preview(ghost)
				return {"part": part.id}, Callable(), Callable())
		_body.add(card)

func _field(label: String, control: Control) -> void:
	_body.add(UI.vbox(2, [UI.label(label, {"kind": "cond", "size": 13, "weight": 600, "color": UI.DIM}), control]))

func _select(options: Array, current, changed: Callable, enabled := true) -> OptionButton:
	var ob := OptionButton.new()
	for i in options.size():
		ob.add_item(str(options[i][1]))
		if options[i][0] == current: ob.select(i)
	ob.disabled = not enabled
	ob.item_selected.connect(func(i: int): changed.call(options[i][0]))
	return ob

func _set_draft(key: String, value) -> void:
	draft = draft.duplicate()
	draft[key] = value

func _set_partner(key: String, value) -> void:
	var p: Dictionary = (draft.partner as Dictionary).duplicate()
	p[key] = value
	_set_draft("partner", p)

# How the robot is put together - looks only (render/dress.gd reads them from
# body.look). Anything left on "Builder's pick" is chosen for the robot.
const LOOK_AUTO := ["", "Builder's pick"]
const LOOK_MATS := [["", "Builder's pick"], ["steel", "Bare steel"], ["hub", "Aluminium"], ["dark", "Black"], ["anod", "Anodised"],
	["accent", "Accent colour"], ["trim", "Trim colour"], ["primary", "Main colour"]]
const LOOK_KIT := [["handle", "lifting handle"], ["sink", "heat sink"], ["aerial", "aerial"], ["box", "junction box"]]

func _set_look(key: String, value) -> void:
	var body: Dictionary = (draft.body as Dictionary).duplicate()
	var look: Dictionary = (body.look as Dictionary).duplicate() if body.get("look") is Dictionary else {}
	if value == null or (value is String and value == ""): look.erase(key)
	else: look[key] = value
	if look.is_empty(): body.erase("look")
	else: body.look = look
	_set_draft("body", body)
	_refresh(true, ["chassis"])

func _look_field(label: String, key: String, options: Array) -> Control:
	var look: Dictionary = draft.body.look if draft.body.get("look") is Dictionary else {}
	var all := [LOOK_AUTO]
	all.append_array(options)
	return UI.vbox(2, [UI.label(label, {"kind": "cond", "size": 13, "weight": 600, "color": UI.DIM}),
		_select(all, str(look.get(key, "")), func(v): _set_look(key, v))])

func _build_html(extras: Dictionary) -> void:
	_body.sub("Build")
	if not Dress.on:
		_body.p("Robot hardware is switched off in Settings, so none of this shows.", {"tone": "muted", "size": 12})
		return
	var look: Dictionary = draft.body.look if draft.body.get("look") is Dictionary else {}
	var mats := LOOK_MATS.slice(1)
	_body.row([_look_field("Frame", "frame", [["rails", "Machined rails"], ["tube", "Tube"], ["none", "None"]]), _look_field("made of", "frameMat", mats)], 12)
	if not extras.has("wheelGuards"):
		_body.row([_look_field("Side armour", "skirts", [["plate", "Plates"], ["bar", "Tube rails"], ["none", "None"]]), _look_field("made of", "skirtMat", mats)], 12)
	if extras.has("forks"):
		_body.row([_look_field("Forks", "forks", [["blade", "Blades"], ["twin", "Twin blades"], ["saw", "Saw-backed"], ["shoe", "Wedgelets"]]), _look_field("made of", "forkMat", mats)], 12)
	# What the weapon is, as it is drawn.
	var def := _def()
	var wv = null
	if Build.can_assemble(reg, def): wv = J.path(Shape.build_shape(Build.assemble_robot(reg, def)), ["weapon", "visual"])
	if wv is Dictionary and wv.get("kind") == "rotor" and wv.get("style") != "shell":
		var style := str(wv.get("style"))
		if style == "disc": _body.row([_look_field("Disc", "disc", [["holes", "Lightening holes"], ["spokes", "Spoked"], ["cam", "Single tooth"], ["saw", "Saw ring"], ["plain", "Solid"]])], 12)
		elif style == "drum": _body.row([_look_field("Drum", "drum", [["teeth", "Teeth"], ["bars", "Impactor bars"], ["discs", "Stacked discs"]]),
			_look_field("made of", "drumMat", [["steel", "Bare steel"], ["brass", "Brass"], ["copper", "Copper"], ["dark", "Black"], ["anod", "Anodised"]])], 12)
		elif style == "bar" and wv.get("axis") == "y": _body.row([_look_field("Bar", "bar", [["hook", "Hooked"], ["slab", "Slab"], ["taper", "Tapered"]])], 12)
		if wv.get("axis") == "z":
			_body.row([_look_field("Weapon drive", "drive", [["deck", "Motor on the deck"], ["inboard", "Motor inside"], ["none", "Hidden"]]),
				_look_field("Belts", "belts", [["1", "One"], ["2", "Two"]])], 12)
		else:
			_body.row([_look_field("Weapon drive", "drive", [["can", "Motor on the hub"], ["engine", "Engine"], ["none", "Hidden"]])], 12)
		_body.row([_look_field("Weapon carriers", "supports", [["truss", "Truss-cut"], ["plate", "Plate"], ["solid", "Solid"]]), _look_field("made of", "supportMat", mats)], 12)
	elif wv is Dictionary and wv.get("kind") == "arm":
		_body.row([_look_field("Pivot tower", "supportMat", mats)], 12)
	# The colour of anodised parts and motor cans.
	var cp := ColorPickerButton.new()
	cp.color = CanvasRec.css(str(look.get("anod", J.g(draft.get("livery") if draft.get("livery") is Dictionary else {}, "accent", "#f0c419"))))
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(64, 30)
	# Deferred: _set_look redraws this tab, and the picker must not leave the
	# tree while the engine is still closing its popup (that crashes Godot).
	cp.popup_closed.connect(func(): _set_look.call_deferred("anod", "#" + cp.color.to_html(false)))
	var auto := UI.button("AUTO", "ghost", {"size": 11})
	auto.tooltip_text = "Use the accent colour"
	auto.disabled = not look.has("anod")
	auto.pressed.connect(func(): _set_look("anod", null))
	_body.row([UI.vbox(2, [UI.label("Anodising and motor cans", {"kind": "cond", "size": 13, "weight": 600, "color": UI.DIM}), cp]), auto], 12)
	# What is bolted to the deck.
	var kit = look.get("kit")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	for k in LOOK_KIT:
		var cb := CheckBox.new()
		cb.text = k[1]
		cb.button_pressed = kit is Array and (kit as Array).has(k[0])
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_override("font", UI.font("cond", 500))
		cb.toggled.connect(func(on: bool):
			var now: Array = (kit as Array).filter(func(x): return x != k[0]) if kit is Array else []
			if on: now.append(k[0])
			_set_look("kit", now))
		flow.add_child(cb)
	_body.add(flow)
	_body.p("On the deck. Until you tick one, the builder picks a couple for you. All of this is looks only - it changes nothing in a fight." if not (kit is Array) else "On the deck. All of this is looks only - it changes nothing in a fight.", {"tone": "muted", "size": 12})

func _set_livery(key: String, value) -> void:
	var lv: Dictionary = (draft.get("livery", {}) as Dictionary).duplicate() if draft.get("livery") is Dictionary else {}
	if value == null: lv.erase(key)
	else: lv[key] = value
	_set_draft("livery", lv)

func _paint_html() -> void:
	var templates := Workshop.TEMPLATES.map(func(t): return [t, Workshop.TEMPLATE_NAMES.get(t, t)])
	if _on_partner():
		var p: Dictionary = draft.partner
		var pm := Workshop.mounts_for(reg, p.build)
		_multibot_html()
		var pname := LineEdit.new()
		pname.text = str(p.name)
		pname.max_length = 28
		pname.text_submitted.connect(func(t: String):
			_set_partner("name", t.strip_edges().substr(0, 28) if t.strip_edges() != "" else "Minibot")
			_refresh(false))
		pname.focus_exited.connect(func():
			if draft.get("partner") != null and pname.text != str(draft.partner.name):
				_set_partner("name", pname.text.strip_edges().substr(0, 28) if pname.text.strip_edges() != "" else "Minibot")
				_foot_html())
		_field("Second unit's name", pname)
		_field("Shape", _select(templates, p.body.get("template"), func(v):
			var body: Dictionary = (draft.partner.body as Dictionary).duplicate()
			body.template = v
			_set_partner("body", Workshop.fit_body(reg, body, draft.partner.build))
			_refresh(true, ["all"])))
		_field("Weapon mount", _select(pm.map(func(m): return [m, Workshop.MOUNT_NAMES.get(m, m)]), p.body.get("mount"), func(v):
			var body: Dictionary = (draft.partner.body as Dictionary).duplicate()
			body.mount = v
			_set_partner("body", Workshop.fit_body(reg, body, draft.partner.build))
			_refresh(true, ["all"]), pm.size() >= 2))
		_body.p("It wears the main robot's paint, and an AI driver drives it beside you.", {"tone": "muted", "size": 12})
		return
	var lv: Dictionary = draft.get("livery", {}) if draft.get("livery") is Dictionary else {}
	var mounts := Workshop.mounts_for(reg, draft.build)
	var extras := {}
	for e in draft.body.get("extras", []): extras[e.type] = true
	if draft.get("partner") != null: _multibot_html()
	var name_edit := LineEdit.new()
	name_edit.text = str(draft.name)
	name_edit.max_length = 28
	name_edit.text_changed.connect(func(t: String):
		_set_draft("name", t)
		_foot_html())
	name_edit.focus_exited.connect(func(): _repaint_soon("robot"))
	_field("Name", name_edit)
	_field("Driver (your AI, and the arena when you press Tab)", _select(PERSONALITIES, draft.get("personality"), func(v):
		_set_draft("personality", v)
		_foot_html()))
	_body.sub("Body")
	_field("Shape", _select(templates, draft.body.get("template"), func(v):
		var body: Dictionary = (draft.body as Dictionary).duplicate()
		body.template = v
		_set_draft("body", Workshop.fit_body(reg, body, draft.build))
		_refresh(true, ["all"])))
	_field("Weapon mount", _select(mounts.map(func(m): return [m, Workshop.MOUNT_NAMES.get(m, m)]), draft.body.get("mount"), func(v):
		var body: Dictionary = (draft.body as Dictionary).duplicate()
		body.mount = v
		_set_draft("body", Workshop.fit_body(reg, body, draft.build))
		_refresh(true, ["weapon"]), mounts.size() >= 2))
	var ex := HFlowContainer.new()
	ex.add_theme_constant_override("h_separation", 10)
	for x in Workshop.EXTRAS:
		var cb := CheckBox.new()
		cb.text = "wheel guards" if x == "wheelGuards" else x
		cb.button_pressed = extras.has(x)
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_override("font", UI.font("cond", 500))
		cb.toggled.connect(func(on: bool):
			var keep: Array = (draft.body.get("extras", []) as Array).filter(func(e): return e.type != x)
			if on: keep.append({"type": x})
			var body: Dictionary = (draft.body as Dictionary).duplicate()
			body.extras = keep
			_set_draft("body", body)
			_refresh(true, ["chassis"]))
		ex.add_child(cb)
	_body.add(ex)
	_body.p("Forks and a plow are real: a horizontal spinner that hits them glances off.", {"tone": "muted", "size": 12})
	_build_html(extras)
	_body.sub("Paint")
	var colors := UI.hbox(14)
	for spec in [["Main", "primary", "#b8babf"], ["Trim", "secondary", "#202227"], ["Accent", "accent", "#f0c419"]]:
		var cp := ColorPickerButton.new()
		cp.color = CanvasRec.css(J.g(lv, spec[1], spec[2]))
		cp.edit_alpha = false
		cp.custom_minimum_size = Vector2(64, 30)
		cp.color_changed.connect(func(col: Color):
			_set_livery(spec[1], "#" + col.to_html(false))
			_repaint_soon("robot"))
		cp.popup_closed.connect(func(): _foot_html())
		colors.add_child(UI.vbox(2, [UI.label(spec[0], {"kind": "cond", "size": 13, "weight": 600, "color": UI.DIM}), cp]))
	_body.add(colors)
	_field("Pattern", _select(Livery.PATTERNS.map(func(p): return [p, p]), J.g(lv, "pattern", ""), func(v):
		_set_livery("pattern", v)
		_refresh()))
	_body.sub("Name on the robot")
	var tc := ColorPickerButton.new()
	tc.color = CanvasRec.css(Livery.name_colour(lv))
	tc.edit_alpha = false
	tc.custom_minimum_size = Vector2(64, 30)
	var auto := UI.button("AUTO", "ghost", {"size": 11})
	auto.tooltip_text = "Pick a colour that stands out on the paint"
	auto.disabled = not J.truthy(lv.get("text"))
	tc.color_changed.connect(func(col: Color):
		_set_livery("text", "#" + col.to_html(false))
		auto.disabled = false
		_repaint_soon("robot"))
	auto.pressed.connect(func():
		_set_livery("text", null)
		_refresh())
	_body.row([UI.vbox(2, [UI.label("Colour", {"kind": "cond", "size": 13, "weight": 600, "color": UI.DIM}), tc]), auto], 12)
	# The name size slider: 100 is the largest that fits.
	var pct := int(round(clampf(float(J.g(lv, "nameSize", 1.0)) if J.truthy(lv.get("nameSize")) else 1.0, 0.4, 1.0) * 100.0))
	var size_label := UI.label("largest that fits" if pct >= 100 else "%d%%" % pct, {"kind": "mono", "size": 13, "weight": 700})
	var slider := HSlider.new()
	slider.min_value = 40
	slider.max_value = 100
	slider.step = 5
	slider.value = pct
	slider.custom_minimum_size.x = 220
	slider.value_changed.connect(func(v: float):
		_set_livery("nameSize", null if v >= 100.0 else v / 100.0)
		size_label.text = "largest that fits" if v >= 100.0 else "%d%%" % int(v)
		_repaint_soon("robot"))
	_field("Size", UI.hbox(10, [slider, size_label]))
	_body.p("The name finds the biggest flat panel it fits on by itself; the slider only makes it smaller.", {"tone": "muted", "size": 12})

func _advisor_html() -> void:
	var c := _career()
	var nf = null if J.truthy(c.get("seasonOver")) else Career.next_fight(reg, c)
	var opp_name = str(Career.fielded_def(reg, c, nf.oppId).name) if nf != null else null
	_body.p("The advisor is optional and works offline: it reasons from your parts, the measured physics matchups, and trial fights it runs on this machine. It only suggests - nothing is bought until you press Buy & fit.",
		{"tone": "muted", "size": 12})
	var edit := TextEdit.new()
	edit.text = brief
	edit.placeholder_text = "Describe a robot: \"a low wedge with a lifter\", \"fast drum under $12,000\", \"vertical disc called Molar Bear\""
	edit.custom_minimum_size = Vector2(0, 64)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(func(): brief = edit.text)
	var design := UI.button("DESIGN IT", "fight", {"small": true})
	design.pressed.connect(func(): ask("design"))
	_body.row([edit, design], 8)
	var row := UI.hbox(6)
	if nf != null:
		var a := UI.button("TAILOR FOR %s" % opp_name.to_upper(), "ghost")
		a.pressed.connect(func(): ask("opponent"))
		var b := UI.button("GAME PLAN VS %s" % opp_name.to_upper(), "ghost")
		b.pressed.connect(func(): ask("fight"))
		row.add_child(a)
		row.add_child(b)
	else: row.add_child(UI.label("No fight drawn right now.", {"kind": "body", "size": 12, "weight": 400, "color": UI.DIM}))
	var sp := UI.button("SEASON PLAN", "ghost")
	sp.pressed.connect(func(): ask("season"))
	row.add_child(sp)
	_body.add(row)
	if advice == null: return
	var a: Dictionary = advice
	var panel := Plate.new(14, 10)
	var d := Doc.new(4)
	d.add(UI.label(str(a.get("title", "")).to_upper(), {"kind": "display", "size": 26, "weight": 600, "italic": true, "wrap": true}))
	d.p(Doc.esc(a.get("summary", "")), {"size": 15})
	for p in a.get("points", []): d.p("•  " + Doc.esc(p), {"kind": "body", "size": 13, "weight": 400})
	if a.get("design") is Dictionary:
		var load_btn := UI.button("LOAD INTO THE WORKSHOP", "fight", {"small": true})
		load_btn.pressed.connect(func(): _load_design(a.design))
		d.row([load_btn])
	var options: Array = a.get("options", [])
	for o in options:
		var try_it := UI.button("TRY IT", "ghost", {"size": 11})
		try_it.pressed.connect(func(): _load_design(o.get("design")))
		d.p("[b]%s[/b]  %s  %s" % [Doc.esc(o.label), Doc.pos("%d%% (+%d)" % [int(round(o.winRate * 100.0)), int(round(o.delta * 100.0))]),
			Doc.muted(money(o.cost) if J.truthy(o.get("cost")) else "free")])
		if J.truthy(o.get("notes")): d.p(Doc.esc(o.notes), {"tone": "muted", "size": 12})
		d.row([try_it])
	panel.add_child(d)
	_body.add(panel)

## Ask the advisor. It runs trial fights, so it works behind a card.
func ask(kind: String) -> void:
	if draft == null: open()
	tab = "advisor"
	var c := _career()
	var nf = null if J.truthy(c.get("seasonOver")) else Career.next_fight(reg, c)
	var req := {"kind": kind, "career": c, "design": draft, "brief": brief, "oppId": nf.oppId if nf != null else null}
	var what: String = {"design": "Designing", "opponent": "Testing changes", "fight": "Planning", "season": "Testing upgrades"}.get(kind, "Thinking")
	cs.menu.add_child(JobOverlay.new("The advisor", "%s... (running trial fights)" % what,
		func(_progress: Callable): return Advisor.advise(reg, req),
		func(result):
			advice = result if result is Dictionary else {"title": "The advisor hit a problem", "summary": "", "points": []}
			_refresh(false)))

func _load_design(d) -> void:
	if not (d is Dictionary): return
	var prev_weapon = draft.build.get("weapon")
	var keep_livery = draft.get("livery")
	draft = J.merge(draft, (d as Dictionary).duplicate(true))
	if d.get("livery") == null: draft.livery = keep_livery
	_refresh(true, ["all" if prev_weapon != draft.build.get("weapon") else "chassis"])

func _spares_html() -> void:
	var c := _career()
	var sp := Garage.spares(reg, c)
	var g := Garage.garage_of(reg, c)
	_body.sub("Spare parts")
	if sp.is_empty(): _body.p("No spares. Parts you take off stay here, to fit again or sell at half price.", {"tone": "muted"})
	else:
		var rows := []
		for id in sp:
			var b := UI.button("SELL %s" % money(Garage.resale_of(reg, id)), "ghost", {"size": 11})
			b.pressed.connect(func():
				Garage.sell_part(reg, _career(), id)
				cs.save()
				_refresh(false))
			rows.append(["%s%s" % [Doc.esc(reg.part(id).name), " x%s" % J.s(sp[id]) if sp[id] > 1 else ""], Doc.muted("%s lb" % J.s(reg.part(id).weight)), b])
		_body.ledger(rows)
	_body.sub("Build log - %s v%s" % [g.name, J.s(g.version)])
	var log_rows: Array = (g.get("log", []) as Array).duplicate()
	log_rows.reverse()
	if log_rows.is_empty(): _body.p("Nothing changed yet.", {"tone": "muted"})
	else: _body.table(2, log_rows.map(func(l): return [Doc.muted("S%s v%s" % [J.s(l.season), J.s(l.version)]), Doc.esc(l.text)]), {"expand": 1})

# Compared in a canonical form: fitting a part and taking it off again must
# not count as a change.
func _look(d: Dictionary) -> String:
	return JSON.stringify([d.get("name"), Workshop.fit_body(reg, d.body, d.build), d.get("livery") if d.get("livery") is Dictionary else {}, d.get("personality")])

func _foot_html() -> void:
	UI.clear(_foot)
	var c := _career()
	var g := Garage.garage_of(reg, c)
	var q := Garage.quote(reg, c, draft.build, J.path(draft, ["partner", "build"]))
	var s = Workshop.summarize(reg, _def())
	var errors: Array = (s.errors as Array).duplicate() if s != null else ["This design does not go together."]
	var changes := Garage.describe_change(reg, g.build, draft.build)
	var had: bool = g.get("partner") != null
	var has: bool = draft.get("partner") != null
	if had != has: changes.append("add %s (multibot)" % draft.partner.name if has else "drop %s" % g.partner.name)
	elif has and JSON.stringify(draft.partner) != JSON.stringify(g.partner): changes.append("%s changed" % draft.partner.name)
	if has and s != null:
		var ps = _partner_summary()
		if ps != null:
			var total: float = s.weightLb + ps.weightLb
			if total > s.capLb: errors.append("Multibot overweight: %s lb." % J.s(J.rnd(total * 10.0) / 10.0))
			for e in ps.errors: errors.append("%s: %s" % [draft.partner.name, e])
	var cosmetic := _look(draft) != _look({"name": g.name, "body": g.body, "build": g.build, "livery": g.get("livery"), "personality": g.get("personality")})
	var dirty := not changes.is_empty() or cosmetic
	var problems := errors.duplicate()
	for l in q.get("locked", []): problems.append("%s: %s" % [l.name, l.reason])
	if not J.truthy(q.get("affordable")): problems.append("Costs %s - you have %s." % [money(q.total), money(c.cash)])
	if dirty:
		var what := "Name, body or paint changed"
		if not changes.is_empty(): what = "; ".join(changes.slice(0, 3)) + (" +%d more" % (changes.size() - 3) if changes.size() > 3 else "")
		var buy: Array = q.get("buy", [])
		_foot.add_child(Doc.text("%s\n%s" % [Doc.esc(what), "New parts: [b]%s[/b] %s" % [money(q.total), Doc.muted("(%s)" % Doc.esc(", ".join(buy.map(func(b): return b.name))))] if not buy.is_empty() else Doc.muted("No parts to buy.")],
			{"size": 14}))
		if not problems.is_empty(): _foot.add_child(Doc.text(Doc.esc(problems[0]), {"size": 12, "color": Color(Doc.NEG)}))
	else:
		_foot.add_child(Doc.text(Doc.muted("This is your robot as it stands. Change a part to start a new design."), {"size": 14}))
	var revert := UI.button("REVERT", "ghost")
	revert.disabled = not dirty
	revert.pressed.connect(func():
		draft = _garage_design()
		if draft.get("partner") == null: unit = "main"
		_refresh(true, ["all"]))
	var apply := UI.button("BUY & FIT (%s)" % money(q.total) if J.truthy(q.get("total")) else "SAVE DESIGN", "fight", {"small": true})
	apply.disabled = not (dirty and problems.is_empty())
	apply.pressed.connect(func():
		var r := Garage.apply_design(reg, _career(), draft)
		if not J.truthy(r.get("ok")):
			_foot.add_child(Doc.text(Doc.esc(str(r.errors[0])), {"size": 12, "color": Color(Doc.NEG)}))
			return
		cs.save()
		cs.menu.refresh_catalog()
		draft = _garage_design()
		_refresh(true, ["all"]))
	var row := UI.hbox(8, [UI.spacer(0, 0, true), revert, apply])
	_foot.add_child(row)
