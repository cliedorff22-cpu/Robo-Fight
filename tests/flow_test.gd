## flow_test.gd - the whole loop in a real window: menu -> Quick Fight ->
## fight -> back to the menu, with pictures on the way.
##   Godot --path . -s tests/flow_test.gd -- out_prefix
extends SceneTree

var _t := 0.0
var _prefix := "user://flow"
var _step := 0

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, n])

func _process(dt: float) -> bool:
	_t += dt
	var game := root.get_node("Game")
	var scene = current_scene
	match _step:
		0:
			var args := OS.get_cmdline_user_args()
			if args.size() > 0: _prefix = args[0]
			Store.prefix = "test."          # leave the player's own picks alone
			game.request = {"screen": "quick"}
			change_scene_to_file("res://scenes/main.tscn")
			_step = 1
			_t = 0.0
		1:
			if _t > 2.5:
				_shot("quick")
				# Untyped on purpose: compiled before the autoloads exist.
				var quick = scene.get("_screen")
				quick.call("choose", "blue", "riptooth", true)
				quick.call("start_fight")
				_step = 2
				_t = 0.0
		2:
			if scene != null and scene.get("_ready_to_run") == true and _t > 1.0:
				scene.call("do_action", "start")
				_step = 3
				_t = 0.0
		3:
			if _t > 9.0:
				_shot("fight")
				print("fight: sim %.1fs phase %s" % [scene.fight.sim_time, scene.fight.bout.phase])
				scene.call("do_action", "pause")
				_step = 4
				_t = 0.0
		4:
			if _t > 0.6:
				_shot("pause")
				scene.call("do_action", "menu")
				_step = 5
				_t = 0.0
		5:
			if _t > 2.0:
				_shot("back")
				print("back at: ", scene.get_script().resource_path, " route ", scene.call("current_route"))
				return true
	return false
