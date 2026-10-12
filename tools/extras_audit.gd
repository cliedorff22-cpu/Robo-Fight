## extras_audit.gd - every body extra the workshop offers, on every body
## shape, measured: is it joined to the body, and how much of it shows?
##   Godot --headless --path . -s tools/extras_audit.gd -- [weapon part id] [chassis part id]
## For each extra piece: `gap` is the space between it and the nearest body
## piece (mm; 0 = touching), `buried` the share of it inside the body.
extends SceneTree

const GAP_MM := 3.0        # further than this from the body: not attached
const BURIED := 0.8        # more of it than this inside the body: it does not show

static func planes_of(points: Array) -> Array:
	var h := Hull.convex_faces(points)
	var out := []
	for f in h.faces: out.append([f.n, f.d])
	return out

static func sd(planes: Array, p: Vector3) -> float:
	var m := -INF
	for pl in planes: m = maxf(m, (pl[0] as Vector3).dot(p) - pl[1])
	return m

# One robot's extras: [{ id, gap (mm), buried (0..1) }].
func measure(reg: Registry, def: Dictionary, rng: RandomNumberGenerator) -> Array:
	var a := Build.assemble_robot(reg, def)
	var sh := Shape.build_shape(a)
	var body := []
	var mine := []
	for p in sh.pieces:
		if str(p.id).begins_with("extra:"): mine.append(p)
		else: body.append(planes_of(p.points))
	var out := []
	for p in mine:
		var pl := planes_of(p.points)
		var b := Hull.bounds(p.points)
		var samples: Array = (p.points as Array).duplicate()
		var tries := 0
		while samples.size() < 260 and tries < 20000:
			tries += 1
			var q := Vector3(rng.randf_range(b.min.x, b.max.x), rng.randf_range(b.min.y, b.max.y), rng.randf_range(b.min.z, b.max.z))
			if pl.is_empty() or sd(pl, q) <= 0.0: samples.append(q)
		var gap := INF
		var inside := 0
		# It may hang off its own kind too (a tail's second segment).
		var kin := []
		for o in mine:
			if not is_same(o, p) and str(o.id).get_slice(":", 1) == str(p.id).get_slice(":", 1): kin.append(planes_of(o.points))
		for q in samples:
			var d := INF
			for bp in body: d = minf(d, sd(bp, q))
			var dk := d
			for kp in kin: dk = minf(dk, sd(kp, q))
			gap = minf(gap, maxf(0.0, dk))
			if d <= 0.0: inside += 1
		out.append({"id": p.id, "gap": gap * 1000.0, "buried": inside / float(samples.size())})
	return out

# Every robot in the data files, as built.
func roster(reg: Registry, rng: RandomNumberGenerator) -> void:
	var bad := 0
	var n := 0
	for def in reg.all_robots():
		for unit in [def] + ([def.partner] if def.get("partner") is Dictionary else []):
			if not (unit.get("body") is Dictionary) or (unit.body.get("extras", []) as Array).is_empty(): continue
			var d: Dictionary = unit if unit.has("id") else unit.merged({"id": def.id + "+"})
			for m in measure(reg, d, rng):
				n += 1
				if m.gap > GAP_MM or m.buried > BURIED:
					bad += 1
					print("%-22s %-8s %-22s gap %5.1f mm  buried %3.0f%%" % [d.id, d.body.get("template", "classic"), m.id, m.gap, m.buried * 100.0])
	print("%d of %d extra pieces in the field need a look" % [bad, n])

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var reg := Registry.shared()
	if args.size() > 0 and args[0] == "roster":
		var r := RandomNumberGenerator.new()
		r.seed = 7
		roster(reg, r)
		quit()
		return
	var base: Dictionary = reg.robot(reg.playerId).duplicate(true)
	if args.size() > 0 and args[0] != "-": base.build = Workshop.set_slot(reg, base.build, "weapon", args[0])
	if args.size() > 1 and args[1] != "-": base.build = Workshop.set_slot(reg, base.build, "chassis", args[1])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bad := 0
	var total := 0
	for tpl in Workshop.TEMPLATES:
		var line := "%-7s" % tpl
		for ex in Workshop.EXTRAS:
			var def: Dictionary = base.duplicate(true)
			def.body = Workshop.fit_body(reg, {"template": tpl, "extras": [{"type": ex}]}, def.build)
			var worst_gap := 0.0
			var worst_buried := 0.0
			var mine := measure(reg, def, rng)
			for m in mine:
				worst_gap = maxf(worst_gap, m.gap)
				worst_buried = maxf(worst_buried, m.buried)
			total += 1
			var flag := ""
			if mine.is_empty(): flag = "NONE"
			elif worst_gap > GAP_MM: flag = "gap%.0f" % worst_gap
			elif worst_buried > BURIED: flag = "bur%.0f" % (worst_buried * 100.0)
			if flag != "": bad += 1
			line += " %-9s" % (flag if flag != "" else "ok")
		print(line)
	print("        " + " ".join(Workshop.EXTRAS.map(func(x): return "%-9s" % x)))
	print("%d of %d need a look" % [bad, total])
	quit()
