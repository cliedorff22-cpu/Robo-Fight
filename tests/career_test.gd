## career_test.gd - walks the career's screens in a real window and saves a
## picture of each: new career, the hub and its tabs, a simulated fight, the
## pit, the workshop.
##   Godot --path . -s tests/career_test.gd -- out_prefix
extends SceneTree

var _t := 0.0
var _prefix := "user://career"
var _step := 0
var _wait := 1.5

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, n])
	print("shot ", n)

func _career():
	# Untyped on purpose: compiled before the autoloads exist.
	return current_scene.get("_screen")

func _process(dt: float) -> bool:
	_t += dt
	if _step > 0 and _t < _wait: return false
	_t = 0.0
	_wait = 1.5
	var game := root.get_node("Game")
	match _step:
		0:
			var args := OS.get_cmdline_user_args()
			if args.size() > 0: _prefix = args[0]
			Store.prefix = "test."
			Store.remove(Store.CAREER)
			game.request = {"screen": "career"}
			change_scene_to_file("res://scenes/main.tscn")
			_wait = 2.5
		1:
			_shot("new")
			_career().call("do_start", "Night Shift Robotics", null, 4242)
			_wait = 2.5
		2:
			_shot("hub")
			var cs = _career()
			for tab in ["bracket", "results", "rivals", "money", "market", "trophies", "settings"]:
				cs.set("tab", tab)
				cs.call("show_screen")
			cs.set("tab", "market")
			cs.call("show_screen")
		3:
			_shot("market")
			_career().call("do_simulate")
			_wait = 2.0
		4:
			_shot("result")
			_career().call("do_continue")
			_wait = 2.5
		5:
			_shot("pit")
			current_scene.call("go", "career/workshop")
			_wait = 3.0
		6:
			_shot("workshop")
			var ws = _career().get("_workshop")
			ws.set("tab", "body")
			ws.call("_refresh", false)
		7:
			_shot("workshop_body")
			var ws = _career().get("_workshop")
			ws.call("_fit", "weapon", null)
			ws.call("_select_slot", "armor:front:0") if false else null
			ws.set("tab", "spares")
			ws.call("_refresh", false)
		8:
			_shot("workshop_spares")
			current_scene.call("go", "career")
			var cs = _career()
			cs.set("tab", "standings")
			cs.call("show_screen")
			_wait = 2.0
		9:
			_shot("hub2")
			print("career ok: season ", _career().get("career").seasonIndex, " cash ", _career().get("career").cash)
			return true
	_step += 1
	return false
