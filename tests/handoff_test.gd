## handoff_test.gd - the hand-offs between the menus and the arena, in a real
## window: a tournament set up and simulated, then a career fight fought in
## the arena (tapped out, to keep it short) and its result picked up by the
## career.
##   Godot --path . -s tests/handoff_test.gd -- out_prefix
extends SceneTree

var _t := 0.0
var _prefix := "user://handoff"
var _step := 0
var _wait := 1.5

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, n])
	print("shot ", n)

# Untyped on purpose: compiled before the autoloads exist.
func _screen():
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
			Store.remove(Store.TOURNAMENT)
			game.request = {"screen": "tournament"}
			change_scene_to_file("res://scenes/main.tscn")
			_wait = 2.5
		1:
			_shot("cup_setup")
			print("cup started: ", _screen().call("do_start", 99))
			_wait = 2.0
		2:
			_shot("cup_hub")
			for i in 3: _screen().call("do_simulate")
			_wait = 1.5
		3:
			_shot("cup_later")
			print("cup log: ", _screen().get("cup").log.size(), " fights")
			current_scene.call("go", "career")
			_wait = 1.5
		4:
			_screen().call("do_start", "Handoff Racing", null, 777)
			_wait = 2.0
		5:
			_screen().call("do_fight")
			_wait = 0.5
		6:
			if current_scene == null or current_scene.get("_ready_to_run") != true:
				_wait = 0.3
				return false
			current_scene.call("do_action", "start")
			_wait = 6.0
		7:
			_shot("career_fight")
			current_scene.call("do_action", "tapout")
			current_scene.call("do_action", "tapout")
			_wait = 4.0
		8:
			_shot("career_fight_over")
			print("handed back: ", game.result != null, " phase ", current_scene.fight.bout.phase)
			current_scene.call("do_action", "menu")
			_wait = 2.5
		9:
			_shot("career_after")
			var cs = _screen()
			print("summary: ", cs.get("summary") != null, " won=", cs.get("summary").get("won") if cs.get("summary") != null else "?", " cash ", cs.get("career").cash)
			return true
	_step += 1
	return false
