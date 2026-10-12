## tex_paint.gd - a small CPU painter for the generated textures (the arena
## floor, grimy steel, hazard stripes, scratched polycarbonate).
##
## No texture files ship with the game: every map is drawn at boot. Drawing a
## pixel at a time from script would take seconds, so everything here is built
## from the two things an Image does natively and quickly: filling rectangles
## and alpha-blending small stamps. A stamp that hangs over an edge is drawn
## again on the far side, so every texture tiles.
class_name TexPaint
extends RefCounted

var img: Image
var s := 512
var rng := RandomNumberGenerator.new()
var _inks := {}

func _init(size: int, base: Color, rng_seed := 1) -> void:
	s = size
	img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(base)
	rng.seed = rng_seed

func rnd(a: float, b: float) -> float:
	return rng.randf_range(a, b)

static func rgba(r: float, g: float, b: float, a := 1.0) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, a)

func _put(src: Image, x: int, y: int) -> void:
	var w := src.get_width()
	var h := src.get_height()
	var r := Rect2i(0, 0, w, h)
	var xs := [x]
	if x < 0: xs.append(x + s)
	elif x + w > s: xs.append(x - s)
	var ys := [y]
	if y < 0: ys.append(y + s)
	elif y + h > s: ys.append(y - s)
	for px in xs:
		for py in ys:
			img.blend_rect(src, r, Vector2i(px, py))

## A blended rectangle.
func rect(x: float, y: float, w: float, h: float, c: Color) -> void:
	var src := Image.create(maxi(1, int(round(w))), maxi(1, int(round(h))), false, Image.FORMAT_RGBA8)
	src.fill(c)
	_put(src, int(round(x)), int(round(y)))

# A round stamp of one colour, soft (fading from the middle) or hard-edged,
# kept small and scaled to each use.
func _ink(c: Color, soft: bool, d: int) -> Image:
	var b := 8 if d <= 8 else (16 if d <= 28 else 32)
	var key := (c.r8 >> 3) | ((c.g8 >> 3) << 5) | ((c.b8 >> 3) << 10) | ((c.a8 >> 3) << 15) | ((1 if soft else 0) << 20) | (b << 21)
	if _inks.has(key): return _inks[key]
	var bytes := PackedByteArray()
	bytes.resize(b * b * 4)
	var h := b / 2.0
	var i := 0
	for y in b:
		for x in b:
			var t := Vector2(x + 0.5 - h, y + 0.5 - h).length() / h
			var a := clampf(1.0 - t, 0.0, 1.0) if soft else clampf((1.0 - t) * h, 0.0, 1.0)
			bytes[i] = c.r8
			bytes[i + 1] = c.g8
			bytes[i + 2] = c.b8
			bytes[i + 3] = int(c.a * a * 255.0)
			i += 4
	var out := Image.create_from_data(b, b, false, Image.FORMAT_RGBA8, bytes)
	_inks[key] = out
	return out

## A soft blob: full colour in the middle, nothing at radius r.
func blob(x: float, y: float, r: float, c: Color) -> void:
	_stamp(x, y, r, c, true)

## A hard-edged disc.
func disc(x: float, y: float, r: float, c: Color) -> void:
	_stamp(x, y, r, c, false)

func _stamp(x: float, y: float, r: float, c: Color, soft: bool) -> void:
	var d := maxi(2, int(round(r * 2.0)))
	var base := _ink(c, soft, d)
	var st := base
	if base.get_width() != d:
		st = base.duplicate()
		st.resize(d, d, Image.INTERPOLATE_BILINEAR)
	_put(st, int(round(x - d / 2.0)), int(round(y - d / 2.0)))

## An irregular patch (oil, rust, scorch): a few overlapping discs, each
## carrying a share of the colour so the overlaps do not pile up.
func blotch(x: float, y: float, r: float, c: Color) -> void:
	disc(x, y, r * 0.72, Color(c.r, c.g, c.b, c.a * 0.6))
	for i in 3:
		var a := rnd(0.0, TAU)
		var o := r * rnd(0.3, 0.55)
		disc(x + cos(a) * o, y + sin(a) * o, r * rnd(0.35, 0.55), Color(c.r, c.g, c.b, c.a * 0.4))

## A straight stroke, round-ended.
func line(x0: float, y0: float, x1: float, y1: float, width: float, c: Color) -> void:
	var w := maxf(1.5, width)
	var a := Vector2(x0, y0)
	var b := Vector2(x1, y1)
	# Stamps overlap, so each carries a share of the stroke's alpha.
	var n := maxi(1, int(ceil(a.distance_to(b) / (w * 0.6))))
	var ink := Color(c.r, c.g, c.b, c.a * 0.6)
	for i in range(n + 1):
		var p := a.lerp(b, float(i) / n)
		disc(p.x, p.y, w * 0.5, ink)

## A stroke along part of a circle.
func arc(x: float, y: float, r: float, a0: float, a1: float, width: float, c: Color) -> void:
	var span := absf(a1 - a0)
	var n := maxi(1, int(ceil(span * r / (maxf(1.5, width) * 0.6))))
	var ink := Color(c.r, c.g, c.b, c.a * 0.6)
	for i in range(n + 1):
		var a := lerpf(a0, a1, float(i) / n)
		disc(x + cos(a) * r, y + sin(a) * r, maxf(1.5, width) * 0.5, ink)

## The picture as a texture (with mipmaps, so it does not shimmer far off).
func texture() -> ImageTexture:
	var out: Image = img.duplicate()
	out.generate_mipmaps()
	return ImageTexture.create_from_image(out)

## The picture read as a height map, as a normal map.
func normal_texture(strength := 2.0) -> ImageTexture:
	var out: Image = img.duplicate()
	out.bump_map_to_normal_map(strength)
	out.generate_mipmaps(true)
	return ImageTexture.create_from_image(out)
