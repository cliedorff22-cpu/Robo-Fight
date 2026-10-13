## picker_test.gd - opens and closes every colour picker in the workshop's
## Body & paint tab in a real window, then picks from every drop-down on both
## tabs with the keyboard. Each of them redraws the tab it sits in; a colour
## picker doing that while its popup closed used to take the engine down.
##   Godot --path . -s tests/picker_test.gd
extends SceneTree

var _t := 0.0
var _step := 0
var _wait := 1.5
var _index := 0
var _open: ColorPickerButton
var _tab := "body"
var _drops := 0
var _took := 0
var _before

func _workshop():
	# Untyped on purpose: compiled before the autoloads exist.
	return current_scene.get("_screen").get("_workshop")

func _pickers(node: Node, out: Array = []) -> Array:
	for c in node.get_children():
		if c is ColorPickerButton: out.append(c)
		_pickers(c, out)
	return out

func _selects(node: Node, out: Array = []) -> Array:
	for c in node.get_children():
		if c is OptionButton and not c.disabled and c.item_count > 1: out.append(c)
		_selects(c, out)
	return out

func _key(action: String) -> void:
	for down in [true, false]:
		var e := InputEventAction.new()
		e.action = action
		e.pressed = down
		Input.parse_input_event(e)

func _process(dt: float) -> bool:
	_t += dt
	if _step > 0 and _t < _wait: return false
	_t = 0.0
	_wait = 0.6
	var game := root.get_node("Game")
	match _step:
		0:
			Store.prefix = "test."
			Store.remove(Store.CAREER)
			game.request = {"screen": "career"}
			change_scene_to_file("res://scenes/main.tscn")
			_wait = 2.5
		1:
			current_scene.get("_screen").call("do_start", "Night Shift Robotics", null, 4242)
			_wait = 2.5
		2:
			current_scene.call("go", "career/workshop")
			_wait = 3.0
		3:
			var ws = _workshop()
			ws.set("tab", "body")
			ws.call("_refresh", false)
		4:
			# Open the next picker and move its colour...
			var all := _pickers(_workshop().get("_body"))
			if _index >= all.size():
				var look = _workshop().get("draft").body.get("look")
				if not (look is Dictionary and look.has("anod")):
					print("picker_test: FAIL - the anodising colour was not kept")
					quit(1)
					return true
				print("picker_test: %d pickers opened and closed" % _index)
				_index = 0
				_step = 6
				return false
			_open = all[_index]
			_open.get_popup().popup(Rect2i(200, 200, 300, 400))
			_open.get_picker().color = Color.from_hsv(0.13 * (_index + 1), 0.8, 0.9)
			_open.get_picker().color_changed.emit(_open.get_picker().color)
			_step = 5
			return false
		5:
			# ...then close it, the way a click outside does.
			print("closing picker ", _index)
			_open.get_popup().hide()
			_index += 1
			_step = 4
			return false
		6:
			# Every drop-down of the tab: open it, step to another line, take it.
			var all := _selects(_workshop().get("_body"))
			if _before != null and not is_same(_before, _workshop().get("draft")): _took += 1
			_before = _workshop().get("draft")
			if _index >= all.size():
				_drops += _index
				if _tab == "body":
					_tab = "parts"
					_index = 0
					_workshop().set("tab", "parts")
					_workshop().call("_refresh", false)
					return false
				if _took == 0:
					print("picker_test: FAIL - no drop-down changed the robot")
					quit(1)
					return true
				print("picker_test: %d drop-downs picked from (%d changed the robot), no crash" % [_drops, _took])
				return true
			var ob: OptionButton = all[_index]
			ob.show_popup()
			_step = 7
			return false
		7:
			_key("ui_up" if _index % 2 == 1 else "ui_down")
			_step = 8
			_wait = 0.15
			return false
		8:
			_key("ui_accept")
			_index += 1
			_step = 6
			_wait = 0.3
			return false
	_step += 1
	return false
