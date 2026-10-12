## arena_view.gd - the arena's visuals, mirrored from the physics pieces.
##
## ArenaWorld returns a `pieces` list describing every static body in metres.
## The meshes are built straight from that list, so the picture can never
## drift out of sync with the collision geometry.
##
## The one deliberate departure: the floor is DRAWN with a slit cut into it
## for each killsaw, while the physics floor stays a solid slab. The stowed
## blades then sit visibly down in the deck under a cover plate, the way they
## do in the real box, without giving bots a hole to fall into.
class_name ArenaView
extends Node3D

# Width of the hazard-striped frames round a killsaw's cover and round the pit.
const SAW_RIM := 0.17
const PIT_RIM := 0.2

var arena: Dictionary
var world: ArenaWorld
var hazards: Hazards
var mats: Mats

var _half_x := 7.3
var _half_z := 7.3
var _wall_h := 2.4
var _cutaway := []             # [{ node, kind, sides, solid }] - what clears out of an outside camera's way
var _ghosts := {}              # material -> its see-through twin
var _cut_key := ""
var _hazard_nodes := {}        # "<hazardId>:<part>" -> Node3D
var _pit_lamps := []           # [{ h, mat }]
var _lamp_t := 0.0

# Geometry gathered by material and drawn as one mesh.
class Batch:
	var by_mat := {}
	var order := []
	func add(geo: Geo, mat: Material) -> void:
		if not by_mat.has(mat):
			by_mat[mat] = Geo.new()
			order.append(mat)
		by_mat[mat].append(geo)
	func commit(parent: Node3D, shadows := true) -> MeshInstance3D:
		var mesh := ArrayMesh.new()
		for mat in order: by_mat[mat].add_to(mesh, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		if not shadows: mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		return mi

func _init(arena_doc: Dictionary, arena_world: ArenaWorld, hazard_set: Hazards, materials: Mats) -> void:
	name = "ArenaView"
	arena = arena_doc
	world = arena_world
	hazards = hazard_set
	mats = materials
	_half_x = world.dims.halfX
	_half_z = world.dims.halfZ
	_wall_h = world.dims.wallH
	_build()

# Decals painted on the deck: flat colour, a hair above it.
static func _decal(color: Color, alpha := 1.0, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	m.roughness = rough
	m.metallic = metal
	if alpha < 1.0: m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# A flat rectangle in the XZ plane facing up, centred on (x, z).
static func _flat(w: float, l: float, x: float, y: float, z: float) -> Geo:
	var g := Geo.new()
	var a := Vector3(x - w / 2.0, y, z - l / 2.0)
	var b := Vector3(x - w / 2.0, y, z + l / 2.0)
	var c := Vector3(x + w / 2.0, y, z + l / 2.0)
	var d := Vector3(x + w / 2.0, y, z - l / 2.0)
	var up := Vector3.UP
	g.tri(a, b, c, up, up, up, Vector2(0, 0), Vector2(0, 1), Vector2(1, 1))
	g.tri(a, c, d, up, up, up, Vector2(0, 0), Vector2(1, 1), Vector2(1, 0))
	return g

# A flat plate (Rect2 in x, z) facing up at height y with rectangular holes
# cut in it: split into a grid along every hole edge, the cells inside a hole
# left out. UVs run 0..1 across the plate.
static func _plate(rect: Rect2, holes: Array, y: float) -> Geo:
	var xs := {rect.position.x: true, rect.end.x: true}
	var zs := {rect.position.y: true, rect.end.y: true}
	for h in holes:
		var r: Rect2 = h
		for x in [r.position.x, r.end.x]:
			if x > rect.position.x and x < rect.end.x: xs[x] = true
		for z in [r.position.y, r.end.y]:
			if z > rect.position.y and z < rect.end.y: zs[z] = true
	var xk := xs.keys()
	xk.sort()
	var zk := zs.keys()
	zk.sort()
	var g := Geo.new()
	var up := Vector3.UP
	for i in range(xk.size() - 1):
		for j in range(zk.size() - 1):
			var x0: float = xk[i]
			var x1: float = xk[i + 1]
			var z0: float = zk[j]
			var z1: float = zk[j + 1]
			var mid := Vector2((x0 + x1) / 2.0, (z0 + z1) / 2.0)
			var cut := false
			for h in holes:
				if (h as Rect2).has_point(mid): cut = true
			if cut: continue
			var u0 := (x0 - rect.position.x) / rect.size.x
			var u1 := (x1 - rect.position.x) / rect.size.x
			var v0 := (z0 - rect.position.y) / rect.size.y
			var v1 := (z1 - rect.position.y) / rect.size.y
			g.tri(Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), up, up, up, Vector2(u0, v0), Vector2(u0, v1), Vector2(u1, v1))
			g.tri(Vector3(x0, y, z0), Vector3(x1, y, z1), Vector3(x1, y, z0), up, up, up, Vector2(u0, v0), Vector2(u1, v1), Vector2(u1, v0))
	return g

static func _box_at(size: Vector3, xf: Transform3D) -> Geo:
	return Geo.box(size.x, size.y, size.z).apply(xf)

static func _at(x: float, y: float, z: float, basis := Basis.IDENTITY) -> Transform3D:
	return Transform3D(basis, Vector3(x, y, z))

# Width of a killsaw's cover plate (and its hazard-striped frame).
static func _saw_cover_width(p: Dictionary) -> float:
	return p.bladeSpacing * (p.bladeCount - 1) + p.bladeThickness * 6.0 + 0.12

# The slits in a killsaw's cover, one per blade, in slot-local X. Each has to
# be as long as the widest chord its blade cuts through the deck, which is at
# full height.
static func _saw_slits(p: Dictionary) -> Array:
	var r: float = p.bladeRadius
	var up: float = minf(J.g(p, "deployedHeight", r), r)
	var chord_half := sqrt(maxf(0.0, r * r - (r - up) * (r - up)))
	var out := []
	for i in int(p.bladeCount):
		out.append({"x": (i - (p.bladeCount - 1) / 2.0) * p.bladeSpacing, "w": p.bladeThickness + 0.04,
			"l": minf(p.slotLength - 0.08, chord_half * 2.0 + 0.06)})
	return out

# A world rectangle (w along local X, l along local Z, yawed) as its bounds.
static func _yawed_rect(cx: float, cz: float, w: float, l: float, yaw: float) -> Rect2:
	var b := Phys.yaw_basis(yaw)
	var r := Rect2(Vector2(cx, cz), Vector2.ZERO)
	for c in [Vector3(-w / 2.0, 0, -l / 2.0), Vector3(w / 2.0, 0, -l / 2.0), Vector3(w / 2.0, 0, l / 2.0), Vector3(-w / 2.0, 0, l / 2.0)]:
		var p: Vector3 = b * c
		r = r.expand(Vector2(cx + p.x, cz + p.z))
	return r

func _build() -> void:
	var solid := Batch.new()       # everything fixed that casts a shadow
	var flat := Batch.new()        # decals and plates on the deck

	# Holes to cut into the drawn deck. The killsaw slits, and the pits (which
	# go right through; the hole is lined by the pitWall pieces and closed by
	# the moving panel).
	var holes := []
	var tub_mat: StandardMaterial3D = mats.lib.darkSteel.duplicate()
	tub_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	for h in hazards.all:
		if h.type != "killsaw": continue
		var p: Dictionary = h.pieces[0]
		for slit in _saw_slits(p):
			# The slit's centre, from slot-local X into the world.
			var c: Vector3 = Phys.yaw_basis(p.yaw) * Vector3(slit.x, 0, 0)
			var cx: float = p.pos.x + c.x
			var cz: float = p.pos.z + c.z
			holes.append(_yawed_rect(cx, cz, slit.w, slit.l, p.yaw))
			# An open-topped steel tub under each slit, a hair inside the
			# hole so its walls do not fight the deck's cut edges.
			var depth := 0.35
			solid.add(_box_at(Vector3(slit.w - 0.02, depth, slit.l - 0.02), _at(cx, -depth / 2.0 - 0.001, cz, Phys.yaw_basis(p.yaw))), tub_mat)
	for r in world.pits:
		holes.append(Rect2(r.cx - r.hw, r.cz - r.hl, r.hw * 2.0, r.hl * 2.0))

	# ---- static pieces straight from the physics description
	for p in world.pieces:
		if p.kind == "floor":
			var deck := _plate(Rect2(-_half_x, -_half_z, _half_x * 2.0, _half_z * 2.0), holes, 0.0)
			var mi := MeshInstance3D.new()
			var deck_mesh := ArrayMesh.new()
			deck.add_to(deck_mesh, mats.lib.steelFloor, true)
			mi.mesh = deck_mesh
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			continue
		# Mapped once across each panel, not tiled by the metre.
		var geo: Geo = Geo.box(p.size.x, p.size.y, p.size.z).face_uvs().apply(p.xf)
		if p.kind == "lexan":
			var mi := geo.instance(mats.lib.polycarbonate, false)
			add_child(mi)
			_cutaway.append({"node": mi, "kind": "lexan", "sides": [p.side], "solid": mats.lib.polycarbonate})
		elif p.kind == "lip":
			# The lip along the top of a wall clears out of the camera's way too.
			var mi := geo.instance(mats.lib.darkSteel)
			add_child(mi)
			_cutaway.append({"node": mi, "kind": "lip", "sides": [p.side], "solid": mats.lib.darkSteel})
		else:
			solid.add(geo, mats.lib.steel if p.kind == "kickplate" else mats.lib.darkSteel)

	# ---- wall framing: uprights at the panel joints, for a built look
	var post_step := _half_x / 2.0
	for i in range(-2, 3):
		var spots := [Vector2(i * post_step, -_half_z - 0.3), Vector2(i * post_step, _half_z + 0.3)]
		# Not mid-wall on the east and west walls: that is dead on the line
		# from the corner camera and the chase cam at the start to the robots.
		if i != 0:
			spots.append(Vector2(-_half_x - 0.3, i * post_step))
			spots.append(Vector2(_half_x + 0.3, i * post_step))
		for s in spots:
			var mi := Geo.box(0.12, _wall_h, 0.12).translate(s.x, _wall_h / 2.0, s.y).instance(mats.lib.darkSteel)
			add_child(mi)
			# A corner post is on two walls.
			var sx: float = s.x * 1.01 if absf(s.x) >= _half_x - 1e-6 else s.x
			var sides := []
			if s.y < -_half_z: sides.append("north")
			if s.y > _half_z: sides.append("south")
			if sx < -_half_x: sides.append("west")
			if sx > _half_x: sides.append("east")
			_cutaway.append({"node": mi, "kind": "post", "sides": sides, "solid": mats.lib.darkSteel})

	# ---- floor markings, after the toy BattleBox and the real deck: a big
	# red and blue starting square on each side and a yellow line round the floor.
	# Where a layout puts a killsaw or the pit in a starting square, the paint
	# stops at its frame: two flat things at one height flicker through each other.
	var plates := []
	for h in hazards.all:
		var p: Dictionary = h.pieces[0]
		if h.type == "killsaw":
			plates.append(_yawed_rect(p.pos.x, p.pos.z, _saw_cover_width(p) + SAW_RIM * 2.0, p.slotLength + SAW_RIM * 2.0, p.yaw))
		elif h.type == "pit":
			plates.append(Rect2(p.pos.x - p.hw - PIT_RIM, p.pos.z - p.hl - PIT_RIM, (p.hw + PIT_RIM) * 2.0, (p.hl + PIT_RIM) * 2.0))
	var square := U.ft_to_m(8.0)
	for s in arena.spawns:
		var at := Vector2(U.ft_to_m(s.pos[0]), U.ft_to_m(s.pos[2]))
		flat.add(_plate(Rect2(at.x - square / 2.0, at.y - square / 2.0, square, square), plates, 0.002),
			_decal(Color.html("#b31c22") if s.id == "red" else Color.html("#1f8fd0"), 0.82))
	var line_in := U.ft_to_m(20.6)
	var line_w := U.ft_to_m(0.35)
	var yellow := _decal(Color.html("#d8b21a"))
	for q in [
		[line_in * 2.0 + line_w, line_w, 0.0, -line_in], [line_in * 2.0 + line_w, line_w, 0.0, line_in],
		[line_w, line_in * 2.0 - line_w, -line_in, 0.0], [line_w, line_in * 2.0 - line_w, line_in, 0.0],
	]:
		flat.add(_flat(q[0], q[1], q[2], 0.002, q[3]), yellow)

	# ---- hazards. Built from the hazard `pieces` description; the moving
	# parts copy their transforms from physics each frame in update().
	for h in hazards.all:
		# Every type needs an explicit branch: a hazard that cannot be drawn
		# should cost its own mesh and nothing else.
		match h.type:
			"screw": _build_screw(h, solid)
			"killsaw": _build_killsaw(h, solid, flat)
			"pulverizer", "hammer": _build_swinger(h, solid)
			"pit": _build_pit(h, flat)
			_: push_warning("[arena_view] no visuals for hazard \"%s\" of type \"%s\"" % [h.id, h.type])

	_build_spikes(solid)
	solid.commit(self)
	flat.commit(self, false)
	update(0.0)

# ---------------------------------------------------------------- screws
# A pair of augers - shaft plus a raised helical flight - standing proud of
# the deck, half-sunk in a steel cradle that runs back to the kickplate.
func _build_screw(h: Hazards.Hazard, solid: Batch) -> void:
	var p: Dictionary = h.pieces[0]
	var shaft_r: float = p.radius * 0.42
	for a in p.augers:
		# Cylinders run along local Y; the body's own rotation lays it down
		# and spins it, so nothing is tilted here.
		var b := Batch.new()
		b.add(Geo.cylinder(shaft_r, shaft_r, p.length, 20), mats.lib.darkSteel)
		b.add(_helicoid(shaft_r * 0.9, p.radius, p.length * 0.97, p.radius * 1.5, a.hand), mats.lib.augerFlight)
		for end in [-1.0, 1.0]:
			b.add(Geo.cylinder(shaft_r * 1.5, shaft_r * 1.5, 0.05, 16).translate(0, end * (p.length / 2.0 - 0.02), 0), mats.lib.steel)
		_hazard_nodes["%s:%s" % [h.id, a.part]] = b.commit(self)
	var cradle = null
	for x in h.pieces:
		if x.kind == "screwCradle": cradle = x
	if cradle == null: return
	# The cradle, straight from its physics box. Built in the unit's own
	# frame: X across (toward the wall is p.toWall), Z along the wall.
	var cw: float = cradle.size.x
	var ch: float = cradle.size.y
	var cl: float = cradle.size.z
	var unit := Transform3D(Phys.yaw_basis(cradle.yaw), Vector3(cradle.pos.x, 0, cradle.pos.z))
	solid.add(Geo.box(cw, ch, cl).translate(0, ch / 2.0, 0).apply(unit), mats.lib.darkSteel)
	# Hazard-striped face on the arena side, and a lip along its top edge, so
	# it reads as a hazard from anywhere in the box.
	var face_x: float = -p.toWall * (cw / 2.0 + 0.006)
	solid.add(Geo.box(0.012, ch * 0.92, cl * 0.995).translate(face_x, ch * 0.5, 0).apply(unit), mats.lib.hazardStripe)
	solid.add(Geo.box(0.06, 0.03, cl).translate(-p.toWall * (cw / 2.0 - 0.03), ch + 0.015, 0).apply(unit), mats.lib.steel)
	# Bearing blocks the shafts turn in, at each end - solid in physics too.
	var eb: Dictionary = cradle.endBlock
	for end in [-1.0, 1.0]:
		solid.add(Geo.box(cw, eb.height, eb.depth).translate(0, ch + eb.height / 2.0, end * eb.offset).apply(unit), mats.lib.steel)
		solid.add(Geo.box(cw * 1.01, 0.05, eb.depth * 1.02).translate(0, ch + eb.height - 0.025, end * eb.offset).apply(unit), mats.lib.hazardStripe)

# A helical auger flight: a ribbon wound round the shaft from r_inner to
# r_outer, running along local Y. `hand` is +1/-1 for right/left-handed.
static func _helicoid(r_inner: float, r_outer: float, length: float, pitch: float, hand: float) -> Geo:
	var turns := length / pitch
	var segs := maxi(24, int(round(turns * 28.0)))
	var g := Geo.new()
	var prev_i := Vector3.ZERO
	var prev_o := Vector3.ZERO
	for i in range(segs + 1):
		var u := float(i) / segs
		var y := -length / 2.0 + u * length
		var a := hand * u * turns * TAU
		var pi := Vector3(cos(a) * r_inner, y, sin(a) * r_inner)
		var po := Vector3(cos(a) * r_outer, y, sin(a) * r_outer)
		if i > 0:
			var n := (prev_o - prev_i).cross(pi - prev_i).normalized()
			g.tri(prev_i, prev_o, pi, n, n, n, Vector2(0, u), Vector2(1, u), Vector2(0, u))
			g.tri(prev_o, po, pi, n, n, n, Vector2(1, u), Vector2(1, u), Vector2(0, u))
		prev_i = pi
		prev_o = po
	return g.tile_uvs()

# ---------------------------------------------------------------- pulverizers
# A steel pedestal rising off the deck in the corner, cheek plates carrying
# the hinge, and a sledgehammer arm that stands up and slams forward.
func _build_swinger(h: Hazards.Hazard, solid: Batch) -> void:
	var arm = null
	var head = null
	var pivot = null
	var base = null
	for p in h.pieces:
		match p.kind:
			"swingerArm": arm = p
			"swingerHead": head = p
			"swingerPivot": pivot = p
			"swingerBase": base = p
	if arm == null or head == null or pivot == null or base == null:
		push_warning("[arena_view] hazard \"%s\" is missing swinger pieces; drawing nothing for it" % h.id)
		return
	var mount := Transform3D(pivot.basis, Vector3(pivot.pos.x, 0, pivot.pos.z))
	var pivot_y: float = pivot.pos.y
	var bw: float = base.size.x
	var bh: float = base.size.y
	var bd: float = base.size.z
	# Deck plate the whole unit is bolted to.
	solid.add(Geo.box(bw * 1.5, 0.04, bd * 1.9).translate(0, 0.02, -bd * 0.25).apply(mount), mats.lib.steel)
	# Pedestal, with a hazard band round its top edge.
	solid.add(Geo.box(bw, bh * 0.82, bd).translate(0, bh * 0.41, 0).apply(mount), mats.lib.darkSteel)
	solid.add(Geo.box(bw * 1.01, bh * 0.18, bd * 1.01).translate(0, bh * 0.91, 0).apply(mount), mats.lib.hazardStripe)
	# Cheek plates either side of the arm, up past the hinge.
	var arm_w: float = arm.thickness[0]
	var cheek_h := pivot_y - bh + 0.22
	for side in [-1.0, 1.0]:
		solid.add(Geo.box(0.07, cheek_h, bd * 0.7).translate(side * (arm_w / 2.0 + 0.06), bh + cheek_h / 2.0 - 0.01, 0).apply(mount), mats.lib.steel)
	# The hinge pin through all of it.
	solid.add(Geo.cylinder(0.07, 0.07, arm_w + 0.34, 16).rotate_z(PI / 2.0).translate(0, pivot_y, 0).apply(mount), mats.lib.steel)
	# Actuator housing behind the hinge, toward the corner.
	solid.add(Geo.cylinder(0.11, 0.11, bh * 0.9, 16).rotate_x(PI / 2.0 - 0.5).translate(0, bh * 0.75, -bd * 0.55).apply(mount), mats.lib.steel)

	# ---- the moving part: arm + head, posed from physics every frame.
	var b := Batch.new()
	b.add(Geo.box(arm.thickness[0], arm.length, arm.thickness[1]).translate(0, -arm.length / 2.0, 0), mats.lib.darkSteel)
	# Head: steel block, hazard stripes on its flanks, a thicker striking
	# plate on the face that hits the floor (local -Z).
	var hs: Vector3 = head.size
	var hl: Vector3 = head.local
	var block := Geo.box(hs.x, hs.y, hs.z)
	var flanks := Geo.new()
	var rest := Geo.new()
	for t in range(0, block.pos.size(), 3):
		var into := flanks if absf(block.nrm[t].x) > 0.9 else rest
		into.tri(block.pos[t], block.pos[t + 1], block.pos[t + 2], block.nrm[t], block.nrm[t + 1], block.nrm[t + 2], block.uv[t], block.uv[t + 1], block.uv[t + 2])
	b.add(flanks.translate(hl.x, hl.y, hl.z), mats.lib.hazardStripe)
	b.add(rest.translate(hl.x, hl.y, hl.z), mats.lib.steel)
	b.add(Geo.box(hs.x * 1.06, hs.y * 1.06, 0.06).translate(hl.x, hl.y, hl.z - hs.z / 2.0 + 0.025), mats.lib.steel)
	_hazard_nodes["%s:arm" % h.id] = b.commit(self)

# ---------------------------------------------------------------- pit
# A hazard-striped frame round the hole, a ring of warning lamps that flash
# before it drops, and the deck panel itself, posed from physics.
func _build_pit(h: Hazards.Hazard, flat: Batch) -> void:
	var p: Dictionary = h.pieces[0]
	var rim := PIT_RIM
	var at := Transform3D(Basis.IDENTITY, Vector3(p.pos.x, 0, p.pos.z))
	for q in [
		[p.hw * 2.0 + rim * 2.0, rim, 0.0, -p.hl - rim / 2.0], [p.hw * 2.0 + rim * 2.0, rim, 0.0, p.hl + rim / 2.0],
		[rim, p.hl * 2.0, -p.hw - rim / 2.0, 0.0], [rim, p.hl * 2.0, p.hw + rim / 2.0, 0.0],
	]:
		flat.add(Geo.box(q[0], 0.012, q[1]).translate(q[2], 0, q[3]).apply(at), mats.lib.hazardStripe)
	# Lamps: little domes along each edge of the frame.
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = Color.html("#401010")
	lamp_mat.roughness = 0.4
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color.html("#ff3020")
	lamp_mat.emission_energy_multiplier = 0.0
	var dome_prof := []
	for i in range(7): dome_prof.append(Vector2(cos(i / 6.0 * PI / 2.0) * 0.06, sin(i / 6.0 * PI / 2.0) * 0.06))
	var lamps := Geo.new()
	var per := 4
	for i in per:
		var f := (i + 0.5) / per - 0.5
		for s in [Vector2(f * p.hw * 2.0, -p.hl - rim / 2.0), Vector2(f * p.hw * 2.0, p.hl + rim / 2.0), Vector2(-p.hw - rim / 2.0, f * p.hl * 2.0), Vector2(p.hw + rim / 2.0, f * p.hl * 2.0)]:
			lamps.append(Geo.lathe(dome_prof, 10).translate(p.pos.x + s.x, 0.006, p.pos.z + s.y))
	add_child(lamps.instance(lamp_mat, false))
	_pit_lamps.append({"h": h, "mat": lamp_mat})

	# The panel: deck steel with a striped border, so it reads as a trapdoor.
	var b := Batch.new()
	b.add(Geo.box(p.hw * 2.0 - 0.01, p.lidT, p.hl * 2.0 - 0.01), mats.lib.steelFloor)
	var band := 0.12
	var yellow := _decal(Color.html("#d8b21a"))
	for q in [
		[p.hw * 2.0 - 0.01, band, 0.0, -p.hl + band / 2.0], [p.hw * 2.0 - 0.01, band, 0.0, p.hl - band / 2.0],
		[band, p.hl * 2.0 - band * 2.0, -p.hw + band / 2.0, 0.0], [band, p.hl * 2.0 - band * 2.0, p.hw - band / 2.0, 0.0],
	]:
		b.add(_flat(q[0], q[1], q[2], p.lidT / 2.0 + 0.002, q[3]), yellow)
	_hazard_nodes["%s:lid" % h.id] = b.commit(self, false)

# ---------------------------------------------------------------- killsaws
# A hazard-striped cover plate let into the deck, with a narrow slit down the
# middle that the blades rise through.
func _build_killsaw(h: Hazards.Hazard, solid: Batch, flat: Batch) -> void:
	var piece: Dictionary = h.pieces[0]
	var slot_l: float = piece.slotLength
	var slot_w := _saw_cover_width(piece)
	var slot := Transform3D(Phys.yaw_basis(piece.yaw), Vector3(piece.pos.x, 0, piece.pos.z))
	# The cover: a plate the size of the slot, with a slit cut for each blade.
	var slits := []
	for s in _saw_slits(piece): slits.append(Rect2(s.x - s.w / 2.0, -s.l / 2.0, s.w, s.l))
	flat.add(_plate(Rect2(-slot_w / 2.0, -slot_l / 2.0, slot_w, slot_l), slits, 0.002).apply(slot), _decal(Color.html("#3a3d42"), 1.0, 0.55, 0.35))
	# Countersunk bolts round the plate.
	for q in [[-1, -1], [1, -1], [-1, 1], [1, 1], [-1, 0], [1, 0]]:
		flat.add(Geo.cylinder(0.018, 0.018, 0.006, 8).translate(q[0] * (slot_w / 2.0 - 0.05), 0.004, q[1] * (slot_l / 2.0 - 0.05)).apply(slot), mats.lib.steel)
	# Hazard-striped border, exactly as the real box marks its saw slots.
	var rim := SAW_RIM
	for q in [
		[rim, slot_l + rim * 2.0, -(slot_w + rim) / 2.0, 0.0], [rim, slot_l + rim * 2.0, (slot_w + rim) / 2.0, 0.0],
		[slot_w, rim, 0.0, -(slot_l + rim) / 2.0], [slot_w, rim, 0.0, (slot_l + rim) / 2.0],
	]:
		flat.add(Geo.box(q[0], 0.012, q[1]).translate(q[2], 0.0, q[3]).apply(slot), mats.lib.hazardStripe)
	# Blade assembly, positioned from physics each frame: side by side on the
	# lateral axle (local X), as in physics.
	var b := Batch.new()
	for i in int(piece.bladeCount):
		var offset: float = (i - (piece.bladeCount - 1) / 2.0) * piece.bladeSpacing
		b.add(Geo.cylinder(piece.bladeRadius, piece.bladeRadius, piece.bladeThickness, 28).rotate_z(PI / 2.0).translate(offset, 0, 0), mats.lib.sawBlade)
	_hazard_nodes["%s:blades" % h.id] = b.commit(self)

# ---- perimeter spike strips. Static furniture, but they are a big part of
# what makes the box look like the box. Kept clear of the corners (the
# pulverizers) and of the screw cradles.
func _build_spikes(solid: Batch) -> void:
	var cfg = arena.get("spikeStrips")
	if not (cfg is Dictionary) or cfg.get("enabled") == false: return
	var sh := U.ft_to_m(cfg.spikeHeight)
	var sw := U.ft_to_m(cfg.spikeWidth)
	var step := U.ft_to_m(cfg.spacingFt)
	var inset := U.ft_to_m(cfg.inset)
	var cradles := []
	for h in hazards.all:
		for p in h.pieces:
			if p.kind == "screwCradle": cradles.append(p)
	var runs := [
		[int(floor((_half_x * 2.0 - 4.0) / step)), "x", -_half_z + inset],
		[int(floor((_half_x * 2.0 - 4.0) / step)), "x", _half_z - inset],
		[int(floor((_half_z * 2.0 - 4.0) / step)), "z", -_half_x + inset],
		[int(floor((_half_z * 2.0 - 4.0) / step)), "z", _half_x - inset],
	]
	for run in runs:
		var n: int = run[0]
		var span := (n - 1) * step
		for i in n:
			var along := -span / 2.0 + i * step
			if absf(along) > (_half_x if run[1] == "x" else _half_z) - 2.2: continue
			var x: float = along if run[1] == "x" else run[2]
			var z: float = run[2] if run[1] == "x" else along
			var near := false
			for p in cradles:
				var dx: float = x - p.pos.x
				var dz: float = z - p.pos.z
				var c := cos(p.yaw)
				var s := sin(p.yaw)
				if absf(dx * s + dz * c) < p.size.z / 2.0 + 0.5 and absf(dx * c - dz * s) < p.size.x / 2.0 + 0.8: near = true
			if near: continue
			# Lean them inward, like the real strips.
			var lean := Basis.IDENTITY
			if run[1] == "x": lean = Basis(Vector3.RIGHT, -0.35 if run[2] < 0.0 else 0.35)
			else: lean = Basis(Vector3.BACK, 0.35 if run[2] < 0.0 else -0.35)
			solid.add(Geo.cone(sw / 2.0, sh, 4).apply(Transform3D(lean, Vector3(x, sh / 2.0, z))), mats.lib.steel)

# ---------------------------------------------------------------- per frame

func _ghost_of(m: StandardMaterial3D) -> StandardMaterial3D:
	if not _ghosts.has(m):
		var g: StandardMaterial3D = m.duplicate()
		g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		g.albedo_color = Color(g.albedo_color, 0.12)
		g.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_ghosts[m] = g
	return _ghosts[m]

## Where the camera is this frame: walls between it and the box get out of
## the way. A camera outside the box looks through the wall on its own side:
## the lip along the top and the uprights cut across the floor, and the
## lexan's scuffs and glare wash it out. So the walls a camera is behind
## clear out of its way: lexan hidden, framing down to a ghost of itself. The
## kickplate stays - it is below the robots.
func set_viewpoint(pos: Vector3) -> void:
	var m := 0.25
	var cut := {"north": pos.z < -_half_z - m, "south": pos.z > _half_z + m, "west": pos.x < -_half_x - m, "east": pos.x > _half_x + m}
	var key := ""
	for k in cut:
		if cut[k]: key += k + ","
	if key == _cut_key: return
	_cut_key = key
	for c in _cutaway:
		var away := false
		for sd in c.sides:
			if cut[sd]: away = true
		var mi: MeshInstance3D = c.node
		if c.kind == "lexan": mi.visible = not away
		else:
			mi.material_override = _ghost_of(c.solid) if away else null
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if away else GeometryInstance3D.SHADOW_CASTING_SETTING_ON

## The hazards' moving parts (arms, augers, blades, the pit's lid).
func moving_parts() -> Array:
	return _hazard_nodes.values()

## The walls cut away right now: ["south", "east"].
func cutaway() -> Array:
	var out := []
	for k in _cut_key.split(",", false): out.append(k)
	return out

## Copy live hazard transforms out of physics. Call once per frame.
func update(dt: float) -> void:
	_lamp_t += dt
	# Pit lamps: flash as it is about to go, burn steady once it is open.
	for l in _pit_lamps:
		var h: Hazards.Hazard = l.h
		var e := 0.0
		if h.travel > 0.0: e = 2.4
		elif h.warning > 0.0: e = 3.0 if sin(_lamp_t * 14.0) > 0.0 else 0.2
		l.mat.emission_energy_multiplier = e
	for t in hazards.transforms():
		var node: Node3D = _hazard_nodes.get("%s:%s" % [t.hazardId, t.part])
		if node != null: node.transform = t.xf
