## robot_view.gd - the robot's visuals, generated from its assembled build.
##
## No hand-modelled bots: the body is the convex pieces shape.gd sculpts (the
## same points physics collides with), painted with the robot's livery
## (livery.gd), and dressed in detailed wheels and weapons (parts.gd) sized
## from the part specs. A new bot in the roster gets a body for free, and the
## workshop previews a build with this exact builder.
##
## A robot file can tune the look without touching stats, in `body.look`:
##   { "teeth": 3, "shell": "drum", "rows": 3, "head": "sledge" }
##
## The view is a Node3D in the robot's own frame (x forward, y up): move it
## with sync(), or parent it wherever a robot should stand.
class_name RobotView
extends Node3D

const STEEL_LIKE := ["ar500_steel", "grade5_ti", "hardox", "steel"]

var assembled: Dictionary
var rig: RobotRig
var mats: Mats
## Meshes by fitting key ("armor.1", "weapon" ...), for damage visuals.
var panel_meshes := {}
## Objects by part key ("weapon", "wheel", "chassis", "armor.N"), so the
## workshop can pick parts with the mouse.
var part_objects := {}

var _classic := false
var _paint: StandardMaterial3D = null
var _paint_maps = null
var _body_bounds = null
var _body_mat: StandardMaterial3D
var _trim_mat: StandardMaterial3D
var _accent_mat: StandardMaterial3D
var _metal: StandardMaterial3D
var _dark: StandardMaterial3D
var _hub_mat: StandardMaterial3D
var _geo := {}                 # MeshInstance3D -> Geo (hull pieces, for dents)
var _state := {}               # MeshInstance3D -> { mat, base, rough, metal, paint }
var _weapon_geos := []         # [[Geo, Node3D]] - the weapon's own parts
var _wheel_nodes: Array[Node3D] = []
var _tyres: Array[MeshInstance3D] = []
var _spinner = null            # how the weapon moves (a Dictionary), or null
var _weapon_cond := 1.0
var _wheel_cond := 1.0
var _weapon_angle := 0.0
var _cond := {}                # fitting key -> condition, as last shown
var _smoke_at := {}
var _old_dents := {}
var _scars := {}               # MeshInstance3D -> { hits, heat, next }: where it was hit (the wear shader's)
var _cooling := false
var _rotor_mi: MeshInstance3D = null    # a spinner's rotor, and what stands in for it at speed
var _rotor_parent: Node3D = null
var _blur = null               # { solid, ghost } once the rotor has been measured
var _blur_key := ""
var _blur_lobes := 2
var _blur_asked := false
var _blur_b := 0.0
var _blur_phase := 0.0

func _init(assembled_robot: Dictionary, robot_rig: RobotRig = null, materials: Mats = null) -> void:
	assembled = assembled_robot
	rig = robot_rig if robot_rig != null else RobotRig.at_rest(assembled)
	mats = materials if materials != null else Mats.shared()
	name = "robot_%s" % str(assembled.id).validate_node_name()
	_build()

static func _is_hull(piece: Dictionary) -> bool:
	var id: String = piece.id
	return id == "core" or id == "chin" or id.begins_with("cheek:") or id.begins_with("body:") or id.begins_with("plate:") or id.begins_with("armor:")

func _seed_of(key: String) -> float:
	return Rng.hash_seed("%s:%s" % [assembled.id, key]) / 4294967296.0

func _material_for(piece: Dictionary, fitting_key) -> StandardMaterial3D:
	# Wedges, forks and plows: the working steel, kept bright like the weapons.
	if piece.role == "metal": return mats.lib.ar500_steel if _classic else _metal
	if piece.role == "trim": return _trim_mat
	if piece.role == "accent": return _accent_mat
	if piece.role == "armor":
		var material = null
		for f in assembled.fittings:
			if f.key == fitting_key:
				material = J.path(f, ["part", "spec", "material"])
				break
		# The test bots keep their raw-material look (steel front, white UHMW).
		if _classic: return mats.by_name(material) if material != null else _body_mat
		if piece.slot == "front" and material != null and STEEL_LIKE.has(material): return mats.by_name(material)
		if _paint != null: return _paint
		if piece.slot == "rear": return _trim_mat
		return _body_mat
	if _paint != null: return _paint
	return _body_mat if _classic else _trim_mat     # the core, mostly under its plates

func _tag(obj: Node, key: String) -> void:
	obj.set_meta("partKey", key)
	if not part_objects.has(key): part_objects[key] = []
	part_objects[key].append(obj)

func _resolve(k: String) -> StandardMaterial3D:
	match k:
		"hub": return _hub_mat
		"dark": return _dark
		"accent": return _accent_mat
		"trim": return _trim_mat
		"paint": return _paint if _paint != null else _body_mat
		"paintFlat": return _body_mat
		"saw": return mats.lib.sawBlade
	return _metal

# One mesh for a list of [{ geo, mat }] parts: a surface per material.
func _add_parts(parent: Node3D, parts: Array, weapon := false) -> MeshInstance3D:
	var by_mat := {}
	var order := []
	for p in parts:
		var mat := _resolve(p.mat) if p.mat is String else (p.mat as StandardMaterial3D)
		if not by_mat.has(mat):
			by_mat[mat] = Geo.new()
			order.append(mat)
		by_mat[mat].append(p.geo)
	var mesh := ArrayMesh.new()
	var all := Geo.new()
	for mat in order:
		by_mat[mat].add_to(mesh, mat)
		all.append(by_mat[mat])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	parent.add_child(mi)
	if weapon: _weapon_geos.append([all, mi])
	return mi

func _one(parent: Node3D, geo: Geo, mat: StandardMaterial3D, weapon := false) -> MeshInstance3D:
	return _add_parts(parent, [{"geo": geo, "mat": mat}], weapon)

func _group(parent: Node3D, at := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n

func _build() -> void:
	var livery: Dictionary = assembled.livery if assembled.get("livery") is Dictionary else {}
	var look: Dictionary = J.path(assembled, ["def", "body", "look"], {})
	_body_mat = mats.livery(J.g(livery, "primary", "#b8babf"))
	_trim_mat = mats.livery(J.g(livery, "secondary", "#202227"))
	_accent_mat = mats.livery(J.g(livery, "accent", "#f0c419"))
	_metal = mats.lib.weaponSteelFine
	_dark = mats.lib.robotDarkFine
	_hub_mat = mats.lib.hubFine

	# ---- body: every convex piece of the robot's shape (logic/shape.gd),
	# drawn from the same hull points the physics collides with.
	var shape: Dictionary = rig.shape
	_classic = shape.template == "classic"
	var hull_points := []
	for p in shape.pieces:
		if _is_hull(p): hull_points.append_array(p.points)
	if not _classic:
		_body_bounds = Hull.bounds(hull_points)
		# Plain primary colour until the paint shop has drawn the picture.
		_paint = mats.robot_paint(CanvasRec.css(J.g(livery, "primary", "#b8babf")))

	for piece in shape.pieces:
		var key = rig.routes.get(piece.id)
		var mat := _material_for(piece, key)
		var geo := Parts.hull_geometry(piece.points, _body_bounds if is_same(mat, _paint) and _paint != null else null)
		var mi := geo.instance(mat)
		add_child(mi)
		mi.set_meta("hull", true)        # its faces are in the paint's own picture already
		_geo[mi] = geo
		var is_weapon: bool = piece.slot == "weapon" or str(piece.id).begins_with("weapon:")
		_tag(mi, "weapon" if is_weapon else (key if key != null else "chassis"))
		# Armour and weapon pieces dent and darken as their fitting takes damage.
		if key != null and key != "chassis" and piece.id != "core":
			if not panel_meshes.has(key): panel_meshes[key] = []
			panel_meshes[key].append(mi)

	var L: float = assembled.dims.lengthM
	var H: float = assembled.dims.heightM
	var W: float = assembled.dims.widthM
	if _classic:
		# Accent stripe down the spine, so rotation is readable at a glance.
		_one(self, Geo.box(L * 0.98, H * 0.18, W * 0.12).translate(0, H / 2.0 + 0.001, 0), _accent_mat)
		# Front marker: you must be able to tell which way a wedge is pointing.
		_one(self, Geo.box(0.02, H * 0.5, W * 0.5).translate(L / 2.0 + 0.002, H * 0.15, 0), _accent_mat)
	else:
		# The power light every bot on the show must carry, high on the tail.
		for p in shape.pieces:
			if p.id != "core": continue
			var tail := INF
			for q in p.points: tail = minf(tail, q.x)
			var tail_top := -INF
			for q in p.points:
				if q.x < tail + 0.02: tail_top = maxf(tail_top, q.y)
			var lamp := _one(self, Geo.box(0.012, 0.016, 0.03).translate(tail - 0.012, tail_top - 0.025, 0), mats.lib.powerLight)
			lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			break

	_build_weapon(shape, look, hull_points)

	# ---- wheels. Placed every frame from suspension telemetry.
	var r: float = assembled.stats.wheelRadiusM
	var wheel_w := U.in_to_m(assembled.parts.wheel.spec.widthIn)
	var wg := Parts.wheel_geometries(r, wheel_w)
	var tyre_mesh: ArrayMesh = wg.tyre.to_mesh(mats.lib.rubber)
	var rest_mesh := ArrayMesh.new()
	# Spokes and a coloured cap, so wheel spin is visible.
	wg.hub.add_to(rest_mesh, _hub_mat)
	wg.spokes.add_to(rest_mesh, _dark)
	wg.cap.add_to(rest_mesh, _accent_mat)
	for i in rig.wheels.size():
		var w := _group(self)
		var tyre := MeshInstance3D.new()
		tyre.mesh = tyre_mesh
		w.add_child(tyre)
		var rest := MeshInstance3D.new()
		rest.mesh = rest_mesh
		w.add_child(rest)
		_tag(w, "wheel")
		_wheel_nodes.append(w)
		_tyres.append(tyre)

	_build_carriers(r, wheel_w)

	# Where the insides would smoke from, in the robot's own frame.
	var wv = J.path(shape, ["weapon", "visual"])
	_smoke_at = {
		"motor": Vector3(-L * 0.22, H * 0.55, W * 0.18),
		"drive": Vector3(-L * 0.22, H * 0.5, -W * 0.18),
		"battery": Vector3(-L * 0.05, H * 0.6, 0),
		"electronics": Vector3(L * 0.05, H * 0.6, 0),
		"weaponMotor": Vector3(L * 0.2, H * 0.55, 0),
	}
	if wv is Dictionary and wv.get("center") is Vector3:
		_smoke_at.weaponMotor = Vector3(wv.center.x * 0.6, maxf(H * 0.5, wv.center.y), 0)

	update_wheels()
	if _paint != null: _order_paint(livery, shape)

# ---- what carries the wheels. Every wheel is on an axle out of the body's
# side. Where the body is narrower than the track at that wheel - a dart's
# nose, a round body inside its wheelbase - a pair of arms reaches out from
# the body to a hub carrier, as an open-wheeled car's do, so no wheel hangs in
# the air beside it. Arms that would cross a horizontal spinner's sweep step
# over it instead (or under, if there is no body up there to start from).
func _build_carriers(r: float, wheel_w: float) -> void:
	# The body, as the planes of its pieces: how far out it reaches beside a wheel.
	var solids := []
	for p in rig.shape.pieces:
		if not _is_hull(p): continue
		var planes := []
		for f in Hull.convex_faces(p.points).faces: planes.append([f.n, f.d])
		if not planes.is_empty(): solids.append(planes)
	if solids.is_empty(): return
	# The body's side at (x, y) on side s: its distance from the centreline, 0 if none.
	var reach := func(x: float, y: float, s: float) -> float:
		var best := 0.0
		for planes in solids:
			var lo := -INF
			var hi := INF
			for pl in planes:
				var n: Vector3 = pl[0]
				var rest: float = pl[1] - n.x * x - n.y * y
				if absf(n.z) < 1e-9:
					if rest < 0.0:
						lo = INF
						break
				elif n.z > 0.0: hi = minf(hi, rest / n.z)
				else: lo = maxf(lo, rest / n.z)
			# (A piece too thin to have faces on both sides bounds nothing.)
			if lo <= hi and lo > -INF and hi < INF: best = maxf(best, hi if s > 0.0 else -lo)
		return best
	var wv = J.path(rig.shape, ["weapon", "visual"])
	var sweep = wv if (wv is Dictionary and wv.get("kind") == "rotor" and wv.get("axis") == "y") else null
	# Whether the straight line a-b passes through the spinner's sweep.
	var swept := func(a: Vector3, b: Vector3) -> bool:
		if sweep == null: return false
		var c: Vector3 = sweep.center
		for k in 9:
			var q := a.lerp(b, k / 8.0)
			if absf(q.y - c.y) < sweep.thickness / 2.0 + 0.012 and Vector2(q.x - c.x, q.z - c.z).length() < sweep.radius + 0.015: return true
		return false
	var drop: float = rig.rest_length * (1.0 - rig.preload_frac)
	var ground: float = rig.shape.groundY
	var arms := Geo.new()
	var hubs := Geo.new()
	for wh in rig.wheels:
		var c: Vector3 = wh.anchor - Vector3(0, drop, 0)
		var s := signf(c.z)
		var face := absf(c.z) - wheel_w / 2.0
		# The height to leave the body at: the axle's, or the nearest the body
		# has at this wheel (a low nose is all below it).
		var ya := NAN
		for k in 17:
			var y: float = c.y + (((k + 1) / 2) * 0.012) * (-1.0 if k % 2 == 1 else 1.0)
			if reach.call(c.x, y, s) > 0.02:
				ya = y
				break
		if is_nan(ya): continue
		var side: float = reach.call(c.x, ya, s)
		# The axle: out of the body (or the hub carrier) into the wheel.
		var inner := maxf(side - 0.012, 0.0)
		var carried: bool = face - side > 0.014 or absf(ya - c.y) > 0.02
		if carried: inner = face - 0.02
		hubs.append(Geo.cylinder(r * 0.15, r * 0.15, absf(c.z) - inner, 12).rotate_x(PI / 2.0).translate(c.x, c.y, s * (absf(c.z) + inner) / 2.0))
		if not carried: continue
		var d := clampf(r * 0.55, 0.03, 0.06)
		var hub_z := face - 0.012
		hubs.append(Geo.box(d * 1.3, r * 0.5, 0.014).translate(c.x, c.y, s * hub_z))
		# Over the sweep, under it, or straight across.
		var probe_a := Vector3(c.x, ya, s * side)
		var probe_b := Vector3(c.x, c.y, s * hub_z)
		var via := NAN
		if swept.call(probe_a, probe_b):
			var over: float = sweep.center.y + sweep.thickness / 2.0 + 0.03
			var under: float = sweep.center.y - sweep.thickness / 2.0 - 0.03
			if reach.call(c.x, over, s) > 0.02: via = over
			elif under > ground + 0.015 and reach.call(c.x, under, s) > 0.02: via = under
		for k in [-1.0, 1.0]:
			var end := Vector3(c.x + k * d * 0.45, c.y, s * hub_z)
			var y0: float = ya if is_nan(via) else via
			var xb: float = c.x + k * d * 1.5
			var out: float = reach.call(xb, y0, s)
			if out <= 0.02:
				xb = c.x
				out = reach.call(xb, y0, s)
			var start := Vector3(xb, y0, s * maxf(out - 0.012, 0.0))
			if is_nan(via): arms.append(_beam(start, end))
			else:
				# Out level past the sweep, then down (or up) to the hub.
				var elbow := Vector3(end.x, via, end.z)
				arms.append(_beam(start, elbow))
				arms.append(_beam(elbow, end))
	if arms.count() == 0 and hubs.count() == 0: return
	var parts := []
	if arms.count() > 0: parts.append({"geo": arms, "mat": "dark"})
	if hubs.count() > 0: parts.append({"geo": hubs, "mat": "hub"})
	_tag(_add_parts(self, parts), "wheel")

# A box beam from a to b.
static func _beam(a: Vector3, b: Vector3, w := 0.018, h := 0.026) -> Geo:
	var along := b - a
	var l := along.length()
	if l < 1e-5: return Geo.new()
	var x := along / l
	var z := x.cross(Vector3.UP)
	if z.length_squared() < 1e-6: z = Vector3.BACK
	z = z.normalized()
	return Geo.box(l + w, h, w).apply(Transform3D(Basis(x, z.cross(x), z), (a + b) / 2.0))

func _build_weapon(shape: Dictionary, look: Dictionary, hull_points: Array) -> void:
	# ---- the weapon, from the shape's description of it: built from the
	# same numbers the colliders are.
	var wv = J.path(shape, ["weapon", "visual"])
	if not (wv is Dictionary): return
	var weapon_id: String = str(J.path(assembled, ["parts", "weapon", "id"], ""))
	if wv.kind == "rotor":
		var hub := _group(self, wv.center)
		var r: float = wv.radius
		var t: float = wv.thickness
		# Built about local Y; a lateral axle is then a quarter turn about X.
		var tilt := _group(hub)
		if wv.axis == "z": tilt.rotation.x = PI / 2.0
		var rotor := _group(tilt)
		var parts: Array
		var style: String = wv.style
		if style == "bar":
			# At rest a bar lies ACROSS the front, the way it is parked in the box.
			if wv.axis == "y": rotor.rotation.y = PI / 2.0
			parts = Parts.bar_rotor(r, t, maxf(0.05, r * 0.22))
		elif style == "tri":
			parts = Parts.tri_rotor(r, t)
		elif style == "shell":
			# The shell covers the whole robot: find the body under it, in the
			# rotor's frame, so it can wrap over without cutting in.
			var ys := PackedFloat64Array()
			var rads := PackedFloat64Array()
			var top_y := -INF
			for q in hull_points:
				ys.append(q.y - wv.center.y)
				rads.append(Vector2(q.x - wv.center.x, q.z - wv.center.z).length())
				top_y = maxf(top_y, q.y - wv.center.y)
			top_y += 0.015
			# Radius of the body's hull at height y, from above: interpolating
			# the radial distance between any point below y and any above it
			# bounds the hull's cross-section.
			var body_radius := func(y: float) -> float:
				var m := 0.0
				for a in ys.size():
					if ys[a] > y: continue
					for c in ys.size():
						if ys[c] < y: continue
						var k := (y - ys[a]) / (ys[c] - ys[a]) if ys[c] - ys[a] > 1e-6 else 0.0
						m = maxf(m, rads[a] + (rads[c] - rads[a]) * k)
				return m
			parts = Parts.shell_rotor(r, t, J.g(look, "shell", "dome"), int(J.g(look, "teeth", 2)), top_y, body_radius)
		elif style == "eggbeater":
			parts = Parts.eggbeater_rotor(r, t)
		elif style == "drum":
			parts = Parts.drum_rotor(r, t, look.get("rows"), int(J.g(look, "teeth", 2)))
		else:
			# The collider is the full width the disc may occupy; the disc
			# itself is a slimmer plate in the middle of it, as real ones are.
			var plate := minf(t, maxf(0.022, r * 0.12))
			parts = Parts.disc_rotor(r, plate, int(J.g(look, "teeth", 2 if r > 0.2 else 3)))
		_rotor_mi = _add_parts(rotor, parts, true)
		_rotor_parent = tilt
		_blur_key = "%s|%s|%s|%.4f|%.4f|%s" % [assembled.id, weapon_id, style, r, t, J.to_json(look)]
		_blur_lobes = 2 if (style == "bar" or style == "eggbeater") else (3 if style == "tri" else int(J.g(look, "teeth", 2)))
		_tag(hub, "weapon")
		# What the rotor turns on: a disc or drum's axle across its two
		# supports (with a bearing cap on each), a bar's shaft up through its
		# bearing plates. Fixed to the hub, so it does not spin.
		if wv.get("axle") is Dictionary:
			var ax: Dictionary = wv.axle
			var fixed := [{"geo": Parts.cyl(ax.radius, ax.radius, ax.halfLen * 2.0, 16).rotate_x(PI / 2.0), "mat": "hub"}]
			for s in [-1.0, 1.0]:
				fixed.append({"geo": Parts.cyl(ax.bossR * 0.72, ax.bossR * 0.72, 0.01, 18).rotate_x(PI / 2.0).translate(0, 0, s * (ax.halfLen + 0.001)), "mat": "hub"})
				fixed.append({"geo": Geo.cylinder(ax.radius * 1.5, ax.radius * 1.5, 0.014, 6).rotate_x(PI / 2.0).translate(0, 0, s * (ax.halfLen + 0.008)), "mat": "dark"})
			_add_parts(hub, fixed, true)
		if wv.get("shaft") is Dictionary:
			var sh: Dictionary = wv.shaft
			var length: float = sh.y1 - sh.y0
			_add_parts(hub, [{"geo": Parts.cyl(sh.r, sh.r, length, 16).translate(0, (sh.y0 + sh.y1) / 2.0 - wv.center.y, 0), "mat": "hub"}], true)
		# Spin about the rotor's own axis (local Y of the inner group).
		_spinner = {"axis": "y", "mesh": rotor, "hub": hub, "angle": rotor.rotation.y}
	elif wv.kind == "arm":
		# Arm and head, swinging about the pivot.
		var arm := _group(self, wv.pivot)
		var style: String = look.head if look.get("head") != null else wv.style
		if look.get("head") == null and style == "axe" and weapon_id.contains("sledge"): style = "sledge"
		_add_parts(arm, Parts.arm_parts(wv.reach, wv.head, style), true)
		_tag(arm, "weapon")
		_spinner = {"axis": "swing", "mesh": arm, "hub": arm, "z": 0.0, "bend": 0.0}
	elif wv.kind == "plate" or wv.kind == "jaw":
		# Flipper, lifter or crusher. The collider is the whole working zone in
		# front of the nose; what is drawn is the mechanism inside it: a flat
		# plate or forks at the floor, and for a crusher an arched beak that
		# comes down over it from the top of the body.
		var plate := _group(self, wv.center)
		var floor_y: float = -wv.size.h / 2.0 + 0.002
		var l: float = wv.size.l
		var w: float = wv.size.w
		var floor_part := _group(plate, Vector3(0, floor_y, 0))
		if wv.style == "lifter" or wv.style == "clamp" or wv.kind == "jaw":
			# Twin forks.
			var forks := []
			for zs in [-1.0, 1.0]:
				forks.append({"geo": Parts.fork_geometry(l, w * 0.22).translate(0, 0.013, zs * w * 0.3), "mat": "steel"})
			_add_parts(floor_part, forks, true)
		else:
			floor_part.rotation.z = -0.08
			_add_parts(floor_part, Parts.flipper_plate(l, w), true)
		if wv.kind == "jaw":
			# The beak, hinged at the top of the body behind the nose.
			var pivot := Vector2(-l * 0.5 - 0.08, wv.top + 0.03 - wv.center.y)
			var beak := _group(plate, Vector3(pivot.x, pivot.y, 0))
			var reach := l * 0.85 - pivot.x
			var drop := pivot.y - floor_y - 0.04
			var bits := []
			if wv.style == "claw":
				for zs in [-1.0, 1.0]:
					bits.append({"geo": Parts.beak_geometry(reach, drop, maxf(0.03, w * 0.1)).translate(0, 0, zs * w * 0.3), "mat": "steel"})
			else:
				bits.append({"geo": Parts.beak_geometry(reach, drop, maxf(0.05, w * 0.3)), "mat": "steel"})
			bits.append({"geo": Parts.cyl(0.03, 0.03, w * 0.5, 14).rotate_x(PI / 2.0), "mat": "hub"})
			_add_parts(beak, bits, true)
			_spinner = {"axis": "jaw", "mesh": beak, "rest": 0.35, "z": 0.0}
		elif J.truthy(wv.get("lid")) and not _classic:
			# A lid flipper: the plate covers the top, hinged at the back.
			var lid_len: float = wv.center.x - wv.hingeX
			var lid := _group(plate, Vector3(wv.hingeX - wv.center.x, wv.top + 0.012 - wv.center.y, 0))
			_add_parts(lid, Parts.lid_parts(lid_len, wv.size.w), true)
			_spinner = {"axis": "flip", "mesh": lid, "z": 0.0}
		else:
			_spinner = {"axis": "lift", "mesh": floor_part, "base": floor_part.position.y}
		_tag(plate, "weapon")

# The transform from `node`'s frame to the robot's, whether or not the view
# is in the scene yet.
func _to_body(node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != self:
		if n is Node3D: t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

# The paint job, last, once everything that could hide it is built: it is
# told which faces wear the paint, where the wheels sit and what the weapon
# covers, so the name lands on a flat panel it fits (livery.gd).
func _order_paint(livery: Dictionary, shape: Dictionary) -> void:
	var def = assembled.get("def")
	var key := "%s|%d|%s" % [assembled.id, hash(J.to_json(def) if def != null else str(assembled.id)), "m" if Parts.mobile else "d"]
	PaintShop.shared().request(key, _plan_paint.bind(livery, shape), _on_paint)

func _plan_paint(livery: Dictionary, shape: Dictionary) -> Dictionary:
	var faces := []
	for pi in shape.pieces.size():
		var piece: Dictionary = shape.pieces[pi]
		var uses_paint := is_same(_material_for(piece, rig.routes.get(piece.id)), _paint)
		var cf := Hull.convex_faces(piece.points)
		for f in cf.faces:
			var ring := []
			for i in f.ring: ring.append(cf.points[i])
			faces.append({"n": f.n, "ring": ring, "paint": uses_paint, "piece": pi})
	var wheel_r: float = assembled.stats.wheelRadiusM
	var wheel_w := U.in_to_m(assembled.parts.wheel.spec.widthIn) if assembled.parts.get("wheel") != null else 0.0
	var wheels := []
	if wheel_w > 0.0:
		for i in rig.wheels.size():
			var anchor := rig.wheel_anchor(i)
			var drop: float = rig.rest_length * (1.0 - rig.telemetry[i].compression)
			wheels.append({"x": anchor.x, "y": anchor.y - drop, "z": anchor.z, "r": wheel_r, "w": wheel_w})
	# The weapon's own parts (arms, uprights, rotors), as triangles in body space.
	var tris := PackedVector3Array()
	for pair in _weapon_geos:
		var geo: Geo = pair[0]
		var xf := _to_body(pair[1])
		for p in geo.pos: tris.append(xf * p)
	var name_text = assembled.get("name")
	if name_text == null: name_text = J.path(assembled, ["def", "name"], "")
	return Livery.paint({
		"id": assembled.id, "name": name_text, "livery": livery, "template": shape.template,
		"bounds": _body_bounds, "relief": 0.5 if Parts.mobile else 1.0, "faces": faces, "wheels": wheels,
		"blockers": [tris] if not tris.is_empty() else [],
	})

func _on_paint(maps: Dictionary) -> void:
	if _paint == null or maps.get("color") == null: return
	_paint_maps = maps
	mats.set_paint_maps(_paint, maps)
	# Panels that have already darkened wear their own copy of the paint.
	for mi in _state:
		var st: Dictionary = _state[mi]
		if not st.paint: continue
		if st.fx:
			RobotFx.copy_look(st.mat, _paint)
			continue
		mats.set_paint_maps(st.mat, maps)
		st.base = Color.WHITE
		st.rough = 1.0 if maps.get("finish") != null else st.rough
		st.metal = 1.0 if maps.get("finish") != null else st.metal
	for key in _cond.keys():
		if _cond[key] < 0.999: set_panel_condition(key, _cond[key])

# ---------------------------------------------------------------- per frame

## Stand the robot at a body pose (from physics, or a recorded replay frame)
## and hang its wheels from the suspension.
func sync(xf: Transform3D) -> void:
	transform = xf
	update_wheels()

## Used by the replay camera, which drives the view from recorded poses.
func set_pose(pos: Vector3, quat: Quaternion) -> void:
	transform = Transform3D(Basis(quat), pos)

func update_wheels() -> void:
	for i in _wheel_nodes.size():
		var node := _wheel_nodes[i]
		var anchor := rig.wheel_anchor(i)
		var tele: Dictionary = rig.telemetry[i]
		# Wheel centre hangs `restLength - compression` below its mount - or
		# above it, when an invertible bot is running on its back.
		var drop: float = rig.rest_length * (1.0 - (tele.compression if tele.grounded else 0.0))
		node.position = Vector3(anchor.x, anchor.y + (drop if rig.inverted else -drop), anchor.z)
		# A damaged wheel runs out of true.
		var wobble := (0.5 - _wheel_cond) * 0.35 * sin(tele.spin + i) if _wheel_cond < 0.5 else 0.0
		node.rotation = Vector3(wobble, 0.0, -tele.spin)

## Drive the weapon mesh from the live weapon state (logic/weapon.gd).
func update_weapon(weapon: Weapon, dt: float) -> void:
	if _spinner == null or weapon == null: return
	var sp: Dictionary = _spinner
	match sp.axis:
		"y":
			# Visible rotation is capped well below the real rim speed: a bar
			# doing 350 rad/s at 60 fps turns ~5.8 rad per frame, which just
			# strobes into a blur going the wrong way.
			var visual := minf(weapon.omegaRadS, 42.0)
			sp.angle += visual * dt
			sp.mesh.rotation.y = sp.angle
			_update_blur(weapon.omegaRadS, dt)
			# A bent rotor wobbles on its shaft; a dead one sits crooked.
			if _weapon_cond < 0.7:
				_weapon_angle += visual * dt
				var tilt := 0.0 if _weapon_cond <= 0.001 else (0.7 - _weapon_cond) * 0.22
				var droop := 0.22 if _weapon_cond <= 0.001 else 0.0
				sp.hub.rotation = Vector3(tilt * sin(_weapon_angle), 0.0, tilt * cos(_weapon_angle) + droop)
		"swing":
			# Hammers slam and reset, so follow the phase rather than a speed.
			var target := -1.35 if weapon.phase == "striking" else (0.1 if weapon.phase == "reloading" else 0.45)
			sp.z += (target - sp.z) * minf(1.0, dt * 14.0)
			sp.mesh.rotation = Vector3(0.0, sp.bend, sp.z)
		"flip":
			# A lid flipper kicks up about its hinge and drops back.
			var target := 0.9 if weapon.phase == "striking" else 0.0
			sp.z += (target - sp.z) * minf(1.0, dt * 18.0)
			sp.mesh.rotation.z = sp.z
		"lift":
			# Forks and plates rise when fired.
			var up := 0.12 if weapon.phase == "striking" else 0.0
			sp.mesh.position.y += (sp.base + up - sp.mesh.position.y) * minf(1.0, dt * 14.0)
		"jaw":
			var closed := weapon.phase == "closed" or weapon.phase == "striking"
			var target: float = 0.0 if closed else sp.rest
			sp.z += (target - sp.z) * minf(1.0, dt * 6.0)
			sp.mesh.rotation.z = sp.z

# A rotor at speed is a blur (robot_fx.gd): its own mesh fades out and the
# two surfaces measured from it stand in - solid where it fills the turn,
# see-through where the blades and teeth sweep.
func _update_blur(omega: float, dt: float) -> void:
	if _rotor_mi == null: return
	var b := smoothstep(RobotFx.BLUR_FROM, RobotFx.BLUR_FULL, omega) if (RobotFx.blur_on and _weapon_cond > 0.001) else 0.0
	if b > 0.0 and _blur == null and not _blur_asked and is_inside_tree():
		_blur_asked = true
		RobotFx.measure(_blur_key, self, _rotor_mi.mesh as ArrayMesh, _on_rotor_measured)
	if _blur == null or (b <= 0.0 and _blur_b <= 0.0): return
	_blur_b = b
	_rotor_mi.transparency = b if b < 0.995 else 0.0
	_rotor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if b >= 0.995 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if _blur.solid != null: (_blur.solid as MeshInstance3D).visible = b > 0.5
	if _blur.ghost != null:
		var ghost: MeshInstance3D = _blur.ghost
		ghost.visible = b > 0.0
		_blur_phase = fmod(_blur_phase + dt * 2.6, TAU)
		var m: ShaderMaterial = ghost.mesh.surface_get_material(0)
		m.set_shader_parameter("fade", b)
		m.set_shader_parameter("phase", _blur_phase)

func _on_rotor_measured(profile: Dictionary) -> void:
	if _blur != null or _rotor_mi == null or not is_instance_valid(_rotor_parent): return
	var materials := []
	for s in _rotor_mi.mesh.get_surface_count(): materials.append(_rotor_mi.mesh.surface_get_material(s))
	_blur = RobotFx.build_blur(profile, materials, _blur_lobes)
	for part in [_blur.solid, _blur.ghost]:
		if part == null: continue
		(part as MeshInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_rotor_parent.add_child(part)

# ---------------------------------------------------------------- damage

## Dent a fitting's pieces at a world-space point.
func dent(fitting_key: String, world_point: Vector3, depth := 0.012) -> void:
	for mi in panel_meshes.get(fitting_key, []):
		_dent_mesh(mi, world_point, depth)
		_scar_at(mi, world_point, 0.05 + depth * 4.0, 1.0)

# Where a panel was hit, for the wear shader: scraped bright there, and hot
# for a second. A panel keeps its last few.
func _scar_at(mi: MeshInstance3D, world_point: Vector3, radius: float, hot: float) -> void:
	var to_world := (global_transform if is_inside_tree() else transform) * _to_body(mi)
	var local := to_world.affine_inverse() * world_point
	if not mi.mesh.get_aabb().grow(radius * 0.6).has_point(local): return
	if not _scars.has(mi):
		var fresh_hits := PackedVector4Array()
		var fresh_heat := PackedFloat32Array()
		fresh_hits.resize(RobotFx.MAX_SCARS)
		fresh_heat.resize(RobotFx.MAX_SCARS)
		_scars[mi] = {"hits": fresh_hits, "heat": fresh_heat, "next": 0}
	var sc: Dictionary = _scars[mi]
	# In the panel's space as built: a panel hanging loose has been re-centred.
	var pivot: Vector3 = mi.get_meta("pivot", Vector3.ZERO)
	var hits: PackedVector4Array = sc.hits
	var heat: PackedFloat32Array = sc.heat
	hits[sc.next] = Vector4(local.x + pivot.x, local.y + pivot.y, local.z + pivot.z, radius)
	heat[sc.next] = hot
	sc.hits = hits
	sc.heat = heat
	sc.next = (sc.next + 1) % RobotFx.MAX_SCARS
	if hot > 0.0: _cooling = true
	_show_scars(mi)

func _show_scars(mi: MeshInstance3D) -> void:
	var st = _state.get(mi)
	if st == null or not st.fx: return
	var m: ShaderMaterial = st.mat
	m.set_shader_parameter("origin", mi.get_meta("pivot", Vector3.ZERO))
	var sc = _scars.get(mi)
	if sc == null: return
	m.set_shader_parameter("hits", sc.hits)
	m.set_shader_parameter("heat", sc.heat)

## Once a frame: what was just hit cools.
func update_fx(dt: float) -> void:
	if not _cooling: return
	_cooling = false
	var k := exp(-dt / 0.5)
	for mi in _scars:
		var sc: Dictionary = _scars[mi]
		var heat: PackedFloat32Array = sc.heat
		var any := false
		for i in heat.size():
			if heat[i] <= 0.0: continue
			heat[i] = heat[i] * k if heat[i] > 0.02 else 0.0
			any = true
		if not any: continue
		sc.heat = heat
		_cooling = true
		var st = _state.get(mi)
		if st != null and st.fx: (st.mat as ShaderMaterial).set_shader_parameter("heat", heat)

## The Settings changed: every damaged panel is shown again, its new way.
func refresh_fx() -> void:
	for key in _cond.keys(): set_panel_condition(key, _cond[key])

# Push vertices in around a point, so a bot that has taken a beating visibly
# carries it. Cheap: a hull piece has few enough vertices that this is a
# handful of distance checks.
func _dent_mesh(mi: MeshInstance3D, world_point: Vector3, depth: float) -> void:
	var geo: Geo = _geo.get(mi)
	if geo == null: return
	var to_world := (global_transform if is_inside_tree() else transform) * _to_body(mi)
	var local := to_world.affine_inverse() * world_point
	var radius := 0.09
	var touched := false
	for i in geo.pos.size():
		var v := geo.pos[i]
		var d := v.distance_to(local)
		if d > radius: continue
		# Falls off smoothly from the impact point.
		var k := (1.0 - d / radius) * depth
		var length := v.length()
		if length < 1e-9: length = 1.0
		geo.pos[i] = v - (v / length) * k
		touched = true
	if not touched: return
	geo.creased_normals()
	var mat := mi.mesh.surface_get_material(0)
	var mesh := mi.mesh as ArrayMesh
	mesh.clear_surfaces()
	geo.add_to(mesh, mat)

# A badly beaten panel comes loose: it hangs off at an angle about its own
# middle (the geometry is re-centred once so it can turn there).
func _loosen(mi: MeshInstance3D, key: String, t: float) -> void:
	if not key.begins_with("armor."): return
	if t >= 0.35 or t <= 0.001:
		if mi.has_meta("pivot"): mi.rotation = Vector3.ZERO
		return
	if not mi.has_meta("pivot"):
		var geo: Geo = _geo.get(mi)
		if geo == null: return
		var c := geo.bounds().get_center()
		geo.translate(-c.x, -c.y, -c.z)
		var mat := mi.mesh.surface_get_material(0)
		(mi.mesh as ArrayMesh).clear_surfaces()
		geo.add_to(mi.mesh, mat)
		mi.position += c
		mi.set_meta("pivot", c)
		_show_scars(mi)
	var k := (0.35 - t) / 0.35
	var s := _seed_of(key)
	mi.rotation = Vector3((s - 0.5) * 0.5 * k, 0.0, (-1.0 if s < 0.5 else 1.0) * (0.12 + 0.18 * k))

## Darken a fitting's pieces as its condition falls, so damage reads at a glance.
func set_panel_condition(fitting_key: String, condition: float) -> void:
	var t := clampf(condition, 0.0, 1.0)
	for mi in panel_meshes.get(fitting_key, []):
		# As built and never hit: the panel's own material, shared, as it came.
		var pristine: bool = t >= 0.999 and not _scars.has(mi)
		if _state.has(mi) and (pristine or _state[mi].fx != RobotFx.wear_on):
			mi.material_override = null
			_state.erase(mi)
		if not pristine:
			if not _state.has(mi):
				var src: StandardMaterial3D = mi.mesh.surface_get_material(0)
				if RobotFx.wear_on:
					# Its own copy as the wear shader: chipped, sooty, scraped where hit.
					var worn := RobotFx.wear_material(src, _seed_of("%s:%d" % [fitting_key, mi.get_index()]))
					mi.material_override = worn
					_state[mi] = {"mat": worn, "fx": true, "paint": is_same(src, _paint)}
					_show_scars(mi)
				else:
					var copy: StandardMaterial3D = src.duplicate()
					mi.material_override = copy
					_state[mi] = {"mat": copy, "fx": false, "base": copy.albedo_color, "rough": copy.roughness, "metal": copy.metallic, "paint": is_same(src, _paint)}
			var st: Dictionary = _state[mi]
			if st.fx:
				(st.mat as ShaderMaterial).set_shader_parameter("wear", 1.0 - t)
			else:
				var own: StandardMaterial3D = st.mat
				var k := 0.42 + 0.58 * t
				own.albedo_color = Color(st.base.r * k, st.base.g * k, st.base.b * k, st.base.a)
				# Scorched and scuffed: duller as it goes.
				own.roughness = minf(1.0, st.rough + (1.0 - t) * 0.35)
				own.metallic = st.metal * (0.6 + 0.4 * t)
		mi.visible = t > 0.001
		_loosen(mi, fitting_key, t)
	_cond[fitting_key] = condition
	if fitting_key == "weapon":
		_weapon_cond = condition
		if _spinner != null:
			if _weapon_cond >= 0.7 and _spinner.axis == "y": _spinner.hub.rotation = Vector3.ZERO
			# A hammer or axe arm bends sideways.
			if _spinner.axis == "swing":
				_spinner.bend = (0.6 - condition) * 0.5 * (-1.0 if _seed_of("arm") < 0.5 else 1.0) if condition < 0.6 else 0.0
				_spinner.mesh.rotation.y = _spinner.bend
	if fitting_key == "wheel":
		_wheel_cond = condition
		# A wheel gone altogether: one corner runs on its hub.
		if not _tyres.is_empty(): _tyres[0].visible = condition > 0.001

## Back to as-built looks (a rematch starts from scratch, then re-applies
## what it carried in).
func reset_condition() -> void:
	_scars.clear()
	var keys := {"weapon": true, "wheel": true}
	for k in panel_meshes: keys[k] = true
	for k in _cond: keys[k] = true
	for k in keys: set_panel_condition(k, 1.0)

## Show a robot's damage all at once - what it carries in from its last
## fight: dents where it was hit, darkened and loose panels, a bent weapon,
## and smoke from what is hurt inside.
func apply_condition(condition: Dictionary) -> void:
	for key in condition:
		var c: float = condition[key]
		if c >= 0.999: continue
		set_panel_condition(key, c)
		# Old dents: a few, placed by the fitting so they are the same every time.
		if c < 0.9 and c > 0.001:
			for mi in panel_meshes.get(key, []):
				var geo: Geo = _geo.get(mi)
				if geo == null or geo.pos.is_empty() or _old_dents.has(mi): continue
				_old_dents[mi] = true
				var to_world := (global_transform if is_inside_tree() else transform) * _to_body(mi)
				for d in int(ceil((1.0 - c) * 5.0)):
					var v := int(floor(_seed_of("%s:%d" % [key, d]) * geo.pos.size()))
					var at: Vector3 = to_world * geo.pos[v]
					_dent_mesh(mi, at, 0.006 + (1.0 - c) * 0.01)
					_scar_at(mi, at, 0.06 + (1.0 - c) * 0.05, 0.0)

## Where this robot is smoking (or burning) from right now, in world space:
## [{ key, pos, rate 0..1, fire, sparks }]. effects.gd turns them into smoke.
func damage_sources() -> Array:
	var out := []
	var xf := global_transform if is_inside_tree() else transform
	for key in _smoke_at:
		if not _cond.has(key): continue
		var c: float = _cond[key]
		if c >= 0.5: continue
		out.append({"key": key, "pos": xf * _smoke_at[key], "rate": minf(1.0, (0.5 - c) * 2.2 + 0.15),
			"fire": key == "battery" and c < 0.22, "sparks": key == "electronics" and c < 0.3})
	return out

## Which part a ray hits ("weapon", "wheel", "chassis", "armor.N"), or "" -
## the workshop's mouse picking. The ray is in world space.
func pick(from: Vector3, dir: Vector3) -> String:
	var best := INF
	var hit := ""
	var world := global_transform if is_inside_tree() else transform
	for key in part_objects:
		for obj in part_objects[key]:
			for mi in _meshes_under(obj):
				var inv := (world * _to_body(mi)).affine_inverse()
				var o := inv * from
				var d := (inv.basis * dir).normalized()
				var faces := (mi.mesh as ArrayMesh).get_faces()
				for t in range(0, faces.size(), 3):
					var p = Geometry3D.ray_intersects_triangle(o, d, faces[t], faces[t + 1], faces[t + 2])
					if p == null: continue
					var dist: float = (p as Vector3).distance_to(o)
					if dist < best:
						best = dist
						hit = key
	return hit

func _meshes_under(obj: Node) -> Array:
	var out := []
	if obj is MeshInstance3D and (obj as MeshInstance3D).visible: out.append(obj)
	for c in obj.get_children(): out.append_array(_meshes_under(c))
	return out
