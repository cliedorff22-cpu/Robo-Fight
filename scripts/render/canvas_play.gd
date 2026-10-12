## canvas_play.gd - draws a CanvasRec display list with Godot's 2D calls.
##
## Put one in a SubViewport the size of the recording and hand it the list.
## Each run of entries that share a clip rectangle becomes one child Control
## with clip_contents on (later runs are later children, so they draw on top,
## as they did on the canvas).
class_name CanvasPlay
extends Control

func show_list(list: Array) -> void:
	for c in get_children(): c.queue_free()
	var layer: Layer = null
	for it in list:
		var clip: Rect2 = it.clip
		if layer == null or layer.clip != clip:
			layer = Layer.new()
			layer.clip = clip
			layer.position = clip.position
			layer.size = clip.size
			layer.clip_contents = true
			layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(layer)
		layer.items.append(it)

class Layer:
	extends Control
	var clip: Rect2
	var items := []

	func _draw() -> void:
		var o := clip.position
		var font := CanvasRec.font()
		for it in items:
			match it.type:
				"poly":
					var pts: PackedVector2Array = it.pts
					# Skip what cannot be triangulated rather than have the
					# engine complain about it every frame.
					if Geometry2D.triangulate_polygon(pts).is_empty(): continue
					var loc := PackedVector2Array()
					for p in pts: loc.append(p - o)
					draw_colored_polygon(loc, it.color)
				"line":
					var loc := PackedVector2Array()
					for p in it.pts: loc.append(p - o)
					if it.closed: loc.append(loc[0])
					draw_polyline(loc, it.color, it.width, true)
					if it.round and not it.closed:
						draw_circle(loc[0], it.width / 2.0, it.color)
						draw_circle(loc[loc.size() - 1], it.width / 2.0, it.color)
				"grad":
					var r: Rect2 = it.rect
					var stops: Array = it.stops
					for i in range(stops.size() - 1):
						var ya: float = lerpf(it.y0, it.y1, stops[i][0]) - o.y
						var yb: float = lerpf(it.y0, it.y1, stops[i + 1][0]) - o.y
						var ca: Color = stops[i][1]
						var cb: Color = stops[i + 1][1]
						var x0 := r.position.x - o.x
						var x1 := r.end.x - o.x
						draw_polygon(PackedVector2Array([Vector2(x0, ya), Vector2(x1, ya), Vector2(x1, yb), Vector2(x0, yb)]), PackedColorArray([ca, ca, cb, cb]))
				"text":
					var fs := int(maxf(1.0, round(it.size)))
					var w := font.get_string_size(it.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
					var at: Vector2 = it.pos - o
					var base := Vector2(at.x - w / 2.0, at.y + (font.get_ascent(fs) - font.get_descent(fs)) / 2.0)
					if it.outline > 0.0: draw_string_outline(font, base, it.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, int(ceil(it.outline)), it.outline_color)
					draw_string(font, base, it.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, it.color)
