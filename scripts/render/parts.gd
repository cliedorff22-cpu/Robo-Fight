## parts.gd - the detailed geometry a robot is dressed in: tyres and hubs,
## spinner bars with impactors, toothed discs, drums, shells, hammer heads,
## flipper plates, forks and beaks.
##
## Every builder works in the frame robot_view.gd animates. A rotor is built
## to spin about its local Y; an arm reaches along +X from its pivot and
## strikes towards -Y. Sizes come from the same numbers shape.gd gives the
## colliders, and the detail stays inside them - a tooth never reaches past
## the radius physics uses.
##
## Builders return [{ geo: Geo, mat: String }] where `mat` is a key
## robot_view resolves: "steel" (polished weapon steel), "hub", "dark",
## "accent", "paint", "paintFlat", "trim", "saw".
class_name Parts

## How a robot is drawn: body pieces rounded to `radius` metres (smaller on
## thin plates), and round parts given `detail` times the base segment count
## (the phone build uses fewer).
const BODY_RADIUS := 0.022
static var mobile := false
## Graphics tier 3: wheels (and the like) as detailed models. Read when a
## robot is built.
static var detailed := true

## Segments for a round part: more on desktop.
static func seg(n: int) -> int:
	return n if mobile else int(round(n * 1.5))

static func _step() -> float:
	return PI / 4.0 if mobile else PI / 6.0

static func _p(geo: Geo, mat: String) -> Dictionary:
	return {"geo": geo, "mat": mat}

static func _poly(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts: out.append(Vector2(p[0], p[1]))
	return out

## Extrude a 2D outline `depth` thick, centred on z = 0, with a small chamfer.
static func extrude(outline: PackedVector2Array, depth: float, bevel := 0.003, holes: Array = []) -> Geo:
	return Geo.extrude(outline, depth, bevel * 2.0, holes)

## A w x h x d block centred on the origin, corners rounded.
static func box(w: float, h: float, d: float) -> Geo:
	return Geo.round_box(w, h, d, 0.006, _step())

## A cylinder about Y with rounded rims.
static func cyl(r_top: float, r_bot: float, h: float, n: int) -> Geo:
	return Geo.cyl(r_top, r_bot, h, seg(n), 2 if mobile else 4)

# ---------------------------------------------------------------- body hulls

## A body piece: its convex hull with every edge and corner rounded. With
## `bounds` (the body's bounds) UVs index the livery atlas; without, they
## tile in world metres.
static func hull_geometry(points: Array, bounds = null) -> Geo:
	var g := Geo.rounded_hull(points, BODY_RADIUS, _step())
	if bounds != null:
		# The paint panel is picked once per triangle, by its own facing, so
		# no triangle straddles two panels of the atlas.
		for t in range(0, g.pos.size(), 3):
			var n := (g.pos[t + 1] - g.pos[t]).cross(g.pos[t + 2] - g.pos[t]).normalized()
			for k in 3: g.uv[t + k] = Livery.atlas_uv(g.pos[t + k], n, bounds)
	return g

## A ring of bolt heads facing +Y (or -Y), radius `rad` about the Y axis.
static func bolt_ring(n: int, rad: float, y: float, head: float, up := 1.0, phase := 0.0) -> Geo:
	var out := Geo.new()
	for i in n:
		var a := phase + (float(i) / n) * TAU
		out.append(Geo.cylinder(head, head, head * 0.9, 6).translate(cos(a) * rad, y + up * head * 0.45, sin(a) * rad))
	return out

# ---------------------------------------------------------------- wheels

## A tyre with rounded shoulders on a hub with five spokes, axle along Z.
## Returns { tyre, hub, spokes, cap } geometries shared by every wheel.
static func wheel_geometries(r: float, w: float) -> Dictionary:
	if detailed and not mobile: return _wheel_detailed(r, w)
	var ri := r * 0.62
	var c := minf(w * 0.32, r * 0.24)
	var prof := [Vector2(ri, -w / 2.0 * 0.94)]
	for i in range(6):
		var a := -PI / 2.0 + (i / 5.0) * (PI / 2.0)
		prof.append(Vector2(r - c + cos(a) * c, -w / 2.0 + c + sin(a) * c))
	for i in range(6):
		var a := (i / 5.0) * (PI / 2.0)
		prof.append(Vector2(r - c + cos(a) * c, w / 2.0 - c + sin(a) * c))
	prof.append(Vector2(ri, w / 2.0 * 0.94))
	var tyre := Geo.lathe(prof, seg(32)).rotate_x(PI / 2.0)
	var hub := cyl(ri * 1.01, ri * 1.01, w * 0.84, 24).rotate_x(PI / 2.0)

	var spokes := Geo.new()
	var caps := Geo.new()
	for s in [-1.0, 1.0]:
		var z: float = s * (w * 0.42 + 0.002)
		for k in 5:
			spokes.append(Geo.box(ri * 0.82, ri * 0.2, 0.006).translate(ri * 0.41, 0, z).rotate_z((k / 5.0) * TAU))
		spokes.append(Geo.torus(ri * 0.9, ri * 0.07, 8, seg(24)).translate(0, 0, z))
		caps.append(Geo.cylinder(ri * 0.26, ri * 0.3, 0.014, 6).rotate_x(PI / 2.0).translate(0, 0, s * (w * 0.42 + 0.007)))
	return {"tyre": tyre, "hub": hub, "spokes": spokes, "cap": caps}

static func _circle(r: float, n: int, cx := 0.0, cy := 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := (float(i) / n) * TAU
		out.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	return out

## The wheel as a model (graphics tier 3): a knobbly tyre - two staggered rows
## of lugs set in a chevron, wrapping the shoulders - on a machined rim with
## lips, a five-hole face plate over a dark well, a boss and its wheel nuts.
## The same four parts as the plain wheel, and nothing reaches past `r`.
static func _wheel_detailed(r: float, w: float) -> Dictionary:
	var ri := r * 0.62
	var lug := clampf(r * 0.075, 0.003, 0.008)
	var rc := r - lug                      # the carcass the lugs stand on
	var c := minf(w * 0.32, rc * 0.24)
	var prof := [Vector2(ri, -w / 2.0 * 0.94)]
	for i in range(6):
		var a := -PI / 2.0 + (i / 5.0) * (PI / 2.0)
		prof.append(Vector2(rc - c + cos(a) * c, -w / 2.0 + c + sin(a) * c))
	for i in range(6):
		var a := (i / 5.0) * (PI / 2.0)
		prof.append(Vector2(rc - c + cos(a) * c, w / 2.0 - c + sin(a) * c))
	prof.append(Vector2(ri, w / 2.0 * 0.94))
	var tyre := Geo.lathe(prof, seg(32)).rotate_x(PI / 2.0)
	var n := clampi(int(round(TAU * r / 0.026)), 14, 40)
	var pitch := TAU / n
	var across := w * 0.5 - 0.0015         # a lug's reach from the middle groove to the tyre's edge
	var along := 2.0 * r * sin(pitch * 0.5) * 0.6
	var deep := lug + c * 0.55             # down into the carcass, so the shoulder never leaves a gap under it
	for row in 2:
		var side := -1.0 if row == 0 else 1.0
		for i in n:
			var block := Geo.box(along, deep, across * 0.9).rotate_y(side * 0.3)
			block.translate(0, r - deep / 2.0, side * (across * 0.5 + 0.0015))
			tyre.append(block.tile_uvs(8.0).rotate_z((i + 0.5 * row) * pitch))
	# Nothing of a lug stands outside the wheel's radius or its width.
	for i in tyre.pos.size():
		var p := tyre.pos[i]
		var flat := Vector2(p.x, p.y)
		if flat.length() > r: flat = flat.normalized() * r
		tyre.pos[i] = Vector3(flat.x, flat.y, clampf(p.z, -w / 2.0, w / 2.0))

	var rim := Geo.ring_extrude(_circle(ri * 1.02, seg(28)), _circle(ri * 0.9, seg(28)), w * 0.86)
	var well_z := w * 0.26
	var hub := Geo.new()
	hub.append(rim)
	hub.append(cyl(ri * 0.34, ri * 0.34, w * 0.8, 16).rotate_x(PI / 2.0))
	var spokes := Geo.new()                # the dark parts: the well behind the plate, the wheel nuts
	spokes.append(Geo.cylinder(ri * 0.91, ri * 0.91, well_z * 2.0, seg(24)).rotate_x(PI / 2.0))
	var caps := Geo.new()
	var holes := []
	for k in 5:
		var a := (k / 5.0) * TAU + PI / 5.0
		var hole := _circle(ri * 0.2, 12, cos(a) * ri * 0.6, sin(a) * ri * 0.6)
		hole.reverse()                     # holes wind the other way
		holes.append(hole)
	for s in [-1.0, 1.0]:
		var z: float = s * (well_z + 0.006)
		hub.append(Geo.extrude(_circle(ri * 0.92, seg(28)), 0.005, 0.002, holes).translate(0, 0, z))
		for k in 5:
			var a := (k / 5.0) * TAU
			spokes.append(Geo.cylinder(ri * 0.055, ri * 0.055, 0.006, 6).rotate_x(PI / 2.0).translate(cos(a) * ri * 0.24, sin(a) * ri * 0.24, s * (w * 0.4 + 0.002)))
		caps.append(Geo.cylinder(ri * 0.13, ri * 0.15, 0.008, 6).rotate_x(PI / 2.0).translate(0, 0, s * (w * 0.4 + 0.004)))
	return {"tyre": tyre, "hub": hub, "spokes": spokes, "cap": caps}

# ---------------------------------------------------------------- rotors

## A spinner bar: a flat bar with a hardened impactor hooked out of each end,
## on a hub boss. Lies along X, spins about Y.
static func bar_rotor(r: float, t: float, b: float, style := "hook") -> Array:
	if style == "slab" or style == "taper": return _bar_plain(r, t, b, style == "taper")
	var h := b / 2.0
	var p := b * 0.34
	var c := b * 0.5
	var outline := _poly([
		[r - c, -h], [r, -h + c * 0.6], [r, h], [r - b * 0.55, h + p], [r - b * 1.25, h + p * 0.2], [r - b * 1.6, h],
		[-r + c, h], [-r, h - c * 0.6], [-r, -h], [-r + b * 0.55, -h - p], [-r + b * 1.25, -h - p * 0.2], [-r + b * 1.6, -h],
	])
	var bar := extrude(outline, t, minf(0.004, t * 0.15)).rotate_x(-PI / 2.0)
	# Impactor inserts: a darker hardened block on each tooth.
	var inserts := Geo.new()
	for s in [-1.0, 1.0]:
		inserts.append(box(b * 0.5, t * 1.04, p * 0.9).translate(s * (r - b * 0.62), 0, -s * (h + p * 0.45)))
	var hub_r := minf(b * 0.85, r * 0.3)
	return [
		_p(bar, "steel"),
		_p(inserts, "dark"),
		_p(cyl(hub_r, hub_r * 1.05, t * 1.5, 20), "hub"),
		_p(bolt_ring(4, hub_r * 0.6, t * 0.75, maxf(0.005, hub_r * 0.12)), "dark"),
	]

# A plain bar: a slab with clipped corners (a Tombstone's), or one that
# tapers from a broad middle to blunt ends. Bolted through a round boss.
static func _bar_plain(r: float, t: float, b: float, taper: bool) -> Array:
	var h := b / 2.0
	var c := b * 0.3
	var outline: PackedVector2Array
	if taper:
		outline = _poly([[r, -h * 0.55], [r, h * 0.55], [r * 0.3, h * 1.25], [-r * 0.3, h * 1.25], [-r, h * 0.55], [-r, -h * 0.55], [-r * 0.3, -h * 1.25], [r * 0.3, -h * 1.25]])
	else:
		outline = _poly([[r - c, -h], [r, -h + c], [r, h], [-r + c, h], [-r, h - c], [-r, -h]])
	var bar := extrude(outline, t, minf(0.004, t * 0.15)).rotate_x(-PI / 2.0)
	# The edges that do the hitting, ground bright.
	var tips := Geo.new()
	for s in [-1.0, 1.0]:
		tips.append(box(b * 0.16, t * 1.03, b * (0.9 if not taper else 0.5)).translate(s * (r - b * 0.09), 0, 0))
	var hub_r := minf(b * 0.8, r * 0.28)
	return [
		_p(bar, "steel"),
		_p(tips, "dark"),
		_p(cyl(hub_r, hub_r * 1.05, t * 1.5, 20), "hub"),
		_p(bolt_ring(6, hub_r * 0.62, t * 0.75, maxf(0.005, hub_r * 0.11)), "dark"),
	]

## How many teeth a disc of this style has (the spinner blur's lobes).
static func disc_teeth(style: String, r: float, teeth: int) -> int:
	if style == "cam": return 1
	if style == "saw": return clampi(int(round(r / 0.024)), 8, 14)
	return teeth

## A disc with hooked teeth and lightening holes, in the XZ plane.
## `fine` makes it a saw blade. `style`: "holes" (three round ones), "spokes"
## (a wheel: windows between spokes), "cam" (one tooth on a snail, the heavy
## side opposite), "saw" (a ring of short teeth) or "plain".
static func disc_rotor(r: float, t: float, teeth := 2, fine := false, style := "holes") -> Array:
	teeth = disc_teeth(style, r, teeth)
	var saw := style == "saw"
	var cam := style == "cam"
	var rin := r * 0.9 if (fine or saw) else r * 0.82
	var lead := 0.02 if fine else (0.04 if saw else 0.05)
	var span := (TAU / teeth) * 0.95 if fine else ((TAU / teeth) * 0.9 if saw else minf(1.1, (TAU / teeth) * 0.5))
	var N := maxi(96, teeth * 6) if fine else (maxi(160, teeth * 14) if saw else 160)
	var pts := PackedVector2Array()
	for i in N:
		var th := (float(i) / N) * TAU
		# A cam's rim winds outward all the way round to its one tooth.
		var floor_r := r * lerpf(0.62, 0.84, fposmod(-th, TAU) / TAU) if cam else rin
		var best := floor_r
		for k in teeth:
			var phi := fposmod(th - (float(k) / teeth) * TAU, TAU)
			var v := floor_r
			if phi < lead: v = floor_r + (r - floor_r) * (phi / lead)
			elif phi < span: v = r - (r - floor_r) * pow((phi - lead) / (span - lead), 0.7)
			best = maxf(best, v)
		pts.append(Vector2(cos(th) * best, sin(th) * best))
	var holes := []
	if not fine and r > 0.12 and style != "plain":
		if style == "spokes" or saw:
			# Windows between spokes, from the hub out to the rim.
			var n := 5 if r > 0.24 else 4
			var r0 := maxf(r * 0.3, 0.04)
			var r1 := r * (0.7 if not saw else 0.74)
			for i in n:
				var a0 := (float(i) / n) * TAU + 0.16
				var a1 := (float(i + 1) / n) * TAU - 0.16
				var hole := PackedVector2Array()
				var m := seg(6)
				for k in range(m + 1):
					var a := lerpf(a0, a1, float(k) / m)
					hole.append(Vector2(cos(a) * r1, sin(a) * r1))
				for k in range(m + 1):
					var a := lerpf(a1 - 0.08, a0 + 0.08, float(k) / m)
					hole.append(Vector2(cos(a) * r0, sin(a) * r0))
				hole.reverse()
				holes.append(hole)
		else:
			# Round ones; a cam's are all on its light side, to balance it.
			var spots := [0.5, 0.5 + TAU / 3.0, 0.5 + 2.0 * TAU / 3.0] if not cam else [1.2, 2.1]
			for a in spots:
				var hole := PackedVector2Array()
				var hn := seg(16)
				var hr := r * (0.14 if not cam else 0.11)
				for k in hn:
					var ha := -(float(k) / hn) * TAU
					hole.append(Vector2(cos(a) * r * 0.52 + cos(ha) * hr, sin(a) * r * 0.52 + sin(ha) * hr))
				holes.append(hole)
	var thick := maxf(0.012, t)
	var disc := extrude(pts, thick, 0.002, holes).rotate_x(-PI / 2.0)
	var hub_r := maxf(0.025, r * 0.2)
	var out := [_p(disc, "saw" if fine else "steel")]
	# The hardened teeth, picked out darker.
	if not fine and not saw:
		var tips := Geo.new()
		for i in teeth:
			var a := (float(i) / teeth) * TAU + lead * 1.5
			tips.append(box((r - rin) * 1.2, thick * 1.06, (r - rin) * 0.9).translate(r - (r - rin) * 0.62, 0, 0).rotate_y(-a))
		out.append(_p(tips, "dark"))
	out.append(_p(cyl(hub_r, hub_r, thick * 1.8 + 0.01, 20), "hub"))
	out.append(_p(bolt_ring(5, hub_r * 0.62, (thick * 1.8 + 0.01) / 2.0, maxf(0.004, hub_r * 0.13)), "dark"))
	return out

## A drum: a heavy steel tube with staggered rows of teeth, axis Y. `style`:
## "teeth" (those), "bars" (two impactors the length of it, a Minotaur's) or
## "discs" (a stack of toothed plates on a slimmer tube). `mat` is what the
## tube is made of.
static func drum_rotor(r: float, length: float, rows_in = null, per_row := 2, style := "teeth", mat := "steel") -> Array:
	if style == "discs": return _drum_discs(r, length, mat)
	if style == "bars": return _drum_bars(r, length, mat)
	var core := cyl(r * 0.76, r * 0.76, length * 0.94, 28)
	var flanges := Geo.new()
	for s in [-1.0, 1.0]:
		flanges.append(cyl(r * 0.82, r * 0.82, length * 0.04, 28).translate(0, s * length * 0.48, 0))
		flanges.append(bolt_ring(6, r * 0.5, s * length * 0.5, r * 0.06, s))
	var rows: int = int(rows_in) if rows_in != null else maxi(2, mini(5, J.rndi(length / (r * 1.25))))
	var teeth := Geo.new()
	var tw := r * 0.42
	var h := r * 0.27
	var tl := minf((length * 0.9) / rows * 0.62, r * 0.75)
	var prof := _poly([[0, -tw / 2.0], [h * 0.75, -tw * 0.3], [h, tw * 0.05], [h, tw * 0.5], [0, tw / 2.0]])
	for row in rows:
		var y := -length * 0.45 + (length * 0.9 * (row + 0.5)) / rows
		for k in per_row:
			var a := (float(k) / per_row) * TAU + (row % 2) * (PI / per_row)
			var radial := Vector3(cos(a), 0, sin(a))
			var tang := Vector3(-sin(a), 0, cos(a))
			teeth.append(extrude(prof, tl, 0.003).apply(Transform3D(Basis(radial, tang, Vector3.UP), radial * (r * 0.73) + Vector3(0, y, 0))))
	return [
		_p(core, mat),
		_p(flanges, "dark"),
		_p(teeth, "dark"),
		_p(cyl(r * 0.2, r * 0.2, length * 1.04, 12), "hub"),
	]

static func _drum_bars(r: float, length: float, mat: String) -> Array:
	var core := cyl(r * 0.8, r * 0.8, length * 0.94, 28)
	var flanges := Geo.new()
	for s in [-1.0, 1.0]:
		flanges.append(cyl(r * 0.86, r * 0.86, length * 0.04, 28).translate(0, s * length * 0.48, 0))
		flanges.append(bolt_ring(6, r * 0.5, s * length * 0.5, r * 0.06, s))
	# An impactor bar each side, let into the tube and standing to the full radius.
	var bars := Geo.new()
	var prof := _poly([[0, -r * 0.2], [r * 0.2, -r * 0.14], [r * 0.24, r * 0.08], [r * 0.24, r * 0.2], [0, r * 0.2]])
	var screws := Geo.new()
	for k in 2:
		var a := k * PI
		var radial := Vector3(cos(a), 0, sin(a))
		var tang := Vector3(-sin(a), 0, cos(a))
		bars.append(extrude(prof, length * 0.88, 0.003).apply(Transform3D(Basis(radial, tang, Vector3.UP), radial * (r * 0.76))))
		var n := clampi(int(round(length / 0.06)), 3, 9)
		for i in n:
			var y := -length * 0.4 + length * 0.8 * i / (n - 1)
			screws.append(Geo.cylinder(r * 0.05, r * 0.05, r * 0.03, 6).apply(Transform3D(Basis(tang, radial, Vector3.UP.cross(radial)), radial * (r * 0.985) + tang * (r * 0.12) + Vector3(0, y, 0))))
	return [_p(core, mat), _p(flanges, "dark"), _p(bars, "dark"), _p(screws, "hub"), _p(cyl(r * 0.2, r * 0.2, length * 1.04, 12), "hub")]

static func _drum_discs(r: float, length: float, mat: String) -> Array:
	var n := clampi(int(round(length / maxf(0.06, r * 0.5))), 3, 7)
	var plate := minf(length / n * 0.5, r * 0.3)
	var discs := Geo.new()
	var tips := Geo.new()
	var spacers := Geo.new()
	for i in n:
		var y := -length * 0.47 + plate / 2.0 + (length * 0.94 - plate) * i / (n - 1)
		for part in disc_rotor(r, plate, 2, false, "plain"):
			var g: Geo = part.geo
			if part.mat == "hub": continue
			g.rotate_y(i * PI / 2.0).translate(0, y, 0)
			if part.mat == "dark": tips.append(g)
			else: discs.append(g)
		if i < n - 1:
			var gap := (length * 0.94 - plate) / (n - 1) - plate
			spacers.append(Geo.cylinder(r * 0.5, r * 0.5, gap, 20, true).translate(0, y + plate / 2.0 + gap / 2.0, 0))
	return [_p(discs, "steel"), _p(tips, "dark"), _p(spacers, mat), _p(cyl(r * 0.2, r * 0.2, length * 1.04, 12), "hub")]

## An eggbeater: two flat hoops crossed on the axle, axis Y, `length` long.
static func eggbeater_rotor(r: float, length: float) -> Array:
	var hoops := Geo.new()
	var n := seg(28)
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	for i in n:
		var a := (float(i) / n) * TAU
		outer.append(Vector2(cos(a) * r, sin(a) * length * 0.46))
		inner.append(Vector2(cos(a) * r * 0.74, sin(a) * (length * 0.46 - r * 0.26)))
	for a in [0.0, PI / 2.0]:
		hoops.append(Geo.ring_extrude(outer, inner, r * 0.3).rotate_y(a))
	# Hardened tips where the hoops bite.
	var tips := Geo.new()
	for a in [0.0, PI / 2.0, PI, PI * 1.5]:
		tips.append(box(r * 0.3, length * 0.2, r * 0.36).translate(r * 0.88, 0, 0).rotate_y(a))
	return [
		_p(hoops, "steel"),
		_p(tips, "dark"),
		_p(cyl(r * 0.16, r * 0.16, length * 1.02, 12), "hub"),
	]

static func _shell_shape(profile: String, s: float) -> float:
	match profile:
		"dome": return 1.0 if s < 0.35 else sqrt(maxf(0.0, 1.0 - pow((s - 0.35) / 0.65, 2.0)))
		"cone": return 1.0 if s < 0.3 else 1.0 - 0.72 * ((s - 0.3) / 0.7)
		"drum": return 1.0 if s < 0.86 else 1.0 - 0.1 * ((s - 0.86) / 0.14)
		"bowl": return 1.0 if s < 0.28 else 1.0 - 0.42 * pow((s - 0.28) / 0.72, 0.6)
		"saucer": return 1.0 if s < 0.15 else 1.0 - 0.75 * pow((s - 0.15) / 0.85, 1.4)
	return 1.0

## A full-body shell, axis Y, from `h/2` below the hub up over the whole
## robot. `profile`: "dome" | "drum" | "cone" | "bowl" | "saucer". `top_y` is
## the top of the shell above the hub, and `body_radius` (Callable(y)) the
## body radius at height y: the shell never cuts into the body it covers.
## The painted shell is in the robot's colour, with a steel skirt carrying
## the teeth at the rim, where the hits land.
static func shell_rotor(r: float, h: float, profile := "dome", teeth := 2, top_y = null, body_radius: Callable = Callable(), rib_count := 6) -> Array:
	var wr := r * 0.94
	var bot := -h / 2.0
	var top := maxf(float(top_y) if top_y != null else h / 2.0, h / 2.0)
	var br := func(y: float) -> float:
		return float(body_radius.call(y)) if body_radius.is_valid() else 0.0
	var N := 20
	var pts := []
	for i in range(N + 1):
		var sn := float(i) / N
		var y := bot + (top - bot) * sn
		# Out to the full weapon radius where the body needs the room.
		var rad := minf(r * 0.99, maxf(_shell_shape(profile, sn) * wr, br.call(y) + 0.012))
		pts.append(Vector2(maxf(0.001, rad), y))
	# Close the top: a flat cap in from the last ring.
	pts.append(Vector2(0.001, top))
	# The skirt is the lower third, in steel.
	var cut := maxi(2, J.rndi(N * 0.3))
	var skirt_prof := [Vector2(wr * 0.9, bot)]
	skirt_prof.append_array(pts.slice(0, cut + 1))
	var skirt := Geo.lathe(skirt_prof, seg(48))
	var shell := Geo.lathe(pts.slice(cut), seg(48))
	var tooth := Geo.new()
	var tw := r * 0.3
	var th := minf(h * 0.4, r * 0.25)
	var ty := bot + h * 0.2
	for i in teeth:
		var a := (float(i) / teeth) * TAU
		var prof2 := _poly([[0, -tw / 2.0], [r - wr + r * 0.06, -tw * 0.2], [r - wr + r * 0.06, tw * 0.5], [0, tw / 2.0]])
		var radial := Vector3(cos(a), 0, sin(a))
		var tang := Vector3(-sin(a), 0, cos(a))
		tooth.append(extrude(prof2, th, 0.003).apply(Transform3D(Basis(radial, tang, Vector3.UP), radial * (maxf(wr, pts[2].x) - r * 0.06) + Vector3(0, ty, 0))))
	# A hub cap and bolt ring on top.
	var cap_r := maxf(0.03, r * 0.14)
	var cap := cyl(cap_r, cap_r * 1.15, 0.022, 20).translate(0, top + 0.008, 0)
	# A painted band round the shell, in the accent colour.
	var band_y := bot + (top - bot) * 0.42
	var band_r: float = minf(r * 0.99, maxf(_shell_shape(profile, 0.42) * wr, br.call(band_y) + 0.012)) + 0.002
	var band := Geo.cylinder(band_r, band_r, maxf(0.012, (top - bot) * 0.06), seg(48), true).translate(0, band_y, 0)
	var out := [
		_p(shell, "paintFlat"),
		_p(skirt, "steel"),
		_p(band, "accent"),
		_p(tooth, "dark"),
		_p(cap, "hub"),
		_p(bolt_ring(6, cap_r * 0.65, top + 0.019, 0.006), "dark"),
	]
	if Dress.on and not mobile:
		# A spun shell is braced and bolted: ribs up over it from the skirt to
		# the hub, and the bolts that hold the skirt on. `ribs` many of them.
		var ribs := Geo.new()
		var rib_r := clampf(r * 0.022, 0.004, 0.008)
		for i in rib_count:
			var a := (float(i) + 0.5) / rib_count * TAU
			var path := []
			for k in range(cut, pts.size() - 1):
				var q: Vector2 = pts[k]
				path.append(Vector3(sin(a) * q.x, q.y, cos(a) * q.x))
			path.append(Vector3(sin(a) * cap_r * 1.1, top, cos(a) * cap_r * 1.1))
			ribs.append(Kit.tube(path, rib_r, 6))
		out.append(_p(ribs, "steel"))
		var studs := Geo.new()
		var n := clampi(int(round(TAU * band_r / 0.07)), 10, 28)
		for i in n:
			var a := (float(i) / n) * TAU
			var dir := Vector3(sin(a), 0, cos(a))
			studs.append(Kit.bolt(0.006).apply(Kit.along(dir, dir * band_r + Vector3(0, band_y, 0))))
		out.append(_p(studs, "hub"))
	return out

## Three arms with a hammer block on each - the meat tenderiser.
static func tri_rotor(r: float, t: float) -> Array:
	var arms := Geo.new()
	var heads := Geo.new()
	for i in 3:
		var a := (i / 3.0) * TAU
		arms.append(extrude(_poly([[0, -r * 0.1], [r * 0.85, -r * 0.06], [r * 0.85, r * 0.06], [0, r * 0.1]]), t * 0.5, 0.003).rotate_x(-PI / 2.0).rotate_y(-a))
		heads.append(extrude(_poly([[-r * 0.13, -r * 0.16], [r * 0.13, -r * 0.13], [r * 0.15, r * 0.13], [-r * 0.13, r * 0.16]]), t * 1.1, 0.005)
			.rotate_x(-PI / 2.0).translate(r * 0.86, 0, 0).rotate_y(-a))
	return [
		_p(arms, "steel"),
		_p(heads, "dark"),
		_p(cyl(r * 0.2, r * 0.22, t * 1.2, 20), "hub"),
		_p(bolt_ring(3, r * 0.12, t * 0.6, 0.007), "dark"),
	]

# ---------------------------------------------------------------- arms

## A hammer or axe arm, pivot at the origin, reaching along +X, striking -Y.
## `head` is { l, h, w } from shape.gd.
static func arm_parts(reach: float, head: Dictionary, style: String) -> Array:
	var tube := cyl(0.02, 0.026, reach, 12).rotate_z(PI / 2.0).translate(reach / 2.0, 0, 0)
	# Twin side plates at the root, where the arm takes its load.
	var cheeks := Geo.new()
	for s in [-1.0, 1.0]:
		cheeks.append(extrude(_poly([[-0.04, -0.035], [reach * 0.35, -0.02], [reach * 0.35, 0.02], [-0.04, 0.04]]), 0.01, 0.002).translate(0, 0, s * 0.032))
	var out := [
		_p(tube, "steel"),
		_p(cheeks, "trim"),
		_p(cyl(0.045, 0.045, 0.1, 18).rotate_x(PI / 2.0), "hub"),
	]
	var l: float = head.l
	var h: float = head.h
	var w: float = head.w
	if style == "saw":
		for part in disc_rotor(l * 1.4, 0.006, 36, true):
			part.geo.rotate_x(PI / 2.0).translate(reach, 0, 0)
			out.append(part)
		# A guard over the top of the blade.
		var guard := Geo.cylinder(l * 1.5, l * 1.5, 0.04, seg(24), true, -PI * 0.05, PI * 0.6).rotate_x(PI / 2.0).rotate_z(-PI / 2.0).translate(reach, 0, 0)
		out.append(_p(guard, "trim"))
	elif style == "spike":
		out.append(_p(box(l * 0.5, h * 0.4, minf(w, 0.08)).translate(reach, 0, 0), "dark"))
		out.append(_p(Geo.cone(h * 0.32, h * 1.3, 16).rotate_z(PI).translate(reach, -h * 0.85, 0), "steel"))
	elif style == "sledge" or style == "hammer":
		var block := extrude(_poly([[-l / 2.0, -h * 0.6], [l / 2.0, -h * 0.6], [l / 2.0, h * 0.4], [-l / 2.0, h * 0.4]]), w, 0.012).translate(reach, 0, 0)
		out.append(_p(block, "dark"))
		out.append(_p(box(l * 0.92, 0.02, w * 0.92).translate(reach, -h * 0.6 - 0.008, 0), "steel"))
		if detailed and not mobile:
			# Bands shrunk on round it, the socket the arm goes into, and the
			# studs of its striking face.
			var bands := Geo.new()
			for s in [-1.0, 1.0]:
				bands.append(box(l * 1.03, h * 1.02, w * 0.1).translate(reach, -h * 0.1, s * w * 0.36))
			out.append(_p(bands, "steel"))
			out.append(_p(cyl(0.034, 0.034, minf(w, 0.09) + 0.01, 14).rotate_z(PI / 2.0).translate(reach - l * 0.5, 0, 0), "hub"))
			var studs := Geo.new()
			for sx in [-1.0, 0.0, 1.0]:
				for sz in [-1.0, 0.0, 1.0]:
					studs.append(Geo.cone(minf(l, w) * 0.09, 0.016, 4).rotate_z(PI).translate(reach + sx * l * 0.3, -h * 0.6 - 0.024, sz * w * 0.3))
			out.append(_p(studs, "steel"))
	else:
		# Axe: a pole on top, a broad blade fanning down to its edge.
		var blade := extrude(_poly([
			[-l * 0.3, h * 0.25], [l * 0.3, h * 0.25], [l * 0.55, -h * 0.7], [l * 0.3, -h * 0.95], [0, -h * 1.02], [-l * 0.3, -h * 0.95], [-l * 0.55, -h * 0.7],
		]), minf(0.035, w * 0.4), 0.004).translate(reach, 0, 0)
		out.append(_p(blade, "steel"))
		out.append(_p(box(l * 0.5, h * 0.35, minf(w, 0.09)).translate(reach, h * 0.2, 0), "dark"))
	return out

# ---------------------------------------------------------------- plates, forks, jaws

## A flipper plate: knife-edged at the front, hinge barrel at the back.
static func flipper_plate(l: float, w: float) -> Array:
	var plate := extrude(_poly([[-l / 2.0, 0.022], [l / 2.0 - 0.035, 0.022], [l / 2.0, 0.002], [-l / 2.0, 0]]), w, 0.002)
	var rails := Geo.new()
	for s in [-1.0, 1.0]:
		rails.append(box(l * 0.8, 0.03, 0.014).translate(-l * 0.08, 0.034, s * w * 0.46))
	return [
		_p(plate, "steel"),
		_p(rails, "dark"),
		_p(cyl(0.018, 0.018, w * 0.9, 12).rotate_x(PI / 2.0).translate(-l / 2.0, 0.018, 0), "hub"),
	]

## One lifter fork, pointing +X, lying on y = 0.
static func fork_geometry(l: float, fw: float) -> Geo:
	return extrude(_poly([[-l / 2.0, -fw / 2.0], [l / 2.0 - fw * 0.8, -fw / 2.0], [l / 2.0, -fw * 0.1], [l / 2.0, fw * 0.1], [l / 2.0 - fw * 0.8, fw / 2.0], [-l / 2.0, fw / 2.0]]), 0.026, 0.003).rotate_x(-PI / 2.0)

## A crusher beak, hinged at the origin, reaching `reach` and dropping `drop`.
static func beak_geometry(reach: float, drop: float, width: float) -> Geo:
	var pts := PackedVector2Array([Vector2(-0.04, 0.035)])
	pts.append_array(Geo.quad_curve(Vector2(-0.04, 0.035), Vector2(reach * 0.75, 0.09), Vector2(reach, -drop * 0.35), seg(16)))
	pts.append(Vector2(reach * 0.97, -drop))
	pts.append_array(Geo.quad_curve(Vector2(reach * 0.97, -drop), Vector2(reach * 0.82, -drop * 0.45), Vector2(reach * 0.55, -0.045), seg(16)))
	pts.append(Vector2(-0.04, -0.04))
	return extrude(pts, width, 0.006)

## A lid: a painted panel with a hinge barrel at its back edge (x = 0).
static func lid_parts(length: float, w: float) -> Array:
	var lid := extrude(_poly([[0, 0], [length - 0.02, 0], [length, -0.01], [length, 0.008], [0, 0.016]]), w, 0.002)
	return [_p(lid, "accent"), _p(cyl(0.015, 0.015, w * 0.96, 12).rotate_x(PI / 2.0), "hub")]
