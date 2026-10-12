## arena_world.gd - builds the physics arena from arena.json: floor, four
## walls (angled steel kickplate + vertical lexan above it), a lip and a roof.
## Hazards are added separately by hazards.gd because they move.
##
## `pieces` describes every static body the picture should show, in metres, so
## the renderer can mirror it without re-deriving geometry:
##   { kind, material, side, size: Vector3, xf: Transform3D, hazardId }
class_name ArenaWorld
extends Node3D

var arena: Dictionary
## { halfX, halfZ, wallH, kickH, kickRun, lexanBottomY, floorThick }
var dims := {}
## The pits in this layout: [{ id, cx, cz, hw, hl, depth }]
var pits := []
var pieces := []

func _init(arena_doc: Dictionary) -> void:
	arena = arena_doc
	name = "ArenaWorld"
	_build()

## The pits in a layout, in metres: centre, half-extents and depth. Pits sit
## square to the walls, so a yaw of 90 just swaps the sides.
static func pit_rects(arena_doc: Dictionary) -> Array:
	var out := []
	for h in arena_doc.get("hazards", []):
		if h.get("type") != "pit" or h.get("enabled") == false: continue
		var turned := absi(int(round(J.g(h, "yaw", 0.0) / 90.0))) % 2 == 1
		var w: float = h.size[1] if turned else h.size[0]
		var l: float = h.size[0] if turned else h.size[1]
		out.append({"id": h.id, "cx": U.ft_to_m(h.pos[0]), "cz": U.ft_to_m(h.pos[2]), "hw": U.ft_to_m(w) / 2.0, "hl": U.ft_to_m(l) / 2.0, "depth": U.ft_to_m(h.depth)})
	return out

static func _cuts(lo: float, hi: float, edges: Array) -> Array:
	var set := {lo: true, hi: true}
	for e in edges:
		if e > lo and e < hi: set[e] = true
	var out := set.keys()
	out.sort()
	return out

func _build() -> void:
	var half_x := U.ft_to_m(arena.floor.size[0]) / 2.0
	var half_z := U.ft_to_m(arena.floor.size[1]) / 2.0
	var floor_thick := U.ft_to_m(arena.floor.thickness)
	var wall_h := U.ft_to_m(arena.walls.height)
	var kick_h := U.ft_to_m(arena.walls.kickplate.height)
	var kick_angle := deg_to_rad(arena.walls.kickplate.angleFromVertical)
	var lexan_t := U.ft_to_m(arena.walls.lexan.thickness)
	var kick_t := 0.05
	var floor_friction: float = arena.floor.friction

	# ---- floor: top surface sits exactly at y = 0, which every other system
	# assumes. A pit layout cuts holes in it: the slab is split into a grid
	# along every pit edge and the cells inside a pit are left out. With no
	# pits that is one cell, the slab it always was.
	pits = pit_rects(arena)
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector3(0, -floor_thick / 2.0, 0)
	floor_body.collision_layer = Phys.ARENA
	floor_body.collision_mask = 0
	floor_body.physics_material_override = Phys.material(floor_friction, 0.0)
	add_child(floor_body)
	var ex := []
	var ez := []
	for p in pits:
		ex.append(p.cx - p.hw); ex.append(p.cx + p.hw)
		ez.append(p.cz - p.hl); ez.append(p.cz + p.hl)
	var xs := _cuts(-half_x, half_x, ex)
	var zs := _cuts(-half_z, half_z, ez)
	for i in range(xs.size() - 1):
		for j in range(zs.size() - 1):
			var mx: float = (xs[i] + xs[i + 1]) / 2.0
			var mz: float = (zs[j] + zs[j + 1]) / 2.0
			var in_pit := false
			for p in pits:
				if absf(mx - p.cx) < p.hw and absf(mz - p.cz) < p.hl: in_pit = true
			if in_pit: continue
			Phys.add_shape(floor_body, Phys.box(Vector3(xs[i + 1] - xs[i], floor_thick, zs[j + 1] - zs[j])), Transform3D(Basis.IDENTITY, Vector3(mx, 0, mz)))
	# Each pit: steel walls lining the hole down to its floor, and the floor.
	# The sinking deck panel itself is a hazard (hazards.gd) because it moves.
	var pit_t := 0.15
	for p in pits:
		var wall_y: float = -p.depth / 2.0 - 0.05
		for q in [
			[p.hw + pit_t, pit_t / 2.0, p.cx, p.cz - p.hl - pit_t / 2.0], [p.hw + pit_t, pit_t / 2.0, p.cx, p.cz + p.hl + pit_t / 2.0],
			[pit_t / 2.0, p.hl, p.cx - p.hw - pit_t / 2.0, p.cz], [pit_t / 2.0, p.hl, p.cx + p.hw + pit_t / 2.0, p.cz],
		]:
			var size := Vector3(q[0] * 2.0, p.depth + 0.1, q[1] * 2.0)
			var xf := Transform3D(Basis.IDENTITY, Vector3(q[2], wall_y, q[3]))
			Phys.static_box(self, xf, size, 0.4, 0.05)
			pieces.append({"kind": "pitWall", "hazardId": p.id, "size": size, "xf": xf})
		Phys.static_box(self, Transform3D(Basis.IDENTITY, Vector3(p.cx, -p.depth - 0.15, p.cz)), Vector3((p.hw + pit_t) * 2.0, 0.2, (p.hl + pit_t) * 2.0), floor_friction, 0.0)
	pieces.append({"kind": "floor", "material": arena.floor.material, "size": Vector3(half_x * 2.0, floor_thick, half_z * 2.0),
		"xf": Transform3D(Basis.IDENTITY, Vector3(0, -floor_thick / 2.0, 0))})

	# ---- walls. Built once in a canonical frame for the -Z side, then yawed
	# onto all four sides. The kickplate's bottom edge meets the floor at the
	# wall line and its top leans outward, so a bot shoved into the wall rides
	# up it instead of catching a square edge.
	var kick_half := kick_h / 2.0
	var kick_cos := cos(kick_angle)
	var kick_sin := sin(kick_angle)
	var kick_center_y := kick_half * kick_cos           # bottom edge lands at y = 0
	var kick_run := kick_h * kick_sin                   # how far out the top leans
	var kick_tilt := Basis(Vector3.RIGHT, -kick_angle)
	var lexan_bottom_y := kick_h * kick_cos
	var lexan_half_h := maxf(0.01, (wall_h - lexan_bottom_y) / 2.0)

	var sides := [
		{"id": "north", "yaw": 0.0, "half": half_z, "span": half_x},
		{"id": "south", "yaw": PI, "half": half_z, "span": half_x},
		{"id": "west", "yaw": PI / 2.0, "half": half_x, "span": half_z},
		{"id": "east", "yaw": -PI / 2.0, "half": half_x, "span": half_z},
	]
	for side in sides:
		var yaw_b := Phys.yaw_basis(side.yaw)
		# Kickplate.
		var kick_xf := Transform3D(yaw_b * kick_tilt, yaw_b * Vector3(0, kick_center_y, -side.half - kick_half * kick_sin))
		var kick_size := Vector3(side.span * 2.0, kick_h, kick_t)
		Phys.static_box(self, kick_xf, kick_size, 0.4, 0.05)
		pieces.append({"kind": "kickplate", "material": arena.walls.kickplate.material, "side": side.id, "size": kick_size, "xf": kick_xf})
		# Lexan panel above the kickplate, offset out by the kickplate's run.
		var lex_xf := Transform3D(yaw_b, yaw_b * Vector3(0, lexan_bottom_y + lexan_half_h, -side.half - kick_run - lexan_t / 2.0))
		var lex_size := Vector3(side.span * 2.0, lexan_half_h * 2.0, lexan_t)
		Phys.static_box(self, lex_xf, lex_size, arena.walls.friction, 0.17)
		pieces.append({"kind": "lexan", "material": arena.walls.lexan.material, "side": side.id, "size": lex_size, "xf": lex_xf})
		# A solid backstop behind the lexan, floor to ceiling. The lexan is
		# thin and a fast tumbling bot can tunnel through it; this guarantees
		# the box actually contains the fight no matter what the solver does.
		# Not in `pieces`: it is invisible.
		if J.path(arena, ["walls", "containment", "enabled"], true) != false:
			var back_t := U.ft_to_m(J.path(arena, ["walls", "containment", "thickness"], 1.0))
			Phys.static_box(self, Transform3D(yaw_b, yaw_b * Vector3(0, wall_h / 2.0, -side.half - kick_run - lexan_t - back_t / 2.0)),
				Vector3((side.span + back_t) * 2.0, wall_h, back_t), 0.3, 0.05)
		# A ceiling-high lip so a flipped bot cannot pop out of the box.
		var lip_xf := Transform3D(yaw_b, yaw_b * Vector3(0, wall_h, -side.half - kick_run - 0.25))
		Phys.static_box(self, lip_xf, Vector3(side.span * 2.0, 0.1, 0.5), 0.5, 0.0)
		pieces.append({"kind": "lip", "material": "steel", "side": side.id, "size": Vector3(side.span * 2.0, 0.1, 0.5), "xf": lip_xf})

	# The roof. The real box is closed over the top; this one is too, and
	# invisible. Nothing a fight can do should put a robot outside the arena.
	var roof_t := 0.5
	Phys.static_box(self, Transform3D(Basis.IDENTITY, Vector3(0, wall_h + roof_t / 2.0, 0)),
		Vector3((half_x + kick_run + 2.0) * 2.0, roof_t, (half_z + kick_run + 2.0) * 2.0), 0.3, 0.05)

	dims = {"halfX": half_x, "halfZ": half_z, "wallH": wall_h, "kickH": kick_h, "kickRun": kick_run, "lexanBottomY": lexan_bottom_y, "floorThick": floor_thick}
