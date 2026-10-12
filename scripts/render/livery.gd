## livery.gd - a robot's paint job, painted into one atlas at build time.
##
## The body is drawn from convex hull pieces (logic/shape.gd). Those pieces
## get UVs by projection: faces looking up read the TOP of this atlas, faces
## looking sideways one of the SIDES, the nose and tail the ENDS. Everything
## here is painted in body metres, so a stripe 4 cm wide is 4 cm wide on
## every bot, and the same pattern fits a wedge or a box.
##
## What a robot file can say (all optional):
##   "livery": { "primary": "#16171a", "secondary": "#b3121b", "accent": "#c9ced6",
##               "pattern": "flames", "decal": "TOMBSTONE", "text": "#ffffff",
##               "nameSize": 0.8 }
##
## Atlas layout (1024 x 1024, top-left origin):
##   rows    0-511   TOP     tail at the left, nose at the right, the robot's
##                           right (-Z) at the top - the view from above
##   rows  512-703   LEFT    the +Z side, nose at the right
##   rows  704-895   RIGHT   the -Z side, nose at the left
##   rows  896-1023  NOSE (cols 0-511) and TAIL (cols 512-1023)
##
## paint() only RECORDS the drawing (render/canvas_rec.gd): pure, seeded, and
## the same picture the browser game painted. render/paint_shop.gd turns the
## recordings into textures.
class_name Livery

const SIZE := 1024.0
const ATLAS := {
	"top": Rect2(0, 0, 1024, 512),
	"left": Rect2(0, 512, 1024, 192),
	"right": Rect2(0, 704, 1024, 192),
	"nose": Rect2(0, 896, 512, 128),
	"tail": Rect2(512, 896, 512, 128),
}
const PATTERNS := [
	"plain", "stripes", "band", "flames", "split", "hazard", "checker", "camo",
	"teeth", "chevron", "bolt", "spots", "scales", "tiger", "pixels", "bricks",
]
const SIDES := ["left", "right"]

const CELL := 0.006          # metres per grid cell (name placement)
const MARGIN := 0.016        # clear of every edge, most of the way off the rounds
const LINE := 1.08           # line height, in letter sizes
const NAME_MIN := 0.014      # smaller than this does not read: leave it off

## Atlas UV for a point on a face with normal n, within body bounds b
## ({ min, max } Vector3s).
static func atlas_uv(p: Vector3, n: Vector3, b: Dictionary) -> Vector2:
	var mn: Vector3 = b.min
	var mx: Vector3 = b.max
	var sx := mx.x - mn.x
	var sy := mx.y - mn.y
	var sz := mx.z - mn.z
	if sx == 0.0: sx = 1.0
	if sy == 0.0: sy = 1.0
	if sz == 0.0: sz = 1.0
	var R: Rect2
	var u: float
	var v: float
	if absf(n.y) >= 0.5:
		R = ATLAS.top; u = (p.x - mn.x) / sx; v = (p.z - mn.z) / sz
	elif absf(n.z) >= absf(n.x):
		v = (mx.y - p.y) / sy
		if n.z > 0: R = ATLAS.left; u = (p.x - mn.x) / sx
		else: R = ATLAS.right; u = (mx.x - p.x) / sx
	else:
		v = (mx.y - p.y) / sy
		if n.x > 0: R = ATLAS.nose; u = (mx.z - p.z) / sz
		else: R = ATLAS.tail; u = (p.z - mn.z) / sz
	u = clampf(u, 0.004, 0.996)
	v = clampf(v, 0.004, 0.996)
	return Vector2((R.position.x + u * R.size.x) / SIZE, (R.position.y + v * R.size.y) / SIZE)

## The colour the name is painted in: the robot's own, or one picked to stand out.
static func name_colour(livery) -> String:
	var lv: Dictionary = livery if livery is Dictionary else {}
	if J.truthy(lv.get("text")): return lv.text
	return _pick_text({"primary": J.g(lv, "primary", "#b8babf"), "secondary": J.g(lv, "secondary", "#202227"), "accent": J.g(lv, "accent", "#f0c419")})

# The painters' own little generator (not the game's Rng: a different recipe,
# kept so the paint comes out as it always has).
class Lcg:
	var s := 1
	func _init(seed_v: int) -> void:
		s = seed_v if seed_v != 0 else 1
	func next() -> float:
		s = (Rng.imul(s, 1664525) + 1013904223) & 0xFFFFFFFF
		return s / 4294967296.0

# One panel of the atlas, with the transform from body metres to its pixels:
# (a, b) is (distance from the tail, height from the bottom) on a side,
# (distance from the tail, distance from the right edge) on top, (across,
# height) on an end.
class Region:
	var R: Rect2
	var spanA := 1.0
	var spanB := 1.0
	var mirror := false
	var kx := 1.0
	var ky := 1.0
	var k := 1.0
	func _init(rect: Rect2, a: float, b: float, m: bool) -> void:
		R = rect
		spanA = a
		spanB = b
		mirror = m
		kx = R.size.x / a
		ky = R.size.y / b
		k = minf(kx, ky)
	## Canvas transform: (a, b) in metres -> pixels, on a canvas `s` times
	## the atlas size (the relief maps can be smaller than the paint).
	func use(g: CanvasRec, s := 1.0) -> void:
		if mirror: g.set_transform(-kx * s, 0, 0, -ky * s, R.end.x * s, R.end.y * s)
		else: g.set_transform(kx * s, 0, 0, -ky * s, R.position.x * s, R.end.y * s)
		g.save()
		g.begin_path()
		g.rect(0, 0, spanA, spanB)
		g.clip()
	func done(g: CanvasRec) -> void:
		g.restore()
		g.reset_transform()
	func px(a: float, b: float) -> Vector2:
		return Vector2(R.end.x - a * kx if mirror else R.position.x + a * kx, R.end.y - b * ky)

# What the painters share.
class Ctx:
	var g: CanvasRec             # the paint layer
	var S: Vector3               # the body's size
	var C: Dictionary            # primary, secondary, accent, text
	var rng: Lcg
	var regions := {}
	var opts: Dictionary
	var template = null
	var surface := false
	var L: Dictionary            # the layer being painted: { g, kind, s }
	var plan = null
	var name_spots = null
	var scuffs = null
	var sight := {}

## Record the paint job.
##   opts { name, id, livery, template, bounds: { min, max }, relief: bool or
##          the relief maps' size as a share of the atlas, faces, wheels, blockers }
## `faces` ([{ n, ring: [Vector3], paint, piece }] - every flat face of the
## body, whether it wears this paint, and which piece it belongs to), `wheels`
## ([{ x, y, z, r, w }]) and `blockers` (PackedVector3Array triangle lists -
## the weapon) let the name find a flat panel it fits on, in plain view.
##
## Returns { pattern, color: CanvasRec, height: CanvasRec, finish: CanvasRec }
## (the last two null without `relief`): the paint, a bump map (grey 128 is
## the paint, darker is cut in, lighter stands proud) and a finish map (green
## = roughness, blue = metalness).
static func paint(opts: Dictionary) -> Dictionary:
	var g := CanvasRec.new(SIZE, SIZE)
	var lv: Dictionary = J.g(opts, "livery", {})
	var b: Dictionary = opts.bounds
	var ctx := Ctx.new()
	ctx.g = g
	ctx.S = b.max - b.min
	ctx.C = {
		"primary": J.g(lv, "primary", "#b8babf"),
		"secondary": J.g(lv, "secondary", "#202227"),
		"accent": J.g(lv, "accent", "#f0c419"),
	}
	ctx.C.text = lv.text if J.truthy(lv.get("text")) else _pick_text(ctx.C)
	var id: String = str(J.g(opts, "id", ""))
	var pattern: String = lv.pattern if J.truthy(lv.get("pattern")) else PATTERNS[1 + (Rng.hash_seed(id) % (PATTERNS.size() - 1))]
	ctx.rng = Lcg.new(Rng.hash_seed(id if id != "" else "x"))
	var S := ctx.S
	ctx.regions = {
		"top": Region.new(ATLAS.top, S.x, S.z, false),
		"left": Region.new(ATLAS.left, S.x, S.y, false),
		"right": Region.new(ATLAS.right, S.x, S.y, true),
		"nose": Region.new(ATLAS.nose, S.z, S.y, true),
		"tail": Region.new(ATLAS.tail, S.z, S.y, false),
	}

	# Base coat everywhere, with a little tonal shading so big panels are not
	# one flat value: darker low on the sides, lighter on top.
	g.reset_transform()
	g.fill_style = ctx.C.primary
	g.fill_rect(0, 0, SIZE, SIZE)
	for k in ["left", "right", "nose", "tail"]:
		var R: Rect2 = ATLAS[k]
		var grd := g.create_linear_gradient(0, R.position.y, 0, R.end.y)
		CanvasRec.add_stop(grd, 0.0, "rgba(255,255,255,0.06)")
		CanvasRec.add_stop(grd, 0.6, "rgba(0,0,0,0)")
		CanvasRec.add_stop(grd, 1.0, "rgba(0,0,0,0.28)")
		g.fill_style = grd
		g.fill_rect(R.position.x, R.position.y, R.size.x, R.size.y)
	# The tail is the back of the bot: secondary, like a rear plate.
	_fill_region(g, ATLAS.tail, ctx.C.secondary, 0.85)

	ctx.opts = opts
	ctx.template = opts.get("template")
	ctx.surface = J.truthy(opts.get("relief"))
	ctx.L = {"g": g, "kind": "color", "s": 1.0}
	_paint_pattern(pattern, ctx)

	# The surface detail rolls its own dice, so turning it on or off leaves
	# the rest of the paint job exactly as it was.
	if ctx.surface: ctx.plan = _surface_plan(ctx)
	var decal: String = str(lv.decal) if lv.get("decal") != null else str(J.g(opts, "name", "")).to_upper()
	# The name picks its panel first; the hatch then keeps out of its way.
	if decal != "": ctx.name_spots = _name_spots(ctx, decal, g)
	_panel_work(ctx, ctx.L)
	if ctx.surface: _fittings(ctx, ctx.L)
	_name_decals(ctx, decal, ctx.L)
	_wear(ctx, ctx.L)
	var out := {"pattern": pattern, "color": g, "height": null, "finish": null}
	if ctx.surface:
		_chips(ctx, ctx.L)
		var rs: float = opts.relief if (typeof(opts.relief) == TYPE_FLOAT or typeof(opts.relief) == TYPE_INT) else 1.0
		for kind in ["height", "finish"]:
			var cg := CanvasRec.new(SIZE * rs, SIZE * rs)
			var L := {"g": cg, "kind": kind, "s": rs}
			# Paint: rough 0.55, metal 0.1.
			cg.fill_style = "rgb(128,128,128)" if kind == "height" else "rgb(0,140,26)"
			cg.fill_rect(0, 0, SIZE * rs, SIZE * rs)
			if kind == "finish":
				cg.set_transform(rs, 0, 0, rs, 0, 0)
				for sh in ctx.plan.sheen: _fill_pts(cg, sh.pts, "rgba(0,122,26,0.3)" if sh.glossy else "rgba(0,160,26,0.3)")
				cg.reset_transform()
			_panel_work(ctx, L)
			_fittings(ctx, L)
			if kind == "finish": _name_decals(ctx, decal, L)
			_wear(ctx, L)
			_chips(ctx, L)
			cg.reset_transform()
			out[kind] = cg
	g.reset_transform()
	return out

# ---------------------------------------------------------------- regions

static func _fill_region(g: CanvasRec, R: Rect2, color, alpha := 1.0) -> void:
	g.reset_transform()
	g.global_alpha = alpha
	g.fill_style = color
	g.fill_rect(R.position.x, R.position.y, R.size.x, R.size.y)
	g.global_alpha = 1.0

## Run fn(A, B, name, region) inside each named region's transform, on layer L.
static func _in_regions(ctx: Ctx, names: Array, fn: Callable, L = null) -> void:
	if L == null: L = ctx.L
	for n in names:
		var r: Region = ctx.regions[n]
		r.use(L.g, L.s)
		fn.call(r.spanA, r.spanB, n, r)
		r.done(L.g)

static func _poly(g: CanvasRec, pts: Array) -> void:
	g.begin_path()
	g.move_to(pts[0][0], pts[0][1])
	for i in range(1, pts.size()): g.line_to(pts[i][0], pts[i][1])
	g.close_path()

# ---------------------------------------------------------------- patterns

static func _paint_pattern(pattern: String, ctx: Ctx) -> void:
	var g := ctx.g
	var C := ctx.C
	var rng := ctx.rng
	var all := ["top", "left", "right"]
	match pattern:
		"stripes":
			# Twin racing stripes nose to tail, carried over the ends.
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				for s in [-1.0, 1.0]: g.fill_rect(0, B / 2 + s * 0.035 - 0.025, A, 0.05)
				g.fill_style = C.secondary
				for s in [-1.0, 1.0]:
					g.fill_rect(0, B / 2 + s * 0.035 - 0.031, A, 0.006)
					g.fill_rect(0, B / 2 + s * 0.035 + 0.025, A, 0.006))
			_in_regions(ctx, ["nose", "tail"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				for s in [-1.0, 1.0]: g.fill_rect(A / 2 + s * 0.035 - 0.025, 0, 0.05, B))
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(0, 0, A, B * 0.22)
				g.fill_style = C.accent
				g.fill_rect(0, B * 0.22, A, 0.008))
		"band":
			# One broad band across the back half, wrapping the sides.
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(A * 0.18, 0, A * 0.22, B)
				g.fill_style = C.accent
				g.fill_rect(A * 0.4, 0, 0.012, B)
				g.fill_rect(A * 0.18 - 0.012, 0, 0.012, B))
		"flames":
			# Flames licking back from the nose.
			var tongues := func(A: float, B: float, count: int):
				for pass_i in 2:
					g.fill_style = C.accent if pass_i == 1 else C.secondary
					var shrink := 0.55 if pass_i == 1 else 1.0
					for i in count:
						var y := B * (0.12 + 0.76 * (i + 0.5) / count) + (rng.next() - 0.5) * B * 0.06
						var ln := A * (0.35 + rng.next() * 0.3) * shrink
						var w := (B / count) * (0.9 + rng.next() * 0.4) * shrink
						g.begin_path()
						g.move_to(A + 0.05, y - w * 0.5)
						g.bezier_curve_to(A - ln * 0.3, y - w * 0.7, A - ln * 0.6, y + w * 0.3, A - ln, y + w * 0.1)
						g.bezier_curve_to(A - ln * 0.55, y - w * 0.05, A - ln * 0.3, y + w * 0.6, A + 0.05, y + w * 0.5)
						g.close_path()
						g.fill()
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region): tongues.call(A, B, 5))
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region): tongues.call(A, B, 3))
			_in_regions(ctx, ["nose"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(0, 0, A, B))
		"split":
			# Front third in the secondary colour, cut on a rake.
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				_poly(g, [[A * 0.62, 0], [A * 0.72, B], [A + 1, B], [A + 1, 0]])
				g.fill()
				g.stroke_style = C.accent
				g.line_width = 0.01
				g.begin_path()
				g.move_to(A * 0.62 - 0.012, 0)
				g.line_to(A * 0.72 - 0.012, B)
				g.stroke())
			_in_regions(ctx, ["nose"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(0, 0, A, B))
		"hazard":
			# Hazard stripes across the nose.
			var stripes := func(A: float, B: float, x0: float, x1: float):
				g.save()
				g.begin_path()
				g.rect(x0, 0, x1 - x0, B)
				g.clip()
				g.fill_style = C.accent
				g.fill_rect(x0, 0, x1 - x0, B)
				g.fill_style = "#121214"
				var s := -B * 2
				while s < A + B:
					_poly(g, [[s, 0], [s + 0.04, 0], [s + 0.04 + B, B], [s + B, B]])
					g.fill()
					s += 0.08
				g.restore()
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region): stripes.call(A, B, A * 0.78, A + 0.01))
			_in_regions(ctx, ["nose"], func(A: float, B: float, _n: String, _r: Region): stripes.call(A, B, -0.01, A + 0.01))
			_in_regions(ctx, ["tail"], func(A: float, B: float, _n: String, _r: Region): stripes.call(A, B, -0.01, A + 0.01))
		"checker":
			# A chequered-flag field on the top rear.
			var sq := 0.05
			var field := func(B: float, x0: float, x1: float):
				var x := x0
				var i := 0
				while x < x1:
					var y := 0.0
					var j := 0
					while y < B:
						g.fill_style = "#f2f2f2" if (i + j) % 2 == 1 else "#111114"
						g.fill_rect(x, y, sq, sq)
						y += sq
						j += 1
					x += sq
					i += 1
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region): field.call(B, 0.0, A * 0.3))
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
				field.call(B, 0.0, A * 0.18)
				g.fill_style = C.accent
				g.fill_rect(A * 0.18, 0, 0.015, B))
			_in_regions(ctx, ["tail"], func(A: float, B: float, _n: String, _r: Region): field.call(B, 0.0, A))
		"camo":
			_in_regions(ctx, ["top", "left", "right", "nose", "tail"], func(A: float, B: float, _n: String, _r: Region):
				for col in [C.secondary, C.accent]:
					g.fill_style = col
					for i in int(ceil(A * B * 60)):
						var bx := rng.next() * A
						var by := rng.next() * B
						var br := 0.03 + rng.next() * 0.07
						_blob(g, bx, by, br, rng))
		"teeth":
			# A shark mouth on the nose.
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
				var x0: float = A * 0.6
				g.fill_style = "#1a0a0c"
				g.begin_path()
				g.move_to(A + 0.01, B * 0.62)
				g.quadratic_curve_to(x0 + (A - x0) * 0.3, B * 0.6, x0, B * 0.42)
				g.quadratic_curve_to(x0 + (A - x0) * 0.35, B * 0.12, A + 0.01, B * 0.14)
				g.close_path()
				g.fill()
				g.fill_style = "#f4f4ef"
				var n := 7
				for i in n:
					var x: float = x0 + ((A - x0) * (i + 0.5)) / n
					var w: float = (A - x0) / n * 0.48
					_poly(g, [[x - w, B * 0.59], [x + w, B * 0.59], [x, B * 0.44]])
					g.fill()
					_poly(g, [[x - w, B * 0.16], [x + w, B * 0.16], [x, B * 0.3]])
					g.fill()
				# An eye.
				g.fill_style = "#f4f4ef"
				g.begin_path()
				g.arc(x0 - 0.02, B * 0.72, minf(B * 0.11, 0.03), 0, 7)
				g.fill()
				g.fill_style = "#111"
				g.begin_path()
				g.arc(x0 - 0.015, B * 0.72, minf(B * 0.06, 0.016), 0, 7)
				g.fill())
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(A * 0.6, 0, A * 0.4, B * 0.12)
				g.fill_rect(A * 0.6, B * 0.88, A * 0.4, B * 0.12))
		"chevron":
			# Arrowheads down the spine, pointing forward.
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				var w := minf(B * 0.5, 0.22)
				var x: float = A * 0.12
				while x < A * 0.9:
					_poly(g, [[x, B / 2 + w / 2], [x + 0.06, B / 2], [x, B / 2 - w / 2], [x + 0.035, B / 2 - w / 2], [x + 0.095, B / 2], [x + 0.035, B / 2 + w / 2]])
					g.fill()
					x += 0.1)
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.secondary
				g.fill_rect(0, 0, A, B * 0.25))
		"bolt":
			# A lightning bolt down each side.
			_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				g.stroke_style = C.secondary
				g.line_width = 0.008
				_poly(g, [[A * 0.06, B * 0.55], [A * 0.45, B * 0.8], [A * 0.42, B * 0.6], [A * 0.95, B * 0.75], [A * 0.55, B * 0.35], [A * 0.58, B * 0.52]])
				g.fill()
				g.stroke())
			_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				_poly(g, [[A * 0.1, B * 0.45], [A * 0.5, B * 0.62], [A * 0.48, B * 0.52], [A * 0.92, B * 0.6], [A * 0.52, B * 0.36], [A * 0.54, B * 0.46]])
				g.fill())
		"spots":
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region):
				g.fill_style = C.accent
				for i in int(ceil(A * B * 30)) + 2:
					var sx := rng.next() * A
					var sy := rng.next() * B
					var sr := 0.025 + rng.next() * 0.035
					g.begin_path()
					g.arc(sx, sy, sr, 0, 7)
					g.fill())
		"scales":
			# Overlapping scales, for the dragons and snakes.
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region):
				g.stroke_style = C.secondary
				g.line_width = 0.006
				var s := 0.06
				var row := 0
				var y := 0.0
				while y < B + s:
					var x := (row % 2) * s * 0.5
					while x < A + s:
						g.begin_path()
						g.arc(x, y, s * 0.5, PI, 2 * PI)
						g.stroke()
						x += s
					y += s * 0.5
					row += 1)
		"pixels":
			# Glitchy blocks, thickest at the tail and breaking up towards the nose.
			var sq := 0.03
			_in_regions(ctx, all, func(A: float, B: float, _n: String, _r: Region):
				var x := 0.0
				while x < A:
					var y := 0.0
					while y < B:
						var p: float = 0.55 * (1 - x / A)
						if rng.next() < p:
							g.fill_style = C.secondary if rng.next() < 0.7 else C.accent
							g.fill_rect(x, y, sq * 0.92, sq * 0.92)
						y += sq
					x += sq)
		"bricks":
			# Running-bond brickwork with mortar lines.
			_in_regions(ctx, ["top", "left", "right", "nose", "tail"], func(A: float, B: float, _n: String, _r: Region):
				var bw := 0.09
				var bh := 0.04
				var row := 0
				var y := 0.0
				while y < B:
					var x := (row % 2) * -bw / 2
					while x < A:
						g.fill_style = _shade(C.primary, (rng.next() - 0.5) * 0.25)
						g.fill_rect(x, y, bw, bh)
						x += bw
					y += bh
					row += 1
				g.stroke_style = C.secondary
				g.line_width = 0.006
				row = 0
				y = 0.0
				while y < B:
					g.begin_path()
					g.move_to(0, y)
					g.line_to(A, y)
					g.stroke()
					var x := (row % 2) * -bw / 2
					while x < A:
						g.begin_path()
						g.move_to(x, y)
						g.line_to(x, y + bh)
						g.stroke()
						x += bw
					y += bh
					row += 1)
		"tiger":
			# Tiger stripes raking back from the spine.
			_in_regions(ctx, all, func(A: float, B: float, name: String, _r: Region):
				g.fill_style = C.secondary
				var is_top: bool = name == "top"
				var x := 0.06
				while x < A:
					var w := 0.018 + rng.next() * 0.02
					var f0: float = B
					var f1: float = 0.0 if is_top else B * 0.1
					var low: float = f1 + (B * 0.55 if is_top else B * 0.2)
					g.begin_path()
					g.move_to(x, f0 + 0.01)
					g.quadratic_curve_to(x - 0.06, B * 0.6, x - 0.02, low)
					g.line_to(x + w * 0.3, low)
					g.quadratic_curve_to(x - 0.03 + w, B * 0.6, x + w, f0 + 0.01)
					g.close_path()
					g.fill()
					if is_top:
						g.begin_path()
						g.move_to(x, -0.01)
						g.quadratic_curve_to(x - 0.06, B * 0.4, x - 0.02, B * 0.45)
						g.line_to(x + w * 0.3, B * 0.45)
						g.quadratic_curve_to(x - 0.03 + w, B * 0.4, x + w, -0.01)
						g.close_path()
						g.fill()
					x += 0.09 + rng.next() * 0.05)

# ---------------------------------------------------------------- panel work

static func _along(a0: float, a1: float, b: float, step: float) -> Array:
	var n := maxi(2, J.rndi((a1 - a0) / step))
	var out := []
	for i in range(n + 1): out.append([a0 + ((a1 - a0) * i) / n, b])
	return out

## Seams and bolt heads: what makes a painted box read as a built machine.
static func _panel_work(ctx: Ctx, L: Dictionary) -> void:
	var S := ctx.S
	var inset := minf(0.022, S.z * 0.05)
	var g: CanvasRec = L.g
	var bolts := func(pts: Array):
		for p in pts: _bolt(ctx, L, p[0], p[1])
	var line := func(a0: float, b0: float, a1: float, b1: float, w := 0.0035, col := "rgba(8,8,10,0.45)"):
		_groove(L, w, col, func(gg: CanvasRec):
			gg.move_to(a0, b0)
			gg.line_to(a1, b1))

	# Top: a plate border, a seam a third of the way along, bolts round both.
	_in_regions(ctx, ["top"], func(A: float, B: float, _n: String, _r: Region):
		var d := inset
		_groove(L, 0.004, "rgba(8,8,10,0.4)", func(gg: CanvasRec): gg.rect(d * 0.45, d * 0.45, A - d * 0.9, B - d * 0.9))
		line.call(A * 0.34, d * 0.45, A * 0.34, B - d * 0.45)
		if L.kind == "color":
			# a light catch on the plate edge
			g.stroke_style = "rgba(255,255,255,0.08)"
			g.line_width = 0.003
			g.stroke_rect(d * 0.45 + 0.003, d * 0.45 + 0.003, A - d * 0.9 - 0.006, B - d * 0.9 - 0.006)
		var pts := _along(d, A - d, d, 0.075)
		pts.append_array(_along(d, A - d, B - d, 0.075))
		var down := _along(d, B - d, d, 0.075)
		for p in down: pts.append([d, p[0]])
		for p in down: pts.append([A - d, p[0]])
		for p in down: pts.append([A * 0.34 + d * 0.6, p[0]])
		bolts.call(pts), L)
	# Sides: a seam above the skid line, bolts along the top edge.
	_in_regions(ctx, SIDES, func(A: float, B: float, _n: String, _r: Region):
		line.call(0.0, B * 0.16, A, B * 0.16, 0.003, "rgba(8,8,10,0.35)")
		line.call(A * 0.34, 0.0, A * 0.34, B, 0.003, "rgba(8,8,10,0.35)")
		bolts.call(_along(0.02, A - 0.02, B - minf(0.016, B * 0.12), 0.08))
		bolts.call(_along(0.02, A - 0.02, minf(0.012, B * 0.08), 0.08)), L)
	_in_regions(ctx, ["nose", "tail"], func(A: float, B: float, _n: String, _r: Region):
		bolts.call(_along(0.02, A - 0.02, B - minf(0.014, B * 0.12), 0.08)), L)

## A cut line (a seam, a plate edge) traced by path(g), on any layer.
static func _groove(L: Dictionary, w: float, col: String, path: Callable) -> void:
	var g: CanvasRec = L.g
	g.begin_path()
	path.call(g)
	if L.kind == "color":
		g.stroke_style = col
		g.line_width = w
		g.stroke()
	elif L.kind == "height":
		# a soft shoulder, then the cut itself
		g.stroke_style = "rgb(92,92,92)"
		g.line_width = w * 2.2
		g.stroke()
		g.stroke_style = "rgb(34,34,34)"
		g.line_width = w
		g.stroke()
	else:
		g.stroke_style = "rgb(0,205,18)"     # dirt packed in: rough, not metal
		g.line_width = w * 1.6
		g.stroke()

static func _disc(g: CanvasRec, x: float, y: float, rad: float, fill) -> void:
	g.fill_style = fill
	g.begin_path()
	g.arc(x, y, rad, 0, 7)
	g.fill()

## A bolt head: a washer, a domed head, and (with surface detail) a hex socket.
static func _bolt(ctx: Ctx, L: Dictionary, a: float, b: float, size := 1.0) -> void:
	var g: CanvasRec = L.g
	var R := 0.0062 * size
	var r := 0.0042 * size
	if L.kind == "color":
		_disc(g, a, b, R, "rgba(10,10,12,0.55)")
		_disc(g, a, b, r, "rgba(190,196,205,0.9)")
		_disc(g, a + 0.0012 * size, b + 0.0014 * size, 0.0015 * size, "rgba(255,255,255,0.7)")
		if ctx.surface: _hexagon(g, a, b, 0.0016 * size, "rgba(16,16,20,0.8)")
	elif L.kind == "height":
		_disc(g, a, b, R, "rgb(150,150,150)")
		var grd := g.create_radial_gradient(a, b, 0, a, b, r)
		CanvasRec.add_stop(grd, 0.0, "rgb(245,245,245)")
		CanvasRec.add_stop(grd, 1.0, "rgb(178,178,178)")
		_disc(g, a, b, r, grd)
		_hexagon(g, a, b, 0.0016 * size, "rgb(84,84,84)")
	else:
		_disc(g, a, b, R, "rgb(0,130,95)")
		_disc(g, a, b, r, "rgb(0,88,150)")     # bare zinc-plated steel

static func _hexagon(g: CanvasRec, x: float, y: float, r: float, fill) -> void:
	g.fill_style = fill
	g.begin_path()
	for i in 6:
		var a := (i / 6.0) * TAU
		if i > 0: g.line_to(x + cos(a) * r, y + sin(a) * r)
		else: g.move_to(x + cos(a) * r, y + sin(a) * r)
	g.close_path()
	g.fill()

# ---------------------------------------------------------------- surface detail

## Where the surface detail goes, decided once so every layer draws the same
## thing: chipped paint along the body's edges (worst at the nose and the
## skids) and a little unevenness in the paint's sheen.
static func _surface_plan(ctx: Ctx) -> Dictionary:
	var id: String = str(J.g(ctx.opts, "id", ""))
	var rng := Lcg.new(Rng.hash_seed((id if id != "" else "x") + ":surface"))
	var chips := {}
	for name in ["top", "left", "right", "nose", "tail"]:
		var reg: Region = ctx.regions[name]
		var A := reg.spanA
		var B := reg.spanB
		# The region's edges as [a0, b0, a1, b1, odds of a chip every 12 mm].
		var edges: Array
		if name == "top": edges = [[0, 0, A, 0, 0.22], [0, B, A, B, 0.22], [0, 0, 0, B, 0.22], [A, 0, A, B, 0.4]]
		elif name == "left" or name == "right": edges = [[0, B, A, B, 0.25], [0, 0, A, 0, 0.35], [0, 0, 0, B, 0.3], [A, 0, A, B, 0.45]]
		else:
			var p := 0.4 if name == "nose" else 0.25
			edges = [[0, B, A, B, p], [0, 0, 0, B, p], [A, 0, A, B, p], [0, 0, A, 0, p]]
		var list := []
		for e in edges:
			var a0: float = e[0]
			var b0: float = e[1]
			var a1: float = e[2]
			var b1: float = e[3]
			var p: float = e[4]
			var ln := Vector2(a1 - a0, b1 - b0).length()
			# inward from this edge, towards the middle of the region
			var ia := (1.0 if a0 == 0.0 else -1.0) if a0 == a1 else 0.0
			var ib := (1.0 if b0 == 0.0 else -1.0) if b0 == b1 else 0.0
			var t := 0.006
			while t < ln:
				if rng.next() < p:
					var f := t / ln
					var inset := rng.next() * 0.004
					var x := a0 + (a1 - a0) * f + ia * inset
					var y := b0 + (b1 - b0) * f + ib * inset
					var rr := 0.0025 + pow(rng.next(), 2.0) * 0.008
					list.append(_blob_pts(x, y, rr, rng))
				t += 0.012
		chips[name] = list
	# Big soft patches of slightly glossier or duller paint, in atlas pixels.
	var sheen := []
	for i in 22:
		var x := rng.next() * SIZE
		var y := rng.next() * SIZE
		var rr := 40 + rng.next() * 90
		var pts := _blob_pts(x, y, rr, rng)
		sheen.append({"pts": pts, "glossy": rng.next() < 0.5})
	return {"chips": chips, "sheen": sheen}

static func _rrect(g: CanvasRec, x: float, y: float, w: float, h: float, r: float) -> void:
	g.move_to(x + r, y)
	g.arc_to(x + w, y, x + w, y + h, r)
	g.arc_to(x + w, y + h, x, y + h, r)
	g.arc_to(x, y + h, x, y, r)
	g.arc_to(x, y, x + w, y, r)
	g.close_path()

static func _fill_rrect(g: CanvasRec, x: float, y: float, w: float, h: float, r: float, col) -> void:
	g.begin_path()
	_rrect(g, x, y, w, h, r)
	g.fill_style = col
	g.fill()

## The hatch and the cooling slots.
static func _fittings(ctx: Ctx, L: Dictionary) -> void:
	var g: CanvasRec = L.g
	var kind: String = L.kind
	# Access hatch on top, in the bay behind the cross seam (the name decal
	# sits in front of it).
	_in_regions(ctx, ["top"], func(_A: float, B: float, _n: String, _r: Region):
		var hatch = _hatch_rect(ctx)
		if hatch == null: return
		var x: float = hatch.position.x
		var y: float = hatch.position.y
		var w: float = hatch.size.x
		var h: float = hatch.size.y
		_fill_rrect(g, x, y, w, h, 0.008, {"color": "rgba(0,0,0,0.07)", "height": "rgb(121,121,121)", "finish": "rgb(0,150,24)"}[kind])
		_groove(L, 0.003, "rgba(8,8,10,0.55)", func(gg: CanvasRec): _rrect(gg, x, y, w, h, 0.008))
		for bp in [[x + 0.009, y + 0.009], [x + w - 0.009, y + 0.009], [x + 0.009, y + h - 0.009], [x + w - 0.009, y + h - 0.009]]:
			_bolt(ctx, L, bp[0], bp[1], 0.7)
		# a latch slot at the tail end
		_fill_rrect(g, x + 0.012, B / 2 - 0.009, 0.006, 0.018, 0.003, {"color": "rgba(10,10,12,0.85)", "height": "rgb(40,40,40)", "finish": "rgb(0,225,30)"}[kind]), L)

	# Cooling slots across the rear plate.
	_in_regions(ctx, ["tail"], func(A: float, B: float, _n: String, _r: Region):
		if B < 0.05 or A < 0.12: return
		var n := 4 if B > 0.09 else 3
		var hh := minf(0.008, B * 0.07)
		var w: float = A * 0.38
		for i in n:
			var y: float = B * (0.3 + (0.4 * i) / (n - 1)) - hh / 2
			var x: float = A / 2 - w / 2
			if kind == "height": _fill_rrect(g, x - 0.002, y - 0.002, w + 0.004, hh + 0.004, hh / 2 + 0.002, "rgb(96,96,96)")
			_fill_rrect(g, x, y, w, hh, hh / 2, {"color": "rgba(8,8,10,0.85)", "height": "rgb(28,28,28)", "finish": "rgb(0,230,30)"}[kind])
			if kind == "color":
				g.stroke_style = "rgba(255,255,255,0.12)"
				g.line_width = 0.0015
				g.begin_path()
				g.move_to(x + hh / 2, y - 0.001)
				g.line_to(x + w - hh / 2, y - 0.001)
				g.stroke(), L)

## The top hatch, in top-region metres (a Rect2), or null where there is no room.
static func _hatch_rect(ctx: Ctx):
	var reg: Region = ctx.regions.top
	var A := reg.spanA
	var B := reg.spanB
	var inset := minf(0.022, ctx.S.z * 0.05)
	var w := minf(0.11, A * 0.34 - inset * 3)
	var h := minf(0.12, B * 0.36)
	if w < 0.05 or h < 0.05: return null
	var rect := Rect2(A * 0.17 - w / 2, B / 2 - h / 2, w, h)
	# Left off where the name sits.
	var pad := 0.01
	if ctx.name_spots != null:
		for sp in ctx.name_spots:
			if sp.region != "top": continue
			if rect.position.x < sp.a + sp.w / 2 + pad and rect.end.x > sp.a - sp.w / 2 - pad and rect.position.y < sp.b + sp.h / 2 + pad and rect.end.y > sp.b - sp.h / 2 - pad: return null
	return rect

## Paint chipped off the edges, down to bare steel.
static func _chips(ctx: Ctx, L: Dictionary) -> void:
	var g: CanvasRec = L.g
	for name in ctx.plan.chips:
		var list: Array = ctx.plan.chips[name]
		_in_regions(ctx, [name], func(_A: float, _B: float, _n: String, _r: Region):
			for pts in list:
				if L.kind == "color":
					_fill_pts(g, pts, "rgba(0,0,0,0.22)", 1.35)          # the torn paint edge
					_fill_pts(g, pts, "rgba(168,174,182,0.92)")
				elif L.kind == "height":
					_fill_pts(g, pts, "rgb(104,104,104)")
				else:
					_fill_pts(g, pts, "rgb(0,100,130)"), L)

# ---------------------------------------------------------------- name decals

static func _name_decals(ctx: Ctx, name: String, L: Dictionary) -> void:
	if name == "" or ctx.name_spots == null: return
	var g: CanvasRec = L.g
	var k: float = L.s
	# On the finish map the decal is just its outline: glossy vinyl.
	var vinyl = "rgb(0,120,22)" if L.kind == "finish" else null
	for sp in ctx.name_spots:
		var r: Region = ctx.regions[sp.region]
		var lines: Array = sp.lines
		# Size the text in pixels, then draw it unmirrored at the right spot.
		var at := r.px(sp.a, sp.b)
		var kw := r.kx * k
		var kh := r.ky * k
		var size := maxf(8 * k, (sp.h * kh) / (lines.size() * LINE))
		g.reset_transform()
		g.font_size = size
		var w := 0.0
		for t in lines: w = maxf(w, g.measure_text(t))
		if w > sp.w * kw:
			size *= (sp.w * kw) / w
			g.font_size = size
		g.save()
		g.translate(at.x * k, at.y * k)
		g.line_width = maxf(2 * k, size * 0.16)
		var y0 := (-(lines.size() - 1) / 2.0) * size * LINE
		g.stroke_style = vinyl if vinyl != null else _shade(ctx.C.text, -0.85)
		g.fill_style = vinyl if vinyl != null else ctx.C.text
		for i in lines.size(): g.text_centred(lines[i], 0, y0 + i * size * LINE)
		g.restore()

# ---------------------------------------------------------------- name placement
#
# A name only reads on a flat painted panel you can see: not wrapped down a
# slope or over a rounded edge, not under a steel plate, not behind a wheel.
# Given the body's faces and wheels, each decal region gets a grid of where
# that is true, and the name is set as large as fits in it, as near its usual
# spot as it can be. `livery.nameSize` (0.4-1) scales it down from there.

static func _width_of(g: CanvasRec, t: String) -> float:
	var w := g.measure_text(t)
	if w <= 0.0: w = t.length() * 70.0
	return (w / 100.0) * 1.06

static func _name_spots(ctx: Ctx, name: String, g: CanvasRec) -> Array:
	var S := ctx.S
	var template = ctx.template
	var opts := ctx.opts
	var ns: float = _nz(J.path(opts, ["livery", "nameSize"]), 1.0)
	var size := minf(1.0, maxf(0.4, ns))
	g.reset_transform()
	g.font_size = 100.0
	# One line, or two split at the space nearest the middle (a long name on a
	# short, deep panel reads far bigger that way).
	var layouts := [[name]]
	var words := name.split(" ")
	if words.size() > 1:
		var best = null
		var best_w := INF
		for i in range(1, words.size()):
			var two := [" ".join(words.slice(0, i)), " ".join(words.slice(i))]
			var w := maxf(_width_of(g, two[0]), _width_of(g, two[1]))
			if best == null or w < best_w:
				best = two
				best_w = w
		layouts.append(best)
	# Box aspect (width / height) of each layout, height = lines x LINE x size.
	var shapes := []
	for lines in layouts:
		var w := 0.0
		for t in lines: w = maxf(w, _width_of(g, t))
		shapes.append({"lines": lines, "aspect": w / (lines.size() * LINE)})
	var aspect: float = shapes[0].aspect
	var mid_a := S.x * 0.36 if template == "wedge" else S.x * 0.5
	# [region, preferred centre a, b, tallest the letters may be]
	var wants := []
	if template != "round":
		for side in SIDES: wants.append([side, mid_a, S.y * 0.56, minf(S.y * 0.5, 0.1)])
	wants.append(["top", S.x * 0.6, S.z * 0.5, minf(S.z * 0.22, 0.09)])
	var has_faces: bool = opts.get("faces") != null
	# Strictly first: flat, in plain view. If that finds nowhere at all, once
	# more looser - slopes too - so every painted robot it can carries its name.
	for loose in ([false, true] if has_faces else [false]):
		var spots := []
		for want in wants:
			var region: String = want[0]
			var pa: float = want[1]
			var pb: float = want[2]
			var h_max: float = want[3]
			var spot = null
			if has_faces:
				# Whichever layout gives the bigger letters (two lines must win clearly).
				var grid := _flat_paint(ctx, region, loose)
				for sh in shapes:
					var n_lines: int = sh.lines.size()
					var tall := n_lines * LINE      # box height per letter size
					var f = _fit_name(grid, sh.aspect, pa, pb, h_max * tall, NAME_MIN * tall)
					var letter: float = f.h / tall if f != null else 0.0
					var best_letter: float = spot.h / (spot.lines.size() * LINE) if spot != null else 0.0
					if f != null and letter > best_letter * (1.15 if n_lines > 1 else 1.0):
						spot = f
						spot.lines = sh.lines
			else:
				# No geometry to go on: the fixed spots.
				var A: float = ctx.regions[region].spanA
				var max_w: float = minf(A * 0.5, 0.5) if region == "top" else A * (0.5 if template == "wedge" else 0.62)
				var h := minf(h_max * LINE, max_w / aspect)
				spot = {"a": pa, "b": pb, "w": h * aspect, "h": h, "lines": [name]}
			if spot != null: spots.append({"region": region, "a": spot.a, "b": spot.b, "w": spot.w * size, "h": spot.h * size, "lines": spot.lines})
		if spots.size() > 0: return spots
	return []

static func _nz(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if (f == 0.0 or is_nan(f)) else f

## What each region's viewer sees, cell by cell: the outermost face (or a
## wheel, -2, or the weapon, -3) and its depth. Every face, wheel and weapon
## triangle is drawn into a depth buffer looking in at that side. Worked out
## once per region and kept on ctx.
static func _sight_of(ctx: Ctx, region: String) -> Dictionary:
	if ctx.sight.has(region): return ctx.sight[region]
	var opts := ctx.opts
	var bb: Dictionary = opts.bounds
	var bmin: Vector3 = bb.min
	var bmax: Vector3 = bb.max
	var reg: Region = ctx.regions[region]
	var A := reg.spanA
	var B := reg.spanB
	var nx := maxi(1, int(ceil(A / CELL)))
	var ny := maxi(1, int(ceil(B / CELL)))
	var depth := PackedFloat64Array()
	depth.resize(nx * ny)
	depth.fill(-INF)
	var owner := PackedInt32Array()
	owner.resize(nx * ny)
	owner.fill(-1)
	# A body point as (a, b, how far out towards the viewer).
	var top := region == "top"
	var sgn := 1.0 if region == "left" else -1.0

	var faces: Array = opts.faces
	for fi in faces.size():
		var f: Dictionary = faces[fi]
		var fn: Vector3 = f.n
		var facing := fn.y if top else sgn * fn.z
		var src: Array = f.ring
		if facing < 0.05 or src.size() < 3: continue
		var ring := PackedVector3Array()
		for p in src:
			ring.append(Vector3(p.x - bmin.x, (bmax.z - p.z) if top else (p.y - bmin.y), p.y if top else sgn * p.z))
		var rn := ring.size()
		# The face's plane as depth = pa*a + pb*b + pc, from three spread corners.
		var p0 := ring[0]
		var q := ring[rn / 3]
		var r := ring[(2 * rn) / 3]
		var det := (q.x - p0.x) * (r.y - p0.y) - (r.x - p0.x) * (q.y - p0.y)
		if absf(det) < 1e-12: continue
		var pa := ((q.z - p0.z) * (r.y - p0.y) - (r.z - p0.z) * (q.y - p0.y)) / det
		var pb := ((r.z - p0.z) * (q.x - p0.x) - (q.z - p0.z) * (r.x - p0.x)) / det
		var a0 := INF
		var a1 := -INF
		var b0 := INF
		var b1 := -INF
		for v in ring:
			a0 = minf(a0, v.x); a1 = maxf(a1, v.x); b0 = minf(b0, v.y); b1 = maxf(b1, v.y)
		var j_end := mini(ny, int(ceil(b1 / CELL)))
		var i_end := mini(nx, int(ceil(a1 / CELL)))
		for j in range(maxi(0, int(floor(b0 / CELL))), j_end):
			var b := (j + 0.5) * CELL
			for i in range(maxi(0, int(floor(a0 / CELL))), i_end):
				var a := (i + 0.5) * CELL
				# inside the convex outline? (either winding)
				var pos := false
				var neg := false
				for k in rn:
					var u := ring[k]
					var v := ring[(k + 1) % rn]
					var c := (v.x - u.x) * (b - u.y) - (v.y - u.y) * (a - u.x)
					if c > 1e-12: pos = true
					elif c < -1e-12: neg = true
					if pos and neg: break
				if pos and neg: continue
				var w := p0.z + pa * (a - p0.x) + pb * (b - p0.y)
				var ci := j * nx + i
				if w > depth[ci]:
					depth[ci] = w
					owner[ci] = fi
	for wh in opts.get("wheels", []):
		if top:
			var a0: float = wh.x - wh.r - bmin.x
			var a1: float = wh.x + wh.r - bmin.x
			var b0: float = bmax.z - wh.z - wh.w / 2
			var b1: float = bmax.z - wh.z + wh.w / 2
			for j in range(maxi(0, int(floor(b0 / CELL))), mini(ny, int(ceil(b1 / CELL)))):
				for i in range(maxi(0, int(floor(a0 / CELL))), mini(nx, int(ceil(a1 / CELL)))):
					var ci := j * nx + i
					if wh.y + wh.r > depth[ci]:
						depth[ci] = wh.y + wh.r
						owner[ci] = -2
		else:
			var ca: float = wh.x - bmin.x
			var cb: float = wh.y - bmin.y
			var out_w: float = sgn * wh.z + wh.w / 2
			for j in range(maxi(0, int(floor((cb - wh.r) / CELL))), mini(ny, int(ceil((cb + wh.r) / CELL)))):
				for i in range(maxi(0, int(floor((ca - wh.r) / CELL))), mini(nx, int(ceil((ca + wh.r) / CELL)))):
					if Vector2((i + 0.5) * CELL - ca, (j + 0.5) * CELL - cb).length() <= wh.r:
						var ci := j * nx + i
						if out_w > depth[ci]:
							depth[ci] = out_w
							owner[ci] = -2
	# The weapon's arms, uprights and rotors: each triangle covers the cells
	# it lies over (at its outermost corner's depth - near enough for a mask).
	for tris in opts.get("blockers", []):
		var t: PackedVector3Array = tris
		for k in range(0, t.size() - 2, 3):
			var pa3 := t[k]
			var pb3 := t[k + 1]
			var pc3 := t[k + 2]
			var xa := pa3.x - bmin.x
			var ya := (bmax.z - pa3.z) if top else (pa3.y - bmin.y)
			var xb := pb3.x - bmin.x
			var yb := (bmax.z - pb3.z) if top else (pb3.y - bmin.y)
			var xc := pc3.x - bmin.x
			var yc := (bmax.z - pc3.z) if top else (pc3.y - bmin.y)
			var w := maxf(pa3.y if top else sgn * pa3.z, maxf(pb3.y if top else sgn * pb3.z, pc3.y if top else sgn * pc3.z))
			var i0 := maxi(0, int(floor(minf(xa, minf(xb, xc)) / CELL)))
			var i1 := mini(nx - 1, int(floor(maxf(xa, maxf(xb, xc)) / CELL)))
			var j0 := maxi(0, int(floor(minf(ya, minf(yb, yc)) / CELL)))
			var j1 := mini(ny - 1, int(floor(maxf(ya, maxf(yb, yc)) / CELL)))
			if i0 > i1 or j0 > j1: continue
			if i0 == i1 and j0 == j1:     # inside one cell
				var ci := j0 * nx + i0
				if w > depth[ci]:
					depth[ci] = w
					owner[ci] = -3
				continue
			var area := (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya)
			for j in range(j0, j1 + 1):
				var b := (j + 0.5) * CELL
				for i in range(i0, i1 + 1):
					var a := (i + 0.5) * CELL
					var s0 := (xb - xa) * (b - ya) - (yb - ya) * (a - xa)
					var s1 := (xc - xb) * (b - yb) - (yc - yb) * (a - xb)
					var s2 := (xa - xc) * (b - yc) - (ya - yc) * (a - xc)
					var inside := (s0 >= 0 and s1 >= 0 and s2 >= 0) if area > 0 else (s0 <= 0 and s1 <= 0 and s2 <= 0)
					if inside:
						var ci := j * nx + i
						if w > depth[ci]:
							depth[ci] = w
							owner[ci] = -3
			# its corners too, so a sliver thinner than a cell still counts
			for cp in [Vector2(xa, ya), Vector2(xb, yb), Vector2(xc, yc)]:
				var ci_x := int(floor(cp.x / CELL))
				var ci_y := int(floor(cp.y / CELL))
				if ci_x >= 0 and ci_x < nx and ci_y >= 0 and ci_y < ny:
					var ci := ci_y * nx + ci_x
					if w > depth[ci]:
						depth[ci] = w
						owner[ci] = -3
	var out := {"owner": owner, "nx": nx, "ny": ny, "top": top, "sgn": sgn}
	ctx.sight[region] = out
	return out

## Where a region shows flat paint, as a grid of cells (1 = usable): the
## outermost thing there is a painted face turned squarely to the viewer, and
## not at a join between pieces.
static func _flat_paint(ctx: Ctx, region: String, loose := false) -> Dictionary:
	var sight := _sight_of(ctx, region)
	var owner: PackedInt32Array = sight.owner
	var nx: int = sight.nx
	var ny: int = sight.ny
	var top: bool = sight.top
	var sgn: float = sight.sgn
	var faces: Array = ctx.opts.faces
	# Strict: within ~23 degrees of square on. Loose: up to ~53 (an A-frame's
	# flanks), where the letters stretch a little but still read.
	var min_facing := 0.6 if loose else 0.92
	var usable := PackedByteArray()
	usable.resize(faces.size())
	var normals := PackedVector3Array()
	var piece_of := PackedInt32Array()
	for i in faces.size():
		var f: Dictionary = faces[i]
		var fn: Vector3 = f.n
		usable[i] = 1 if (J.truthy(f.get("paint")) and (fn.y if top else sgn * fn.z) > min_facing) else 0
		normals.append(fn)
		piece_of.append(int(f.get("piece", -1)))
	# Where one piece meets another is an edge, even level with it: every
	# piece is drawn with rounded edges, so there is a groove or a step there
	# and the name must not run across it. Within a piece, only a real crease is.
	var crease := cos(deg_to_rad(20.0 if loose else 10.0))
	var ok := PackedByteArray()
	ok.resize(nx * ny)
	for c in ok.size(): ok[c] = 1 if (owner[c] >= 0 and usable[owner[c]] == 1) else 0
	for j in ny:
		for i in nx:
			var c := j * nx + i
			var p := owner[c]
			if i + 1 < nx:
				var q := owner[c + 1]
				if q != p and (p < 0 or q < 0 or piece_of[p] < 0 or piece_of[p] != piece_of[q] or normals[p].dot(normals[q]) < crease):
					ok[c] = 0
					ok[c + 1] = 0
			if j + 1 < ny:
				var q := owner[c + nx]
				if q != p and (p < 0 or q < 0 or piece_of[p] < 0 or piece_of[p] != piece_of[q] or normals[p].dot(normals[q]) < crease):
					ok[c] = 0
					ok[c + nx] = 0
	return {"ok": ok, "nx": nx, "ny": ny}

static func _any_fit(sat: PackedInt32Array, W: int, nx: int, ny: int, wc: int, hc: int) -> bool:
	if wc > nx or hc > ny: return false
	var want := wc * hc
	for j in range(0, ny - hc + 1):
		var r0 := j * W
		var r1 := (j + hc) * W
		for i in range(0, nx - wc + 1):
			if sat[r1 + i + wc] - sat[r0 + i + wc] - sat[r1 + i] + sat[r0 + i] == want: return true
	return false

## The biggest name box (aspect w/h) that fits the grid, nearest (pa, pb), or null.
static func _fit_name(grid: Dictionary, aspect: float, pa: float, pb: float, h_max: float, h_min := NAME_MIN):
	var ok: PackedByteArray = grid.ok
	var nx: int = grid.nx
	var ny: int = grid.ny
	# Summed-area table: any rectangle's usable-cell count in four lookups.
	var W := nx + 1
	var sat := PackedInt32Array()
	sat.resize(W * (ny + 1))
	for j in ny:
		for i in nx:
			sat[(j + 1) * W + i + 1] = ok[j * nx + i] + sat[j * W + i + 1] + sat[(j + 1) * W + i] - sat[j * W + i]
	var m := int(ceil(MARGIN / CELL))
	var dims := func(h: float) -> Vector2i:
		return Vector2i(int(ceil((h * aspect) / CELL)) + 2 * m, int(ceil(h / CELL)) + 2 * m)
	# A box that fits also fits smaller, so halve the gap to the largest.
	var d: Vector2i = dims.call(h_min)
	if not _any_fit(sat, W, nx, ny, d.x, d.y): return null
	var good := h_min
	var bad := h_max * 1.0001
	d = dims.call(h_max)
	if _any_fit(sat, W, nx, ny, d.x, d.y): good = h_max
	else:
		while bad / good > 1.03:
			var h := sqrt(good * bad)
			d = dims.call(h)
			if _any_fit(sat, W, nx, ny, d.x, d.y): good = h
			else: bad = h
	# Then the spot nearest the usual one, at that size.
	d = dims.call(good)
	var wc := d.x
	var hc := d.y
	var want := wc * hc
	var best_a := 0.0
	var best_b := 0.0
	var best_d := INF
	for j in range(0, ny - hc + 1):
		var r0 := j * W
		var r1 := (j + hc) * W
		for i in range(0, nx - wc + 1):
			if sat[r1 + i + wc] - sat[r0 + i + wc] - sat[r1 + i] + sat[r0 + i] != want: continue
			var a := (i + wc / 2.0) * CELL
			var b := (j + hc / 2.0) * CELL
			var dd := (a - pa) * (a - pa) + (b - pb) * (b - pb)
			if dd < best_d:
				best_d = dd
				best_a = a
				best_b = b
	return {"a": best_a, "b": best_b, "w": good * aspect, "h": good}

# ---------------------------------------------------------------- wear

static func _wear(ctx: Ctx, L: Dictionary) -> void:
	var g: CanvasRec = L.g
	# The dice are rolled on the paint pass and kept, so the bump and finish
	# maps put every scrape in the same place.
	if ctx.scuffs == null:
		var rng := ctx.rng
		var scrapes := []
		var soot := []
		# Scrapes down to bright metal, mostly low and near the nose.
		for i in 120:
			var x := rng.next() * SIZE
			var y := rng.next() * SIZE
			var a := (rng.next() - 0.5) * 0.9
			a += 0.0 if rng.next() < 0.5 else PI
			var l := 6 + rng.next() * 40
			var alpha := 0.12 + rng.next() * 0.3
			var w := 0.6 + rng.next() * 1.6
			scrapes.append([x, y, x + cos(a) * l, y + sin(a) * l, alpha, w])
		# Soot and grime along the bottom of the sides.
		for k in ["left", "right", "nose", "tail"]:
			var R: Rect2 = ATLAS[k]
			for i in 14:
				var sx := R.position.x + rng.next() * R.size.x
				var sy := R.position.y + R.size.y * (0.75 + rng.next() * 0.3)
				var sr := 8 + rng.next() * 26
				soot.append(_blob_pts(sx, sy, sr, rng))
		ctx.scuffs = {"scrapes": scrapes, "soot": soot}
	var s: float = L.s
	g.set_transform(s, 0, 0, s, 0, 0)
	g.line_cap = "round"
	for sc in ctx.scuffs.scrapes:
		var alpha: float = sc[4]
		if L.kind == "color": g.stroke_style = Color(205 / 255.0, 210 / 255.0, 218 / 255.0, alpha)
		elif L.kind == "height": g.stroke_style = Color(80 / 255.0, 80 / 255.0, 80 / 255.0, minf(1.0, alpha * 1.4))
		else: g.stroke_style = Color(0, 84 / 255.0, 140 / 255.0, minf(1.0, alpha * 1.8))
		g.line_width = sc[5]
		g.begin_path()
		g.move_to(sc[0], sc[1])
		g.line_to(sc[2], sc[3])
		g.stroke()
	g.line_cap = "butt"
	if L.kind != "height":      # soot has no depth
		for pts in ctx.scuffs.soot: _fill_pts(g, pts, "rgba(22,20,20,0.16)" if L.kind == "color" else "rgba(0,235,10,0.4)")
	g.reset_transform()

# ---------------------------------------------------------------- helpers

## An irregular blob's outline: { x, y, pts: [Vector2] }.
static func _blob_pts(x: float, y: float, r: float, rng: Lcg) -> Dictionary:
	var n := 9
	var pts := PackedVector2Array()
	for i in range(n + 1):
		var a := (float(i) / n) * TAU
		var rr := r * (0.6 + rng.next() * 0.6)
		pts.append(Vector2(x + cos(a) * rr, y + sin(a) * rr))
	return {"x": x, "y": y, "pts": pts}

## Fill a blob from _blob_pts, optionally grown about its middle.
static func _fill_pts(g: CanvasRec, blob: Dictionary, fill, grow := 1.0) -> void:
	g.fill_style = fill
	g.begin_path()
	var c := Vector2(blob.x, blob.y)
	var first := true
	for p in blob.pts:
		var q: Vector2 = c + (p - c) * grow
		if first: g.move_to(q.x, q.y)
		else: g.line_to(q.x, q.y)
		first = false
	g.close_path()
	g.fill()

static func _blob(g: CanvasRec, x: float, y: float, r: float, rng: Lcg) -> void:
	_fill_pts(g, _blob_pts(x, y, r, rng), g.fill_style)

static func _luminance(c) -> float:
	var col := CanvasRec.css(c)
	var out := 0.0
	var wts := [0.2126, 0.7152, 0.0722]
	var ch := [col.r, col.g, col.b]
	for i in 3:
		var v: float = round(ch[i] * 255.0) / 255.0
		out += wts[i] * (v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4))
	return out

static func _contrast(a, b) -> float:
	var la := _luminance(a)
	var lb := _luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)

## Decal colour: the accent if it stands out on the paint, else white or black.
static func _pick_text(C: Dictionary) -> String:
	for c in [C.accent, C.secondary]:
		if _contrast(c, C.primary) >= 2.6: return c
	return "#ffffff" if _contrast("#ffffff", C.primary) > _contrast("#111114", C.primary) else "#111114"

## Lighten (k > 0) or darken (k < 0) a colour.
static func _shade(c, k: float) -> Color:
	var col := CanvasRec.css(c)
	var out := Color(0, 0, 0, 1)
	for i in 3:
		var v: float = round(col[i] * 255.0)
		out[i] = round(v * (1 + k) if k < 0 else v + (255 - v) * k) / 255.0
	return out
