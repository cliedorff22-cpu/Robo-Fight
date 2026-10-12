## venue_view.gd - the building round the box: stands, the crowd, the
## lighting rig, screens, banners and each venue's own furniture
## (data/arenas.json).
##
## Pure decoration. Nothing here has physics and nothing reads the sim except
## through the bus, which it listens to so the crowd can react: big hits, the
## count, a knockout, the bell. One venue per league and one for the Giant Nut.
##
## Kept out of the cameras' way on purpose: everything over the box hangs
## above the overhead camera (52 ft), the stands start beyond the fixed
## cameras, and the hall is drawn from the inside only, so a camera that ends
## up above the roof looks straight through it.
class_name VenueView
extends Node3D

const SEAT_PITCH_M := 0.62            # one fan per this much row
# Sides of the box: the stands are built for the south (+Z) side and turned.
const SIDES := {"s": 0.0, "e": PI / 2.0, "n": PI, "w": -PI / 2.0}
# The crowd looks up no shadows: nothing in the hall casts one as far as the
# stands, and asking on every fan's pixels costs frame time.
const CROWD_SHADER := "shader_type spatial;\nrender_mode shadows_disabled;\nuniform float u_time = 0.0;\nuniform float u_excite = 0.4;\nuniform float u_glow = 0.14;\nvarying vec3 tint;\nvoid vertex() {\n\tfloat phase = INSTANCE_CUSTOM.x;\n\tfloat gain = INSTANCE_CUSTOM.y;\n\tfloat ex = clamp(u_excite * gain, 0.0, 1.6);\n\tfloat bob = sin(u_time * (1.6 + gain) + phase) * 0.025 * (0.5 + ex);\n\tfloat jump = max(0.0, sin(u_time * 8.5 + phase * 3.0)) * 0.24 * smoothstep(0.75, 1.3, ex);\n\tVERTEX.y += bob + jump + UV.x * 0.52 * smoothstep(0.45 + 0.35 * fract(phase), 1.0, ex);\n\ttint = COLOR.rgb;\n}\nvoid fragment() {\n\tALBEDO = tint;\n\tROUGHNESS = 0.92;\n\tMETALLIC = 0.0;\n\tEMISSION = tint * u_glow;\n}\n"

var venue: Dictionary

var _rng: Rng
var _mats := {}
var _half_x := 7.3
var _half_z := 7.3
var _deck_bottom := -0.3
var _hx := 20.0
var _hz := 20.0
var _hh := 12.0
var _accent := Color.WHITE
var _tiers := []               # [{ u0, u1, v0, v1, rows, under }]
var _length := 20.0
var _crowd_mat: ShaderMaterial
var _glow := 0.14
var _rest := 0.4
var _excite := 0.4
var _flash := 0.0
var _t := 0.0
var _beams := []               # [{ node, mat, out, along, at, phase }]
static var _beam_shader: Shader = null
var _ribbons := []
var _lamp_mat: StandardMaterial3D
var _pyros := []               # [{ flame, core, fmat, cmat, t }]
## The graphics card's flame (a GpuFx), when Settings -> Spark showers is on:
## the flame cannons then throw real fire and the cones stay dark.
var gpu_fire = null
var _nut: Node3D = null
var _cube: Node3D = null
var _board: Dictionary = {}
var _last_clock = null
var _last_phase = null
var _offs := []

## `names`: { red, blue } robot names for the screens.
func _init(venue_def: Dictionary, arena: Dictionary, bus: Bus = null, decor_seed = 1, names: Dictionary = {}) -> void:
	name = "VenueView"
	venue = venue_def
	_rng = Rng.new(Rng.hash_seed("venue:%s:%s" % [venue.get("name"), J.s(decor_seed)]))
	_half_x = U.ft_to_m(arena.floor.size[0]) / 2.0
	_half_z = U.ft_to_m(arena.floor.size[1]) / 2.0
	_deck_bottom = -U.ft_to_m(arena.floor.thickness)
	var hall: Dictionary = venue.hall
	_hx = U.ft_to_m(hall.half[0])
	_hz = U.ft_to_m(hall.half[1])
	_hh = U.ft_to_m(hall.height)
	_accent = _col(venue.get("accent"), "#ffffff")
	_rest = J.path(venue, ["crowd", "energy"], 0.4)
	_excite = _rest
	_glow = J.path(venue, ["crowd", "glow"], 0.14)
	var b := ArenaView.Batch.new()
	_build_hall(b, hall)
	_build_stands(b)
	_build_lights(b)
	_build_screens(b, names)
	_build_banners(b)
	_build_extras(b)
	b.commit(self, false)
	if Parts.detailed: _build_pit_gear()
	if bus != null:
		_offs.append(bus.on(Bus.HIT, func(e):
			var big := 1.1 if e.severity == "catastrophic" else (0.75 if e.severity == "heavy" else (0.35 if e.severity == "hit" else 0.15))
			react(big, e.severity == "catastrophic")))
		_offs.append(bus.on(Bus.PART_FAILED, func(_e): react(0.7)))
		_offs.append(bus.on(Bus.REF_COUNT, func(_e): react(0.55)))
		_offs.append(bus.on(Bus.KO, func(_e): react(1.5, true)))
		_offs.append(bus.on(Bus.MATCH_END, func(_e): react(1.3, true)))
		_offs.append(bus.on(Bus.HAZARD_FIRE, func(e): react(0.9 if e.type == "pit" else 0.2)))
		_offs.append(bus.on(Bus.MATCH_STATE, func(e):
			if e.get("phase") == "live": react(1.0, true)
			elif e.get("phase") == "countdown": react(0.5)))

func _exit_tree() -> void:
	for off in _offs:
		if (off as Callable).is_valid(): off.call()

static func _col(c, fallback := "#808080") -> Color:
	return CanvasRec.css(c if c != null else fallback)

# A plain material, shared by colour and finish.
func _mat(color: Color, rough := 0.9, metal := 0.05, glow := 0.0, glow_color = null, two_sided := false) -> StandardMaterial3D:
	var gc: Color = glow_color if glow_color != null else color
	var key := "%s|%.2f|%.2f|%.2f|%s|%s" % [color.to_html(), rough, metal, glow, gc.to_html(), two_sided]
	if _mats.has(key): return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = gc
		m.emission_energy_multiplier = glow
	if two_sided: m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m

static func _box(w: float, h: float, d: float, x: float, y: float, z: float, yaw := 0.0) -> Geo:
	var g := Geo.box(w, h, d)
	if yaw != 0.0: g.rotate_y(yaw)
	return g.translate(x, y, z)

static func _flat(w: float, l: float, x: float, y: float, z: float) -> Geo:
	var g := Geo.new()
	var up := Vector3.UP
	g.quad(Vector3(x - w / 2.0, y, z - l / 2.0), Vector3(x - w / 2.0, y, z + l / 2.0), Vector3(x + w / 2.0, y, z + l / 2.0), Vector3(x + w / 2.0, y, z - l / 2.0), up, up, up, up)
	return g

# ---------------------------------------------------------------- the hall

func _build_hall(b: ArenaView.Batch, hall: Dictionary) -> void:
	var wall_c := _col(hall.get("wall"))
	# Walls: an open-topped box seen from inside; the roof is its underside
	# only, so from above the hall is see-through.
	var walls := Geo.new()
	var y0 := _deck_bottom
	var y1 := _deck_bottom + _hh
	var c := [Vector3(-_hx, 0, -_hz), Vector3(_hx, 0, -_hz), Vector3(_hx, 0, _hz), Vector3(-_hx, 0, _hz)]
	for i in 4:
		var p: Vector3 = c[i]
		var q: Vector3 = c[(i + 1) % 4]
		var n := -((p + q) / 2.0).normalized()
		walls.quad(Vector3(q.x, y0, q.z), Vector3(p.x, y0, p.z), Vector3(p.x, y1, p.z), Vector3(q.x, y1, q.z), n, n, n, n)
	b.add(walls, _mat(wall_c, 0.92, 0.05, 0.12))
	var roof := Geo.new()
	var dn := Vector3.DOWN
	roof.quad(Vector3(-_hx, y1, -_hz), Vector3(_hx, y1, -_hz), Vector3(_hx, y1, _hz), Vector3(-_hx, y1, _hz), dn, dn, dn, dn)
	b.add(roof, _mat(_col(hall.get("roof")), 0.95, 0.0))
	var floor_c := _col(hall.get("floor"))
	# Poured concrete (the scanned sets, tinted to the venue's own floor
	# colour; the flat colour where those are off), 2.5 m to a repeat.
	var mats := Mats.shared()
	var walk_c := Color(minf(1.0, floor_c.r * 1.5), minf(1.0, floor_c.g * 1.5), minf(1.0, floor_c.b * 1.5))
	b.add(_flat(_hx * 2.0, _hz * 2.0, 0, _deck_bottom - 0.005, 0).tile_uvs(1.0),
		mats.surface("concrete_dark", 0.4, Color(floor_c.r / 0.3, floor_c.g / 0.3, floor_c.b / 0.3), floor_c, 0.85, 0.1))
	# The walkway round the box, a shade lighter, with a painted safety line.
	b.add(_flat(_half_x * 2.0 + 5.0, _half_z * 2.0 + 5.0, 0, _deck_bottom, 0).tile_uvs(1.0),
		mats.surface("concrete", 0.4, Color(walk_c.r / 0.75, walk_c.g / 0.75, walk_c.b / 0.75), walk_c, 0.8, 0.0))
	var line := _mat(Color.html("#d8b21a"), 0.7, 0.0)
	for q in [[_half_x * 2.0 + 5.0, 0.12, 0.0, -_half_z - 2.5], [_half_x * 2.0 + 5.0, 0.12, 0.0, _half_z + 2.5],
			[0.12, _half_z * 2.0 + 5.0, -_half_x - 2.5, 0.0], [0.12, _half_z * 2.0 + 5.0, _half_x + 2.5, 0.0]]:
		b.add(_flat(q[0], q[1], q[2], _deck_bottom + 0.004, q[3]), line)

# ---------------------------------------------------------------- stands

func _side_off(side: String) -> float:
	# A stand along an X side (e/w) reaches out from halfX, not halfZ.
	return _half_x - _half_z if (side == "e" or side == "w") else 0.0

func _build_stands(b: ArenaView.Batch) -> void:
	# Each side is one extruded stepped profile per tier: seat colour on the
	# treads, the stand colour on the risers.
	var st: Dictionary = venue.stands
	var stand_mat := _mat(_col(st.get("color")), 0.9, 0.05, 0.12)
	var seat_mat := _mat(_col(st.get("seat")), 0.9, 0.05, 0.12)
	var row_d := U.ft_to_m(st.rowDepth)
	var rise := U.ft_to_m(st.rowRise)
	_length = U.ft_to_m(st.length)
	var barrier_h := 1.1
	var prev_end := 0.0
	var prev_top := 0.0
	for k in st.tiers.size():
		var t: Dictionary = st.tiers[k]
		var u0: float = _half_z + U.ft_to_m(st.gap) if k == 0 else prev_end - U.ft_to_m(J.g(t, "back", 0.0))
		var v0: float = _deck_bottom + barrier_h if k == 0 else prev_top + U.ft_to_m(J.g(t, "lift", 8.0))
		var u1: float = u0 + t.rows * row_d
		var v1: float = v0 + (t.rows - 1) * rise
		_tiers.append({"u0": u0, "u1": u1, "v0": v0, "v1": v1, "rows": int(t.rows), "under": _deck_bottom if k == 0 else v0 - 1.4})
		prev_end = u1
		prev_top = v1
	var tread_geos := []
	var riser_geos := []
	for t in _tiers:
		# Profile in (outward, up); the shape is extruded along the side.
		var s := PackedVector2Array([Vector2(t.u0, t.under), Vector2(t.u0, t.v0 + 0.25), Vector2(t.u0 + 0.12, t.v0 + 0.25), Vector2(t.u0 + 0.12, t.v0)])
		for i in t.rows:
			var v: float = t.v0 + i * rise
			s.append(Vector2(t.u0 + (i + 1) * row_d, v))
			if i < t.rows - 1: s.append(Vector2(t.u0 + (i + 1) * row_d, v + rise))
		s.append(Vector2(t.u1, t.under))
		# Shape X -> outward (+Z), extrusion -> along X.
		var g := Geo.extrude(s, _length, 0.0).rotate_y(-PI / 2.0)
		var treads := Geo.new()
		var risers := Geo.new()
		for i in range(0, g.pos.size(), 3):
			var into := treads if g.nrm[i].y > 0.7 else risers
			into.tri(g.pos[i], g.pos[i + 1], g.pos[i + 2], g.nrm[i], g.nrm[i + 1], g.nrm[i + 2])
		tread_geos.append(treads)
		riser_geos.append(risers)
	var hall_wall := _col(venue.hall.get("wall"))
	var back_mat := _mat(Color(hall_wall.r * 0.8, hall_wall.g * 0.8, hall_wall.b * 0.8), 0.9, 0.0)
	var seats := []
	var fill: float = J.path(venue, ["crowd", "fill"], 0.8)
	var top: Dictionary = _tiers[_tiers.size() - 1]
	for side in st.sides:
		if not SIDES.has(side): continue
		var yaw: float = SIDES[side]
		var off := _side_off(side)
		var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(sin(yaw) * off, 0, cos(yaw) * off))
		for g in tread_geos: b.add(g.copy().apply(xf), seat_mat)
		for g in riser_geos: b.add(g.copy().apply(xf), stand_mat)
		# A back wall behind the top tier, up to the roof line - banners hang off it.
		var turn := Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO)
		b.add(Geo.box(_length + 2.0, top.v1 + 3.0 - _deck_bottom, 0.4).translate(0, (top.v1 + 3.0 + _deck_bottom) / 2.0, top.u1 + 0.3 + off).apply(turn), back_mat)
		# Seats for the crowd.
		for t in _tiers:
			for i in t.rows:
				var z: float = t.u0 + i * row_d + row_d * 0.55 + off
				var y: float = t.v0 + i * rise
				var x := -_length / 2.0 + 0.5
				while x <= _length / 2.0 - 0.5:
					if _rng.next() <= fill: seats.append([yaw, x + _rng.float_range(-0.08, 0.08), y, z])
					x += SEAT_PITCH_M
	# Front barriers: a padded wall along the front of every tier, the LED
	# ribbon where the venue has one.
	var extras: Array = venue.get("extras", [])
	var lit := extras.has("ledRibbon")
	for side in st.sides:
		if not SIDES.has(side): continue
		var yaw: float = SIDES[side]
		var off := _side_off(side)
		var turn := Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO)
		for k in _tiers.size():
			if k != 0 and not lit: continue
			var t: Dictionary = _tiers[k]
			var h := 0.5
			var g := Geo.box(_length, h, 0.06).translate(0, t.v0 + 0.25 - h / 2.0 + 0.02, t.u0 - 0.04 + off).apply(turn)
			if lit:
				var m := StandardMaterial3D.new()
				m.albedo_color = Color.html("#111111")
				m.roughness = 0.4
				m.emission_enabled = true
				m.emission = _accent
				m.emission_energy_multiplier = 1.4
				_ribbons.append(m)
				add_child(g.instance(m, false))
			else:
				var banners: Array = venue.get("banners", [])
				b.add(g, _mat(_col(banners[0] if not banners.is_empty() else null, "#333333"), 0.7, 0.0))
	_build_crowd(seats)

# ---------------------------------------------------------------- crowd
# Two multimeshes - shirts (with arms) and heads - animated entirely on the
# graphics card: each fan has a phase and an excitability, and one shared
# `excite` level makes them bob, jump and put their arms up.
func _build_crowd(seats: Array) -> void:
	if seats.is_empty(): return
	var sh := Shader.new()
	sh.code = CROWD_SHADER
	_crowd_mat = ShaderMaterial.new()
	_crowd_mat.shader = sh
	_crowd_mat.set_shader_parameter("u_excite", _excite)
	_crowd_mat.set_shader_parameter("u_glow", _glow)
	# A seated fan from the waist up, facing -Z: torso and two arms (uv.x = 1).
	var body := Geo.box(0.42, 0.56, 0.26).translate(0, 0.70, 0)
	for i in body.uv.size(): body.uv[i] = Vector2.ZERO
	for sx in [-0.27, 0.27]:
		var arm := Geo.box(0.11, 0.5, 0.13).translate(sx, 0.70, 0)
		for i in arm.uv.size(): arm.uv[i] = Vector2(1, 0)
		body.append(arm)
	var head_prof := []
	for i in range(8): head_prof.append(Vector2(sin(i / 7.0 * PI) * 0.115, -cos(i / 7.0 * PI) * 0.115))
	var head := Geo.lathe(head_prof, 9).translate(0, 1.14, 0)
	for i in head.uv.size(): head.uv[i] = Vector2.ZERO
	if Parts.detailed:
		# People rather than blocks, for about the same number of triangles:
		# a torso with shoulders, round arms, and a head that spends fewer.
		body = Geo.lathe([Vector2(0.17, 0.42), Vector2(0.19, 0.6), Vector2(0.215, 0.82), Vector2(0.2, 0.93), Vector2(0.09, 0.99), Vector2(0.0, 1.0)], 6)
		body.apply(Transform3D(Basis.from_scale(Vector3(1.0, 1.0, 0.62)), Vector3.ZERO))
		for i in body.uv.size(): body.uv[i] = Vector2.ZERO
		for sx in [-0.255, 0.255]:
			var arm := Geo.cylinder(0.05, 0.06, 0.5, 5).translate(sx, 0.70, 0)
			for i in arm.uv.size(): arm.uv[i] = Vector2(1, 0)
			body.append(arm)
		head_prof = []
		for i in range(5): head_prof.append(Vector2(sin(i / 4.0 * PI) * 0.115, -cos(i / 4.0 * PI) * 0.125))
		head = Geo.lathe(head_prof, 6).translate(0, 1.13, 0)
		for i in head.uv.size(): head.uv[i] = Vector2.ZERO
	var palette := []
	for c in J.path(venue, ["crowd", "palette"], ["#888888"]): palette.append(_col(c).srgb_to_linear())
	var skins := []
	for c in ["#f1c6a4", "#d9a07a", "#b77a52", "#8a5634", "#5e3a22", "#f5d7bd"]: skins.append(Color.html(c).srgb_to_linear())
	var mms := []
	for geo in [body, head]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = geo.to_mesh(_crowd_mat)
		mm.instance_count = seats.size()
		mms.append(mm)
	for i in seats.size():
		var s: Array = seats[i]
		# Into the world: the side's yaw, then the seat; fans face the box
		# (-Z in the side's frame) give or take a glance.
		var yaw: float = s[0]
		var p := Basis(Vector3.UP, yaw) * Vector3(s[1], s[2], s[3])
		var k := _rng.float_range(0.92, 1.08)
		var basis := Basis(Vector3.UP, yaw + PI + _rng.float_range(-0.35, 0.35)).scaled(Vector3(k, k, k))
		var xf := Transform3D(basis, p)
		var shirt: Color = palette[_rng.int_range(0, palette.size() - 1)]
		var skin: Color = skins[_rng.int_range(0, skins.size() - 1)]
		var custom := Color(_rng.float_range(0.0, TAU), _rng.float_range(0.55, 1.25), 0, 0)
		mms[0].set_instance_transform(i, xf)
		mms[1].set_instance_transform(i, xf)
		mms[0].set_instance_color(i, shirt)
		mms[1].set_instance_color(i, skin)
		mms[0].set_instance_custom_data(i, custom)
		mms[1].set_instance_custom_data(i, custom)
	for mm in mms:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-_hx, _deck_bottom, -_hz), Vector3(_hx * 2.0, _hh, _hz * 2.0))
		add_child(mmi)

# ---------------------------------------------------------------- lighting rig
# A square truss round the box at the height of the arena's own rigs, lamp
# heads aimed in, and (in the bigger venues) beams that sweep and flash.
func _build_lights(b: ArenaView.Batch) -> void:
	var L: Dictionary = venue.get("lights", {})
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color.html("#222222")
	_lamp_mat.roughness = 0.3
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = _col(L.get("color"), "#ffffff")
	_lamp_mat.emission_energy_multiplier = 2.2
	var truss := _mat(Color.html("#2a2c30"), 0.5, 0.6)
	var truss_y := U.ft_to_m(27.0)
	var ring := maxf(_half_x, _half_z) + U.ft_to_m(5.0)
	var rows := int(J.g(L, "rows", 4))
	if L.get("kind") == "fluorescent":
		# Warehouse tubes hung in rows over the stands and walkways - never over the box.
		var tube := _mat(Color.html("#dddddd"), 0.5, 0.0, 2.0, _col(L.get("color")))
		var tube_y := minf(_hh - 1.0, U.ft_to_m(24.0))
		for r in rows:
			var z := (r - (rows - 1) / 2.0) * (_hz * 1.6 / maxf(1.0, rows - 1))
			var x := -_hx + 4.0
			while x <= _hx - 4.0:
				if not (absf(x) < _half_x + 2.5 and absf(z) < _half_z + 2.5):
					b.add(_box(2.6, 0.08, 0.3, x, tube_y, z), truss)
					b.add(_box(2.4, 0.05, 0.12, x, tube_y - 0.06, z), tube)
					# Hanging wires.
					for dx in [-1.1, 1.1]:
						b.add(_box(0.01, _hh - tube_y, 0.01, x + dx, tube_y + (_hh - tube_y) / 2.0, z), truss)
				x += 4.2
		return
	if Parts.detailed:
		# The real thing: box truss, four chords laced with diagonals.
		for q in [[-1, -1, 1, -1], [-1, 1, 1, 1], [-1, -1, -1, 1], [1, -1, 1, 1]]:
			b.add(_truss(Vector3(q[0] * ring, truss_y, q[1] * ring), Vector3(q[2] * ring, truss_y, q[3] * ring), 0.35), truss)
	else:
		for q in [[ring * 2.0, 0.35, 0.0, -ring], [ring * 2.0, 0.35, 0.0, ring], [0.35, ring * 2.0, -ring, 0.0], [0.35, ring * 2.0, ring, 0.0]]:
			b.add(_box(q[0], 0.35, q[1], q[2], truss_y, q[3]), truss)
	# Chains up to the roof at the corners.
	for q in [[-ring, -ring], [ring, -ring], [-ring, ring], [ring, ring]]:
		b.add(_box(0.05, _hh - truss_y, 0.05, q[0], truss_y + (_hh - truss_y) / 2.0, q[1]), truss)
	var per_side := maxi(2, int(J.g(L, "rows", 3)) + 1)
	var beam_colors := []
	for c in L.get("beamColors", [J.g(L, "color", "#ffffff")]): beam_colors.append(_col(c))
	var bi := 0
	var lamps := Geo.new()
	for q in [[1, 0, 0, -1], [1, 0, 0, 1], [0, 1, -1, 0], [0, 1, 1, 0]]:
		for i in per_side:
			var f := (i + 0.5) / per_side - 0.5
			var at := Vector3(q[0] * f * ring * 2.0 + q[2] * ring, truss_y - 0.35, q[1] * f * ring * 2.0 + q[3] * ring)
			# Tip toward the middle of the box.
			var down := (Vector3(0, 0, 0) - at).normalized()
			var yb := -down
			var xb := yb.cross(Vector3.UP).normalized()
			var basis := Basis(xb, yb, xb.cross(yb))
			var xf := Transform3D(basis, at)
			b.add(Geo.cylinder(0.22, 0.26, 0.5, 12).apply(xf), truss)
			if Parts.detailed: b.add(_lamp_fittings(xf, Vector3(at.x, truss_y - 0.17, at.z)), truss)
			lamps.append(Geo.cylinder(0.2, 0.2, 0.02, 14).translate(0, -0.26, 0).apply(xf))
			if J.truthy(L.get("beams")):
				if bi % 2 == 0:
					# Beams sweep the crowd, not the box: nothing gets between
					# the cameras and the fight.
					var c: Color = beam_colors[_beams.size() % beam_colors.size()]
					var beam := _make_beam(c, truss_y)
					beam.node.position = Vector3(at.x, truss_y - 0.6, at.z)
					add_child(beam.node)
					beam.merge({"out": Vector2(q[2], q[3]), "along": Vector2(q[0], q[1]), "at": f, "phase": _rng.float_range(0.0, TAU)})
					_beams.append(beam)
				bi += 1
	add_child(lamps.instance(_lamp_mat, false))

# A run of box truss from `a` to `b`, `size` square: a chord along each
# corner and a zigzag of lacing on all four faces.
static func _truss(a: Vector3, b: Vector3, size: float) -> Geo:
	var g := Geo.new()
	var dir := (b - a).normalized()
	var side := dir.cross(Vector3.UP).normalized() * (size / 2.0)
	var up := Vector3.UP * (size / 2.0)
	var corners := [side + up, side - up, -side - up, -side + up]
	for c in corners: g.append(RobotView._beam(a + c, b + c, 0.05, 0.05))
	var bays := maxi(1, int(round(a.distance_to(b) / size)))
	for i in bays:
		var p := a.lerp(b, float(i) / bays)
		var q := a.lerp(b, float(i + 1) / bays)
		for k in 4:
			var c0: Vector3 = corners[k]
			var c1: Vector3 = corners[(k + 1) % 4]
			# Each face's lacing leans the other way from bay to bay.
			if i % 2 == 0: g.append(RobotView._beam(p + c0, q + c1, 0.025, 0.025))
			else: g.append(RobotView._beam(p + c1, q + c0, 0.025, 0.025))
	return g

# What makes a can a stage lamp: cooling fins and a cap behind, barn doors
# round the lens, and the yoke it hangs by, with a clamp up to the truss at
# `hang`. `xf` is the lamp's frame: it shines along -Y.
static func _lamp_fittings(xf: Transform3D, hang: Vector3) -> Geo:
	var g := Geo.new()
	for y in [0.06, 0.13, 0.2]: g.append(Geo.cylinder(0.275, 0.275, 0.014, 12).translate(0, y, 0))
	g.append(Geo.cylinder(0.16, 0.2, 0.09, 12).translate(0, 0.29, 0))
	# Barn doors, each hinged on the rim and swung a little open.
	for k in 4:
		var door := Geo.box(0.34, 0.2, 0.012).translate(0, -0.1, 0).rotate_x(0.45).translate(0, -0.25, -0.25)
		g.append(door.rotate_y(k * PI / 2.0))
	# The yoke: an arm down each side from a bar across the back.
	for sx in [-0.31, 0.31]: g.append(Geo.box(0.025, 0.46, 0.07).translate(sx, 0.21, 0))
	g.append(Geo.box(0.645, 0.025, 0.07).translate(0, 0.44, 0))
	g.apply(xf)
	g.append(RobotView._beam(xf * Vector3(0, 0.44, 0), hang, 0.05, 0.05))
	return g

# A light beam: an open cone, additive, opening along -Z from its apex (so
# look_at aims it). Brightest where you look through the middle of it and
# gone at its outline, and thinning out close to the camera - a camera that
# stands in a beam (the Stands Cam) sees a glow, not a slab with an edge.
const BEAM_SHADER := "shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec3 tint : source_color = vec3(1.0);
uniform float strength = 0.02;
void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = tint;
	ALPHA = strength * 2.4 * facing * facing * smoothstep(2.0, 9.0, -VERTEX.z);
}
"

func _make_beam(color: Color, length: float) -> Dictionary:
	var g := Geo.cylinder(0.0, length * 0.28, length * 1.15, 20, true).translate(0, -length * 1.15 / 2.0, 0).rotate_x(PI / 2.0)
	if _beam_shader == null:
		_beam_shader = Shader.new()
		_beam_shader.code = BEAM_SHADER
	var m := ShaderMaterial.new()
	m.shader = _beam_shader
	m.set_shader_parameter("tint", color)
	m.set_shader_parameter("strength", 0.02)
	return {"node": g.instance(m, false), "mat": m, "color": color}

# ---------------------------------------------------------------- screens
# The venue, both robots and the clock, drawn in a small offscreen picture
# and redrawn only when the clock ticks over.
func _build_screens(b: ArenaView.Batch, names: Dictionary) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 288)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var bg := ColorRect.new()
	bg.color = Color.html("#07080b")
	bg.size = Vector2(512, 288)
	vp.add_child(bg)
	for y in [0, 280]:
		var bar := ColorRect.new()
		bar.color = _accent
		bar.position = Vector2(0, y)
		bar.size = Vector2(512, 8)
		vp.add_child(bar)
	var title := UI.label(str(venue.get("name", "")).to_upper(), {"kind": "cond", "size": 22, "weight": 700, "color": Color("9aa3b2"), "align": "center", "clip": true})
	title.position = Vector2(20, 14)
	title.size = Vector2(472, 30)
	vp.add_child(title)
	var corner_names := [str(names.get("red", "RED")).to_upper(), str(names.get("blue", "BLUE")).to_upper()]
	for i in 2:
		var box := ColorRect.new()
		box.color = Color.html("#d8343a") if i == 0 else Color.html("#2a83d8")
		box.position = Vector2(16 + i * 250, 60)
		box.size = Vector2(230, 92)
		vp.add_child(box)
		var n: String = corner_names[i]
		var l := UI.label(n, {"kind": "cond", "size": clampi(int(380.0 / maxf(1.0, n.length())), 14, 30), "weight": 700, "color": Color.WHITE, "align": "center", "clip": true})
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.position = Vector2(4, 0)
		l.size = Vector2(222, 92)
		box.add_child(l)
	var clock := UI.label("3:00", {"kind": "display", "size": 96, "weight": 700, "color": Color.WHITE, "align": "center"})
	clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clock.position = Vector2(0, 160)
	clock.size = Vector2(512, 116)
	vp.add_child(clock)
	add_child(vp)
	var face := StandardMaterial3D.new()
	face.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	face.albedo_texture = vp.get_texture()
	face.disable_fog = true
	_board = {"vp": vp, "clock": clock, "mat": face}

	var sc: Dictionary = venue.get("screens", {})
	var frame := _mat(Color.html("#111215"), 0.5, 0.5)
	var top: Dictionary = _tiers[_tiers.size() - 1]
	if sc.get("kind") == "scoreboard":
		var w := 7.0
		var h := 3.5
		_add_screen(b, self, frame, w, h, Vector3(0, minf(_hh - h, _deck_bottom + top.v1 + 4.2), -_hz + 0.6), 0.0)
	if sc.get("kind") == "ends" or J.truthy(sc.get("ends")):
		var w := 12.0
		var h := 6.0
		var y := minf(maxf(_deck_bottom + top.v1 + 4.5, U.ft_to_m(20.0)), _hh - h / 2.0 - 1.0)
		_add_screen(b, self, frame, w, h, Vector3(-_hx + 0.6, y, 0), PI / 2.0)
		_add_screen(b, self, frame, w, h, Vector3(_hx - 0.6, y, 0), -PI / 2.0)
	if sc.get("kind") == "centre":
		# Centre-hung, four-sided, clear above the overhead camera.
		var w := 7.5
		var h := 4.2
		var y := maxf(U.ft_to_m(56.0) + h / 2.0 + 0.5, minf(_hh - h, U.ft_to_m(66.0)))
		_cube = Node3D.new()
		_cube.position.y = y
		add_child(_cube)
		var cb := ArenaView.Batch.new()
		for i in 4:
			var yaw := i * PI / 2.0
			_add_screen(cb, _cube, frame, w, h, Vector3(sin(yaw) * (w / 2.0 + 0.2), 0, cos(yaw) * (w / 2.0 + 0.2)), yaw, 0.15)
		# Lit rings top and bottom in the venue's colour.
		for dy in [-h / 2.0 - 0.35, h / 2.0 + 0.35]:
			cb.add(_box(w + 0.9, 0.25, w + 0.9, 0, dy, 0), _mat(Color.html("#111111"), 0.5, 0.0, 1.6, _accent))
		cb.commit(_cube, false)
		b.add(_box(0.06, _hh - y, 0.06, 0, y + (_hh - y) / 2.0, 0), _mat(Color.html("#2a2c30"), 0.5, 0.6))

func _add_screen(b: ArenaView.Batch, parent: Node3D, frame: StandardMaterial3D, w: float, h: float, at: Vector3, yaw: float, pad := 0.2) -> void:
	b.add(_box(w + pad * 2.0, h + pad * 2.0, 0.3, 0, 0, 0, 0.0).rotate_y(yaw).translate(at.x, at.y, at.z), frame)
	# The picture: a quad just proud of the frame, facing +Z before the turn.
	var g := Geo.new()
	var n := Vector3(0, 0, 1)
	g.tri(Vector3(-w / 2.0, -h / 2.0, 0.16), Vector3(w / 2.0, -h / 2.0, 0.16), Vector3(w / 2.0, h / 2.0, 0.16), n, n, n, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0))
	g.tri(Vector3(-w / 2.0, -h / 2.0, 0.16), Vector3(w / 2.0, h / 2.0, 0.16), Vector3(-w / 2.0, h / 2.0, 0.16), n, n, n, Vector2(0, 1), Vector2(1, 0), Vector2(0, 0))
	g.rotate_y(yaw).translate(at.x, at.y, at.z)
	parent.add_child(g.instance(_board.mat, false))

# ---------------------------------------------------------------- banners
# Hung off the back walls above the top row, in the venue's colours.
func _build_banners(b: ArenaView.Batch) -> void:
	var cols: Array = venue.get("banners", [])
	if cols.is_empty(): return
	var top: Dictionary = _tiers[_tiers.size() - 1]
	var bh := 3.2
	var bw := 1.3
	for side in venue.stands.sides:
		if not SIDES.has(side): continue
		var turn := Transform3D(Basis(Vector3.UP, SIDES[side]), Vector3.ZERO)
		var off := _side_off(side)
		var i := 0
		var x := -_length / 2.0 + 2.0
		while x <= _length / 2.0 - 2.0:
			# A hanging banner with a swallowtail foot.
			var g := Geo.new()
			var n := Vector3(0, 0, -1)
			var pts := [Vector3(-bw / 2.0, 0, 0), Vector3(bw / 2.0, 0, 0), Vector3(bw / 2.0, -bh, 0), Vector3(0, -bh + bw * 0.45, 0), Vector3(-bw / 2.0, -bh, 0)]
			for tri in [[0, 1, 3], [1, 2, 3], [0, 3, 4]]: g.tri(pts[tri[0]], pts[tri[1]], pts[tri[2]], n, n, n)
			b.add(g.translate(x, top.v1 + 2.6, top.u1 + 0.05 + off).apply(turn), _mat(_col(cols[i % cols.size()]), 0.8, 0.0, 0.0, null, true))
			x += 4.5
			i += 1

# ---------------------------------------------------------------- pit gear
# What stands round a real box between the fights: crew stations on the
# walkway outside the safety line - a tool cart or chest, a barrel, a sack
# truck, an extinguisher - and gas bottles and shelving in the free corners.
# Authored models (CC0, Poly Haven - see assets/CREDITS.md), graphics tier 3.

const PROP_PATH := "res://assets/models/%s/%s_1k.gltf"
static var _props := {}

static func _prop(id: String) -> Node3D:
	if not _props.has(id):
		var path := PROP_PATH % [id, id]
		_props[id] = load(path) if ResourceLoader.exists(path) else null
	var scene: PackedScene = _props[id]
	return scene.instantiate() if scene != null else null

# One prop standing on the hall floor at (x, z), turned `yaw`.
func _place(id: String, x: float, z: float, yaw: float) -> void:
	var n := _prop(id)
	if n == null: return
	n.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(x, _deck_bottom, z))
	# Dressing, out in the dim of the hall: it costs no shadow pass.
	for mi in n.find_children("*", "GeometryInstance3D", true, false):
		(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(n)

func _build_pit_gear() -> void:
	# A station either side of the middle of each wall, backed up to where
	# the stands (or the hall) begin and facing the box.
	var kits := [
		[["tool_cart", 0.0, 0.0, 0.0], ["Barrel_01", 1.15, 0.1, 0.7], ["korean_fire_extinguisher_01", -0.95, -0.25, 0.3]],
		[["metal_tool_chest", 0.0, 0.0, 0.0], ["hand_truck", 1.0, 0.05, 2.6], ["korean_fire_extinguisher_01", -0.7, -0.2, -0.4]],
	]
	var k := 0
	for side in ["s", "e", "n", "w"]:
		var turn := Basis(Vector3.UP, SIDES[side])
		var half: float = _half_z if side == "s" or side == "n" else _half_x
		var along: float = _half_x if side == "s" or side == "n" else _half_z
		for f in [-0.62, 0.62]:
			var kit: Array = kits[k % kits.size()]
			k += 1
			for q in kit:
				# In the side's own frame: x along the wall, z out from the box.
				var p: Vector3 = turn * Vector3(f * along + q[1], 0, half + 3.3 + q[2])
				_place(q[0], p.x, p.z, SIDES[side] + PI + q[3] + _rng.float_range(-0.2, 0.2))
	# The free corners: gas for the flame jets, and a rack of spares.
	for c in [[-1.0, -1.0], [1.0, -1.0], [-1.0, 1.0], [1.0, 1.0]]:
		var at := Vector2(c[0] * (_half_x + 2.9), c[1] * (_half_z + 2.9))
		var yaw := atan2(-at.x, -at.y)
		if c[0] * c[1] > 0.0:
			_place("steel_frame_shelves_01", at.x, at.y, yaw)
		else:
			for i in 3: _place("propane_tank", at.x + (i - 1) * 0.42 * c[1], at.y + (i - 1) * 0.42 * c[0], yaw + i * 1.3)

# ---------------------------------------------------------------- extras

func _free_corner(sx: float, sz: float) -> Vector2:
	var gap := U.ft_to_m(venue.stands.gap)
	return Vector2(sx * (_half_x + gap + 1.5), sz * (_half_z + gap + 1.5))

func _build_extras(b: ArenaView.Batch) -> void:
	var extras: Array = venue.get("extras", [])
	var banners: Array = venue.get("banners", [])
	var db := _deck_bottom
	if extras.has("garageDoors"):
		var door := _mat(Color.html("#8a9096"), 0.6, 0.5)
		var rib := _mat(Color.html("#6c7277"), 0.6, 0.5)
		for sx in [-1.0, 1.0]:
			for z in [-_hz * 0.45, _hz * 0.45]:
				var x: float = sx * (_hx - 0.1)
				b.add(_box(0.15, 5.5, 6.0, x, db + 2.75, z), door)
				var y := 0.4
				while y < 5.5:
					b.add(_box(0.22, 0.06, 6.0, x, db + y, z), rib)
					y += 0.55
	if extras.has("crates"):
		var crate := _mat(Color.html("#7a5a36"), 0.9, 0.0)
		var pallet := _mat(Color.html("#5a4128"), 0.95, 0.0)
		for q in [[1, 1], [-1, -1], [1, -1]]:
			var c := _free_corner(q[0], q[1])
			for i in 4:
				var s := _rng.float_range(0.8, 1.3)
				var x := c.x + _rng.float_range(-1.5, 1.5)
				var z := c.y + _rng.float_range(-1.5, 1.5)
				b.add(_box(s, s, s, x, db + s / 2.0 + (1.1 if i == 3 else 0.0), z, _rng.float_range(0.0, PI)), pallet if i % 2 == 1 else crate)
	if extras.has("flags"):
		# A string of pennants across each corner, above head height.
		for q in [[-1, 1], [1, 1], [-1, -1], [1, -1]]:
			var c := _free_corner(q[0], q[1])
			for i in 8:
				var t := i / 7.0
				var col: Color = _col(banners[i % banners.size()]) if not banners.is_empty() else _accent
				b.add(Geo.cone(0.22, 0.5, 3).rotate_x(PI).translate(c.x - q[0] * 3.0 * (1.0 - t), U.ft_to_m(16.0) - sin(t * PI) * 0.6, c.y - q[1] * 3.0 * t), _mat(col, 0.8, 0.0))
	if extras.has("entranceTunnel"):
		# The robots' way in, in the south-east corner: a lit arch.
		var c := _free_corner(1, 1)
		var arch := _mat(Color.html("#1a1c20"), 0.4, 0.6)
		var glow := _mat(Color.html("#111111"), 0.5, 0.0, 2.0, _accent)
		var w := 4.5
		var h := 4.2
		var d := 3.0
		# Facing the box: local -Z toward the centre.
		var at := Vector3(c.x, 0, c.y)
		var zb := (at - Vector3.ZERO).normalized()
		var xf := Transform3D(Basis(Vector3.UP.cross(zb).normalized(), Vector3.UP, zb), at)
		for sx in [-1.0, 1.0]:
			b.add(_box(0.6, h, d, sx * (w / 2.0 + 0.3), db + h / 2.0, 0).apply(xf), arch)
			b.add(_box(0.1, h - 0.4, 0.1, sx * (w / 2.0 + 0.02), db + h / 2.0, -d / 2.0 - 0.02).apply(xf), glow)
		b.add(_box(w + 1.2, 0.9, d, 0, db + h + 0.45, 0).apply(xf), arch)
		b.add(_box(w + 0.2, 0.12, 0.1, 0, db + h - 0.02, -d / 2.0 - 0.02).apply(xf), glow)
		b.add(_box(w, h, 0.1, 0, db + h / 2.0, d * 0.5).apply(xf), _mat(Color.html("#050506"), 1.0, 0.0))
	var top: Dictionary = _tiers[_tiers.size() - 1]
	if extras.has("lightTowers"):
		var tower := _mat(Color.html("#2b2e34"), 0.4, 0.7)
		var heads := Geo.new()
		for q in [[-1, -1], [1, -1], [-1, 1], [1, 1]]:
			var r: float = top.u1 + 2.0
			var x: float = q[0] * r * 0.82
			var z: float = q[1] * r * 0.82
			var h := minf(_hh - 2.0, top.v1 + 9.0)
			b.add(_box(0.8, h - db, 0.8, x, (h + db) / 2.0, z), tower)
			var at := Vector3(x, h + 1.0, z)
			var zb := (Vector3.ZERO - at).normalized()
			var xb := Vector3.UP.cross(zb).normalized()
			var xf := Transform3D(Basis(xb, zb.cross(xb), zb), at)
			b.add(Geo.box(3.2, 2.0, 0.3).apply(xf), tower)
			for i in 6:
				heads.append(Geo.cylinder(0.32, 0.32, 0.02, 12).rotate_x(PI / 2.0).translate((i % 3 - 1) * 1.0, floorf(i / 3.0) * 0.9 - 0.45, 0.16).apply(xf))
		add_child(heads.instance(_lamp_mat, false))
	if extras.has("pyro"):
		# Flame cannons at the four corners of the box, outside the walls.
		var base := _mat(Color.html("#222326"), 0.4, 0.7)
		for q in [[-1, -1], [1, -1], [-1, 1], [1, 1]]:
			var x: float = q[0] * (_half_x + 2.2)
			var z: float = q[1] * (_half_z + 2.2)
			b.add(Geo.cylinder(0.35, 0.45, 0.8, 12).translate(x, db + 0.4, z), base)
			var parts := []
			for spec in [[0.55, 14, Color.html("#ff7a1a")], [0.28, 10, Color.html("#fff0b0")]]:
				var m := StandardMaterial3D.new()
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.albedo_color = Color(spec[2] * 2.0, 0.0)
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
				var mi := Geo.cylinder(0.0, spec[0], 1.0, spec[1], true).instance(m, false)
				mi.position = Vector3(x, db + 0.8, z)
				mi.visible = false
				add_child(mi)
				parts.append([mi, m])
			_pyros.append({"flame": parts[0][0], "fmat": parts[0][1], "core": parts[1][0], "cmat": parts[1][1], "t": 0.0})
	if extras.has("nutStatue"):
		# The trophy itself, ten times over, turning slowly on a plinth in
		# the north-west corner.
		var c := _free_corner(-1, -1)
		b.add(_box(5, 3, 5, c.x - 1.5, db + 1.5, c.y - 1.5), _mat(Color.html("#1a1420"), 0.5, 0.4))
		var R := 3.0
		var hexagon := PackedVector2Array()
		for i in 6: hexagon.append(Vector2(cos(i / 6.0 * TAU) * R, sin(i / 6.0 * TAU) * R))
		var hole := PackedVector2Array()
		for i in 32: hole.append(Vector2(cos(i / 32.0 * TAU) * R * 0.48, sin(i / 32.0 * TAU) * R * 0.48))
		var gold := StandardMaterial3D.new()
		gold.albedo_color = Color.html("#e0b02a")
		gold.metallic = 1.0
		gold.roughness = 0.22
		gold.emission_enabled = true
		gold.emission = Color.html("#3a2800")
		gold.emission_energy_multiplier = 0.6
		_nut = Geo.extrude(hexagon, 1.6, 0.12, [hole]).instance(gold, false)
		_nut.position = Vector3(c.x - 1.5, db + 3.0 + R + 0.2, c.y - 1.5)
		add_child(_nut)

# ---------------------------------------------------------------- reactions

## The crowd's excitement: a level that jumps on big moments and settles back
## to the venue's resting energy.
func react(level: float, pyro := false) -> void:
	_excite = maxf(_excite, _rest + level)
	_flash = maxf(_flash, minf(1.0, level))
	if pyro:
		for p in _pyros: p.t = 1.2

## Once per rendered frame. `bout` (optional) puts its clock on the screens.
func update(dt: float, bout: Match = null) -> void:
	_t += dt
	_excite += (_rest - _excite) * minf(1.0, dt * 0.55)
	_flash = maxf(0.0, _flash - dt * 1.6)
	if _crowd_mat != null:
		_crowd_mat.set_shader_parameter("u_time", _t)
		_crowd_mat.set_shader_parameter("u_excite", _excite)
		_crowd_mat.set_shader_parameter("u_glow", _glow * (1.0 + 1.2 * _flash))
	var t0: Dictionary = _tiers[0]
	for b in _beams:
		# Aim at a point in the stand behind the lamp, wandering along it.
		var reach: float = t0.u0 + (t0.u1 - t0.u0) * (0.45 + 0.3 * sin(_t * 0.37 + b.phase))
		var along: float = b.at * _length + sin(_t * 0.23 + b.phase * 2.0) * _length * 0.35
		var aim := Vector3(b.out.x * reach + b.along.x * along, t0.v0 + (t0.v1 - t0.v0) * 0.5, b.out.y * reach + b.along.y * along)
		(b.node as Node3D).look_at(aim, Vector3.UP)
		(b.mat as ShaderMaterial).set_shader_parameter("strength", 0.015 + 0.04 * _flash)
	for m in _ribbons: (m as StandardMaterial3D).emission_energy_multiplier = 1.2 + 1.6 * _flash * (0.5 + 0.5 * sin(_t * 18.0))
	_lamp_mat.emission_energy_multiplier = 2.2 + 1.5 * _flash
	for p in _pyros:
		p.t = maxf(0.0, p.t - dt)
		var on: bool = p.t > 0.0
		var jets: bool = gpu_fire != null and is_instance_valid(gpu_fire)
		p.flame.visible = on and not jets
		p.core.visible = on and not jets
		if not on: continue
		if jets:
			# A jet: fire thrown straight up, hard at first and dying back.
			var at: Vector3 = (p.flame as Node3D).position
			at.y = _deck_bottom + 0.9
			var push: float = minf(1.0, p.t / 0.35)
			p.owed = p.get("owed", 0.0) + dt * 90.0
			while p.owed >= 1.0:
				p.owed -= 1.0
				gpu_fire.flame(at + Vector3(randf() - 0.5, 0.0, randf() - 0.5) * 0.2, Vector3((randf() - 0.5) * 0.5, (7.0 + randf() * 5.0) * push + 1.0, (randf() - 0.5) * 0.5),
					0.45 + randf() * 0.35, 0.3 + randf() * 0.35, 0.9)
			continue
		var k: float = p.t / 1.2
		var h := 2.5 + 3.5 * sin(minf(1.0, (1.0 - k) * 4.0) * PI / 2.0) * (0.85 + 0.15 * sin(_t * 40.0))
		for part in [[p.flame, p.fmat, 1.0, 0.7], [p.core, p.cmat, 0.7, 0.9]]:
			var node: MeshInstance3D = part[0]
			var w: float = part[2]
			node.scale = Vector3(w, h * w, w)
			node.position.y = _deck_bottom + 0.8 + (h * w) / 2.0
			var mat: StandardMaterial3D = part[1]
			mat.albedo_color.a = minf(1.0, k * 2.0) * part[3]
	if _nut != null: _nut.rotate_y(dt * 0.25)
	if _cube != null: _cube.rotate_y(dt * 0.05)
	if bout != null and not _board.is_empty():
		var clock := int(ceil(bout.clockS))
		if clock != _last_clock or bout.phase != _last_phase:
			_last_clock = clock
			_last_phase = bout.phase
			var ended := bout.phase == Match.ENDED
			var l: Label = _board.clock
			l.text = "FINAL" if ended else U.format_clock(clock)
			l.add_theme_color_override("font_color", _accent if ended else Color.WHITE)
			(_board.vp as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
