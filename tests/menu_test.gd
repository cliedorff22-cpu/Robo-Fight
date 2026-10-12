## menu_test.gd - opens the real menus in a window on a given screen and
## saves a picture.
##   Godot --path . -s tests/menu_test.gd -- out.png [route] [seconds]
extends SceneTree

var _t := 0.0
var _out := "user://menu.png"
var _seconds := 2.5
var _booted := false

func _process(dt: float) -> bool:
	if not _booted:
		_booted = true
		var args := OS.get_cmdline_user_args()
		if args.size() > 0: _out = args[0]
		var game := root.get_node("Game")
		game.request = {"screen": args[1] if args.size() > 1 else ""}
		_seconds = float(args[2]) if args.size() > 2 else 2.5
		change_scene_to_file("res://scenes/main.tscn")
		return false
	_t += dt
	if _t >= _seconds:
		root.get_texture().get_image().save_png(_out)
		print("saved ", _out)
		return true
	return false
