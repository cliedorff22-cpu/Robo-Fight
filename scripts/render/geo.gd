## geo.gd - triangle soup with the handful of builders the robots and the
## arena are made from: boxes, cylinders, lathes, extrusions, hulls.
##
## A Geo is a flat list of triangles (position, normal, uv per corner), wound
## counter-clockwise seen from outside - the maths convention the hull code
## uses. Godot draws clockwise triangles as front faces, so to_mesh() flips
## them on the way out; nothing else needs to know.
##
## Builders follow the frames the part code was written in: cylinders, cones
## and lathes stand on Y; an extrusion's outline is in XY and its depth runs
## along Z, centred on z = 0.
class_name Geo
extends RefCounted

var pos := PackedVector3Array()
var nrm := PackedVector3Array()
var uv := PackedVector2Array()

# ---------------------------------------------------------------- basics

func tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		ua := Vector2.ZERO, ub := Vector2.ZERO, uc := Vector2.ZERO) -> void:
	pos.append(a); pos.append(b); pos.append(c)
	nrm.append(na); nrm.append(nb); nrm.append(nc)
	uv.append(ua); uv.append(ub); uv.append(uc)

## A flat triangle: the normal is its own.
func flat_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	tri(a, b, c, n, n, n)

## A quad a-b-c-d (counter-clockwise), with a normal per corner.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	tri(a, b, c, na, nb, nc)
	tri(a, c, d, na, nc, nd)

func flat_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var n := (b - a).cross(d - a).normalized()
	quad(a, b, c, d, n, n, n, n)

func count() -> int:
	return pos.size()

func append(o: Geo) -> Geo:
	if o == null: return self
	pos.append_array(o.pos)
	nrm.append_array(o.nrm)
	uv.append_array(o.uv)
	return self

static func merge(list: Array) -> Geo:
	var g := Geo.new()
	for x in list:
		if x != null: g.append(x)
	return g

func apply(t: Transform3D) -> Geo:
	var b := t.basis
	for i in pos.size():
		pos[i] = t * pos[i]
		nrm[i] = (b * nrm[i]).normalized()
	return self

func translate(x: float, y: float, z: float) -> Geo:
	var o := Vector3(x, y, z)
	for i in pos.size(): pos[i] += o
	return self

func rotate_x(a: float) -> Geo: return apply(Transform3D(Basis(Vector3.RIGHT, a), Vector3.ZERO))
func rotate_y(a: float) -> Geo: return apply(Transform3D(Basis(Vector3.UP, a), Vector3.ZERO))
func rotate_z(a: float) -> Geo: return apply(Transform3D(Basis(Vector3.BACK, a), Vector3.ZERO))

func copy() -> Geo:
	var g := Geo.new()
	g.pos = pos.duplicate()
	g.nrm = nrm.duplicate()
	g.uv = uv.duplicate()
	return g

## Tiling UVs: world metres x2 on each triangle's dominant plane, for
## materials like steel that just repeat.
func tile_uvs(scale := 2.0) -> Geo:
	for t in range(0, pos.size(), 3):
		var n := (pos[t + 1] - pos[t]).cross(pos[t + 2] - pos[t])
		var ax := absf(n.x)
		var ay := absf(n.y)
		var az := absf(n.z)
		for k in 3:
			var p := pos[t + k]
			if ay >= maxf(ax, az): uv[t + k] = Vector2(p.x, p.z) * scale
			elif az >= ax: uv[t + k] = Vector2(p.x, p.y) * scale
			else: uv[t + k] = Vector2(p.z, p.y) * scale
	return self

## UVs that run 0..1 across each face of the whole shape (its bounds), the
## way a plain box is usually mapped - for big flat arena pieces whose
## texture should stretch over the panel rather than tile by the metre.
func face_uvs() -> Geo:
	var b := bounds()
	var s := b.size
	for t in range(0, pos.size(), 3):
		var n := (pos[t + 1] - pos[t]).cross(pos[t + 2] - pos[t])
		var ax := absf(n.x)
		var ay := absf(n.y)
		var az := absf(n.z)
		for k in 3:
			var p := pos[t + k] - b.position
			if ay >= maxf(ax, az): uv[t + k] = Vector2(p.x / maxf(s.x, 1e-6), p.z / maxf(s.z, 1e-6))
			elif az >= ax: uv[t + k] = Vector2(p.x / maxf(s.x, 1e-6), 1.0 - p.y / maxf(s.y, 1e-6))
			else: uv[t + k] = Vector2(p.z / maxf(s.z, 1e-6), 1.0 - p.y / maxf(s.y, 1e-6))
	return self

## Each triangle's own normal on its three corners (faceted).
func flat_normals() -> Geo:
	for t in range(0, pos.size(), 3):
		var n := (pos[t + 1] - pos[t]).cross(pos[t + 2] - pos[t]).normalized()
		nrm[t] = n; nrm[t + 1] = n; nrm[t + 2] = n
	return self

## Smooth normals that keep hard creases: each corner averages the triangles
## meeting at that point that face within `crease` radians of its own.
func creased_normals(crease := 0.7) -> Geo:
	var tris := pos.size() / 3
	var cos_c := cos(crease)
	var face := PackedVector3Array()
	face.resize(tris)
	for t in tris:
		face[t] = (pos[t * 3 + 1] - pos[t * 3]).cross(pos[t * 3 + 2] - pos[t * 3])
	var at := {}
	for i in pos.size():
		var k := (pos[i] * 20000.0).round()
		if not at.has(k): at[k] = PackedInt32Array()
		at[k].append(i / 3)
	for i in pos.size():
		var own := face[i / 3].normalized()
		var sum := Vector3.ZERO
		for t in at[(pos[i] * 20000.0).round()]:
			if face[t].normalized().dot(own) < cos_c: continue
			sum += face[t]
		nrm[i] = sum.normalized() if sum.length_squared() > 0.0 else own
	return self

## An ArrayMesh of this geometry (winding flipped for Godot).
func to_mesh(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	add_to(mesh, material)
	return mesh

## Add this geometry to `mesh` as one more surface. Tangents (which normal
## maps need) are worked out from the UVs, a triangle at a time.
func add_to(mesh: ArrayMesh, material: Material = null, uv2 := false) -> void:
	if pos.is_empty(): return
	var n := pos.size()
	var p := PackedVector3Array()
	var nn := PackedVector3Array()
	var u := PackedVector2Array()
	var tg := PackedFloat32Array()
	p.resize(n); nn.resize(n); u.resize(n); tg.resize(n * 4)
	for t in range(0, n, 3):
		var p0 := pos[t]
		var e1 := pos[t + 1] - p0
		var e2 := pos[t + 2] - p0
		var d1 := uv[t + 1] - uv[t]
		var d2 := uv[t + 2] - uv[t]
		var det := d1.x * d2.y - d2.x * d1.y
		var tan := Vector3.ZERO
		var bin := Vector3.ZERO
		if absf(det) > 1e-14:
			tan = (e1 * d2.y - e2 * d1.y) / det
			# Texture "up" is against v, which runs down the picture.
			bin = (e1 * d2.x - e2 * d1.x) / det
		p[t] = p0; p[t + 1] = pos[t + 2]; p[t + 2] = pos[t + 1]
		nn[t] = nrm[t]; nn[t + 1] = nrm[t + 2]; nn[t + 2] = nrm[t + 1]
		u[t] = uv[t]; u[t + 1] = uv[t + 2]; u[t + 2] = uv[t + 1]
		for k in 3:
			var vn := nn[t + k]
			var vt := tan - vn * vn.dot(tan)
			if vt.length_squared() < 1e-16:
				vt = vn.cross(Vector3.UP if absf(vn.y) < 0.9 else Vector3.RIGHT)
			vt = vt.normalized()
			var o := (t + k) * 4
			tg[o] = vt.x; tg[o + 1] = vt.y; tg[o + 2] = vt.z
			tg[o + 3] = -1.0 if vn.cross(vt).dot(bin) < 0.0 else 1.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = p
	arrays[Mesh.ARRAY_NORMAL] = nn
	arrays[Mesh.ARRAY_TEX_UV] = u
	arrays[Mesh.ARRAY_TANGENT] = tg
	# A second UV set, the same as the first: a material's detail layer can
	# then repeat at its own rate.
	if uv2: arrays[Mesh.ARRAY_TEX_UV2] = u
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null: mesh.surface_set_material(mesh.get_surface_count() - 1, material)

## A MeshInstance3D of this geometry.
func instance(material: Material = null, shadows := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = to_mesh(material)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func bounds() -> AABB:
	if pos.is_empty(): return AABB()
	var b := AABB(pos[0], Vector3.ZERO)
	for p in pos: b = b.expand(p)
	return b

# ---------------------------------------------------------------- solids

## A w x h x d block centred on the origin, sharp-edged.
static func box(w: float, h: float, d: float) -> Geo:
	var g := Geo.new()
	var x := w / 2.0
	var y := h / 2.0
	var z := d / 2.0
	g.flat_quad(Vector3(x, -y, z), Vector3(x, -y, -z), Vector3(x, y, -z), Vector3(x, y, z))      # +X
	g.flat_quad(Vector3(-x, -y, -z), Vector3(-x, -y, z), Vector3(-x, y, z), Vector3(-x, y, -z))  # -X
	g.flat_quad(Vector3(-x, y, z), Vector3(x, y, z), Vector3(x, y, -z), Vector3(-x, y, -z))      # +Y
	g.flat_quad(Vector3(-x, -y, -z), Vector3(x, -y, -z), Vector3(x, -y, z), Vector3(-x, -y, z))  # -Y
	g.flat_quad(Vector3(-x, -y, z), Vector3(x, -y, z), Vector3(x, y, z), Vector3(-x, y, z))      # +Z
	g.flat_quad(Vector3(x, -y, -z), Vector3(-x, -y, -z), Vector3(-x, y, -z), Vector3(x, y, -z))  # -Z
	return g.tile_uvs()

## A block with its edges and corners rounded over (falls back to a sharp one).
static func round_box(w: float, h: float, d: float, radius := 0.006, step := PI / 6.0) -> Geo:
	var rh = RoundedHull.build(Shape.box_pts(0, 0, 0, w / 2.0, h / 2.0, d / 2.0), {"radius": radius, "step": step})
	if rh == null: return box(w, h, d)
	return from_soup(rh.positions, rh.normals).tile_uvs()

static func from_soup(positions: PackedVector3Array, normals: PackedVector3Array) -> Geo:
	var g := Geo.new()
	g.pos = positions.duplicate()
	g.nrm = normals.duplicate()
	g.uv.resize(positions.size())
	return g

## A surface of revolution about Y. `profile` is [Vector2(radius, y)] running
## bottom to top; the surface faces outward.
static func lathe(profile: Array, segments: int, phi_start := 0.0, phi_length := TAU) -> Geo:
	var g := Geo.new()
	var m := profile.size()
	if m < 2: return g
	# A normal per profile point, in the profile's plane: averaged between the
	# two spans meeting there, so a rounded rim shades as a curve.
	var pn := []
	for i in m:
		var a: Vector2 = profile[maxi(0, i - 1)]
		var b: Vector2 = profile[mini(m - 1, i + 1)]
		var t := b - a
		var n := Vector2(t.y, -t.x)
		pn.append(n.normalized() if n.length_squared() > 0.0 else Vector2(1, 0))
	for s in segments:
		var p0 := phi_start + phi_length * float(s) / segments
		var p1 := phi_start + phi_length * float(s + 1) / segments
		var s0 := sin(p0)
		var c0 := cos(p0)
		var s1 := sin(p1)
		var c1 := cos(p1)
		for i in m - 1:
			var a: Vector2 = profile[i]
			var b: Vector2 = profile[i + 1]
			var na: Vector2 = pn[i]
			var nb: Vector2 = pn[i + 1]
			var a0 := Vector3(a.x * s0, a.y, a.x * c0)
			var a1 := Vector3(a.x * s1, a.y, a.x * c1)
			var b0 := Vector3(b.x * s0, b.y, b.x * c0)
			var b1 := Vector3(b.x * s1, b.y, b.x * c1)
			var na0 := Vector3(na.x * s0, na.y, na.x * c0)
			var na1 := Vector3(na.x * s1, na.y, na.x * c1)
			var nb0 := Vector3(nb.x * s0, nb.y, nb.x * c0)
			var nb1 := Vector3(nb.x * s1, nb.y, nb.x * c1)
			var u0 := float(s) / segments
			var u1 := float(s + 1) / segments
			var va := float(i) / (m - 1)
			var vb := float(i + 1) / (m - 1)
			if a.x > 1e-6: g.tri(a0, a1, b1, na0, na1, nb1, Vector2(u0, va), Vector2(u1, va), Vector2(u1, vb))
			if b.x > 1e-6: g.tri(a0, b1, b0, na0, nb1, nb0, Vector2(u0, va), Vector2(u1, vb), Vector2(u0, vb))
	return g

## A plain cylinder (or cone frustum) about Y, centred on the origin. Its
## side shades smooth and its caps are flat. `open` leaves the caps off.
static func cylinder(r_top: float, r_bot: float, h: float, n: int, open := false, theta_start := 0.0, theta_length := TAU) -> Geo:
	var g := Geo.new()
	var slope := (r_bot - r_top) / h if h != 0.0 else 0.0
	for s in n:
		var t0 := theta_start + theta_length * float(s) / n
		var t1 := theta_start + theta_length * float(s + 1) / n
		var d0 := Vector3(sin(t0), 0, cos(t0))
		var d1 := Vector3(sin(t1), 0, cos(t1))
		var n0 := Vector3(d0.x, slope, d0.z).normalized()
		var n1 := Vector3(d1.x, slope, d1.z).normalized()
		var b0 := d0 * r_bot + Vector3(0, -h / 2.0, 0)
		var b1 := d1 * r_bot + Vector3(0, -h / 2.0, 0)
		var t0p := d0 * r_top + Vector3(0, h / 2.0, 0)
		var t1p := d1 * r_top + Vector3(0, h / 2.0, 0)
		var u0 := float(s) / n
		var u1 := float(s + 1) / n
		if r_bot > 1e-6: g.tri(b0, b1, t1p, n0, n1, n1, Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1))
		if r_top > 1e-6: g.tri(b0, t1p, t0p, n0, n1, n0, Vector2(u0, 0), Vector2(u1, 1), Vector2(u0, 1))
		if not open:
			var up := Vector3.UP
			var dn := Vector3.DOWN
			if r_top > 1e-6: g.tri(Vector3(0, h / 2.0, 0), t0p, t1p, up, up, up)
			if r_bot > 1e-6: g.tri(Vector3(0, -h / 2.0, 0), b1, b0, dn, dn, dn)
	return g

## A cylinder about Y whose rims are rounded over instead of knife-sharp.
static func cyl(r_top: float, r_bot: float, h: float, n: int, rim_steps := 4) -> Geo:
	var e := minf(0.006, minf(h * 0.25, minf(r_top, r_bot) * 0.25))
	if e <= 1e-5: return cylinder(r_top, r_bot, h, n)
	var prof := [Vector2(0, -h / 2.0)]
	for i in range(rim_steps + 1):
		var a := -PI / 2.0 + (float(i) / rim_steps) * (PI / 2.0)
		prof.append(Vector2(r_bot - e + cos(a) * e, -h / 2.0 + e + sin(a) * e))
	for i in range(rim_steps + 1):
		var a := (float(i) / rim_steps) * (PI / 2.0)
		prof.append(Vector2(r_top - e + cos(a) * e, h / 2.0 - e + sin(a) * e))
	prof.append(Vector2(0, h / 2.0))
	return lathe(prof, n)

## A cone standing on Y, apex up, centred on the origin.
static func cone(r: float, h: float, n: int) -> Geo:
	return cylinder(0.0, r, h, n)

## A torus about Z (lying in the XY plane), centred on the origin.
static func torus(radius: float, tube: float, radial_segments: int, tubular_segments: int) -> Geo:
	var g := Geo.new()
	for j in tubular_segments:
		var u0 := TAU * float(j) / tubular_segments
		var u1 := TAU * float(j + 1) / tubular_segments
		for i in radial_segments:
			var v0 := TAU * float(i) / radial_segments
			var v1 := TAU * float(i + 1) / radial_segments
			var p := []
			var nn := []
			for uv_pair in [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]:
				var u: float = uv_pair[0]
				var v: float = uv_pair[1]
				var c := Vector3(cos(u), sin(u), 0) * radius
				var q := Vector3((radius + tube * cos(v)) * cos(u), (radius + tube * cos(v)) * sin(u), tube * sin(v))
				p.append(q)
				nn.append((q - c).normalized())
			g.quad(p[0], p[1], p[2], p[3], nn[0], nn[1], nn[2], nn[3])
	return g

# ---------------------------------------------------------------- extrusions

static func _signed_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return a / 2.0

## The outline moved inward by `d` (a mitre at each corner, capped).
static func _inset(pts: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := pts.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var p := pts[i]
		var a := (p - pts[(i - 1 + n) % n]).normalized()
		var b := (pts[(i + 1) % n] - p).normalized()
		# Inward normals of the two edges (the outline runs counter-clockwise).
		var na := Vector2(-a.y, a.x)
		var nb := Vector2(-b.y, b.x)
		var m := na + nb
		var l := m.length()
		if l < 1e-6:
			out[i] = p + na * d
			continue
		m /= l
		var k := d / maxf(0.35, m.dot(na))
		out[i] = p + m * k
	return out

## Extrude a closed 2D outline `depth` thick along Z, centred on z = 0, with
## a chamfer of `bevel` that eats INTO the outline (so the part never grows
## past the size it was given). `holes` are outlines cut through it; each must
## lie inside and be reachable by a straight cut from the outline's nearest
## point (true of the lightening holes in a disc).
static func extrude(outline: PackedVector2Array, depth: float, bevel := 0.003, holes: Array = [], crease := 0.6) -> Geo:
	var g := Geo.new()
	var pts := outline
	if pts.size() < 3: return g
	if _signed_area(pts) < 0.0:
		pts = pts.duplicate()
		pts.reverse()
	var bev := minf(bevel, depth * 0.3)
	if bev < 1e-5: bev = 0.0
	var zf := depth / 2.0
	var zs := zf - bev
	var cap := _inset(pts, bev) if bev > 0.0 else pts

	# Caps (with any holes cut in).
	var cap_poly := cap
	var cap_holes := []
	for h in holes:
		var hp: PackedVector2Array = h
		if _signed_area(hp) > 0.0:
			hp = hp.duplicate()
			hp.reverse()
		# A hole's edge chamfers too: it opens out by the bevel at the faces.
		cap_holes.append(_inset(hp, bev) if bev > 0.0 else hp)
	cap_poly = _cut_holes(cap, cap_holes)
	var idx := Geometry2D.triangulate_polygon(cap_poly)
	var front := Vector3(0, 0, 1)
	var back := Vector3(0, 0, -1)
	for t in range(0, idx.size(), 3):
		var a := cap_poly[idx[t]]
		var b := cap_poly[idx[t + 1]]
		var c := cap_poly[idx[t + 2]]
		if (b - a).cross(c - a) < 0.0:
			var tmp := b
			b = c
			c = tmp
		g.tri(Vector3(a.x, a.y, zf), Vector3(b.x, b.y, zf), Vector3(c.x, c.y, zf), front, front, front)
		g.tri(Vector3(a.x, a.y, -zf), Vector3(c.x, c.y, -zf), Vector3(b.x, b.y, -zf), back, back, back)

	_walls(g, pts, cap, zf, zs, bev, crease, false)
	for hi in holes.size():
		var hp: PackedVector2Array = holes[hi]
		if _signed_area(hp) > 0.0:
			hp = hp.duplicate()
			hp.reverse()
		_walls(g, hp, cap_holes[hi], zf, zs, bev, crease, true)
	return g.tile_uvs()

# The side wall and the two chamfer bands of one outline. `pts` runs
# counter-clockwise for an outer edge and clockwise for a hole's, so "left of
# travel" is always the solid side.
static func _walls(g: Geo, pts: PackedVector2Array, cap: PackedVector2Array, zf: float, zs: float, bev: float, crease: float, _hole: bool) -> void:
	var n := pts.size()
	# Outward normal of each edge, and a smoothed one per vertex where the
	# outline curves gently.
	var en := PackedVector2Array()
	en.resize(n)
	for i in n:
		var e := (pts[(i + 1) % n] - pts[i]).normalized()
		en[i] = Vector2(e.y, -e.x)
	var cos_c := cos(crease)
	for i in n:
		var j := (i + 1) % n
		var prev := (i - 1 + n) % n
		var nxt := (i + 1) % n
		var ni := en[i]
		var na := (en[prev] + ni).normalized() if en[prev].dot(ni) > cos_c else ni
		var nb := (en[nxt] + ni).normalized() if en[nxt].dot(ni) > cos_c else ni
		var p := pts[i]
		var q := pts[j]
		var n3a := Vector3(na.x, na.y, 0)
		var n3b := Vector3(nb.x, nb.y, 0)
		if zs > 1e-6:
			g.quad(Vector3(p.x, p.y, -zs), Vector3(q.x, q.y, -zs), Vector3(q.x, q.y, zs), Vector3(p.x, p.y, zs), n3a, n3b, n3b, n3a)
		if bev > 0.0:
			var cp := cap[i]
			var cq := cap[j]
			var fa := (n3a + Vector3(0, 0, 1)).normalized()
			var fb := (n3b + Vector3(0, 0, 1)).normalized()
			g.quad(Vector3(p.x, p.y, zs), Vector3(q.x, q.y, zs), Vector3(cq.x, cq.y, zf), Vector3(cp.x, cp.y, zf), fa, fb, fb, fa)
			var ba := (n3a + Vector3(0, 0, -1)).normalized()
			var bb := (n3b + Vector3(0, 0, -1)).normalized()
			g.quad(Vector3(q.x, q.y, -zs), Vector3(p.x, p.y, -zs), Vector3(cp.x, cp.y, -zf), Vector3(cq.x, cq.y, -zf), bb, ba, ba, bb)

# One outline with its holes joined in by hairline cuts, so a plain
# ear-clipper can triangulate it.
static func _cut_holes(outer: PackedVector2Array, holes: Array) -> PackedVector2Array:
	var poly := outer.duplicate()
	for h in holes:
		var hp: PackedVector2Array = h
		if hp.size() < 3: continue
		# The nearest pair of points, one on each.
		var bi := 0
		var bj := 0
		var bd := INF
		for i in poly.size():
			for j in hp.size():
				var d := poly[i].distance_squared_to(hp[j])
				if d < bd:
					bd = d
					bi = i
					bj = j
		var out := PackedVector2Array()
		for i in range(bi + 1): out.append(poly[i])
		# Round the hole and back, the return a hair to one side so no two
		# points of the polygon coincide.
		for k in range(hp.size() + 1): out.append(hp[(bj + k) % hp.size()])
		var dir := (hp[bj] - poly[bi]).normalized()
		var side := Vector2(dir.y, -dir.x) * 1e-5
		out[out.size() - 1] = hp[bj] + side
		out.append(poly[bi] + side)
		for i in range(bi + 1, poly.size()): out.append(poly[i])
		poly = out
	return poly

## A flat ring between two closed outlines sampled in step (the same number
## of points, corresponding in order), `depth` thick along Z - an eggbeater's
## hoop. No bevel.
static func ring_extrude(outer: PackedVector2Array, inner: PackedVector2Array, depth: float) -> Geo:
	var g := Geo.new()
	var n := outer.size()
	var z := depth / 2.0
	var front := Vector3(0, 0, 1)
	var back := Vector3(0, 0, -1)
	for i in n:
		var j := (i + 1) % n
		var o0 := outer[i]
		var o1 := outer[j]
		var i0 := inner[i]
		var i1 := inner[j]
		g.quad(Vector3(i0.x, i0.y, z), Vector3(o0.x, o0.y, z), Vector3(o1.x, o1.y, z), Vector3(i1.x, i1.y, z), front, front, front, front)
		g.quad(Vector3(o0.x, o0.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i1.x, i1.y, -z), Vector3(o1.x, o1.y, -z), back, back, back, back)
		var no0 := Vector3(o0.x, o0.y, 0).normalized()
		var no1 := Vector3(o1.x, o1.y, 0).normalized()
		g.quad(Vector3(o0.x, o0.y, -z), Vector3(o1.x, o1.y, -z), Vector3(o1.x, o1.y, z), Vector3(o0.x, o0.y, z), no0, no1, no1, no0)
		var ni0 := -Vector3(i0.x, i0.y, 0).normalized()
		var ni1 := -Vector3(i1.x, i1.y, 0).normalized()
		g.quad(Vector3(i1.x, i1.y, -z), Vector3(i0.x, i0.y, -z), Vector3(i0.x, i0.y, z), Vector3(i1.x, i1.y, z), ni1, ni0, ni0, ni1)
	return g.tile_uvs()

# ---------------------------------------------------------------- hulls

## A convex hull, flat-shaded, with tiling UVs.
static func hull(points) -> Geo:
	var g := Geo.new()
	var h := Hull.convex_hull(points)
	var pts: PackedVector3Array = h.points
	for t in h.triangles: g.flat_tri(pts[t[0]], pts[t[1]], pts[t[2]])
	return g.tile_uvs()

## A convex piece with its edges rounded (smooth-shaded), or the plain hull
## if it cannot be rounded.
static func rounded_hull(points, radius := 0.022, step := PI / 6.0) -> Geo:
	var rh = RoundedHull.build(points, {"radius": radius, "step": step})
	if rh == null: return hull(points)
	return from_soup(rh.positions, rh.normals).tile_uvs()

# ---------------------------------------------------------------- curves

## Points along a quadratic Bezier (the end point included, the start not).
static func quad_curve(p0: Vector2, c: Vector2, p1: Vector2, steps := 12) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(1, steps + 1):
		var t := float(i) / steps
		out.append(p0.lerp(c, t).lerp(c.lerp(p1, t), t))
	return out

## Points along a cubic Bezier (the end point included, the start not).
static func cubic_curve(p0: Vector2, c0: Vector2, c1: Vector2, p1: Vector2, steps := 16) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(1, steps + 1):
		out.append(p0.bezier_interpolate(c0, c1, p1, float(i) / steps))
	return out
