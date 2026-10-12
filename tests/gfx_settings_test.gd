## gfx_settings_test.gd - pictures of the Graphics settings: on the Settings
## page of the menus, and in a fight's pause screen.
##   Godot --path . -s tests/gfx_settings_test.gd -- out_prefix
## Nothing is saved: it only looks.
extends SceneTree

var _prefix := "user://gfx_settings"
var _t := 0.0
var _step := 0

# Scroll the page so the Graphics heading is at the top of what shows.
func _to_graphics() -> void:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text != "GRAPHICS" or not (l as Label).is_visible_in_tree(): continue
		var p: Node = l.get_parent()
		while p != null and not (p is ScrollContainer): p = p.get_parent()
		if p == null: continue
		var sc := p as ScrollContainer
		sc.scroll_vertical += int((l as Label).global_position.y - sc.global_position.y) - 8

func _process(dt: float) -> bool:
	_t += dt
	var game := root.get_node("Game")
	match _step:
		0:
			var args := OS.get_cmdline_user_args()
			if args.size() > 0: _prefix = args[0]
			game.request = {"screen": "settings"}
			change_scene_to_file("res://scenes/main.tscn")
			_step = 1
			_t = 0.0
		1:
			if _t > 1.5:
				_to_graphics()
				_step = 2
				_t = 0.0
		2:
			if _t > 0.5:
				root.get_texture().get_image().save_png("%s_menu.png" % _prefix)
				game.settings["sound"] = false
				game.start_fight({"venue": "world", "red": "grim_reaper", "blue": "gorefest", "seed": 7, "driver": "ai"})
				_step = 3
				_t = 0.0
		3:
			# Untyped on purpose: this script is compiled before the autoloads exist.
			var scene = current_scene
			if scene != null and scene.get("_ready_to_run") == true and _t > 1.0:
				scene.do_action("pause")
				_step = 4
				_t = 0.0
		4:
			if _t > 0.6:
				_to_graphics()
				_step = 5
				_t = 0.0
		5:
			if _t > 0.5:
				root.get_texture().get_image().save_png("%s_pause.png" % _prefix)
				print("saved ", _prefix)
				return true
	return false
