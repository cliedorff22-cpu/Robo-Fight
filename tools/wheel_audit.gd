## wheel_audit.gd - every robot's wheels, measured: is each one carried by
## something, and does anything cut into its tyre?
##   Godot --headless --path . -s tools/wheel_audit.gd -- [robot_id ...]
## For each robot:
##   gap   how far the worst wheel's inner face stands off the nearest body
##         piece beside it (mm). A wide gap is not wrong in itself - the
##         picture carries such a wheel on an axle and arms (render/robot_view)
##         - it is what that carrier has to span.
##   cut   how deep the worst piece goes into a tyre (mm), and which piece.
##         Over CUT_MM is a fault: a guard, wing or leg drawn through a wheel.
## Exits with an error if any robot has a cut.
extends SceneTree

const CUT_MM := 2.0

static func planes_of(points: Array) -> Array:
	var out := []
	for f in Hull.convex_faces(points).faces: out.append([f.n, f.d])
	return out

# How deep inside a convex piece a point is (negative: outside).
static func depth(planes: Array, p: Vector3) -> float:
	var m := -INF
	for pl in planes: m = maxf(m, (pl[0] as Vector3).dot(p) - pl[1])
	return -m

## One robot: { gap (m), cut (m), cutBy (piece id) }.
static func measure(assembled: Dictionary) -> Dictionary:
	var rig := RobotRig.at_rest(assembled)
	var st: Dictionary = assembled.stats
	var r: float = st.wheelRadiusM
	var w: float = U.in_to_m(assembled.parts.wheel.spec.widthIn)
	var drop: float = rig.rest_length * (1.0 - rig.preload_frac)
	var pieces := []
	for p in rig.shape.pieces: pieces.append([p.id, planes_of(p.points), Hull.bounds(p.points)])
	var worst_gap := 0.0
	var worst_cut := 0.0
	var cut_by := ""
	for wh in rig.wheels:
		var c: Vector3 = wh.anchor - Vector3(0, drop, 0)
		var s := signf(c.z)
		# The tyre, as points through its volume.
		var samples := []
		for k in 5:
			var z := c.z + (k / 4.0 - 0.5) * w * 0.98
			for ring in [1.0, 0.82, 0.66]:
				for a in 20:
					var ang := a / 20.0 * TAU
					samples.append(Vector3(c.x + cos(ang) * r * ring, c.y + sin(ang) * r * ring, z))
		var reach := 0.0
		for pc in pieces:
			var b: Dictionary = pc[2]
			# Cut: any tyre point inside the piece.
			if b.max.x > c.x - r and b.min.x < c.x + r and b.max.y > c.y - r and b.min.y < c.y + r and (b.max.z * s) > (c.z * s - w / 2.0) - 0.001:
				for q in samples:
					var d := depth(pc[1], q)
					if d > worst_cut:
						worst_cut = d
						cut_by = pc[0]
			# Gap: how far out this piece comes beside the wheel, anywhere in
			# the height and length of the wheel's inner face.
			if str(pc[0]).begins_with("weapon"): continue
			for kx in 5:
				var x := c.x + (kx / 4.0 - 0.5) * r * 1.2
				for ky in 5:
					var y := c.y + (ky / 4.0 - 0.5) * r * 1.6
					var lo := -INF
					var hi := INF
					for pl in pc[1]:
						var n: Vector3 = pl[0]
						var rest: float = pl[1] - n.x * x - n.y * y
						if absf(n.z) < 1e-9:
							if rest < 0.0:
								lo = INF
								break
						elif n.z > 0.0: hi = minf(hi, rest / n.z)
						else: lo = maxf(lo, rest / n.z)
					if lo > hi or lo == -INF or hi == INF: continue
					reach = maxf(reach, hi * s if s > 0.0 else -lo)
		worst_gap = maxf(worst_gap, (absf(c.z) - w / 2.0) - reach)
	return {"gap": worst_gap, "cut": worst_cut, "cutBy": cut_by}

func _init() -> void:
	var reg := Registry.load_all()
	var only := OS.get_cmdline_user_args()
	var cuts := 0
	var wide := 0
	for def in reg.all_robots():
		if not only.is_empty() and not only.has(def.id): continue
		var m := measure(Build.assemble_robot(reg, def))
		var cut: bool = m.cut * 1000.0 > CUT_MM
		if cut: cuts += 1
		if m.gap > 0.03: wide += 1
		if cut or m.gap > 0.03 or not only.is_empty():
			print("%-22s gap %4.0f mm   cut %4.0f mm %s" % [def.id, m.gap * 1000.0, m.cut * 1000.0, ("by " + m.cutBy) if cut else ""])
	print("wheels standing more than 30 mm off the body: %d robots   something cutting into a tyre: %d robots" % [wide, cuts])
	quit(1 if cuts > 0 else 0)
