## canvas_rec.gd - a recording 2D canvas.
##
## The paint jobs (render/livery.gd) and the generated textures were written
## against a browser's 2D canvas: a transform, a clip, paths, fills, strokes
## and text. This is that drawing surface as a RECORDER: every call is
## flattened to pixels and kept in a display list, which render/canvas_play.gd
## then draws with Godot's CanvasItem calls inside a SubViewport.
##
## Recording first keeps the painting code pure (it runs headless, and the
## same list can be drawn at any size), and puts all the engine-specific
## drawing in one small file.
##
## Only what the game's painters use is here: clips are always rectangles,
## gradients are linear (top to bottom) or radial, text is drawn unrotated.
class_name CanvasRec
extends RefCounted

var size := Vector2(1024, 1024)
## The display list: dictionaries with `clip` (Rect2 in pixels) and a `type`:
##   poly  { pts: PackedVector2Array, color }
##   line  { pts, color, width, round, closed }
##   grad  { rect: Rect2, stops: [[offset, Color]] }      vertical gradient
##   text  { text, pos (centre), size, color, outline, outline_color }
var list := []

# ---- state (saved and restored together, as a canvas does)
var xf := Transform2D.IDENTITY
var clip_rect := Rect2(0, 0, 1024, 1024)
var fill_style = Color.BLACK        # Color, or a gradient dictionary
var stroke_style = Color.BLACK
var line_width := 1.0
var global_alpha := 1.0
var line_cap := "butt"
var font_size := 10.0
var _stack := []

var _path := []                     # subpaths: [PackedVector2Array (pixels), closed]
var _cur := PackedVector2Array()
var _cur_user := Vector2.ZERO       # the pen, in user units (for curves)

## The font the names are set in, shared by every canvas.
static var _font: Font = null

static func font() -> Font:
	if _font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Arial Black", "Impact", "Helvetica Neue", "Arial", "sans-serif"])
		f.font_weight = 900
		f.font_italic = true
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_font = f
	return _font

func _init(w := 1024.0, h := 1024.0) -> void:
	size = Vector2(w, h)
	clip_rect = Rect2(Vector2.ZERO, size)

# ---------------------------------------------------------------- colours

## A CSS colour: "#rgb", "#rrggbb", "rgb(r,g,b)" or "rgba(r,g,b,a)".
static func css(c) -> Color:
	if c is Color: return c
	var s := str(c).strip_edges()
	if s.begins_with("#"): return Color.html(s)
	if s.begins_with("rgb"):
		var inner := s.substr(s.find("(") + 1)
		inner = inner.substr(0, inner.find(")"))
		var p := inner.split(",")
		var a := p[3].to_float() if p.size() > 3 else 1.0
		return Color(p[0].to_float() / 255.0, p[1].to_float() / 255.0, p[2].to_float() / 255.0, a)
	return Color.html(s) if Color.html_is_valid(s) else Color.MAGENTA

func _col(style) -> Color:
	var c := css(style) if not (style is Dictionary) else Color.WHITE
	c.a *= global_alpha
	return c

# ---------------------------------------------------------------- state

func set_transform(a: float, b: float, c: float, d: float, e: float, f: float) -> void:
	xf = Transform2D(Vector2(a, b), Vector2(c, d), Vector2(e, f))

func reset_transform() -> void:
	xf = Transform2D.IDENTITY

func translate(x: float, y: float) -> void:
	xf = xf * Transform2D(0.0, Vector2(x, y))

func scale_by(x: float, y: float) -> void:
	xf = xf * Transform2D(Vector2(x, 0), Vector2(0, y), Vector2.ZERO)

func save() -> void:
	_stack.append([xf, clip_rect, fill_style, stroke_style, line_width, global_alpha, line_cap, font_size])

func restore() -> void:
	if _stack.is_empty(): return
	var s: Array = _stack.pop_back()
	xf = s[0]; clip_rect = s[1]; fill_style = s[2]; stroke_style = s[3]
	line_width = s[4]; global_alpha = s[5]; line_cap = s[6]; font_size = s[7]

## How many pixels one user unit is, near enough (for line widths).
func _unit() -> float:
	return sqrt(absf(xf.x.x * xf.y.y - xf.x.y * xf.y.x))

# ---------------------------------------------------------------- paths

func begin_path() -> void:
	_path = []
	_cur = PackedVector2Array()

func _flush(closed := false) -> void:
	if _cur.size() > 0: _path.append([_cur, closed])
	_cur = PackedVector2Array()

func move_to(x: float, y: float) -> void:
	_flush()
	_cur_user = Vector2(x, y)
	_cur.append(xf * _cur_user)

func line_to(x: float, y: float) -> void:
	_cur_user = Vector2(x, y)
	_cur.append(xf * _cur_user)

func close_path() -> void:
	_flush(true)

func rect(x: float, y: float, w: float, h: float) -> void:
	_flush()
	_cur = PackedVector2Array([xf * Vector2(x, y), xf * Vector2(x + w, y), xf * Vector2(x + w, y + h), xf * Vector2(x, y + h)])
	_flush(true)
	_cur_user = Vector2(x, y)

func bezier_curve_to(c1x: float, c1y: float, c2x: float, c2y: float, x: float, y: float) -> void:
	var p0 := _cur_user
	var c1 := Vector2(c1x, c1y)
	var c2 := Vector2(c2x, c2y)
	var p1 := Vector2(x, y)
	for i in range(1, 17):
		_cur.append(xf * p0.bezier_interpolate(c1, c2, p1, i / 16.0))
	_cur_user = p1

func quadratic_curve_to(cx: float, cy: float, x: float, y: float) -> void:
	var p0 := _cur_user
	var c := Vector2(cx, cy)
	var p1 := Vector2(x, y)
	for i in range(1, 13):
		var t := i / 12.0
		_cur.append(xf * p0.lerp(c, t).lerp(c.lerp(p1, t), t))
	_cur_user = p1

## An arc of a circle from angle a0 to a1 (radians; more than a full turn is
## a full circle), joined to the path by a line as a canvas joins it.
func arc(x: float, y: float, r: float, a0: float, a1: float) -> void:
	var sweep := minf(a1 - a0, TAU)
	var px := maxf(1.0, r * _unit())
	var n := clampi(int(ceil(sweep * sqrt(px) * 1.6)), 6, 48)
	for i in range(n + 1):
		var a := a0 + sweep * float(i) / n
		_cur_user = Vector2(x + cos(a) * r, y + sin(a) * r)
		_cur.append(xf * _cur_user)

## The corner arc of radius r that rounds the turn from the pen through
## (x1, y1) towards (x2, y2).
func arc_to(x1: float, y1: float, x2: float, y2: float, r: float) -> void:
	var p0 := _cur_user
	var p1 := Vector2(x1, y1)
	var p2 := Vector2(x2, y2)
	var d0 := (p0 - p1).normalized()
	var d2 := (p2 - p1).normalized()
	var cos_t := clampf(d0.dot(d2), -1.0, 1.0)
	if r <= 0.0 or absf(cos_t) > 0.9999 or d0 == Vector2.ZERO or d2 == Vector2.ZERO:
		line_to(x1, y1)
		return
	var half := acos(cos_t) / 2.0
	var dist := r / tan(half)
	var t0 := p1 + d0 * dist
	var t2 := p1 + d2 * dist
	var centre := p1 + (d0 + d2).normalized() * (r / sin(half))
	var a0 := (t0 - centre).angle()
	var a1 := (t2 - centre).angle()
	var da := wrapf(a1 - a0, -PI, PI)
	line_to(t0.x, t0.y)
	for i in range(1, 7):
		var a := a0 + da * i / 6.0
		_cur_user = centre + Vector2(cos(a), sin(a)) * r
		_cur.append(xf * _cur_user)

# ---------------------------------------------------------------- painting

func _clean(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-4: out.append(p)
	if out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) < 1e-4: out.remove_at(out.size() - 1)
	return out

func fill() -> void:
	_flush()
	for sp in _path:
		var pts := _clean(sp[0])
		if pts.size() < 3: continue
		if fill_style is Dictionary:
			_radial(pts, fill_style)
		else:
			list.append({"type": "poly", "clip": clip_rect, "pts": pts, "color": _col(fill_style)})

func stroke() -> void:
	_flush()
	var w := maxf(0.5, line_width * _unit())
	for sp in _path:
		var pts := _clean(sp[0])
		if pts.size() < 2: continue
		list.append({"type": "line", "clip": clip_rect, "pts": pts, "color": _col(stroke_style), "width": w, "round": line_cap == "round", "closed": sp[1]})

## Clip to the current path, which must be one rectangle.
func clip() -> void:
	_flush()
	if _path.is_empty(): return
	var pts: PackedVector2Array = _path[_path.size() - 1][0]
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts: r = r.expand(p)
	clip_rect = clip_rect.intersection(r)

func fill_rect(x: float, y: float, w: float, h: float) -> void:
	if fill_style is Dictionary and fill_style.get("kind") == "linear":
		# A top-to-bottom gradient over an unrotated rectangle.
		var a := xf * Vector2(x, y)
		var b := xf * Vector2(x + w, y + h)
		var stops := []
		for s in fill_style.stops:
			var c: Color = s[1]
			c.a *= global_alpha
			stops.append([s[0], c])
		list.append({"type": "grad", "clip": clip_rect, "rect": Rect2(a, b - a).abs(), "y0": (xf * Vector2(0, fill_style.y0)).y, "y1": (xf * Vector2(0, fill_style.y1)).y, "stops": stops})
		return
	var pts := PackedVector2Array([xf * Vector2(x, y), xf * Vector2(x + w, y), xf * Vector2(x + w, y + h), xf * Vector2(x, y + h)])
	list.append({"type": "poly", "clip": clip_rect, "pts": pts, "color": _col(fill_style)})

func stroke_rect(x: float, y: float, w: float, h: float) -> void:
	begin_path()
	rect(x, y, w, h)
	stroke()

func create_linear_gradient(_x0: float, y0: float, _x1: float, y1: float) -> Dictionary:
	return {"kind": "linear", "y0": y0, "y1": y1, "stops": []}

func create_radial_gradient(x: float, y: float, _r0: float, _x1: float, _y1: float, r1: float) -> Dictionary:
	return {"kind": "radial", "x": x, "y": y, "r": r1, "stops": []}

static func add_stop(grad: Dictionary, offset: float, color) -> void:
	grad.stops.append([offset, css(color)])

# A radial gradient fill, as a few shrinking rings about its centre.
func _radial(pts: PackedVector2Array, grad: Dictionary) -> void:
	var c: Vector2 = xf * Vector2(grad.x, grad.y)
	var steps := 4
	for i in range(steps):
		var t := 1.0 - float(i) / steps            # 1 = the rim, towards 0 = the centre
		var col := _stop_at(grad.stops, t - 0.5 / steps)
		col.a *= global_alpha
		var ring := PackedVector2Array()
		for p in pts: ring.append(c + (p - c) * t)
		list.append({"type": "poly", "clip": clip_rect, "pts": ring, "color": col})

static func _stop_at(stops: Array, t: float) -> Color:
	if stops.is_empty(): return Color.WHITE
	if t <= stops[0][0]: return stops[0][1]
	for i in range(stops.size() - 1):
		if t <= stops[i + 1][0]:
			var k: float = (t - stops[i][0]) / maxf(1e-6, stops[i + 1][0] - stops[i][0])
			return stops[i][1].lerp(stops[i + 1][1], k)
	return stops[stops.size() - 1][1]

# ---------------------------------------------------------------- text

## Width of `text` at the current font size, in pixels.
func measure_text(text: String) -> float:
	return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(maxf(1.0, font_size))).x

## Text centred on (x, y) in user units, filled in the fill style with an
## outline of `line_width` in the stroke style (0 for none).
func text_centred(text: String, x: float, y: float, outline := true) -> void:
	list.append({"type": "text", "clip": clip_rect, "text": text, "pos": xf * Vector2(x, y), "size": font_size,
		"color": _col(fill_style), "outline": line_width / 2.0 if outline else 0.0, "outline_color": _col(stroke_style)})
