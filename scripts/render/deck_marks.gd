## deck_marks.gd - what a fight leaves on the floor.
##
## The deck's own texture has old gouges and stains painted into it; these are
## the new ones, laid down where this fight makes them: a bright gouge (still
## glowing for a second) under a weapon hit, soot where something blew, a
## smear of rubber where two robots shoved, oil under a part that failed and a
## trail of it behind a robot that is bleeding, a burn that spreads under a
## battery fire. By the last minute the floor shows where the fight was.
##
## Each mark is a Decal: a picture projected onto the deck, so it lies on the
## painted squares and the plate seams alike. They are projected onto what
## never moves only (the stage's static layer), so a robot driving over a mark
## is not painted with it. A pool of them, the oldest giving way to the
## newest. Like effects.gd this listens to the bus and nothing else.
class_name DeckMarks
extends Node3D

const MAX_MARKS := 56
const DEPTH := 0.3             # how far above and below the deck a mark reaches
const GLOW_S := 1.3            # how long a fresh gouge stays hot

var _views: Dictionary         # robot id -> RobotView
var _rng: Rng
var _half := Vector2(7.3, 7.3)
var _pool: Array[Decal] = []
var _age := PackedFloat32Array()
var _hot := PackedFloat32Array()
var _next := 0
var _offs := []
var _drip := {}                # robot id -> { at, owed }
var _burn := {}                # robot id -> seconds until its fire marks the deck again

static var _tex := {}

func _init(bus: Bus, robot_views: Dictionary, half: Vector2, random: Rng) -> void:
	name = "DeckMarks"
	_views = robot_views
	_half = half
	_rng = random
	_textures()
	for i in MAX_MARKS:
		var d := Decal.new()
		d.visible = false
		d.cull_mask = Stage.STATIC_LAYER
		# Not up the kickplates or down the walls of the pit.
		d.normal_fade = 0.6
		d.upper_fade = 0.01
		d.lower_fade = 0.01
		add_child(d)
		_pool.append(d)
		_age.append(0.0)
		_hot.append(0.0)
	_offs.append(bus.on(Bus.HIT, _on_hit))
	_offs.append(bus.on(Bus.PART_FAILED, _on_failed))

# ---------------------------------------------------------------- the pictures

# Drawn once and shared by every fight. Nothing reaches a picture's edge: a
# mark must end inside its own square.
static func _textures() -> void:
	if not _tex.is_empty(): return
	var S := 256
	var clear := Color(0, 0, 0, 0)

	# A gouge: a few scrapes side by side, bright where the steel is fresh,
	# with the dark of the cut beside each. Runs along the picture's x.
	var g := TexPaint.new(S, clear, 201)
	var h := TexPaint.new(S, Color.html("#808080"), 202)
	var e := TexPaint.new(S, Color.BLACK, 203)
	for i in 5:
		var y := S * 0.5 + g.rnd(-34, 34)
		var x0 := g.rnd(S * 0.14, S * 0.36)
		var x1 := g.rnd(S * 0.64, S * 0.86)
		var dy := g.rnd(-10, 10)
		var w := g.rnd(2.5, 6.5)
		g.line(x0, y + 2.5, x1, y + dy + 2.5, w * 1.9, TexPaint.rgba(10, 10, 12, 0.85))
		g.line(x0, y, x1, y + dy, w, TexPaint.rgba(g.rnd(150, 205), g.rnd(152, 207), g.rnd(162, 216), 0.95))
		h.line(x0, y, x1, y + dy, w * 1.4, Color.html("#2c2c2c"))
		e.line(x0 + 8, y, x1 - 8, y + dy, w * 0.9, TexPaint.rgba(255, 150, 40, 0.9))
	# Fine chatter round them.
	for i in 26:
		var x := g.rnd(S * 0.2, S * 0.8)
		var y := S * 0.5 + g.rnd(-46, 46)
		var l := g.rnd(6, 26)
		g.line(x, y, x + l, y + g.rnd(-3, 3), 1.6, TexPaint.rgba(170, 174, 184, g.rnd(0.3, 0.7)))
	_tex.gouge = g.texture()
	_tex.gouge_n = h.normal_texture(3.2)
	_tex.gouge_e = e.texture()

	# Soot: black in the middle, ragged and thin at the edge.
	var s := TexPaint.new(S, clear, 211)
	for i in 46:
		var a := s.rnd(0.0, TAU)
		var r := s.rnd(0.0, S * 0.3)
		s.blob(S * 0.5 + cos(a) * r, S * 0.5 + sin(a) * r, s.rnd(14, 40), TexPaint.rgba(8, 7, 7, s.rnd(0.2, 0.45)))
	for i in 9:
		var a := s.rnd(0.0, TAU)
		s.line(S * 0.5, S * 0.5, S * 0.5 + cos(a) * S * s.rnd(0.2, 0.38), S * 0.5 + sin(a) * S * s.rnd(0.2, 0.38), s.rnd(3, 8), TexPaint.rgba(6, 6, 6, 0.3))
	s.blob(S * 0.5, S * 0.5, S * 0.2, TexPaint.rgba(4, 4, 4, 0.9))
	_tex.soot = s.texture()

	# Oil: a pool with a ragged edge and a few flung drops. Slick, so the
	# hall's lights sit in it.
	var o := TexPaint.new(S, clear, 221)
	var slick := TexPaint.new(S, TexPaint.rgba(255, 150, 0), 222)
	for i in 14:
		var a := o.rnd(0.0, TAU)
		var r := o.rnd(0.0, S * 0.17)
		var x := S * 0.5 + cos(a) * r
		var y := S * 0.5 + sin(a) * r
		var rad := o.rnd(18, 44)
		o.disc(x, y, rad, TexPaint.rgba(9, 8, 10, 0.93))
		slick.disc(x, y, rad, TexPaint.rgba(255, 16, 0))
	for i in 16:
		var a := o.rnd(0.0, TAU)
		var r := o.rnd(S * 0.24, S * 0.42)
		var x := S * 0.5 + cos(a) * r
		var y := S * 0.5 + sin(a) * r
		var rad := o.rnd(2.5, 8)
		o.disc(x, y, rad, TexPaint.rgba(9, 8, 10, 0.9))
		slick.disc(x, y, rad, TexPaint.rgba(255, 16, 0))
	_tex.oil = o.texture()
	_tex.oil_orm = slick.texture()

	# Rubber: a short curved smear, as a tyre leaves when it is shoved sideways.
	var t := TexPaint.new(S, clear, 231)
	for i in 4:
		var y := S * 0.5 + (i - 1.5) * 15.0 + t.rnd(-3, 3)
		var c := S * 1.4 * (1.0 if i % 2 == 0 else 1.15)
		t.arc(S * 0.5, y + c, c, -PI / 2.0 - 0.22, -PI / 2.0 + 0.22, t.rnd(7, 11), TexPaint.rgba(12, 11, 12, t.rnd(0.35, 0.6)))
	_tex.rubber = t.texture()

# ---------------------------------------------------------------- laying one down

func _on_deck(at: Vector3, margin := 0.15) -> bool:
	return absf(at.x) < _half.x - margin and absf(at.z) < _half.y - margin

# One mark: `kind` picks the picture, `size` is its footprint in metres
# (along, across), `yaw` which way its picture's x points. Returns its place
# in the pool.
func _lay(kind: String, at: Vector3, size: Vector2, yaw: float, strength := 1.0, hot := 0.0) -> int:
	if not visible or not _on_deck(at): return -1
	var i := _next
	_next = (_next + 1) % MAX_MARKS
	var d := _pool[i]
	d.texture_albedo = _tex[kind]
	d.texture_normal = _tex.gouge_n if kind == "gouge" else null
	d.texture_orm = _tex.oil_orm if kind == "oil" else null
	d.texture_emission = _tex.gouge_e if kind == "gouge" else null
	d.emission_energy = hot
	d.modulate = Color(1, 1, 1, strength)
	d.albedo_mix = 0.0
	d.size = Vector3(size.x, DEPTH * 2.0, size.y)
	d.position = Vector3(at.x, 0.0, at.z)
	d.rotation = Vector3(0, yaw, 0)
	d.visible = true
	_age[i] = 0.0
	_hot[i] = hot
	return i

func _yaw_of(dir: Vector3) -> float:
	return atan2(-dir.z, dir.x) if Vector2(dir.x, dir.z).length_squared() > 1e-6 else _rng.next() * TAU

func _on_hit(e: Dictionary) -> void:
	if not (e.get("at") is Vector3): return
	var at: Vector3 = e.at
	var level: int = Damage.SEVERITY_ORDER.get(e.severity, 0)
	if level < 2: return
	# Which way the blow went: from the one that struck to the one that took it.
	var dir := Vector3.ZERO
	var atk = _views.get(e.get("attackerId"))
	var def = _views.get(e.get("defenderId"))
	if atk != null and def != null and is_instance_valid(atk) and is_instance_valid(def): dir = (def as Node3D).global_position - (atk as Node3D).global_position
	var yaw := _yaw_of(dir) + (_rng.next() - 0.5) * 0.5
	var k := (level - 1) / 3.0          # 0.33 a hit, 0.67 heavy, 1 catastrophic
	if e.get("kind") == "ram":
		# Two robots shoving: rubber, laid across the push.
		_lay("rubber", at, Vector2(0.5, 0.35) * (0.8 + k), yaw + PI / 2.0, 0.6 + 0.4 * k)
		return
	# A weapon (or a hazard) low enough to reach the deck bites it.
	if at.y < 0.45:
		var along := 0.45 + 0.9 * k + _rng.next() * 0.2
		_lay("gouge", at + dir.normalized() * along * 0.2, Vector2(along, along * 0.55), yaw, 0.75 + 0.25 * k, 2.0 + 4.0 * k)
	if level >= 3: _lay("soot", at, Vector2.ONE * (0.7 + 0.8 * k + _rng.next() * 0.3), _rng.next() * TAU, 0.7 + 0.3 * k)

func _on_failed(e: Dictionary) -> void:
	if not (e.get("at") is Vector3): return
	# What a broken part lets go of: its oil, flung a little the way it was hit.
	var normal: Vector3 = e.normal if e.get("normal") is Vector3 else Vector3.ZERO
	var at: Vector3 = e.at + Vector3(normal.x, 0, normal.z) * 0.25
	var size := 0.7 + _rng.next() * 0.5
	if e.get("category") == "armor":
		_lay("soot", at, Vector2.ONE * size, _rng.next() * TAU, 0.6)
	else:
		_lay("oil", at, Vector2.ONE * size, _rng.next() * TAU, 0.9)

# ---------------------------------------------------------------- per frame

## Once a frame: fresh gouges cool, new marks come up over a few frames, and
## whatever is bleeding or burning leaves its trail.
func update(dt: float) -> void:
	if not visible: return
	for i in MAX_MARKS:
		var d := _pool[i]
		if not d.visible: continue
		_age[i] += dt
		if d.albedo_mix < 1.0: d.albedo_mix = minf(1.0, _age[i] / 0.12)
		if _hot[i] > 0.0:
			var e := _hot[i] * maxf(0.0, 1.0 - _age[i] / GLOW_S)
			d.emission_energy = e * e / maxf(_hot[i], 0.001)
			if _age[i] >= GLOW_S:
				_hot[i] = 0.0
				d.texture_emission = null
	for id in _views:
		var view: RobotView = _views[id]
		if not is_instance_valid(view) or not view.visible: continue
		var here := view.global_position
		var leaking := false
		var burning := false
		for src in view.damage_sources():
			if src.fire: burning = true
			elif src.key == "motor" or src.key == "drive" or src.key == "weaponMotor": leaking = true
		if leaking:
			# A drop every stride: a trail while it moves, one spot while it sits.
			var st: Dictionary = _drip.get(id, {"at": Vector3(INF, 0, 0)})
			if (st.at as Vector3).distance_to(here) > 0.55:
				st.at = here
				_drip[id] = st
				var s := 0.16 + _rng.next() * 0.16
				_lay("oil", here + Vector3((_rng.next() - 0.5) * 0.2, 0, (_rng.next() - 0.5) * 0.2), Vector2(s, s), _rng.next() * TAU, 0.85)
		if burning:
			var wait: float = _burn.get(id, 0.0) - dt
			if wait <= 0.0:
				wait = 1.1
				var s := 0.6 + _rng.next() * 0.5
				_lay("soot", here + Vector3((_rng.next() - 0.5) * 0.3, 0, (_rng.next() - 0.5) * 0.3), Vector2(s, s), _rng.next() * TAU, 0.45)
			_burn[id] = wait

## Settings -> Battle marks.
func apply_settings(settings: Dictionary) -> void:
	var want := Gfx.on(settings, "gfxDecals")
	if want == visible: return
	visible = want
	if not want: clear()

## Between matches: a clean deck.
func clear() -> void:
	for i in MAX_MARKS:
		_pool[i].visible = false
		_hot[i] = 0.0
	_drip.clear()
	_burn.clear()

func _exit_tree() -> void:
	for off in _offs:
		if (off as Callable).is_valid(): off.call()
