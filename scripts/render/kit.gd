## kit.gd - the hardware a fighting robot is bolted together from: motor
## cans, pulleys and belts, sprockets, tubes, truss-cut plates, bolts, gas
## bottles, rams.
##
## parts.gd draws what a robot IS (wheels, rotors, arms); this is what it is
## built WITH - the things you see on a real one when the lid is off or the
## weapon is parked. dress.gd decides which of them a robot gets and where.
##
## Round parts stand on Y, as Geo's do. A builder returns either a Geo or a
## list of [{ geo, mat }] parts with the material keys robot_view.gd resolves.
class_name Kit

static func _p(geo: Geo, mat: String) -> Dictionary:
	return {"geo": geo, "mat": mat}

## A frame whose Y axis runs along `axis`, standing at `at`: what turns a
## part built on Y into one pointing anywhere.
static func along(axis: Vector3, at := Vector3.ZERO) -> Transform3D:
	var y := axis.normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	return Transform3D(Basis(x, y, x.cross(y)), at)

## Move a list of parts (in place).
static func place(parts: Array, t: Transform3D) -> Array:
	for p in parts: (p.geo as Geo).apply(t)
	return parts

static func shift(parts: Array, by: Vector3) -> Array:
	for p in parts: (p.geo as Geo).translate(by.x, by.y, by.z)
	return parts

## Every corner of a list of parts.
static func points_of(parts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in parts: out.append_array((p.geo as Geo).pos)
	return out

# ---------------------------------------------------------------- fasteners

## A hex bolt head standing on y = 0.
static func bolt(r: float) -> Geo:
	return Geo.cylinder(r, r, r * 0.8, 6).translate(0, r * 0.4, 0)

## Bolt heads along the line a-b, standing on the plane whose normal is `up`.
static func bolt_row(a: Vector3, b: Vector3, up: Vector3, r: float, pitch := 0.06) -> Geo:
	var out := Geo.new()
	var n := maxi(2, int(round(a.distance_to(b) / pitch)) + 1)
	for i in n:
		out.append(bolt(r).apply(along(up, a.lerp(b, float(i) / (n - 1)))))
	return out

## Bolt heads in a ring about Y, standing on y = 0.
static func bolt_circle(n: int, rad: float, r: float, phase := 0.0) -> Geo:
	var out := Geo.new()
	for i in n:
		var a := phase + (float(i) / n) * TAU
		out.append(bolt(r).translate(cos(a) * rad, 0, sin(a) * rad))
	return out

# ---------------------------------------------------------------- round stock

## A ball.
static func sphere(r: float, n := 14) -> Geo:
	var prof := []
	var m := maxi(4, n / 2)
	for i in range(m + 1):
		var a := -PI / 2.0 + PI * float(i) / m
		prof.append(Vector2(maxf(0.0, cos(a) * r), sin(a) * r))
	return Geo.lathe(prof, n)

## A path with its corners rounded off to `radius`.
static func round_path(path: Array, radius: float, steps := 5) -> Array:
	var m := path.size()
	if m < 3: return path
	var out := [path[0]]
	for i in range(1, m - 1):
		var p: Vector3 = path[i]
		var a: Vector3 = path[i - 1]
		var b: Vector3 = path[i + 1]
		var c := minf(radius, minf(p.distance_to(a), p.distance_to(b)) * 0.45)
		var p0 := p + (a - p).normalized() * c
		var p1 := p + (b - p).normalized() * c
		out.append(p0)
		for k in range(1, steps + 1):
			var t := float(k) / steps
			out.append(p0.lerp(p, t).lerp(p.lerp(p1, t), t))
	out.append(path[m - 1])
	return out

## A round bar along a path, `r0` thick at its start and `r1` at its end.
static func tube(path: Array, r0: float, n := 8, r1 := -1.0) -> Geo:
	var g := Geo.new()
	var m := path.size()
	if m < 2: return g
	if r1 < 0.0: r1 = r0
	var total := 0.0
	for i in range(1, m): total += (path[i] as Vector3).distance_to(path[i - 1])
	if total < 1e-6: return g
	var rings := []
	var norms := []
	var u := Vector3.ZERO
	var run := 0.0
	for i in m:
		var here: Vector3 = path[i]
		var t: Vector3
		if i == 0: t = (path[1] as Vector3) - here
		elif i == m - 1: t = here - (path[m - 2] as Vector3)
		else: t = ((path[i + 1] as Vector3) - here).normalized() + (here - (path[i - 1] as Vector3)).normalized()
		if t.length_squared() < 1e-12: t = Vector3.RIGHT
		t = t.normalized()
		if i == 0:
			u = t.cross(Vector3.UP)
			if u.length_squared() < 1e-4: u = t.cross(Vector3.RIGHT)
		else:
			run += here.distance_to(path[i - 1])
			u = u - t * u.dot(t)
			if u.length_squared() < 1e-8: u = t.cross(Vector3.UP)
		u = u.normalized()
		var v := t.cross(u)
		var rad := lerpf(r0, r1, run / total)
		var ring := PackedVector3Array()
		var nn := PackedVector3Array()
		for k in n:
			var a := TAU * float(k) / n
			var d := u * cos(a) + v * sin(a)
			ring.append(here + d * rad)
			nn.append(d)
		rings.append(ring)
		norms.append(nn)
	for i in m - 1:
		var ra: PackedVector3Array = rings[i]
		var rb: PackedVector3Array = rings[i + 1]
		var na: PackedVector3Array = norms[i]
		var nb: PackedVector3Array = norms[i + 1]
		for k in n:
			var j := (k + 1) % n
			g.quad(ra[k], ra[j], rb[j], rb[k], na[k], na[j], nb[j], nb[k])
	var first: PackedVector3Array = rings[0]
	var last: PackedVector3Array = rings[m - 1]
	var t0 := ((path[0] as Vector3) - (path[1] as Vector3)).normalized()
	var t1 := ((path[m - 1] as Vector3) - (path[m - 2] as Vector3)).normalized()
	for k in n:
		var j := (k + 1) % n
		if r0 > 1e-4: g.tri(path[0], first[j], first[k], t0, t0, t0)
		if r1 > 1e-4: g.tri(path[m - 1], last[k], last[j], t1, t1, t1)
	return g.tile_uvs()

# ---------------------------------------------------------------- plate

## A flat ring between two outlines that run counter-clockwise in step,
## `depth` thick along Z. Flat-sided, unlike Geo.ring_extrude, and it does not
## have to be centred on the origin.
static func ring(outer: PackedVector2Array, inner: PackedVector2Array, depth: float) -> Geo:
	var g := Geo.new()
	var n := outer.size()
	var z := depth / 2.0
	for i in n:
		var j := (i + 1) % n
		var o0 := outer[i]
		var o1 := outer[j]
		var i0 := inner[i]
		var i1 := inner[j]
		g.flat_quad(Vector3(i0.x, i0.y, z), Vector3(o0.x, o0.y, z), Vector3(o1.x, o1.y, z), Vector3(i1.x, i1.y, z))
		g.flat_quad(Vector3(o0.x, o0.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i1.x, i1.y, -z), Vector3(o1.x, o1.y, -z))
		g.flat_quad(Vector3(o0.x, o0.y, -z), Vector3(o1.x, o1.y, -z), Vector3(o1.x, o1.y, z), Vector3(o0.x, o0.y, z))
		g.flat_quad(Vector3(i1.x, i1.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i0.x, i0.y, z), Vector3(i1.x, i1.y, z))
	return g.tile_uvs()

## The convex outline of a set of 2D points, counter-clockwise.
static func outline_of(pts: Array) -> PackedVector2Array:
	var sorted := pts.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var lower: Array = []
	for p in sorted:
		while lower.size() >= 2 and ((lower[-1] as Vector2) - (lower[-2] as Vector2)).cross((p as Vector2) - (lower[-1] as Vector2)) <= 1e-12: lower.pop_back()
		lower.append(p)
	var upper: Array = []
	for i in range(sorted.size() - 1, -1, -1):
		var p: Vector2 = sorted[i]
		while upper.size() >= 2 and ((upper[-1] as Vector2) - (upper[-2] as Vector2)).cross(p - (upper[-1] as Vector2)) <= 1e-12: upper.pop_back()
		upper.append(p)
	lower.pop_back()
	upper.pop_back()
	var out := PackedVector2Array()
	for p in lower: out.append(p)
	for p in upper: out.append(p)
	return out

## How far inside a convex counter-clockwise outline a point is (negative: outside).
static func inside_by(outline: PackedVector2Array, p: Vector2) -> float:
	var m := INF
	var n := outline.size()
	for i in n:
		var a := outline[i]
		var e := (outline[(i + 1) % n] - a).normalized()
		m = minf(m, e.cross(p - a))
	return m

# Where the upright line x cuts a convex outline: [low, high] or [].
static func _span_at(outline: PackedVector2Array, x: float) -> Array:
	var lo := INF
	var hi := -INF
	var n := outline.size()
	for i in n:
		var a := outline[i]
		var b := outline[(i + 1) % n]
		if (a.x - x) * (b.x - x) > 0.0 or absf(b.x - a.x) < 1e-9: continue
		var y := a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return [lo, hi] if hi > lo else []

## A truss cut from plate: the outline as a frame `bar` wide, braced by a
## zig-zag of struts along X, `depth` thick along Z. What a weapon arm or an
## upright is on a real machine: the metal that carries load, and daylight.
static func truss(outline: PackedVector2Array, depth: float, bar: float, bays := 0) -> Geo:
	var pts := outline
	if Geo._signed_area(pts) < 0.0:
		pts = pts.duplicate()
		pts.reverse()
	var inner := Geo._inset(pts, bar)
	var g := ring(pts, inner, depth)
	var x0 := INF
	var x1 := -INF
	for p in inner:
		x0 = minf(x0, p.x)
		x1 = maxf(x1, p.x)
	var span := x1 - x0
	if span < bar * 3.0: return g
	if bays <= 0:
		var mid := _span_at(inner, (x0 + x1) / 2.0)
		var tall: float = (mid[1] - mid[0]) if not mid.is_empty() else span
		bays = clampi(int(round(span / maxf(tall * 1.1, bar * 3.0))), 1, 6)
	var up := true
	for i in bays:
		var xa := x0 + span * float(i) / bays
		var xb := x0 + span * float(i + 1) / bays
		var sa := _span_at(inner, xa + (0.002 if i == 0 else 0.0))
		var sb := _span_at(inner, xb - (0.002 if i == bays - 1 else 0.0))
		if sa.is_empty() or sb.is_empty(): continue
		var a := Vector2(xa, sa[0] if up else sa[1])
		var b := Vector2(xb, sb[1] if up else sb[0])
		up = not up
		var d := b - a
		if d.length() < bar: continue
		g.append(Geo.box(d.length() + bar * 0.6, bar * 0.8, depth * 0.86).rotate_z(d.angle()).translate((a.x + b.x) / 2.0, (a.y + b.y) / 2.0, 0))
	return g

## Round lightening holes for a convex plate: up to `count` along the line
## a-b, as big as the plate leaves room for, clear of `keep` ([centre, radius]
## discs that must stay solid). Returns outlines for Geo.extrude.
static func lightening(outline: PackedVector2Array, a: Vector2, b: Vector2, count: int, keep: Array = [], biggest := 0.04, land := 0.012) -> Array:
	var pts := outline
	if Geo._signed_area(pts) < 0.0:
		pts = pts.duplicate()
		pts.reverse()
	var holes := []
	var made := []
	for i in count:
		var c := a.lerp(b, (i + 0.5) / count)
		var room := inside_by(pts, c) - land
		for k in keep: room = minf(room, c.distance_to(k[0]) - float(k[1]) - land * 0.6)
		for k in made: room = minf(room, c.distance_to(k[0]) - float(k[1]) - land * 0.8)
		var r := minf(room, biggest)
		if r < 0.009: continue
		made.append([c, r])
		var hole := PackedVector2Array()
		var n := 14
		for k in n:
			var ang := TAU * float(k) / n
			hole.append(c + Vector2(cos(ang), sin(ang)) * r)
		holes.append(hole)
	return holes

# ---------------------------------------------------------------- drive

## A brushless outrunner: mount plate, the windings showing under the can,
## the can with its cooling slots, the end bell and a stub of shaft. Stands on
## y = 0, `length` tall, with `shaft` more of shaft above it.
static func motor(r: float, length: float, shaft := 0.012, can := "can") -> Array:
	var body := maxf(0.012, length - 0.02)
	var parts := [
		_p(Geo.cylinder(r * 1.08, r * 1.08, 0.006, 20).translate(0, 0.003, 0), "black"),
		_p(Geo.cylinder(r * 0.8, r * 0.8, 0.008, 18).translate(0, 0.01, 0), "copper"),
		_p(Parts.cyl(r, r, body, 20).translate(0, 0.014 + body / 2.0, 0), can),
		_p(Geo.cylinder(r * 0.5, r * 0.94, 0.006, 20).translate(0, 0.014 + body + 0.003, 0), "hub"),
	]
	var slots := Geo.new()
	var n := clampi(int(round(r / 0.006)), 6, 10)
	for i in n:
		slots.append(Geo.box(0.003, body * 0.5, r * 0.24).translate(r - 0.0006, 0.014 + body * 0.5, 0).rotate_y(TAU * float(i) / n))
	parts.append(_p(slots, "black"))
	if shaft > 0.0:
		parts.append(_p(Geo.cylinder(r * 0.17, r * 0.17, shaft + 0.004, 10).translate(0, length + shaft / 2.0 - 0.002, 0), "hub"))
	return parts

## A belt pulley about Y, centred on the origin: `w` wide between its flanges.
static func pulley(r: float, w: float, boss := 0.0) -> Array:
	var flanges := Geo.new()
	for s in [-1.0, 1.0]:
		flanges.append(Geo.cylinder(r + 0.003, r + 0.003, 0.002, 20).translate(0, s * (w / 2.0 + 0.001), 0))
	var parts := [_p(Geo.cylinder(r, r, w, 20, true), "hub"), _p(flanges, "black")]
	if boss > 0.0: parts.append(_p(Geo.cylinder(r * 0.5, r * 0.5, w + boss, 12), "hub"))
	return parts

## A chain sprocket about Y, centred on the origin.
static func sprocket(r: float, w: float) -> Array:
	var teeth := Geo.new()
	var n := clampi(int(round(TAU * r / 0.012)), 9, 28)
	for i in n:
		teeth.append(Geo.box(0.007, w * 0.8, 0.005).translate(r, 0, 0).rotate_y(TAU * float(i) / n))
	return [_p(Geo.cylinder(r * 0.97, r * 0.97, w, n), "hub"), _p(teeth, "hub"), _p(Geo.cylinder(r * 0.42, r * 0.42, w + 0.008, 12), "black")]

## A belt (or chain) round two wheels at `a` and `b` in the XY plane, `w` wide
## along Z and `th` thick, hugging radii ra and rb.
static func belt(a: Vector2, ra: float, b: Vector2, rb: float, w: float, th := 0.004) -> Geo:
	var g := Geo.new()
	var d := b - a
	var l := d.length()
	if l < absf(ra - rb) + 1e-4: return g
	var th0 := d.angle()
	var beta := acos(clampf((ra - rb) / l, -1.0, 1.0))
	var stops := []          # [centre, radius, angle]
	var na := maxi(4, int(ceil((TAU - 2.0 * beta) / 0.32)))
	for i in range(na + 1): stops.append([a, ra, th0 + beta + (TAU - 2.0 * beta) * i / na])
	var nb := maxi(3, int(ceil(2.0 * beta / 0.32)))
	for i in range(nb + 1): stops.append([b, rb, th0 - beta + 2.0 * beta * i / nb])
	var z := w / 2.0
	var front := Vector3(0, 0, 1)
	var back := Vector3(0, 0, -1)
	var m := stops.size()
	for i in m:
		var s0: Array = stops[i]
		var s1: Array = stops[(i + 1) % m]
		var d0 := Vector2(cos(s0[2]), sin(s0[2]))
		var d1 := Vector2(cos(s1[2]), sin(s1[2]))
		var i0: Vector2 = (s0[0] as Vector2) + d0 * float(s0[1])
		var i1: Vector2 = (s1[0] as Vector2) + d1 * float(s1[1])
		var o0 := i0 + d0 * th
		var o1 := i1 + d1 * th
		var n0 := Vector3(d0.x, d0.y, 0)
		var n1 := Vector3(d1.x, d1.y, 0)
		g.quad(Vector3(o0.x, o0.y, -z), Vector3(o1.x, o1.y, -z), Vector3(o1.x, o1.y, z), Vector3(o0.x, o0.y, z), n0, n1, n1, n0)
		g.quad(Vector3(i1.x, i1.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i0.x, i0.y, z), Vector3(i1.x, i1.y, z), -n1, -n0, -n0, -n1)
		g.quad(Vector3(i0.x, i0.y, z), Vector3(o0.x, o0.y, z), Vector3(o1.x, o1.y, z), Vector3(i1.x, i1.y, z), front, front, front, front)
		g.quad(Vector3(o0.x, o0.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i1.x, i1.y, -z), Vector3(o1.x, o1.y, -z), back, back, back, back)
	return g.tile_uvs()

## How far the point p is from the loop a belt makes round wheels a and b
## (negative: inside the loop).
static func belt_gap(a: Vector2, ra: float, b: Vector2, rb: float, p: Vector2) -> float:
	var d := b - a
	var l2 := d.length_squared()
	var t := clampf((p - a).dot(d) / l2, 0.0, 1.0) if l2 > 1e-12 else 0.0
	return p.distance_to(a + d * t) - lerpf(ra, rb, t)

# ---------------------------------------------------------------- pneumatics, hydraulics

## A gas bottle lying along Y, centred on the origin: domed ends, a valve and
## regulator at the top end, two straps.
static func bottle(r: float, length: float, body := "accent") -> Array:
	var prof := [Vector2(0.001, -length / 2.0)]
	var steps := 5
	for i in range(1, steps + 1):
		var a := -PI / 2.0 + (PI / 2.0) * float(i) / steps
		prof.append(Vector2(cos(a) * r, -length / 2.0 + r * 0.7 + sin(a) * r * 0.7))
	for i in range(steps):
		var a := (PI / 2.0) * float(i) / steps
		prof.append(Vector2(cos(a) * r, length / 2.0 - r * 0.7 + sin(a) * r * 0.7))
	prof.append(Vector2(r * 0.3, length / 2.0))
	var straps := Geo.new()
	for s in [-1.0, 1.0]:
		straps.append(Geo.cylinder(r + 0.002, r + 0.002, 0.014, 18, true).translate(0, s * length * 0.24, 0))
	return [
		_p(Geo.lathe(prof, 18), body),
		_p(straps, "black"),
		_p(Geo.cylinder(r * 0.3, r * 0.3, 0.018, 10).translate(0, length / 2.0 + 0.008, 0), "hub"),
		_p(Geo.cylinder(r * 0.42, r * 0.42, 0.014, 6).translate(0, length / 2.0 + 0.022, 0), "brass"),
	]

## A ram lying along Y from y = 0: `barrel` of cylinder, then `rod` of rod
## ending in an eye.
static func ram(r: float, barrel: float, rod: float) -> Array:
	var caps := Geo.new()
	caps.append(Geo.cylinder(r * 1.12, r * 1.12, 0.012, 14).translate(0, 0.006, 0))
	caps.append(Geo.cylinder(r * 1.12, r * 1.12, 0.012, 14).translate(0, barrel - 0.006, 0))
	return [
		_p(Parts.cyl(r, r, barrel, 14).translate(0, barrel / 2.0, 0), "can"),
		_p(caps, "black"),
		_p(Geo.cylinder(r * 0.42, r * 0.42, rod, 10).translate(0, barrel + rod / 2.0, 0), "steel"),
		_p(Geo.cylinder(r * 0.7, r * 0.7, 0.016, 10).rotate_x(PI / 2.0).translate(0, barrel + rod, 0), "hub"),
	]

# ---------------------------------------------------------------- odds and ends

## A finned heat-sink block (a speed controller) sitting on y = 0.
static func heat_sink(l: float, w: float, h: float) -> Array:
	var fins := Geo.new()
	var n := clampi(int(round(w / 0.009)), 4, 12)
	for i in n:
		var z := -w / 2.0 + w * (i + 0.5) / n
		fins.append(Geo.box(l * 0.92, h * 0.55, w / n * 0.42).translate(0, h * 0.45 + h * 0.275, z))
	return [_p(Geo.box(l, h * 0.45, w).translate(0, h * 0.225, 0), "black"), _p(fins, "hub")]

## A lifting handle: a hoop of bar standing on y = 0, across X.
static func handle(span: float, rise: float, r := 0.005) -> Geo:
	var path := round_path([Vector3(-span / 2.0, -0.004, 0), Vector3(-span / 2.0, rise, 0), Vector3(span / 2.0, rise, 0), Vector3(span / 2.0, -0.004, 0)], rise * 0.5, 4)
	return tube(path, r, 6)
