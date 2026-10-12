## hull.gd - convex hulls of small point sets.
##
## Robot bodies are built from a handful of convex pieces (logic/shape.gd).
## Physics turns each piece's points into a convex collision shape; the
## renderer needs the SAME hull as faces to draw it. Computing it here, from
## the same points, keeps the picture and the collision shape from disagreeing.
##
## An incremental hull (add a point, cut away the faces it can see, close the
## hole from the horizon), then coplanar triangles are gathered into whole
## faces so no face is drawn twice.
##
## Triangles and rings are wound counter-clockwise seen from outside - the
## maths convention. Godot draws CLOCKWISE triangles as front faces, so mesh
## builders flip them (see render/mesh_util.gd).
class_name Hull

## { points: PackedVector3Array (deduplicated), triangles: Array of [i, j, k] }
static func convex_hull(input) -> Dictionary:
	var cf := convex_faces(input)
	var triangles := []
	for f in cf.faces:
		var ring: Array = f.ring
		for t in range(1, ring.size() - 1):
			triangles.append([ring[0], ring[t], ring[t + 1]])
	return {"points": cf.points, "triangles": triangles}

## The same hull as whole faces rather than triangles.
## { points, faces: [{ n: Vector3, d: float, ring: [indices] }] } - each face's
## outward unit normal, plane offset and corners in order. No faces if flat.
static func convex_faces(input) -> Dictionary:
	var points := dedupe(input)
	var n := points.size()
	if n < 4: return {"points": points, "faces": []}
	var scale := extent(points)
	if scale <= 0.0: scale = 1.0
	var tol := scale * 2e-5

	var tris := _incremental(points, tol)
	if tris.is_empty(): return {"points": points, "faces": []}

	# Gather the triangles into planes, and each plane's points into one polygon.
	var faces := []          # { n, d, ring, on: {index: true} }
	var planes := []
	for t in tris:
		var a: Vector3 = points[t[0]]
		var nrm: Vector3 = (points[t[1]] - a).cross(points[t[2]] - a)
		var l := nrm.length()
		if l < 1e-12: continue
		nrm /= l
		var d := nrm.dot(a)
		var seen := false
		for p in planes:
			if p.n.dot(nrm) > 1.0 - 1e-6 and absf(p.d - d) < tol * 4.0:
				seen = true
				break
		if seen: continue
		planes.append({"n": nrm, "d": d})

		var on_plane := []
		var on_set := {}
		for m in n:
			if absf(nrm.dot(points[m]) - d) <= tol * 4.0:
				on_plane.append(m)
				on_set[m] = true
		# Two distinct faces share at most an edge, so a plane whose points
		# all belong to a face already found is that face again, tilted by
		# rounding; a wider one replaces it.
		var dup := false
		for f in faces:
			var all_in := true
			for m in on_plane:
				if not f.on.has(m):
					all_in = false
					break
			if all_in:
				dup = true
				break
		if dup: continue
		for fi in range(faces.size() - 1, -1, -1):
			var sub := true
			for m in faces[fi].on:
				if not on_set.has(m):
					sub = false
					break
			if sub: faces.remove_at(fi)
		var ring := _order_on_plane(on_plane, points, nrm)
		if ring.size() < 3: continue
		faces.append({"n": nrm, "d": d, "ring": ring, "on": on_set})

	if faces.size() < 4: return {"points": points, "faces": []}
	var out := []
	for f in faces: out.append({"n": f.n, "d": f.d, "ring": f.ring})
	return {"points": points, "faces": out}

## Axis-aligned bounds of a point list: { min: Vector3, max: Vector3 }.
static func bounds(points) -> Dictionary:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for p in points:
		mn = mn.min(p)
		mx = mx.max(p)
	return {"min": mn, "max": mx}

## Volume of a hull (divergence theorem over its triangles).
static func hull_volume(h: Dictionary) -> float:
	var v := 0.0
	var pts: PackedVector3Array = h.points
	for t in h.triangles:
		v += pts[t[0]].dot(pts[t[1]].cross(pts[t[2]])) / 6.0
	return absf(v)

# ---------------------------------------------------------------- helpers

static func dedupe(pts) -> PackedVector3Array:
	var out := PackedVector3Array()
	var scale := extent(pts)
	if scale <= 0.0: scale = 1.0
	var eps := scale * 1e-5
	for p in pts:
		var dupe := false
		for q in out:
			if absf(q.x - p.x) + absf(q.y - p.y) + absf(q.z - p.z) < eps:
				dupe = true
				break
		if not dupe: out.append(p)
	return out

static func extent(pts) -> float:
	if pts.size() == 0: return 0.0
	var b := bounds(pts)
	var e: Vector3 = b.max - b.min
	return maxf(e.x, maxf(e.y, e.z))

## Triangles [[a, b, c]] of the hull, outward-wound. Empty if the set is flat.
static func _incremental(points: PackedVector3Array, tol: float) -> Array:
	var n := points.size()
	# A starting tetrahedron: two far points, the point furthest from their
	# line, the point furthest from that plane.
	var i0 := 0
	var i1 := -1
	var best := 0.0
	for i in n:
		var dd := points[i].distance_squared_to(points[i0])
		if dd > best:
			best = dd
			i1 = i
	if i1 < 0: return []
	var dir := (points[i1] - points[i0]).normalized()
	var i2 := -1
	best = 0.0
	for i in n:
		var v := points[i] - points[i0]
		var dd := (v - dir * v.dot(dir)).length_squared()
		if dd > best:
			best = dd
			i2 = i
	if i2 < 0 or best < tol * tol: return []
	var pn := (points[i1] - points[i0]).cross(points[i2] - points[i0]).normalized()
	var i3 := -1
	best = 0.0
	for i in n:
		var dd := absf(pn.dot(points[i] - points[i0]))
		if dd > best:
			best = dd
			i3 = i
	if i3 < 0 or best < tol * 4.0: return []

	var inside := (points[i0] + points[i1] + points[i2] + points[i3]) / 4.0
	var faces := []      # [a, b, c, normal, d]
	for t in [[i0, i1, i2], [i0, i1, i3], [i0, i2, i3], [i1, i2, i3]]:
		faces.append(_face(points, t[0], t[1], t[2], inside))

	var used := {i0: true, i1: true, i2: true, i3: true}
	for i in n:
		if used.has(i): continue
		var p := points[i]
		var visible := []
		for fi in faces.size():
			var f: Array = faces[fi]
			if f[3].dot(p) - f[4] > tol: visible.append(fi)
		if visible.is_empty(): continue
		# The horizon: edges of visible faces whose other side stays.
		var edges := {}
		for fi in visible:
			var f: Array = faces[fi]
			for e in [[f[0], f[1]], [f[1], f[2]], [f[2], f[0]]]:
				var rev := Vector2i(e[1], e[0])
				if edges.has(rev): edges.erase(rev)
				else: edges[Vector2i(e[0], e[1])] = true
		visible.reverse()
		for fi in visible: faces.remove_at(fi)
		for e in edges:
			faces.append(_face(points, e.x, e.y, i, inside))
	var out := []
	for f in faces: out.append([f[0], f[1], f[2]])
	return out

static func _face(points: PackedVector3Array, a: int, b: int, c: int, inside: Vector3) -> Array:
	var nrm := (points[b] - points[a]).cross(points[c] - points[a])
	var l := nrm.length()
	if l > 0.0: nrm /= l
	var d := nrm.dot(points[a])
	if nrm.dot(inside) > d:
		return [a, c, b, -nrm, -d]
	return [a, b, c, nrm, d]

## The plane's points as a convex polygon, counter-clockwise about the normal.
## Points strictly inside the polygon are dropped: they would only add slivers.
static func _order_on_plane(idx: Array, points: PackedVector3Array, nrm: Vector3) -> Array:
	var c := Vector3.ZERO
	for i in idx: c += points[i]
	c /= float(idx.size())
	# An in-plane basis.
	var ref := Vector3(1, 0, 0) if absf(nrm.x) < 0.9 else Vector3(0, 1, 0)
	var u := nrm.cross(ref).normalized()
	var v := nrm.cross(u)
	var flat := []
	for i in idx:
		var r := points[i] - c
		flat.append(Vector3(r.dot(u), r.dot(v), float(i)))
	# Monotone chain in 2D, which also discards interior and collinear points.
	flat.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var lower := []
	var upper := []
	for p in flat:
		while lower.size() >= 2 and _turn(lower[lower.size() - 2], lower[lower.size() - 1], p) <= 1e-10:
			lower.pop_back()
		lower.append(p)
	for i in range(flat.size() - 1, -1, -1):
		var p: Vector3 = flat[i]
		while upper.size() >= 2 and _turn(upper[upper.size() - 2], upper[upper.size() - 1], p) <= 1e-10:
			upper.pop_back()
		upper.append(p)
	upper.pop_back()
	lower.pop_back()
	var out := []
	for p in lower: out.append(int(p.z))
	for p in upper: out.append(int(p.z))
	return out

static func _turn(o: Vector3, a: Vector3, b: Vector3) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
