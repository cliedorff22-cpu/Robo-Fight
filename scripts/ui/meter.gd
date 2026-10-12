## meter.gd - a flat bar that fills left to right in a gradient: health, a
## weapon's spin, a weight against its cap.
class_name Meter
extends Control

var value := 1.0: set = set_value
var from := UI.OK
var to := UI.ACCENT
var back := Color(1, 1, 1, 0.08)
## Shown value eases toward `value` at this rate (per second); 0 = at once.
var ease_rate := 6.0
var _shown := 1.0

func _init(height := 7.0, min_width := 60.0) -> void:
	custom_minimum_size = Vector2(min_width, height)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_value(v: float) -> void:
	value = clampf(v, 0.0, 1.0)
	if ease_rate <= 0.0: _shown = value
	queue_redraw()

func set_colors(a: Color, b: Color) -> void:
	if from == a and to == b: return
	from = a
	to = b
	queue_redraw()

func _process(dt: float) -> void:
	if absf(_shown - value) < 0.002: return
	_shown = lerpf(_shown, value, minf(1.0, dt * ease_rate)) if ease_rate > 0.0 else value
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), back)
	var w := size.x * _shown
	if w < 0.5: return
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, size.y), Vector2(0, size.y)]),
		PackedColorArray([from, from.lerp(to, _shown), from.lerp(to, _shown), from]))
