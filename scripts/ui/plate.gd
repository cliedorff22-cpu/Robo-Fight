## plate.gd - a bolted gunmetal panel with cut corners: what every card,
## panel and overlay in the game is drawn on.
class_name Plate
extends PanelContainer

var cut := 12.0
var top_color := UI.PANEL_TOP
var bottom_color := UI.PANEL_BOT
var border_color := UI.EDGE
var bolts := true
## Optional coloured bars along an edge (the red corner, the accent top).
var bar_top = null
var bar_left = null
var bar_right = null
var bar_w := 4.0
## Optional glow inside the border (an active corner).
var ring = null
## Corners that are cut: top-left and bottom-right by default.
var cut_all := false

func _init(pad_h := 14, pad_v := 10) -> void:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	add_theme_stylebox_override("panel", sb)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: queue_redraw()

func outline() -> PackedVector2Array:
	var w := size.x
	var h := size.y
	var c := minf(cut, minf(w, h) * 0.4)
	if cut_all:
		return PackedVector2Array([Vector2(c, 0), Vector2(w - c, 0), Vector2(w, c), Vector2(w, h - c), Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, c)])
	return PackedVector2Array([Vector2(c, 0), Vector2(w, 0), Vector2(w, h - c), Vector2(w - c, h), Vector2(0, h), Vector2(0, c)])

func _draw() -> void:
	var pts := outline()
	if size.x < 2.0 or size.y < 2.0: return
	var cols := PackedColorArray()
	for p in pts: cols.append(top_color.lerp(bottom_color, clampf(p.y / size.y, 0.0, 1.0)))
	draw_polygon(pts, cols)
	if bar_top != null: draw_rect(Rect2(0, 0, size.x, bar_w), bar_top)
	if bar_left != null: draw_rect(Rect2(0, 0, bar_w - 1.0, size.y), bar_left)
	if bar_right != null: draw_rect(Rect2(size.x - bar_w + 1.0, 0, bar_w - 1.0, size.y), bar_right)
	var closed := pts.duplicate()
	closed.append(pts[0])
	if ring != null: draw_polyline(closed, ring, 3.0, true)
	elif border_color.a > 0.0: draw_polyline(closed, border_color, 1.0, true)
	if bolts and size.x > 60.0 and size.y > 40.0:
		for b in [Vector2(9, 9), Vector2(size.x - 9, 9), Vector2(9, size.y - 9), Vector2(size.x - 9, size.y - 9)]:
			draw_circle(b, 2.8, Color("3a3e45"))
			draw_circle(b, 1.5, Color("9aa0a8"))
