## switch.gd - an on/off switch.
class_name Switch
extends Control

signal toggled(on: bool)

var on := false: set = set_on

func _init(start := false) -> void:
	on = start
	custom_minimum_size = Vector2(40, 22)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func set_on(v: bool) -> void:
	on = v
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		on = not on
		toggled.emit(on)
		accept_event()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UI.ACCENT if on else Color(1, 1, 1, 0.12))
	var k := Rect2(size.x - 19 if on else 3, 3, 16, size.y - 6)
	draw_rect(k, UI.INK if on else Color("e7ecf4"))
