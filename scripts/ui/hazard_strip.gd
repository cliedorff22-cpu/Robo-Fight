## hazard_strip.gd - a run of yellow-and-black hazard stripes.
class_name HazardStrip
extends Control

var stripe := 10.0
var color_a := UI.ACCENT
var color_b := UI.INK

func _init(height := 5.0, stripe_w := 10.0) -> void:
	custom_minimum_size = Vector2(0, height)
	stripe = stripe_w
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), color_b)
	var h := size.y
	var x := -h - stripe * 2.0
	while x < size.x + h:
		draw_colored_polygon(PackedVector2Array([Vector2(x, h), Vector2(x + stripe, h), Vector2(x + stripe + h, 0), Vector2(x + h, 0)]), color_a)
		x += stripe * 2.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: queue_redraw()
