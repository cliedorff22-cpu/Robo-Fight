## dress.gd - what turns a robot's sculpted shape into a built machine: the
## weapon's drive (motor, belt, pulleys), the truss-cut arms and uprights that
## carry it, thin hinged forks, tube roll hoops, frame rails along the body's
## edges, and the bits and pieces on the deck.
##
## Render only. The pieces physics collides with (logic/shape.gd) stay exactly
## as they are; this draws a modelled part INSIDE a piece's own points in
## place of its plain rounded hull, and bolts hardware onto the body where
## there is room for it.
##
## Nothing may float and nothing may cut into anything: every bolt-on is
## tried against the body, the tyres and everything the weapon sweeps
## (Check.fit) and is left off - or tried somewhere else - if it does not sit
## right. tools/dress_audit.gd runs the same test over the whole field.
##
## A robot file tunes it, without touching stats, in `body.look`:
##   "forks": "blade" | "twin" | "saw" | "shoe"     "forkMat": a material key
##   "supports": "truss" | "plate" | "solid"        "supportMat": a material key
##   "drive": "deck" | "inboard" | "can" | "engine" | "none"    "belts": 2
##   "frame": "rails" | "tube" | "none"             "frameMat": a material key
##   "kit": ["handle", "sink", "aerial", ...] - what is on the deck
## Left out, each is picked for the robot from its id, so no two are alike.
##
## plan() returns
##   pieces  { piece id: [{ geo, mat }] }  - body space, drawn instead of the hull
##   items   [{ id, parts: [{ geo, mat }] }] - body space, bolted on
class_name Dress

## Graphics setting "Robot hardware". Read when a robot is built.
static var on := true
## Why things were left off, for tools/dress_audit.gd.
static var trace: Array = []

const GAP := 0.003            # how far a bolt-on's free surfaces may sink into something

static func is_hull(piece: Dictionary) -> bool:
	var id: String = piece.id
	return id == "core" or id == "chin" or id.begins_with("cheek:") or id.begins_with("body:") or id.begins_with("plate:") or id.begins_with("armor:")

static func _p(geo: Geo, mat: String) -> Dictionary:
	return {"geo": geo, "mat": mat}

# ---------------------------------------------------------------- the body, as solids

class Body:
	var pieces := []         # [{ id, planes: [[n, d]], lo, hi, hull }]

	func _init(shape: Dictionary) -> void:
		for p in shape.pieces:
			var planes := []
			for f in Hull.convex_faces(p.points).faces: planes.append([f.n, f.d])
			if planes.is_empty(): continue
			var b: Dictionary = Hull.bounds(p.points)
			pieces.append({"id": p.id, "planes": planes, "lo": b.min, "hi": b.max, "hull": Dress.is_hull(p)})

	# How deep inside a piece a point is (negative: outside it).
	static func depth_in(pc: Dictionary, q: Vector3) -> float:
		var m := -INF
		for pl in pc.planes: m = maxf(m, (pl[0] as Vector3).dot(q) - float(pl[1]))
		return -m

	## How deep the point is in the deepest piece of the kind asked for
	## (hull: the body itself; not hull: extras and weapon pieces).
	func depth(q: Vector3, hull: bool, skip: Array = []) -> float:
		var best := -INF
		for pc in pieces:
			if pc.hull != hull or skip.has(pc.id): continue
			var lo: Vector3 = pc.lo
			var hi: Vector3 = pc.hi
			if q.x < lo.x - 0.03 or q.x > hi.x + 0.03 or q.y < lo.y - 0.03 or q.y > hi.y + 0.03 or q.z < lo.z - 0.03 or q.z > hi.z + 0.03: continue
			best = maxf(best, depth_in(pc, q))
		return best

	# Where the upright line at (x, z) passes through a piece: [low, high] or [].
	static func column(pc: Dictionary, x: float, z: float) -> Array:
		var lo := -INF
		var hi := INF
		for pl in pc.planes:
			var n: Vector3 = pl[0]
			var rest: float = float(pl[1]) - n.x * x - n.z * z
			if absf(n.y) < 1e-9:
				if rest < 0.0: return []
			elif n.y > 0.0: hi = minf(hi, rest / n.y)
			else: lo = maxf(lo, rest / n.y)
		return [lo, hi] if (lo <= hi and lo > -INF and hi < INF) else []

	## The top of the body at (x, z), or -INF where there is none.
	func top(x: float, z: float) -> float:
		var best := -INF
		for pc in pieces:
			if not pc.hull: continue
			var col := column(pc, x, z)
			if not col.is_empty(): best = maxf(best, col[1])
		return best

	## The lowest and highest the body's top is under a footprint, or [] where
	## any of it hangs over the edge.
	func seat(x: float, z: float, hx: float, hz: float) -> Array:
		var lo := INF
		var hi := -INF
		for dx in [-1.0, 0.0, 1.0]:
			for dz in [-1.0, 0.0, 1.0]:
				var y := top(x + dx * hx, z + dz * hz)
				if y == -INF: return []
				lo = minf(lo, y)
				hi = maxf(hi, y)
		return [lo, hi]

	## How far out from the centreline the body's side is at (x, y) on side s
	## (+1 left, -1 right); 0 where there is no body.
	func reach(x: float, y: float, s: float) -> float:
		var best := 0.0
		for pc in pieces:
			if not pc.hull: continue
			var lo := -INF
			var hi := INF
			var miss := false
			for pl in pc.planes:
				var n: Vector3 = pl[0]
				var rest: float = float(pl[1]) - n.x * x - n.y * y
				if absf(n.z) < 1e-9:
					if rest < 0.0:
						miss = true
						break
				elif n.z > 0.0: hi = minf(hi, rest / n.z)
				else: lo = maxf(lo, rest / n.z)
			if miss or lo > hi or lo == -INF or hi == INF: continue
			best = maxf(best, hi if s > 0.0 else -lo)
		return best

	func piece(id: String):
		for pc in pieces:
			if pc.id == id: return pc
		return null

# ---------------------------------------------------------------- what must be kept clear

class Check:
	var body: Body
	var tyres := []          # [{ c, r, hw }]
	var sweeps := []
	var floor_y := -INF
	var ceil_y := INF
	var taken := []          # AABBs of what has been bolted on already

	## Why the point cannot have anything in it, or "".
	func blocked(q: Vector3) -> String:
		if q.y < floor_y: return "floor"
		if q.y > ceil_y: return "ceiling"
		for t in tyres:
			var c: Vector3 = t.c
			if absf(q.z - c.z) < t.hw and Vector2(q.x - c.x, q.y - c.y).length() < t.r: return "tyre"
		for s in sweeps:
			if Dress.in_sweep(s, q): return "weapon"
		return ""

	## Try a bolt-on (parts in body space). "" if it sits right, else why not.
	##   into    piece ids it is mounted in or on (it may run into those)
	##   buried  the share of it allowed to be out of sight inside the body
	##   loose   true: it need not touch the body itself (it hangs off `into`)
	func fit(parts: Array, into: Array = [], buried := 0.45, apart := true) -> String:
		var pts := Dress.samples(parts)
		if pts.is_empty(): return "empty"
		var box := AABB(pts[0], Vector3.ZERO)
		var sunk := 0
		var held := false
		for q in pts:
			box = box.expand(q)
			var why := blocked(q)
			if why != "": return why
			if body.depth(q, false, into) > Dress.GAP: return "part"
			var d := body.depth(q, true)
			if d > 0.012: sunk += 1
			if d > -0.004: held = true
			elif not held and not into.is_empty() and body.depth(q, false) > -0.004: held = true
		if not held: return "floating"
		if float(sunk) / pts.size() > buried: return "buried"
		if apart:
			var slim := box.grow(-0.004)
			for other in taken:
				if slim.intersects(other): return "crowded"
		return ""

	## Whether something carried by another part (a belt between two pulleys)
	## passes clear of everything: "" or what it runs into.
	func clear(parts: Array, into: Array = []) -> String:
		for q in Dress.samples(parts):
			var why := blocked(q)
			if why != "": return why
			if body.depth(q, false, into) > Dress.GAP: return "part"
			if body.depth(q, true) > Dress.GAP: return "body"
		return ""

	## The same for a handful of points picked by hand (cheap).
	func clear_at(pts: Array) -> String:
		for q in pts:
			var why := blocked(q)
			if why != "": return why
			if body.depth(q, false) > Dress.GAP: return "part"
		return ""

	func take(parts: Array) -> void:
		var pts := Kit.points_of(parts)
		if pts.is_empty(): return
		var box := AABB(pts[0], Vector3.ZERO)
		for q in pts: box = box.expand(q)
		taken.append(box)

## The corners of a list of parts, with points along any long edge - what a
## part is tested by.
static func samples(parts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in parts:
		var pos: PackedVector3Array = (p.geo as Geo).pos
		out.append_array(pos)
		for t in range(0, pos.size(), 3):
			for k in 3:
				var a := pos[t + k]
				var b := pos[t + (k + 1) % 3]
				var l := a.distance_to(b)
				if l < 0.03: continue
				var n := int(l / 0.02)
				for i in range(1, n): out.append(a.lerp(b, float(i) / n))
	return out

## Everything the weapon passes through as it works.
static func sweeps_of(shape: Dictionary) -> Array:
	var out := []
	var wv = J.path(shape, ["weapon", "visual"])
	if not (wv is Dictionary): return out
	if wv.kind == "rotor":
		var whole: bool = wv.get("style") == "shell"
		out.append({"type": "rotor", "c": wv.center, "axis": wv.axis, "r": wv.radius + 0.002, "hh": wv.thickness / 2.0 + 0.001, "over": whole})
	elif wv.kind == "arm":
		var head: Dictionary = wv.head
		var big := maxf(head.l * 1.5, head.h * 1.5)
		out.append({"type": "arm", "p": wv.pivot, "reach": wv.reach, "r0": maxf(0.06, wv.reach - big), "r1": wv.reach + big + 0.02,
			"hz": maxf(head.w / 2.0, 0.05) + 0.006})
	elif wv.kind == "plate" or wv.kind == "jaw":
		var c: Vector3 = wv.center
		var l: float = wv.size.l
		var w: float = wv.size.w
		out.append({"type": "box", "lo": Vector3(c.x - l / 2.0 - 0.012, c.y - wv.size.h / 2.0 - 0.01, -w / 2.0 - 0.01),
			"hi": Vector3(c.x + l / 2.0 + 0.012, c.y + wv.size.h / 2.0 + 0.15, w / 2.0 + 0.01)})
		if wv.kind == "jaw":
			var px: float = c.x - l * 0.5 - 0.08
			var wide: float = (w * 0.36 if wv.get("style") == "claw" else maxf(0.03, w * 0.16)) + 0.008
			out.append({"type": "box", "lo": Vector3(px - 0.06, wv.top + 0.004, -wide), "hi": Vector3(c.x + l, INF, wide)})
			out.append({"type": "box", "lo": Vector3(px - 0.036, wv.top - 0.002, -w * 0.25 - 0.004), "hi": Vector3(px + 0.036, wv.top + 0.07, w * 0.25 + 0.004)})
		elif J.truthy(wv.get("lid")):
			out.append({"type": "box", "lo": Vector3(wv.hingeX - 0.022, wv.top + 0.004, -w / 2.0 - 0.006), "hi": Vector3(c.x + 0.012, INF, w / 2.0 + 0.006)})
	return out

static func in_sweep(s: Dictionary, q: Vector3) -> bool:
	match s.type:
		"rotor":
			var c: Vector3 = s.c
			if s.axis == "y":
				if Vector2(q.x - c.x, q.z - c.z).length() >= s.r: return false
				return q.y > c.y - s.hh if s.over else absf(q.y - c.y) < s.hh
			return absf(q.z - c.z) < s.hh and Vector2(q.x - c.x, q.y - c.y).length() < s.r
		"arm":
			var p: Vector3 = s.p
			var d := Vector2(q.x - p.x, q.y - p.y)
			var rho := d.length()
			if rho > s.r1: return false
			var ang := d.angle()
			if ang < -1.8 or ang > 0.65: return false
			return absf(q.z) < (s.hz if rho > s.r0 else 0.052)
		"box":
			var lo: Vector3 = s.lo
			var hi: Vector3 = s.hi
			return q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y and q.z > lo.z and q.z < hi.z
	return false

# ---------------------------------------------------------------- planning

class Ctx:
	var assembled: Dictionary
	var shape: Dictionary
	var look: Dictionary
	var body: Body
	var check: Check
	var wv = null            # the weapon, as shape.gd describes it to the renderer
	var cls := ""
	var L := 0.0
	var H := 0.0
	var W := 0.0
	var yb := 0.0
	var id := ""

	## A choice: the robot file's, or one of `options` picked by the robot's id.
	func pick(key: String, options: Array) -> String:
		return Dress.pick_for(id, look, key, options)

	## A number in 0..1 that is this robot's own for `key`.
	func roll(key: String) -> float:
		return Rng.hash_seed("%s:look:%s" % [id, key]) / 4294967296.0

## A look: what the robot file says, or one of `options` picked by its id.
static func pick_for(id: String, look: Dictionary, key: String, options: Array) -> String:
	var v = look.get(key)
	if v != null and str(v) != "": return str(v)
	return options[Rng.hash_seed("%s:look:%s" % [id, key]) % options.size()]

static func context(assembled: Dictionary, rig) -> Ctx:
	var c := Ctx.new()
	var shape: Dictionary = rig.shape
	c.assembled = assembled
	c.shape = shape
	c.id = str(assembled.id)
	c.look = J.path(assembled, ["def", "body", "look"], {})
	c.L = assembled.dims.lengthM
	c.H = assembled.dims.heightM
	c.W = assembled.dims.widthM
	c.yb = -c.H / 2.0
	c.body = Body.new(shape)
	c.wv = J.path(shape, ["weapon", "visual"])
	var wp = assembled.parts.get("weapon")
	c.cls = str(wp.spec["class"]) if wp != null else ""
	var ck := Check.new()
	ck.body = c.body
	ck.sweeps = sweeps_of(shape)
	ck.floor_y = float(shape.groundY) + 0.004
	if J.truthy(shape.get("invertible")): ck.ceil_y = float(shape.wheelTopY) - 0.006
	var r: float = assembled.stats.wheelRadiusM
	var w := U.in_to_m(assembled.parts.wheel.spec.widthIn)
	var drop: float = rig.rest_length * (1.0 - rig.preload_frac)
	for wh in rig.wheels:
		ck.tyres.append({"c": (wh.anchor as Vector3) - Vector3(0, drop, 0), "r": r + 0.014, "hw": w / 2.0 + 0.0015})
	c.check = ck
	return c

static var _plans := {}
static var _plan_order: Array = []

## Everything a robot is dressed in. `rig` is its RobotRig. The same build is
## planned once and remembered (the parts are never changed after).
static func plan(assembled: Dictionary, rig) -> Dictionary:
	var out := {"pieces": {}, "items": []}
	var shape: Dictionary = rig.shape
	if shape.template == "classic": return out      # the test bots stay plain boxes
	var def = assembled.get("def")
	var key := "%s|%d" % [assembled.id, hash(J.to_json(def) if def != null else str(assembled.id))]
	if _plans.has(key): return _plans[key]
	_plans[key] = out
	_plan_order.append(key)
	if _plan_order.size() > 48: _plans.erase(_plan_order.pop_front())
	var c := context(assembled, rig)
	for piece in shape.pieces:
		var model = _piece_model(piece, c)
		if model != null and not (model as Array).is_empty(): out.pieces[piece.id] = model
	_drive(c, out.items)
	_rails(c, out.items)
	_skirts(c, out.items, rig)
	_deck_kit(c, out.items)
	return out

static func _add(c: Ctx, items: Array, id: String, parts: Array) -> void:
	items.append({"id": id, "parts": parts})
	c.check.take(parts)

# ---------------------------------------------------------------- pieces as models

static func _role_mat(piece: Dictionary, def := "steel") -> String:
	match str(piece.get("role", "")):
		"trim": return "trim"
		"accent": return "accent"
		"metal": return "steel"
	return def

static func _piece_model(piece: Dictionary, c: Ctx):
	var id: String = piece.id
	if id.begins_with("extra:forks:"): return _forks(piece, c)
	if id.begins_with("extra:spikes:"): return _spike(piece, c)
	if id.begins_with("extra:cage:"): return _hoop(piece, c)
	if id.begins_with("extra:fin:"): return _fin(piece, c)
	if id.begins_with("extra:stack:"): return _stack(piece, c)
	if id.begins_with("extra:eyes:"): return _eye(piece, c)
	if id.begins_with("extra:dome:"): return _dome(piece, c)
	if id.begins_with("extra:plow:"): return _plow(piece, c)
	if id.begins_with("extra:mast:") or id == "weapon:mast": return _mast(piece, c)
	if id.begins_with("extra:uprights:"): return _upright(piece, c)
	if id.begins_with("extra:horns:"): return _horn(piece, c)
	if id == "extra:pod:0" or id == "weapon:bearing": return _arm_plate(piece, c)
	if id.begins_with("weapon:support:"): return _support(piece, c)
	if id == "weapon:pivot": return _tower(piece, c)
	if id.begins_with("extra:tail:"): return _tail(piece, c)
	if id == "weapon:wedge": return _wedge(piece, c)
	return null

# A scorpion's tail: jointed tube up over the back, and a sting.
static func _tail(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var x0: float = b.min.x
	var x1: float = b.max.x
	var y0: float = b.min.y
	var y1: float = b.max.y
	var r: float = minf((b.max.z - b.min.z) * 0.36, 0.024)
	if y1 - y0 < r * 3.0 or x1 - x0 < r * 3.0: return null
	var path: Array
	var sting: bool = piece.id == "extra:tail:1"
	if sting: path = [Vector3(x0 + r, y0 + 0.006, 0), Vector3(x0 + r, y1 - r, 0), Vector3(x1 - (x1 - x0) * 0.3, y1 - r, 0)]
	else: path = [Vector3(x1 - r - 0.004, y0, 0), Vector3(x1 - r - 0.004, y0 + (y1 - y0) * 0.3, 0), Vector3(x0 + r, y0 + (y1 - y0) * 0.6, 0), Vector3(x0 + r, y1 - r * 0.5, 0)]
	var round := Kit.round_path(path, (x1 - x0) * 0.4, 5)
	var tube := Kit.tube(round, r, 10, r * 0.82)
	var joints := Geo.new()
	for i in range(0, round.size(), 4):
		var j: Vector3 = round[i]
		joints.append(Kit.sphere(r * 1.22, 10).translate(j.x, j.y, j.z))
	var out := [_p(tube, _role_mat(piece, "trim")), _p(joints, "dark")]
	if sting:
		var from: Vector3 = round[round.size() - 1]
		out.append(_p(Kit.tube([from, Vector3(x1, y0 + 0.008, 0)], r * 0.9, 10, 0.002), "steel"))
	return out

# A wedge as it is welded up: a plate on cheeks and ribs, hinged at the body.
static func _wedge(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var x0: float = b.min.x
	var x1: float = b.max.x
	var y0: float = b.min.y
	var rise: float = b.max.y - y0
	var hw: float = b.max.z
	var run := x1 - x0
	if run < 0.06 or rise < 0.02: return null
	var t := 0.012
	var slope := Vector2(run, -rise).normalized()
	var nrm := Vector2(-slope.y, slope.x)                 # out of the face, up and forward
	var plate := Geo.hull([
		Vector3(x0, y0 + rise, hw), Vector3(x0, y0 + rise, -hw), Vector3(x1, y0 + 0.002, hw), Vector3(x1, y0 + 0.002, -hw),
		Vector3(x0, y0 + rise - t * 1.1, hw), Vector3(x0, y0 + rise - t * 1.1, -hw), Vector3(x1 - 0.03, y0, hw), Vector3(x1 - 0.03, y0, -hw),
	])
	var ribs := Geo.new()
	var rib := PackedVector2Array([Vector2(x0, y0 + 0.006), Vector2(x0 + run * 0.78, y0 + 0.006), Vector2(x0, y0 + rise - t * 1.4)])
	var n := clampi(int(round(hw * 2.0 / 0.14)), 3, 7)
	for i in n:
		var z := -hw + 0.006 + (hw * 2.0 - 0.012) * float(i) / (n - 1)
		ribs.append(Geo.extrude(rib, 0.01, 0.0).translate(0, 0, z))
	# Hinge barrels along the top edge, and the bolts that hold the plate down.
	var hinge := Geo.new()
	var hn := clampi(int(round(hw * 2.0 / 0.16)), 2, 5)
	for i in hn:
		var z := -hw * 0.8 + hw * 1.6 * float(i) / (hn - 1)
		hinge.append(Geo.cylinder(0.011, 0.011, 0.05, 10).rotate_x(PI / 2.0).translate(x0 + 0.004, y0 + rise - 0.012, z))
	var up := Vector3(nrm.x, nrm.y, 0)
	var at := Vector2(x0, y0 + rise) + slope * (run * 0.2)
	var bolts := Kit.bolt_row(Vector3(at.x, at.y, hw * 0.88), Vector3(at.x, at.y, -hw * 0.88), up, 0.005, 0.09)
	return [_p(plate, _role_mat(piece)), _p(ribs, "dark"), _p(hinge, "hub"), _p(bolts, "dark")]

# A fork: a blade cut from plate with a swept top edge, hinged in a clevis at
# its root - not a fat prism. The blade lies inside the prism physics uses.
static func _forks(piece: Dictionary, c: Ctx):
	var style := c.pick("forks", ["blade", "blade", "twin", "saw"])
	# A shoe is the wedgelet as physics has it; it only changes what it is made of.
	if style == "shoe":
		var shoe_mat := str(J.g(c.look, "forkMat", ""))
		return [_p(Geo.rounded_hull(piece.points, 0.008), shoe_mat)] if shoe_mat != "" else null
	var b: Dictionary = Hull.bounds(piece.points)
	var x0: float = b.min.x
	var x1: float = b.max.x
	var y0: float = b.min.y
	var back: float = b.max.y - y0
	var zc: float = (b.min.z + b.max.z) / 2.0
	var w: float = b.max.z - b.min.z
	var length := x1 - x0
	if length < 0.05 or back < 0.014: return null
	var mat := c.pick("forkMat", ["steel", "steel", "accent", "dark"])
	# The prism's top edge: nothing of the blade stands above it.
	var edge := func(x: float) -> float:
		return y0 + back + (0.006 - back) * (x - x0) / length - 0.002
	var root := minf(0.05, length * 0.26)
	var xr := x0 + root * 0.7
	var steps := 12 if style == "saw" else 8
	var prof := PackedVector2Array([Vector2(x0, y0 + 0.001), Vector2(x1, y0 + 0.001), Vector2(x1, y0 + 0.004)])
	var curve := Geo.quad_curve(Vector2(x1, y0 + 0.004), Vector2(x0 + length * 0.45, y0 + back * 0.1 + 0.004), Vector2(xr, edge.call(xr)), steps)
	for i in curve.size():
		var q := curve[i]
		q.y = minf(q.y, edge.call(q.x))
		if style == "saw" and i % 2 == 0 and i < curve.size() - 2:
			q.y += (float(edge.call(q.x)) - q.y) * 0.65
		prof.append(q)
	prof.append(Vector2(x0, edge.call(x0)))
	var blades := Geo.new()
	var pins := Geo.new()
	var cheeks := Geo.new()
	var pin_r := minf(0.008, back * 0.16)
	if style == "twin":
		var tb := clampf(w * 0.2, 0.008, 0.013)
		for s in [-1.0, 1.0]:
			blades.append(Geo.extrude(prof, tb, 0.002).translate(0, 0, zc + s * (w / 2.0 - tb / 2.0 - 0.001)))
		pins.append(Geo.cylinder(pin_r, pin_r, w * 0.96, 8).rotate_x(PI / 2.0).translate(x0 + root * 0.55, y0 + back * 0.5, zc))
		var xm := x0 + length * 0.5
		pins.append(Geo.cylinder(pin_r * 0.8, pin_r * 0.8, w * 0.96, 8).rotate_x(PI / 2.0).translate(xm, y0 + 0.004 + pin_r, zc))
	else:
		var tb := clampf(w * 0.3, 0.012, 0.022)
		blades.append(Geo.extrude(prof, tb, 0.003).translate(0, 0, zc))
		for s in [-1.0, 1.0]:
			cheeks.append(Geo.box(root, back * 0.6, 0.008).translate(x0 + root / 2.0 - 0.003, y0 + back * 0.4, zc + s * (tb / 2.0 + 0.0045)))
		pins.append(Geo.cylinder(pin_r, pin_r, tb + 0.03, 8).rotate_x(PI / 2.0).translate(x0 + root * 0.55, y0 + back * 0.48, zc))
	var out := [_p(blades, mat), _p(pins, "hub")]
	if cheeks.count() > 0: out.append(_p(cheeks, "dark"))
	return out

# A spike: a turned point on a hex base.
static func _spike(piece: Dictionary, _c: Ctx):
	var pts: Array = piece.points
	if pts.size() != 5: return null
	var tip: Vector3 = pts[4]
	var x0: float = (pts[0] as Vector3).x
	var r: float = absf((pts[0] as Vector3).y - tip.y)
	var length := tip.x - x0
	if length < 0.02 or r < 0.008: return null
	var point := Geo.cylinder(0.0, r * 0.7, length - 0.012, 14).rotate_z(-PI / 2.0).translate(x0 + 0.012 + (length - 0.012) / 2.0, tip.y, tip.z)
	var base := Geo.cylinder(r * 0.92, r * 0.92, 0.014, 6).rotate_z(-PI / 2.0).translate(x0 + 0.006, tip.y, tip.z)
	return [_p(point.tile_uvs(), "steel"), _p(base, "dark")]

# A roll hoop: two bent tubes with rungs between them, feet on the body.
static func _hoop(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var xc: float = (b.min.x + b.max.x) / 2.0
	var hw: float = (b.max.x - b.min.x) / 2.0
	var crown_y: float = b.max.y
	# The feet, each side, and how wide the crown is.
	var foot := {1.0: INF, -1.0: INF}
	var crown := 0.0
	for q in piece.points:
		var s := 1.0 if q.z >= 0.0 else -1.0
		if q.y < crown_y - 0.004: foot[s] = minf(foot[s], q.y)
		else: crown = maxf(crown, absf(q.z))
	var half: float = maxf(absf(b.max.z), absf(b.min.z))
	if foot[1.0] == INF or foot[-1.0] == INF or crown <= 0.0: return null
	var rt := clampf(hw * 0.32, 0.007, 0.012)
	var tubes := Geo.new()
	var feet := Geo.new()
	for dx in [-1.0, 1.0]:
		var x: float = xc + dx * (hw - rt)
		var path := Kit.round_path([
			Vector3(x, foot[1.0] - 0.004, half - rt), Vector3(x, crown_y - rt, crown - rt),
			Vector3(x, crown_y - rt, -(crown - rt)), Vector3(x, foot[-1.0] - 0.004, -(half - rt)),
		], 0.035, 5)
		tubes.append(Kit.tube(path, rt, 8))
		for s in [1.0, -1.0]:
			feet.append(Geo.cylinder(rt * 1.8, rt * 1.8, 0.008, 10).translate(x, foot[s] + 0.003, s * (half - rt)))
	var n := clampi(int(round(crown * 2.0 / 0.09)), 2, 5)
	for i in n:
		var z := -crown * 0.7 + crown * 1.4 * float(i) / (n - 1)
		tubes.append(Kit.tube([Vector3(xc - hw + rt, crown_y - rt, z), Vector3(xc + hw - rt, crown_y - rt, z)], rt * 0.8, 6))
	return [_p(tubes, _role_mat(piece)), _p(feet, "dark")]

# A fin: a plate with lightening holes on a bolted foot.
static func _fin(piece: Dictionary, c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var x0: float = b.min.x
	var x1: float = b.max.x
	var lo: float = b.min.y
	var zc: float = (b.min.z + b.max.z) / 2.0
	var peak := Vector3.ZERO
	for q in piece.points:
		if q.y > peak.y or peak == Vector3.ZERO: peak = q
	var h := peak.y - lo
	if x1 - x0 < 0.05 or h < 0.03: return null
	var prof := PackedVector2Array([Vector2(x0, lo), Vector2(x1, lo), Vector2(x1, lo + minf(0.012, h * 0.2)),
		Vector2(peak.x + (x1 - peak.x) * 0.08, peak.y), Vector2(peak.x - (peak.x - x0) * 0.3, peak.y), Vector2(x0, lo + h * 0.45)])
	var holes := []
	if c.pick("fin", ["holes", "holes", "plain"]) == "holes":
		var a := Vector2(x0 + (x1 - x0) * 0.12, lo + h * 0.3)
		var e := Vector2(x1 - (x1 - x0) * 0.2, lo + h * 0.16)
		holes = Kit.lightening(Kit.outline_of(Array(prof)), a, e, 3, [], h * 0.22, 0.011)
	var t := 0.011
	var plate := Geo.extrude(prof, t, 0.002, holes).translate(0, 0, zc)
	var foot := Geo.box((x1 - x0) * 0.94, 0.008, 0.04).translate((x0 + x1) / 2.0, lo + 0.008, zc)
	return [_p(plate, _role_mat(piece, "accent")), _p(foot, "dark")]

# An exhaust stack: a flanged pipe, flared and open at the top.
static func _stack(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var cx: float = (b.min.x + b.max.x) / 2.0
	var cz: float = (b.min.z + b.max.z) / 2.0
	var r: float = (b.max.x - b.min.x) / 2.0
	var y0: float = b.min.y
	var y1: float = b.max.y
	if y1 - y0 < 0.04 or r < 0.012: return null
	var pipe := Geo.lathe([Vector2(r * 0.94, y0), Vector2(r * 0.94, y0 + 0.01), Vector2(r * 0.7, y0 + 0.01), Vector2(r * 0.7, y1 - 0.03), Vector2(r * 0.88, y1)], 16)
	var bore := Geo.lathe([Vector2(r * 0.88, y1), Vector2(r * 0.76, y1), Vector2(r * 0.6, y1 - 0.04), Vector2(0.001, y1 - 0.04)], 16)
	var bolts := Kit.bolt_circle(6, r * 0.82, 0.005).translate(0, y0 + 0.01, 0)
	return Kit.shift([_p(pipe, "hub"), _p(bore, "black"), _p(bolts, "dark")], Vector3(cx, 0, cz))

# An eye: a ball in a socket, looking forward.
static func _eye(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var cx: float = (b.min.x + b.max.x) / 2.0
	var cz: float = (b.min.z + b.max.z) / 2.0
	var r: float = (b.max.x - b.min.x) / 2.0
	var y0: float = b.min.y
	var y1: float = b.max.y
	if r < 0.012 or y1 - y0 < r: return null
	var rb := minf(r * 0.9, (y1 - y0) * 0.5)
	var at := Vector3(cx, y1 - rb, cz)
	var look := Vector3(0.94, 0.34, 0.0).normalized()
	var socket := Geo.cylinder(rb * 0.75, r * 0.92, at.y - y0, 14).translate(cx, (at.y + y0) / 2.0, cz)
	return [
		_p(socket, "dark"),
		_p(Kit.sphere(rb, 16).translate(at.x, at.y, at.z), "white"),
		_p(Kit.sphere(rb * 0.52, 12).apply(Transform3D(Basis.IDENTITY, at + look * rb * 0.56)), "accent"),
		_p(Kit.sphere(rb * 0.3, 10).apply(Transform3D(Basis.IDENTITY, at + look * rb * 0.82)), "black"),
	]

# A dome: turned smooth, on a bolted ring.
static func _dome(piece: Dictionary, c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var cx: float = (b.min.x + b.max.x) / 2.0
	var R: float = (b.max.x - b.min.x) / 2.0
	var y0: float = b.min.y
	var y1: float = b.max.y
	# The shoulder ring: the points that are neither the rim nor the crown.
	var ys := y0
	for q in piece.points:
		if q.y > y0 + 0.002 and q.y < y1 - 0.002: ys = q.y
	if R < 0.03 or y1 - y0 < 0.02 or ys <= y0: return null
	var k := 0.94          # inside the ten-sided piece physics uses
	var prof := [Vector2(R * k, y0), Vector2(R * k, y0 + (ys - y0) * 0.25)]
	prof.append_array(Array(Geo.cubic_curve(Vector2(R * k, y0 + (ys - y0) * 0.25), Vector2(R * k * 0.98, ys - (ys - y0) * 0.2), Vector2(R * 0.72, y1), Vector2(0.001, y1), 12)))
	var mat := c.pick("dome", ["trim", "trim", "poly", "steel"])
	var ring := Geo.cylinder(R * 0.99, R * 0.99, 0.012, 24, true).translate(0, y0 + 0.012, 0)
	var bolts := Geo.new()
	for i in 10:
		var a := TAU * (i + 0.5) / 10.0
		bolts.append(Kit.bolt(0.005).apply(Kit.along(Vector3(sin(a), 0, cos(a)), Vector3(sin(a) * R * 0.99, y0 + 0.012, cos(a) * R * 0.99))))
	return Kit.shift([_p(Geo.lathe(prof, 24), mat), _p(ring, "dark"), _p(bolts, "hub")], Vector3(cx, 0, (b.min.z + b.max.z) / 2.0))

# A plow: a plate raked forward on gussets, the way one is welded up.
static func _plow(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var xb: float = b.min.x
	var xf: float = b.max.x
	var yb: float = b.min.y
	var h: float = b.max.y - yb
	var half: float = b.max.z
	if xf - xb < 0.05 or h < 0.03: return null
	var t := 0.012
	var run := xf - xb
	var slope := Vector2(run, 0.006 - h).normalized()
	var down := Vector2(slope.y, -slope.x) * t          # into the plow, square to its face
	var blade := Geo.hull([
		Vector3(xb, yb + h, half), Vector3(xb, yb + h, -half), Vector3(xf, yb + 0.006, half * 0.92), Vector3(xf, yb + 0.006, -half * 0.92),
		Vector3(xb, yb + h + down.y * 1.2, half), Vector3(xb, yb + h + down.y * 1.2, -half), Vector3(xf - 0.02, yb + 0.001, half * 0.92), Vector3(xf - 0.02, yb + 0.001, -half * 0.92),
	])
	var ribs := Geo.new()
	var rib := PackedVector2Array([Vector2(xb, yb + 0.012), Vector2(xb + run * 0.72, yb + 0.012), Vector2(xb, yb + h - t * 1.6)])
	var n := clampi(int(round(half * 2.0 / 0.13)), 3, 7)
	for i in n:
		var z := -half * 0.9 + half * 1.8 * float(i) / (n - 1)
		ribs.append(Geo.extrude(rib, 0.008, 0.0).translate(0, 0, z * (0.96 if absf(z) > half * 0.8 else 1.0)))
	ribs.append(Geo.box(0.012, h * 0.7, half * 1.9).translate(xb + 0.004, yb + h * 0.42, 0))
	return [_p(blade, _role_mat(piece)), _p(ribs, "dark")]

# A mast: a tube on a flange, braced by gussets.
static func _mast(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var cx: float = (b.min.x + b.max.x) / 2.0
	var cz: float = (b.min.z + b.max.z) / 2.0
	var r: float = minf(b.max.x - b.min.x, b.max.z - b.min.z) / 2.0
	var y0: float = b.min.y
	var y1: float = b.max.y
	if y1 - y0 < 0.03 or r < 0.015: return null
	var gussets := Geo.new()
	var gh := minf((y1 - y0) * 0.5, r * 1.4)
	for i in 4:
		var tri := PackedVector2Array([Vector2(r * 0.6, y0 + 0.008), Vector2(r * 0.98, y0 + 0.008), Vector2(r * 0.6, y0 + gh)])
		gussets.append(Geo.extrude(tri, 0.006, 0.0).rotate_y(PI / 4.0 + i * PI / 2.0))
	return Kit.shift([
		_p(Parts.cyl(r * 0.66, r * 0.66, y1 - y0, 14).translate(0, (y0 + y1) / 2.0, 0), _role_mat(piece, "trim")),
		_p(Geo.cylinder(r * 0.98, r * 0.98, 0.012, 16).translate(0, y0 + 0.006, 0), "dark"),
		_p(gussets, "dark"),
		_p(Kit.bolt_circle(6, r * 0.84, 0.0045, 0.3).translate(0, y0 + 0.012, 0), "hub"),
	], Vector3(cx, 0, cz))

# An upright: a tapered plate with a slot through it, bolted down.
static func _upright(piece: Dictionary, _c: Ctx):
	var b: Dictionary = Hull.bounds(piece.points)
	var cx: float = (b.min.x + b.max.x) / 2.0
	var hx: float = (b.max.x - b.min.x) / 2.0
	var cz: float = (b.min.z + b.max.z) / 2.0
	var hz: float = (b.max.z - b.min.z) / 2.0
	var y0: float = b.min.y
	var y1: float = b.max.y
	if y1 - y0 < 0.04: return null
	var prof := PackedVector2Array([Vector2(cx - hx, y0), Vector2(cx + hx, y0), Vector2(cx + hx, y0 + 0.02), Vector2(cx + hx * 0.5, y1), Vector2(cx - hx * 0.5, y1), Vector2(cx - hx, y0 + 0.02)])
	var holes := Kit.lightening(prof, Vector2(cx, y0 + 0.015), Vector2(cx, y1 - 0.008), 2, [], hx * 0.5, 0.011)
	var plates := Geo.new()
	for s in [-1.0, 1.0]:
		plates.append(Geo.extrude(prof, 0.011, 0.002, holes).translate(0, 0, cz + s * (hz - 0.0055)))
	var ties := Geo.new()
	ties.append(Geo.box(hx * 2.0, 0.012, hz * 2.0).translate(cx, y0 + 0.006, cz))
	ties.append(Geo.cylinder(0.008, 0.008, hz * 2.0, 8).rotate_x(PI / 2.0).translate(cx, y1 - 0.014, cz))
	return [_p(plates, _role_mat(piece, "trim")), _p(ties, "dark")]

# A horn: a tapering bar curving up from a collar.
static func _horn(piece: Dictionary, _c: Ctx):
	var pts: Array = piece.points
	var tip: Vector3 = pts[pts.size() - 1]
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in pts.size() - 1:
		lo = lo.min(pts[i])
		hi = hi.max(pts[i])
	var r: float = (hi.x - lo.x) / 2.0
	var base := Vector3((lo.x + hi.x) / 2.0, lo.y, (lo.z + hi.z) / 2.0)
	if r < 0.01 or tip.y - base.y < 0.03: return null
	var mid := base.lerp(tip, 0.45) + Vector3(-0.1, 0.08, 0.0) * base.distance_to(tip) * 0.5
	var path := [base]
	for k in range(1, 9):
		var t := k / 8.0
		path.append(base.lerp(mid, t).lerp(mid.lerp(tip, t), t))
	var horn := Kit.tube(path, r * 0.72, 10, 0.003)
	var collar := Geo.cylinder(r * 0.95, r * 0.95, 0.012, 12).translate(base.x, base.y + 0.008, base.z)
	return [_p(horn, _role_mat(piece)), _p(collar, "dark")]

# The plate that carries a bar's bearing out over the hub: cut as a truss,
# solid round the bearing.
static func _arm_plate(piece: Dictionary, c: Ctx):
	if not (c.wv is Dictionary) or c.wv.get("center") == null: return null
	var style := c.pick("supports", ["truss", "truss", "plate"])
	if style == "solid": return null
	var b: Dictionary = Hull.bounds(piece.points)
	var x0: float = b.min.x
	var x1: float = b.max.x
	var y0: float = b.min.y
	var y1: float = b.max.y
	var hw0 := 0.0
	var hw1 := 0.0
	for q in piece.points:
		if q.x < x0 + 0.001: hw0 = maxf(hw0, absf(q.z))
		if q.x > x1 - 0.001: hw1 = maxf(hw1, absf(q.z))
	var cx: float = (c.wv.center as Vector3).x
	var depth := y1 - y0
	if depth < 0.006 or x1 - x0 < 0.06: return null
	var mat := c.pick("supportMat", [_role_mat(piece), _role_mat(piece), "trim", "dark"])
	var boss_r := hw1 * 0.98
	var xe := minf(cx - boss_r * 0.5, x1 - 0.02)          # where the truss gives way to the solid boss
	var hwe := lerpf(hw0, hw1, (xe - x0) / (x1 - x0))
	var out := Geo.new()
	var outline := PackedVector2Array([Vector2(x0, -hw0), Vector2(xe, -hwe), Vector2(xe, hwe), Vector2(x0, hw0)])
	if style == "truss" and xe - x0 > 0.07:
		out.append(Kit.truss(outline, depth, clampf(hw1 * 0.34, 0.012, 0.026)))
	else:
		var holes := Kit.lightening(outline, Vector2(x0 + 0.02, 0), Vector2(xe - 0.01, 0), 3, [], hw0 * 0.55, 0.012)
		out.append(Geo.extrude(outline, depth, 0.003, holes))
	# The outline is drawn in (x, z); stand it up so its depth runs along Y.
	out.rotate_x(PI / 2.0).translate(0, (y0 + y1) / 2.0, 0)
	var nose := PackedVector2Array([Vector2(xe - 0.004, -hwe), Vector2(x1, -hw1), Vector2(x1, hw1), Vector2(xe - 0.004, hwe)])
	out.append(Geo.extrude(nose, depth, 0.003).rotate_x(PI / 2.0).translate(0, (y0 + y1) / 2.0, 0))
	var cap := Geo.cylinder(boss_r * 0.7, boss_r * 0.7, 0.006, 16).translate(cx, y1 + 0.002, 0)
	var top: bool = piece.id == "extra:pod:0"
	var bolts := Kit.bolt_circle(6, boss_r * 0.52, 0.0045).translate(cx, y1 + 0.004, 0)
	if not top:
		cap.translate(0, y0 - y1 - 0.004, 0)
		bolts = Kit.bolt_circle(6, boss_r * 0.52, 0.0045).rotate_x(PI).translate(cx, y0 - 0.004, 0)
	return [_p(out, mat), _p(cap, "hub"), _p(bolts, "dark")]

# What carries a disc or drum's axle: a plate in its own side profile with
# lightening holes, solid round the bearing.
static func _support(piece: Dictionary, c: Ctx):
	if not (c.wv is Dictionary) or c.wv.get("center") == null: return null
	var style := c.pick("supports", ["truss", "plate", "plate"])
	if style == "solid": return null
	var b: Dictionary = Hull.bounds(piece.points)
	var flat := []
	for q in piece.points: flat.append(Vector2(q.x, q.y))
	var outline := Kit.outline_of(flat)
	if outline.size() < 3: return null
	var axle := Vector2((c.wv.center as Vector3).x, (c.wv.center as Vector3).y)
	var boss: float = J.path(c.wv, ["axle", "bossR"], 0.04)
	var depth: float = b.max.z - b.min.z
	var zc: float = (b.min.z + b.max.z) / 2.0
	# From the middle of its back edge towards the bearing.
	var rear := Vector2(b.min.x, 0.0)
	var span := Kit._span_at(outline, b.min.x + 0.004)
	rear.y = ((span[0] + span[1]) / 2.0) if not span.is_empty() else axle.y
	var holes := Kit.lightening(outline, rear.lerp(axle, 0.08), axle, 3, [[axle, boss * 0.95]], 0.045, 0.013)
	var plate := Geo.extrude(outline, depth * 0.94, 0.004, holes).translate(0, 0, zc)
	var s := signf(zc)
	var bolts := Geo.new()
	for i in 6:
		var a := TAU * (i + 0.5) / 6.0
		bolts.append(Kit.bolt(0.0045).apply(Kit.along(Vector3(0, 0, s), Vector3(axle.x + cos(a) * boss * 0.86, axle.y + sin(a) * boss * 0.86, zc + s * depth * 0.47))))
	var mat := c.pick("supportMat", ["trim", "trim", "accent", "dark", "steel"])
	return [_p(plate, mat), _p(bolts, "hub")]

# A hammer's pivot: two cheek plates rising to the bearing, on a base plate.
static func _tower(piece: Dictionary, c: Ctx):
	if not (c.wv is Dictionary) or c.wv.get("pivot") == null: return null
	var b: Dictionary = Hull.bounds(piece.points)
	var P: Vector3 = c.wv.pivot
	var x0: float = b.min.x
	var x1: float = b.max.x
	var ylo: float = b.min.y
	var hz: float = b.max.z
	var rho: float = minf(minf(P.x - x0, x1 - P.x), b.max.y - P.y) * 0.96
	if rho < 0.02 or P.y - ylo < 0.02: return null
	var prof := PackedVector2Array([Vector2(x0, ylo), Vector2(x1, ylo), Vector2(x1, ylo + 0.022)])
	for i in range(11):
		var a := -0.35 + (PI + 0.7) * i / 10.0
		prof.append(Vector2(P.x + cos(a) * rho, P.y + sin(a) * rho))
	prof.append(Vector2(x0, ylo + 0.022))
	var pivot2 := Vector2(P.x, P.y)
	var holes := Kit.lightening(Kit.outline_of(Array(prof)), Vector2(P.x, ylo + 0.02), pivot2, 1, [[pivot2, rho * 0.62]], rho * 0.6, 0.012)
	var plates := Geo.new()
	var bosses := Geo.new()
	var t := 0.02
	for s in [-1.0, 1.0]:
		plates.append(Geo.extrude(prof, t, 0.003, holes).translate(0, 0, s * (hz - t / 2.0)))
		bosses.append(Geo.cylinder(rho * 0.5, rho * 0.5, 0.008, 14).rotate_x(PI / 2.0).translate(P.x, P.y, s * (hz + 0.002)))
	var ties := Geo.new()
	ties.append(Geo.box(x1 - x0, 0.014, hz * 2.0).translate((x0 + x1) / 2.0, ylo + 0.007, 0))
	for x in [x0 + 0.014, x1 - 0.014]:
		ties.append(Geo.cylinder(0.008, 0.008, hz * 2.0 - 0.01, 8).rotate_x(PI / 2.0).translate(x, ylo + 0.03, 0))
	return [_p(plates, c.pick("supportMat", ["trim", "trim", "accent", "steel"])), _p(bosses, "hub"), _p(ties, "dark")]

# ---------------------------------------------------------------- the weapon's drive

# How big the weapon motor is: [radius, length].
static func _motor_size(c: Ctx) -> Array:
	var w: float = J.path(c.assembled, ["parts", "weaponMotor", "spec", "powerW"], 3000.0)
	return [0.024 + w * 3.0e-6, 0.045 + w * 7.0e-6]

# Saddles under a round part lying along `axis` (a unit vector along X or Z)
# centred at `at`: from the deck up to its underside.
static func _cradles(c: Ctx, at: Vector3, axis: Vector3, r: float, length: float, deck_lo: float) -> Geo:
	var g := Geo.new()
	var across := Vector3(axis.z, 0, axis.x).abs()
	for k in [-0.3, 0.3]:
		var p: Vector3 = at + axis * (length * k)
		var h := at.y - r * 0.2 - (deck_lo - 0.006)
		var size := across * (r * 1.8) + axis.abs() * 0.008 + Vector3(0, h, 0)
		g.append(Geo.box(size.x, size.y, size.z).translate(p.x, deck_lo - 0.006 + h / 2.0, p.z))
	return g

static func _drive(c: Ctx, items: Array) -> void:
	if not (c.wv is Dictionary): return
	var want := str(J.g(c.look, "drive", ""))
	if want == "none": return
	var wv: Dictionary = c.wv
	if wv.kind == "rotor":
		if wv.get("style") == "shell": return                 # all of it is under the shell
		if wv.axis == "z": _drive_vertical(c, items, want)
		else: _drive_horizontal(c, items, want)
	elif wv.kind == "arm": _drive_hammer(c, items, want)
	elif wv.kind == "jaw": _drive_ram(c, items)
	elif wv.kind == "plate": _drive_plate(c, items)

# A disc or drum on its axle: a pulley beside the rotor and a belt back to
# the motor - on a cradle on the deck behind the slot, or inside the body with
# only the belt showing.
static func _drive_vertical(c: Ctx, items: Array, want: String) -> void:
	var wv: Dictionary = c.wv
	if not (wv.get("axle") is Dictionary): return
	var C: Vector3 = wv.center
	var r: float = wv.radius
	var half_w: float = wv.thickness / 2.0
	var gap: float = Shape._mount_gauge(r).gap
	var rp := clampf(r * 0.34, 0.03, 0.075)
	var size := _motor_size(c)
	var rm: float = size[0]
	var lm: float = size[1]
	var rmp := clampf(rm * 0.5, 0.012, 0.02)
	var bw := gap - 0.0035
	var sides := [-1.0, 1.0] if c.roll("driveSide") < 0.5 else [1.0, -1.0]
	var belts := int(J.g(c.look, "belts", 1))
	var modes := ["deck", "inboard"]
	if want == "inboard": modes = ["inboard", "deck"]
	elif want == "" and c.roll("drive") < 0.3: modes = ["inboard", "deck"]
	var made := 0
	for s in sides:
		if made >= belts: break
		var zb: float = s * (half_w + gap / 2.0)
		var driven := Geo.cylinder(rp, rp, gap - 0.004, 20).rotate_x(PI / 2.0).translate(C.x, C.y, zb)
		var done := false
		for mode in modes:
			if done: break
			if mode == "deck":
				# Back from the slot until there is deck to stand on, and up
				# until the belt clears the body's edge.
				for step in 10:
					if done: break
					var xm: float = C.x - r - rm - 0.014 - step * 0.012
					var zm: float = zb - s * (lm * 0.5 + 0.006)
					var seat := c.body.seat(xm, zm, rm * 0.7, lm * 0.45)
					if seat.is_empty() or seat[1] - seat[0] > 0.03:
						trace.append("deck drive at x %.3f: no flat deck %s" % [xm, str(seat)])
						continue
					for lift in [0.0, 0.02, 0.04]:
						var ym: float = seat[1] + rm + 0.005 + lift
						var parts := Kit.place(Kit.motor(rm, lm, 0.012), Kit.along(Vector3(0, 0, s), Vector3(xm, ym, zb - s * (lm + 0.006))))
						parts.append_array(Kit.place(Kit.pulley(rmp, bw), Kit.along(Vector3(0, 0, s), Vector3(xm, ym, zb))))
						parts.append(_p(_cradles(c, Vector3(xm, ym, zm), Vector3(0, 0, 1), rm, lm, seat[0]), "black"))
						var belt := [_p(Kit.belt(Vector2(C.x, C.y), rp, Vector2(xm, ym), rmp, bw).translate(0, 0, zb), "rubber")]
						var why := c.check.fit(parts, [], 0.3)
						if why == "": why = "belt " + c.check.clear(belt)
						if why != "belt ":
							trace.append("deck drive at x %.3f lift %.2f: %s" % [xm, lift, why])
							continue
						parts.append_array(belt)
						parts.append(_p(driven, "hub"))
						_add(c, items, "drive:%d" % made, parts)
						done = true
						break
			else:
				# A pulley inside the body: the belt runs back into the wall.
				for step in 8:
					var xh: float = C.x - r - 0.03 - step * 0.012
					var roof := c.body.top(xh, zb)
					if roof == -INF:
						trace.append("inboard drive at x %.3f: no body" % xh)
						continue
					var yh := clampf(C.y, c.yb + rmp + 0.016, roof - rmp - 0.016)
					var far := (Vector2(xh, yh) - Vector2(C.x, C.y)).normalized() * (rmp + 0.006)
					if c.body.depth(Vector3(xh, yh, zb), true) < 0.006 or c.body.depth(Vector3(xh + far.x, yh + far.y, zb), true) < 0.002:
						trace.append("inboard drive at x %.3f y %.3f z %.3f (roof %.3f floor %.3f): body too thin (%.3f)" % [xh, yh, zb, roof, c.yb, c.body.depth(Vector3(xh, yh, zb), true)])
						continue
					var belt := [_p(Kit.belt(Vector2(C.x, C.y), rp, Vector2(xh, yh), rmp, bw).translate(0, 0, zb), "rubber")]
					var why := c.check.fit(belt, [], 1.0, false)
					if why != "":
						trace.append("inboard drive at x %.3f: %s" % [xh, why])
						continue
					belt.append(_p(driven, "hub"))
					_add(c, items, "drive:%d" % made, belt)
					done = true
					break
		if done: made += 1
	if made > 0: return
	# No room for a belt: the motor is in the rotor's hub, and what shows is
	# its end, bolted to the outside of a support.
	var ax: Dictionary = wv.axle
	for s in sides:
		var sup = c.body.piece("weapon:support:%s" % ("L" if s > 0.0 else "R"))
		if sup == null: continue
		var rh := minf(float(ax.bossR) * 0.82, rm)
		var parts := Kit.place(Kit.motor(rh, 0.03, 0.0), Kit.along(Vector3(0, 0, s), Vector3(C.x, C.y, s * (float(ax.halfLen) - 0.003))))
		var why := c.check.fit(parts, [sup.id], 0.3)
		if why != "":
			trace.append("hub motor side %d: %s" % [int(s), why])
			continue
		_add(c, items, "drive:0", parts)
		return

# A bar or disc on an upright shaft: the motor is a can on the hub, over the
# bearing plate (or, with "engine", an engine in its housing).
static func _drive_horizontal(c: Ctx, items: Array, want: String) -> void:
	var wv: Dictionary = c.wv
	var C: Vector3 = wv.center
	var half: float = wv.thickness / 2.0
	var size := _motor_size(c)
	var rm: float = size[0] * 1.15
	var pod = c.body.piece("extra:pod:0")
	var base_y: float
	var into := []
	if pod != null:
		base_y = (pod.hi as Vector3).y
		into = ["extra:pod:0"]
	elif c.body.piece("weapon:mast") != null:
		base_y = C.y + maxf(half * 1.5, half + 0.002) + 0.003            # on the rotor's own hub
		into = ["weapon:mast"]
	else:
		# Round the middle of a round body: the motor stands on its crown.
		base_y = c.body.top(C.x, 0.0)
		if base_y == -INF or base_y < C.y + half: return
	var on_body: bool = pod != null or into.is_empty()
	var sits := func(parts: Array) -> String:
		if on_body: return c.check.fit(parts, into, 0.3)
		# Carried by the mast through the hub: it only has to be clear.
		for q in samples(parts):
			var why := c.check.blocked(q)
			if why != "": return why
		return ""
	if want == "engine":
		var parts := _engine(Vector3(C.x, base_y, 0), rm)
		if sits.call(parts) == "":
			if not on_body: parts.append(_p(Geo.cylinder(0.02, 0.02, base_y - C.y - half, 12).translate(C.x, (C.y + half + base_y) / 2.0 + 0.004, 0), "hub"))
			items.append({"id": "drive:0", "parts": parts, "carried": not on_body})
			c.check.take(parts)
			return
	for lm in [minf(size[1], 0.075), 0.045, 0.026]:
		var r_use: float = rm if lm > 0.03 else rm * 1.5
		var parts := Kit.shift(Kit.motor(r_use, lm, 0.0), Vector3(C.x, base_y, 0))
		if sits.call(parts) != "": continue
		# Its leads, back along the plate and down into the body.
		if pod != null:
			var x_back: float = (pod.lo as Vector3).x
			var lead := [_p(Kit.tube(Kit.round_path([Vector3(C.x - r_use * 0.9, base_y + 0.008, 0.012), Vector3(x_back + 0.02, base_y + 0.005, 0.012), Vector3(x_back - 0.03, base_y - 0.03, 0.012)], 0.02, 4), 0.005, 6), "black")]
			if c.check.fit(lead, into, 1.0, false) == "" and c.body.depth(Vector3(x_back - 0.03, base_y - 0.03, 0.012), true) > 0.0: parts.append_array(lead)
		elif not on_body: parts.append(_p(Geo.cylinder(0.02, 0.02, base_y - C.y - half, 12).translate(C.x, (C.y + half + base_y) / 2.0 + 0.004, 0), "hub"))
		items.append({"id": "drive:0", "parts": parts, "carried": not on_body})
		c.check.take(parts)
		return
	trace.append("hub motor: " + str(sits.call(Kit.shift(Kit.motor(rm * 1.5, 0.026, 0.0), Vector3(C.x, base_y, 0)))))

# An engine in its housing, standing on `at`: what drives an Icewave.
static func _engine(at: Vector3, r: float) -> Array:
	var l := r * 4.2
	var w := r * 3.4
	var h := r * 2.4
	var fins := Geo.new()
	for i in 6:
		fins.append(Geo.box(l * 0.34, h * 0.07, w * 1.04).translate(-l * 0.2, h * (0.2 + 0.12 * i), 0))
	var pipe := Kit.tube(Kit.round_path([Vector3(l * 0.2, h * 0.5, w * 0.5), Vector3(l * 0.2, h * 0.5, w * 0.72), Vector3(-l * 0.45, h * 0.62, w * 0.72)], 0.02, 4), r * 0.28, 8)
	return Kit.shift([
		_p(Parts.box(l, h, w).translate(0, h / 2.0, 0), "black"),
		_p(fins, "hub"),
		_p(pipe, "hub"),
		_p(Geo.cylinder(r * 0.4, r * 0.4, 0.012, 12).translate(l * 0.22, h + 0.004, -w * 0.2), "accent"),
		_p(Kit.bolt_circle(4, r * 1.1, 0.005, PI / 4.0).translate(0, h, 0), "hub"),
	], at)

# A hammer or axe: a gearmotor on the side of the pivot tower.
static func _drive_hammer(c: Ctx, items: Array, _want: String) -> void:
	var tower = c.body.piece("weapon:pivot")
	if tower == null: return
	var P: Vector3 = c.wv.pivot
	var hz: float = (tower.hi as Vector3).z
	var size := _motor_size(c)
	var rm: float = size[0] * 1.1
	var sides := [-1.0, 1.0] if c.roll("driveSide") < 0.5 else [1.0, -1.0]
	for lm in [minf(size[1], 0.07), 0.04, 0.018]:
		for s in sides:
			var t := Kit.along(Vector3(0, 0, s), Vector3(P.x, P.y, s * (hz + 0.001)))
			var parts := Kit.place([_p(Geo.cylinder(rm * 1.25, rm * 1.25, 0.02, 18).translate(0, 0.01, 0), "black")], t)
			parts.append_array(Kit.place(Kit.shift(Kit.motor(rm, lm, 0.0), Vector3(0, 0.02, 0)), t))
			var why := c.check.fit(parts, ["weapon:pivot"], 0.2)
			if why != "":
				trace.append("hammer motor %.0f mm side %d: %s" % [lm * 1000.0, int(s), why])
				continue
			_add(c, items, "drive:0", parts)
			return

# Round things that lie on the deck (a gas bottle, a ram, a motor): tried at
# each of `spots` ([x, z, axis]) until one sits right.
static func _lay(c: Ctx, items: Array, id: String, build: Callable, r: float, length: float, spots: Array, into: Array = []) -> bool:
	for sp in spots:
		var axis: Vector3 = sp[2]
		var hx := (length * 0.45) if absf(axis.x) > 0.5 else r * 0.7
		var hz := (length * 0.45) if absf(axis.z) > 0.5 else r * 0.7
		var seat := c.body.seat(sp[0], sp[1], hx, hz)
		if seat.is_empty() or seat[1] - seat[0] > 0.035:
			trace.append("%s at %.2f %.2f: no flat deck" % [id, sp[0], sp[1]])
			continue
		var at := Vector3(sp[0], seat[1] + r + 0.005, sp[1])
		var parts: Array = Kit.place(build.call(), Kit.along(axis, at - axis * (length / 2.0)))
		parts.append(_p(_cradles(c, at, axis.abs(), r, length, seat[0]), "black"))
		var why := c.check.fit(parts, into, 0.35)
		if why != "":
			trace.append("%s at %.2f %.2f: %s" % [id, sp[0], sp[1], why])
			continue
		_add(c, items, id, parts)
		return true
	return false

# Spots on the deck, from the tail forward, across and along.
static func _deck_spots(c: Ctx, from := -0.4, to := 0.3) -> Array:
	var out := []
	for k in 8:
		var x := c.L * lerpf(from, to, k / 7.0)
		out.append([x, 0.0, Vector3(0, 0, 1)])
		for s in [1.0, -1.0]:
			out.append([x, s * c.W * 0.24, Vector3(1, 0, 0)])
			out.append([x, s * c.W * 0.24, Vector3(0, 0, 1)])
	return out

# The same, slung across the tail on two brackets: where a low machine that
# drives both ways up, or one whose lid covers its deck, has the room.
static func _hang(c: Ctx, items: Array, id: String, build: Callable, r: float, length: float) -> bool:
	for y in [0.0, c.yb + c.H * 0.4, c.yb + c.H * 0.6]:
		# The tail face at this height.
		var tail := NAN
		for k in 60:
			var x := -c.L / 2.0 - 0.06 + k * 0.004
			if c.body.depth(Vector3(x, y, 0), true) > 0.0:
				tail = x
				break
		if is_nan(tail): continue
		for z in [0.0, c.W * 0.2, -c.W * 0.2]:
			var at := Vector3(tail - r - 0.008, y, z)
			var parts: Array = Kit.place(build.call(), Kit.along(Vector3(0, 0, 1), at - Vector3(0, 0, length / 2.0)))
			var brackets := Geo.new()
			for k in [-0.3, 0.3]:
				brackets.append(Geo.box(r * 1.5 + 0.02, r * 1.5, 0.008).translate(tail - r * 0.75 + 0.004, y, z + length * k))
			parts.append(_p(brackets, "black"))
			var why := c.check.fit(parts, [], 0.25)
			if why != "":
				trace.append("%s on the tail at y %.2f z %.2f: %s" % [id, y, z, why])
				continue
			_add(c, items, id, parts)
			return true
	return false

# A flipper's gas bottle (or an electric one's gearmotor); a lifter's gearmotor.
static func _drive_plate(c: Ctx, items: Array) -> void:
	var wid := str(J.path(c.assembled, ["parts", "weapon", "id"], ""))
	var size := _motor_size(c)
	if c.cls == "flipper" and not wid.contains("electric"):
		var mat := c.pick("bottle", ["accent", "white", "trim", "hub"])
		for r in [clampf(c.W * 0.075, 0.026, 0.04), 0.024]:
			for length in [minf(0.22, c.W * 0.5), 0.14]:
				if _lay(c, items, "drive:0", func(): return Kit.bottle(r, length, mat), r, length + 0.03, _deck_spots(c)): return
		for r in [0.03, 0.022]:
			if _hang(c, items, "drive:0", func(): return Kit.bottle(r, 0.16, mat), r, 0.19): return
		return
	var rm: float = size[0]
	var lm: float = size[1]
	var spots := _deck_spots(c, 0.3, -0.35) if c.cls == "lifter" else _deck_spots(c)
	var gearmotor := func():
		var parts := [_p(Geo.cylinder(rm * 1.2, rm * 1.2, 0.03, 16).translate(0, lm + 0.015, 0), "black")]
		parts.append_array(Kit.motor(rm, lm, 0.0))
		return parts
	if _lay(c, items, "drive:0", gearmotor, rm * 1.2, lm + 0.03, spots): return
	rm = minf(rm, 0.026)
	_hang(c, items, "drive:0", gearmotor, rm * 1.2, lm + 0.03)

# A crusher: the ram that closes the beak, lying on the deck behind its
# hinge, and the pump that feeds it.
static func _drive_ram(c: Ctx, items: Array) -> void:
	var wv: Dictionary = c.wv
	var px: float = (wv.center as Vector3).x - wv.size.l * 0.5 - 0.08
	var r := 0.026
	for barrel in [0.18, 0.12, 0.08]:
		var rod := 0.05
		var length: float = barrel + rod
		var spots := []
		for z in [0.0, c.W * 0.14, -c.W * 0.14]: spots.append([px - 0.04 - length / 2.0, z, Vector3(1, 0, 0)])
		if _lay(c, items, "drive:0", func(): return Kit.ram(r, barrel, rod), r, length, spots): break
	var size := _motor_size(c)
	_lay(c, items, "drive:pump", func(): return Kit.motor(size[0] * 0.9, size[1] * 0.8, 0.0), size[0] * 0.9, size[1] * 0.8, _deck_spots(c, -0.42, 0.0))

# ---------------------------------------------------------------- frame rails

# Machined rails (or tube) along the body's long edges, standing a little
# proud: the frame a real machine's panels bolt to.
static func _rails(c: Ctx, items: Array) -> void:
	var style := c.pick("frame", ["rails", "rails", "tube", "none"])
	if style == "none": return
	var mat := c.pick("frameMat", ["anod", "hub", "dark", "steel", "trim"])
	var size := 0.016 if style == "rails" else 0.011
	var rails := Geo.new()
	var bolts := Geo.new()
	var seen := {}
	for pc in c.body.pieces:
		if not pc.hull: continue
		var piece: Dictionary = {}
		for p in c.shape.pieces:
			if p.id == pc.id: piece = p
		var cf := Hull.convex_faces(piece.points)
		var faces: Array = cf.faces
		var pts: PackedVector3Array = cf.points
		# Every edge with the two faces that meet on it.
		var edges := {}
		for fi in faces.size():
			var ring: Array = faces[fi].ring
			for k in ring.size():
				var a: int = ring[k]
				var b: int = ring[(k + 1) % ring.size()]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if not edges.has(key): edges[key] = []
				edges[key].append(fi)
		for key in edges:
			var pair: Array = edges[key]
			if pair.size() != 2: continue
			var n0: Vector3 = faces[pair[0]].n
			var n1: Vector3 = faces[pair[1]].n
			if n0.dot(n1) > 0.75: continue                     # not a real corner
			var a: Vector3 = pts[key.x]
			var b: Vector3 = pts[key.y]
			var along := b - a
			var length := along.length()
			if length < 0.09: continue
			var out := (n0 + n1).normalized()
			if out.y < -0.2: continue                          # not along the underside
			var dir := along / length
			var mid := (a + b) / 2.0
			var tag := "%d,%d,%d" % [int(round(mid.x * 250)), int(round(mid.y * 250)), int(round(mid.z * 250))]
			if seen.has(tag): continue
			# On the outside of the whole body, not where two pieces meet.
			if c.body.depth(mid + out * 0.006, true, [pc.id]) > 0.0: continue
			if c.body.depth(mid + out * 0.006, false) > 0.0: continue
			var bar: Geo
			# The face the bolts go in: the one that looks up, or failing that out.
			var face := n0 if (n0.y > n1.y + 0.05 or (absf(n0.y - n1.y) <= 0.05 and absf(n0.z) >= absf(n1.z))) else n1
			var other := n1 if is_same(face, n0) or face == n0 else n0
			if style == "tube": bar = Kit.tube([a + dir * 0.012 - out * 0.003, b - dir * 0.012 - out * 0.003], size, 8)
			else:
				# Square to the bolt face, its outer corner just proud of the
				# body's own corner.
				var z_axis := dir.cross(face).normalized()
				if z_axis.dot(other) < 0.0: z_axis = -z_axis
				var x_axis := face.cross(z_axis).normalized()
				var proud := 0.003
				bar = Geo.box(length - 0.024, size, size).apply(Transform3D(Basis(x_axis, face, z_axis), mid - face * (size / 2.0 - proud) - z_axis * (size / 2.0 - proud)))
			var along_it := []
			var n_pts := maxi(3, int(length / 0.025))
			for k in n_pts + 1:
				var q := a.lerp(b, float(k) / n_pts)
				along_it.append(q + out * 0.007)
				along_it.append(q + n0 * 0.006)
				along_it.append(q + n1 * 0.006)
			if c.check.clear_at(along_it) != "": continue
			var in_way := false
			for q in samples([_p(bar, mat)]):
				if c.check.blocked(q) != "":
					in_way = true
					break
			if in_way: continue
			seen[tag] = true
			rails.append(bar)
			if style != "tube" and length > 0.12:
				bolts.append(Kit.bolt_row(a + dir * 0.03 + face * 0.003 - (dir.cross(face).normalized() * (1.0 if dir.cross(face).dot(other) > 0.0 else -1.0)) * (size / 2.0 - 0.003),
					b - dir * 0.03 + face * 0.003 - (dir.cross(face).normalized() * (1.0 if dir.cross(face).dot(other) > 0.0 else -1.0)) * (size / 2.0 - 0.003), face, 0.0035, 0.07))
	if rails.count() == 0: return
	var parts := [_p(rails, mat)]
	if bolts.count() > 0: parts.append(_p(bolts, "hub"))
	items.append({"id": "frame", "parts": parts})

# ---------------------------------------------------------------- side armour

# Armour outside the wheels, for the machines that hide theirs (a Witch
# Doctor, a Bite Force, a Minotaur - a Tombstone or a HyperShock runs them in
# the open): a plate down each side on stand-offs from the body, with a window
# over each hub - or a tube rail. The tyres show above and below it.
static func _skirts(c: Ctx, items: Array, rig) -> void:
	# Most machines run their wheels in the open: only one in four of those
	# that do not say gets any.
	var style := c.pick("skirts", ["none", "none", "none", "plate"])
	if style == "none": return
	for p in c.shape.pieces:
		if str(p.id).begins_with("extra:wheelGuards") or str(p.id).begins_with("extra:wings") or str(p.id).begins_with("extra:legs"): return
	var st: Dictionary = c.assembled.stats
	var r: float = st.wheelRadiusM
	var w := U.in_to_m(c.assembled.parts.wheel.spec.widthIn)
	var drop: float = rig.rest_length * (1.0 - rig.preload_frac)
	var mat := c.pick("skirtMat", ["accent", "trim", "primary", "steel", "dark"])
	var parts_all := []
	for s in [1.0, -1.0]:
		var xs := []
		var axle := 0.0
		var track := 0.0
		for wh in rig.wheels:
			var a: Vector3 = wh.anchor
			if signf(a.z) != s: continue
			xs.append(a.x)
			axle = a.y - drop
			track = maxf(track, absf(a.z))
		if xs.is_empty(): return
		xs.sort()
		var xa: float = xs[0] - r * 0.92
		var xb: float = xs[xs.size() - 1] + r * 0.92
		var z_in := track + w / 2.0 + 0.008
		var t := 0.022 if style == "bar" else 0.01
		var zm: float = s * (z_in + t / 2.0)
		var ylo := maxf(axle - r * 0.66, float(c.shape.groundY) + 0.02)
		var yhi := axle + r * 0.66
		var parts := []
		if style == "bar":
			var rt := 0.011
			var path := Kit.round_path([Vector3(xa, axle - r * 0.2, zm), Vector3(xa + r * 0.3, axle + r * 0.34, zm), Vector3(xb - r * 0.3, axle + r * 0.34, zm), Vector3(xb, axle - r * 0.2, zm)], 0.03, 4)
			var low := [Vector3(xa + r * 0.1, axle - r * 0.3, zm), Vector3(xb - r * 0.1, axle - r * 0.3, zm)]
			var tubes := Kit.tube(path, rt, 8)
			tubes.append(Kit.tube(low, rt * 0.85, 8))
			tubes.append(Kit.tube([Vector3(xa + r * 0.1, axle - r * 0.3, zm), Vector3(xa, axle - r * 0.2, zm)], rt * 0.85, 6))
			tubes.append(Kit.tube([Vector3(xb - r * 0.1, axle - r * 0.3, zm), Vector3(xb, axle - r * 0.2, zm)], rt * 0.85, 6))
			parts.append(_p(tubes, mat))
		else:
			var cut := minf(r * 0.5, (yhi - ylo) * 0.42)
			var prof := PackedVector2Array([Vector2(xa + cut, ylo), Vector2(xb - cut, ylo), Vector2(xb, ylo + cut), Vector2(xb, yhi - cut),
				Vector2(xb - cut, yhi), Vector2(xa + cut, yhi), Vector2(xa, yhi - cut), Vector2(xa, ylo + cut)])
			var holes := []
			for x in xs:
				var hole := PackedVector2Array()
				for k in 16: hole.append(Vector2(x + cos(TAU * k / 16.0) * r * 0.36, axle + sin(TAU * k / 16.0) * r * 0.36))
				holes.append(hole)
			if xs.size() >= 2 and xs[xs.size() - 1] - xs[0] > r * 2.6:
				# A slot between the wheels.
				var x0: float = xs[0] + r * 1.0
				var x1: float = xs[xs.size() - 1] - r * 1.0
				var hh := (yhi - ylo) * 0.2
				holes.append(PackedVector2Array([Vector2(x0 + hh, axle - hh), Vector2(x1 - hh, axle - hh), Vector2(x1, axle), Vector2(x1 - hh, axle + hh), Vector2(x0 + hh, axle + hh), Vector2(x0, axle)]))
			parts.append(_p(Geo.extrude(prof, t, 0.002, holes).translate(0, 0, zm), mat))
		var over := []
		for i in 13:
			for j in 4:
				for dz in [-t / 2.0, t / 2.0]: over.append(Vector3(lerpf(xa, xb, i / 12.0), lerpf(ylo if style != "bar" else axle - r * 0.3, yhi if style != "bar" else axle + r * 0.34, j / 3.0), zm + dz))
		var why_not := c.check.clear_at(over)
		if why_not == "":
			for q in over:
				if c.body.depth(q, true) > GAP: why_not = "body"
		if why_not != "":
			trace.append("skirt: " + why_not)
			return
		# Stand-offs: from the body's side out to it, wherever one passes
		# clear of the tyres.
		var offs := Geo.new()
		var heads := Geo.new()
		var held := 0
		var tries := [xa + r * 0.12, xb - r * 0.12, (xa + xb) / 2.0]
		for x in xs:
			tries.append(x - r - 0.03)
			tries.append(x + r + 0.03)
		for x in tries:
			if held >= 4: break
			for y in [axle + r * 0.3, axle - r * 0.25, axle]:
				var from: float = c.body.reach(x, y, s)
				if from < 0.02: continue
				var rod := [_p(Kit.tube([Vector3(x, y, s * (from - 0.006)), Vector3(x, y, s * (z_in + 0.002))], 0.008, 8), "hub")]
				var line := []
				for k in 7: line.append(Vector3(x, y, s * lerpf(from, z_in, k / 6.0)))
				if c.check.clear_at(line) != "": continue
				if style != "bar" and Kit.inside_by(Kit.outline_of([Vector2(xa, ylo + 0.004), Vector2(xb, ylo + 0.004), Vector2(xb, yhi - 0.004), Vector2(xa, yhi - 0.004)]), Vector2(x, y)) < 0.006: continue
				offs.append(rod[0].geo)
				heads.append(Kit.bolt(0.0065).apply(Kit.along(Vector3(0, 0, s), Vector3(x, y, s * (z_in + t)))))
				held += 1
				break
		if held < 2:
			trace.append("skirt: only %d stand-offs" % held)
			return
		parts.append(_p(offs, "hub"))
		if style != "bar": parts.append(_p(heads, "dark"))
		parts_all.append_array(parts)
	items.append({"id": "skirts", "parts": parts_all})

# ---------------------------------------------------------------- on the deck

# The small stuff every real machine carries: lifting handles, a speed
# controller's heat sink, a radio aerial. Each robot gets a few of them, where
# its deck has room.
static func _deck_kit(c: Ctx, items: Array) -> void:
	var kit = c.look.get("kit")
	var want: Array
	if kit is Array: want = kit
	else:
		want = []
		var all := ["handle", "sink", "aerial", "handle", "sink", "aerial", "box"]
		var n := 2 + int(c.roll("kitN") * 2.0)
		for i in n:
			var k: String = all[int(c.roll("kit%d" % i) * all.size()) % all.size()]
			if not want.has(k): want.append(k)
	var i := 0
	for name in want:
		i += 1
		var spots := _deck_spots(c, -0.42, 0.1)
		# Each starts from its own place, so the decks do not all look alike.
		var start := int(c.roll("spot:%s" % name) * spots.size())
		for k in spots.size():
			var sp: Array = spots[(start + k) % spots.size()]
			var parts := _kit_part(c, str(name), sp)
			if parts.is_empty(): continue
			if c.check.fit(parts, [], 0.4) != "": continue
			_add(c, items, "kit:%s:%d" % [name, i], parts)
			break

static func _kit_part(c: Ctx, name: String, sp: Array) -> Array:
	var x: float = sp[0]
	var z: float = sp[1]
	var along_x: bool = absf((sp[2] as Vector3).x) > 0.5
	var turn := Basis.IDENTITY if along_x else Basis(Vector3.UP, PI / 2.0)
	match name:
		"handle":
			var span := clampf(c.W * 0.22, 0.07, 0.12)
			var seat := c.body.seat(x, z, span / 2.0 if along_x else 0.008, 0.008 if along_x else span / 2.0)
			if seat.is_empty() or seat[1] - seat[0] > 0.008: return []
			return [_p(Kit.handle(span, 0.03).apply(Transform3D(turn, Vector3(x, seat[0], z))), "hub")]
		"sink":
			var l := clampf(c.L * 0.16, 0.06, 0.1)
			var w := clampf(c.W * 0.14, 0.05, 0.08)
			var seat := c.body.seat(x, z, (l if along_x else w) / 2.0, (w if along_x else l) / 2.0)
			if seat.is_empty() or seat[1] - seat[0] > 0.006: return []
			return Kit.place(Kit.heat_sink(l, w, 0.022), Transform3D(turn, Vector3(x, seat[0] - 0.002, z)))
		"box":
			var l := clampf(c.L * 0.14, 0.05, 0.09)
			var seat := c.body.seat(x, z, l / 2.0, l * 0.35)
			if seat.is_empty() or seat[1] - seat[0] > 0.006: return []
			var lid := Parts.box(l, 0.016, l * 0.7).translate(0, 0.006, 0)
			var bolts := Geo.new()
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]: bolts.append(Kit.bolt(0.004).translate(sx * l * 0.4, 0.014, sz * l * 0.26))
			return Kit.place([_p(lid, "black"), _p(bolts, "hub")], Transform3D(turn, Vector3(x, seat[0], z)))
		"aerial":
			var seat := c.body.seat(x, z, 0.012, 0.012)
			if seat.is_empty() or seat[1] - seat[0] > 0.006: return []
			var h := clampf(c.H * 0.8, 0.06, 0.12)
			var whip := Kit.tube([Vector3(0, 0.012, 0), Vector3(-h * 0.08, h, 0)], 0.0022, 5)
			return Kit.shift([_p(Geo.cylinder(0.008, 0.01, 0.014, 10).translate(0, 0.006, 0), "black"), _p(whip, "black"),
				_p(Kit.sphere(0.005, 8).translate(-h * 0.08, h, 0), "accent")], Vector3(x, seat[0], z))
	return []
