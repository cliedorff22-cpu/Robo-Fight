## saves_test.gd - the career's saves in a real window: two careers side by
## side, switching between them, restarting one and deleting one.
##   Godot --path . -s tests/saves_test.gd -- out_prefix
extends SceneTree

var _t := 0.0
var _prefix := "user://saves"
var _step := 0
var _wait := 1.5

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, n])
	print("shot ", n)

# Untyped on purpose: compiled before the autoloads exist.
func _cs():
	return current_scene.get("_screen")

func _say(what: String) -> void:
	var c = _cs().get("career")
	print(what, ": view=", _cs().get("view"), " slot=", _cs().get("slot"), " stored slot=", Store.career_slot(),
		" team=", c.team if c != null else "-", " fights=", c.stats.fights if c != null else "-", " cash=", c.cash if c != null else "-")

func _wipe() -> void:
	for n in range(1, Store.CAREER_SLOTS + 1): Store.remove(Store.career_key(n))
	Store.remove(Store.CAREER_SLOT)

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
			_wipe()
			game.request = {"screen": "career"}
			change_scene_to_file("res://scenes/main.tscn")
			_wait = 2.5
		1:
			_say("nothing saved")
			_shot("new")
			_cs().call("do_start", "Alpha Racing", null, 11)
			_wait = 2.0
		2:
			_say("first career")
			_cs().call("do_simulate")
			_cs().call("do_continue")
			current_scene.call("go", "career/saves")
			_wait = 2.0
		3:
			_say("list")
			_shot("list_one")
			_cs().call("do_new", 2)
		4:
			_say("new form")
			_shot("new_two")
			_cs().call("do_start", "Beta Works", 50000.0, 22)
			_wait = 2.0
		5:
			_say("second career")
			_shot("hub_two")
			current_scene.call("go", "career/saves")
			_wait = 2.0
		6:
			_shot("list_two")
			_cs().call("do_open", 1)
			_wait = 2.0
		7:
			_say("back in the first")
			# The workshop, then a switch: its draft must not follow.
			current_scene.call("go", "career/workshop")
			_wait = 2.5
		8:
			_cs().call("do_open", 2)
			_wait = 2.0
		9:
			_say("switched from the workshop")
			_cs().call("do_restart", 1)
			_wait = 2.0
		10:
			_say("first restarted")
			_shot("restarted")
			_cs().call("do_delete", 1)
			_wait = 2.0
		11:
			_say("first deleted")
			_shot("list_after_delete")
			print("saves left: ", range(1, Store.CAREER_SLOTS + 1).filter(func(n): return Store.has(Store.career_key(n))))
			_cs().call("do_delete", 2)
			_wait = 1.5
		12:
			_say("all deleted")
			_wipe()
			return true
	_step += 1
	return false
