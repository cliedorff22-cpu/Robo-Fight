## keys_test.gd - a quick fight driven with real key presses: start, fight,
## pause, back to the menu with M, a second fight, the next opponent with O.
##   Godot --path . -s tests/keys_test.gd
## Leaving the fight by key is its own path through the scene (the key is
## still being handled when the scene goes), so it gets its own check.
extends SceneTree

var _t := 0.0
var _step := 0

func _key(code: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = down
		Input.parse_input_event(e)

func _fight_ready() -> bool:
	var scene := current_scene
	return scene != null and scene.get("_ready_to_run") == true

func _process(dt: float) -> bool:
	_t += dt
	var game := root.get_node("Game")
	match _step:
		0:
			game.settings["sound"] = false
			game.start_fight({"venue": "pro", "layout": "sawmill", "red": "meridian", "blue": "coldsnap", "seed": 7})
			_step = 1
		1, 4:
			if _fight_ready():
				_t = 0.0
				_key(KEY_ENTER)
				_step += 1
		2:
			if _t > 5.0:
				_key(KEY_M)
				_t = 0.0
				_step = 3
		3:
			if _t > 1.5:
				print("after M: scene is ", current_scene.get_script().resource_path if current_scene != null else "none")
				game.start_fight({"venue": "rookie", "red": "meridian", "blue": "coldsnap", "seed": 8})
				_step = 4
		5:
			if _t > 3.0:
				_key(KEY_O)
				_t = 0.0
				_step = 6
		6:
			if _t > 1.0 and _fight_ready():
				print("after O: fighting ", current_scene.fight.blue.assembled.name)
				_key(KEY_M)
				_t = 0.0
				_step = 7
		7:
			if _t > 1.5:
				print("back at: ", current_scene.get_script().resource_path if current_scene != null else "none")
				return true
	return false
