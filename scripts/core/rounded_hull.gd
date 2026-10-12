## rounded_hull.gd - a convex piece with its edges and corners rounded off,
## as triangles with smooth normals, for drawing.
##
## The shape is the hull shrunk by `r` and grown back by a ball of radius r (a
## Minkowski sum): flat faces stay flat, every edge becomes a quarter-round
## strip and every corner a small spherical patch. It always sits INSIDE the
## hull physics collides with, so the picture never sticks out past the
## collider - it just loses its sharp edges.
##
## Built directly, not by hulling a cloud of points: faces, edge strips and
## corner patches each come from the same arc samples, so the mesh closes with
## no cracks and every normal is exact.
##
## Returns null when it cannot round the piece cleanly; callers then draw the
## plain hull. Triangles are wound counter-clockwise seen from outside (see
## hull.gd).
class_name RoundedHull

## How far a corner may end up from the rounded piece, as a share of the
## radius: a square corner is 0.73 of it (root 3, less 1), so a little over.
const KEEP := 0.85

## opt: { radius = 0.012, step = PI/12, minFrac = 0.28 }
## Returns { positions: PackedVector3Array, normals: PackedVector3Array, radius } or null.
static func build(points, opt: Dictionary = {}):
	var radius: float = opt.get("radius", 0.012)
	var step: float = opt.get("step", PI / 12.0)
	var min_frac: float = opt.get("minFrac", 0.28)
	var cf := Hull.convex_faces(points)
	var pts: PackedVector3Array = cf.points
	if cf.faces.is_empty(): return null

	# The hull's face planes, one per flat face.
	var planes := []
	for f in cf.faces: planes.append([f.n, f.d])

	# Thin pieces (armour plates) get a smaller round, so they do not vanish.
	var min_width := INF
	for p in planes:
		var n: Vector3 = p[0]
		var lo := INF
		for q in pts: lo = minf(lo, n.dot(q))
		min_width = minf(min_width, p[1] - lo)
	var r := minf(radius, min_frac * min_width)

	# The shrunk hull: every plane pulled in by r. Its corners are where three
	# planes meet inside all the others.
	#
	# A piece that tapers - a wedge, a dart's nose, a skin over a slope - is
	# thick at one end and thin at the other, and shrinking it by a radius the
	# thick end can take leaves nothing of the thin end: the nose would be
	# drawn centimetres short of where physics has it, and whatever is bolted
	# to it would hang in the air. So the radius comes down until every corner
	# of the hull is still there: no further from the shrunk hull than a
	# square corner would be.
	var solved := PackedVector3Array()
	var kept := false
	for attempt in 14:
		if not (r > 5e-4): return null
		solved = _shrunk_corners(planes, r)
		var worst := 0.0
		for q in pts:
			var near := INF
			for x in solved: near = minf(near, q.distance_to(x))
			worst = maxf(worst, near - r)
		if worst <= r * KEEP + 0.0015:
			kept = true
			break
		r *= 0.78
	if not kept: return null

	# Corners closer than a millimetre or so are one corner: where a small
	# face was squeezed out they crowd together and only make slivers - and
	# can leave an edge undecided, so try a little coarser before giving up.
	var verts := PackedVector3Array()
	var faces := []
	var edges = null
	for snap in [1e-3, 2.5e-3, 5e-3]:
		var corners := PackedVector3Array()
		for x in solved:
			var near := false
			for v in corners:
				if v.distance_to(x) < snap:
					near = true
					break
			if not near: corners.append(x)
		var icf := Hull.convex_faces(corners)
		verts = icf.points
		faces = icf.faces
		if faces.size() < 4: continue
		edges = _edges_of(faces)
		if edges != null: break
	if edges == null: return null

	var b := Builder.new()
	b.r = r
	b.step = step
	b.faces = faces

	# Flat faces, pushed back out to where the hull's faces were.
	for f in faces:
		var fn: Vector3 = f.n
		var ring: Array = f.ring
		var p0 := verts[ring[0]] + fn * r
		for t in range(1, ring.size() - 1):
			b.tri(p0, fn, verts[ring[t]] + fn * r, fn, verts[ring[t + 1]] + fn * r, fn)

	# Edge strips: a quarter-round (or however wide the edge's angle is).
	for e in edges.values():
		var A := verts[e.a]
		var B := verts[e.b]
		var ns := b.arc(e.faces[0], e.faces[1])
		for s in range(ns.size() - 1):
			var u0: Vector3 = ns[s]
			var u1: Vector3 = ns[s + 1]
			b.tri(A + u0 * r, u0, B + u0 * r, u0, B + u1 * r, u1)
			b.tri(A + u0 * r, u0, B + u1 * r, u1, A + u1 * r, u1)

	# Corner patches: the bit of ball between the arcs meeting at a corner,
	# fanned out from its middle in rings.
	for vi in verts.size():
		var v := verts[vi]
		# The faces round this corner, in order: step from face to face across
		# the edge that leaves the corner next in each face's ring.
		var first := -1
		for fi in faces.size():
			if faces[fi].ring.has(vi):
				first = fi
				break
		if first < 0: continue
		var order := []
		var fi := first
		for guard in 64:
			order.append(fi)
			var ring: Array = faces[fi].ring
			var nxt: int = ring[(ring.find(vi) + 1) % ring.size()]
			var across: Array = edges[_ekey(vi, nxt)].faces
			fi = across[1] if across[0] == fi else across[0]
			if fi == first: break
		if order.size() < 3: continue
		var c := Vector3.ZERO
		for f2 in order: c += faces[f2].n
		c = c.normalized()
		var rim := []
		for k in order.size():
			var seg := b.arc(order[k], order[(k + 1) % order.size()])
			for q in range(seg.size() - 1): rim.append(seg[q])
		var widest := 0.0
		for u in rim: widest = maxf(widest, _angle(c, u))
		var rings := maxi(1, int(ceil(widest / step)))
		var prev := []
		for t in range(1, rings + 1):
			var cur := []
			if t == rings: cur = rim
			else:
				for u in rim: cur.append(_slerp(c, u, float(t) / rings))
			for k in cur.size():
				var k2 := (k + 1) % cur.size()
				if prev.is_empty():
					b.tri(v + c * r, c, v + cur[k] * r, cur[k], v + cur[k2] * r, cur[k2])
				else:
					b.tri(v + prev[k] * r, prev[k], v + cur[k] * r, cur[k], v + cur[k2] * r, cur[k2])
					b.tri(v + prev[k] * r, prev[k], v + cur[k2] * r, cur[k2], v + prev[k2] * r, prev[k2])
			prev = cur

	return {"positions": b.positions, "normals": b.normals, "radius": r}

class Builder:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var r := 0.012
	var step := PI / 12.0
	var faces: Array
	var _arcs := {}

	# One arc of normals per pair of neighbouring faces, shared by the edge
	# strip and both corner patches it meets, so the seams line up exactly.
	func arc(fa: int, fb: int) -> Array:
		var lo := mini(fa, fb)
		var hi := maxi(fa, fb)
		var key := Vector2i(lo, hi)
		if not _arcs.has(key):
			var A: Vector3 = faces[lo].n
			var B: Vector3 = faces[hi].n
			var m := maxi(1, int(ceil(RoundedHull._angle(A, B) / step)))
			var pts := []
			for s in range(m + 1): pts.append(RoundedHull._slerp(A, B, float(s) / m))
			_arcs[key] = pts
		var out: Array = _arcs[key]
		if fa < fb: return out
		var rev := out.duplicate()
		rev.reverse()
		return rev

	func tri(p0: Vector3, n0: Vector3, p1: Vector3, n1: Vector3, p2: Vector3, n2: Vector3) -> void:
		# Wind it to face outward, whichever way it was handed in.
		var g := (p1 - p0).cross(p2 - p0)
		if g.length_squared() < 1e-20: return     # a sliver where an arc has no length
		if g.dot(n0 + n1 + n2) < 0:
			positions.append(p0); positions.append(p2); positions.append(p1)
			normals.append(n0); normals.append(n2); normals.append(n1)
		else:
			positions.append(p0); positions.append(p1); positions.append(p2)
			normals.append(n0); normals.append(n1); normals.append(n2)

## The corners of the hull with every plane pulled in by r: where three planes
## meet inside all the others.
static func _shrunk_corners(planes: Array, r: float) -> PackedVector3Array:
	var np := planes.size()
	var inner_n := PackedVector3Array()
	var inner_d := PackedFloat64Array()
	for p in planes:
		inner_n.append(p[0])
		inner_d.append(p[1] - r)
	var solved := PackedVector3Array()
	for i in np:
		var pn := inner_n[i]
		var pd := inner_d[i]
		for j in range(i + 1, np):
			var qn := inner_n[j]
			var qd := inner_d[j]
			var pq := pn.cross(qn)
			if pq.length_squared() < 1e-12: continue      # parallel planes meet nowhere
			for k in range(j + 1, np):
				var rn := inner_n[k]
				var det := pq.dot(rn)
				if absf(det) < 1e-7: continue
				var x := (qn.cross(rn) * pd + rn.cross(pn) * qd + pq * inner_d[k]) / det
				var ok := true
				for h in np:
					if inner_n[h].dot(x) - inner_d[h] > 2e-5:
						ok = false
						break
				if ok: solved.append(x)
	return solved

static func _ekey(a: int, b: int) -> Vector2i:
	return Vector2i(a, b) if a < b else Vector2i(b, a)

static func _slerp(a: Vector3, b: Vector3, t: float) -> Vector3:
	var th := _angle(a, b)
	if th < 1e-6: return a
	var s := sin(th)
	return (a * (sin((1.0 - t) * th) / s) + b * (sin(t * th) / s)).normalized()

static func _angle(a: Vector3, b: Vector3) -> float:
	return acos(clampf(a.dot(b), -1.0, 1.0))

## Each edge of a face list with the two faces on it, or null if any edge has
## not exactly two.
static func _edges_of(faces: Array):
	var edges := {}
	for fi in faces.size():
		var ring: Array = faces[fi].ring
		for k in ring.size():
			var a: int = ring[k]
			var b: int = ring[(k + 1) % ring.size()]
			var key := _ekey(a, b)
			if not edges.has(key): edges[key] = {"a": mini(a, b), "b": maxi(a, b), "faces": []}
			edges[key].faces.append(fi)
	for e in edges.values():
		if e.faces.size() != 2: return null
	return edges
