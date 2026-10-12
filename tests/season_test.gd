## season_test.gd - a whole season through the career's own buttons, in a
## real window: every fight simulated, every pit stop taken, then the
## off-season (the background job) and into season two. Then the advisor.
##   Godot --path . -s tests/season_test.gd -- out_prefix
extends SceneTree

var _t := 0.0
var _prefix := "user://season"
var _step := 0
var _wait := 1.0
var _fights := 0
var _t0 := 0

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, n])
	print("shot ", n)

# Untyped on purpose: compiled before the autoloads exist.
func _cs():
	return current_scene.get("_screen")

func _overlay_up() -> bool:
	for c in current_scene.get_children():
		if c is ColorRect and c.get_script() != null and str(c.get_script().resource_path).ends_with("job_overlay.gd"): return true
	return false

func _process(dt: float) -> bool:
	_t += dt
	if _step > 0 and _t < _wait: return false
	_t = 0.0
	_wait = 0.05
	var game := root.get_node("Game")
	match _step:
		0:
			var args := OS.get_cmdline_user_args()
			if args.size() > 0: _prefix = args[0]
			Store.prefix = "test."
			Store.remove(Store.CAREER)
			game.request = {"screen": "career"}
			change_scene_to_file("res://scenes/main.tscn")
			_wait = 2.0
		1:
			_cs().call("do_start", "Season Test", null, 31337)
			_wait = 1.0
		2:
			# One thing per frame: a fight, its result, its pit stop.
			var cs = _cs()
			var career = cs.get("career")
			if career.get("seasonOver") == true:
				_shot("season_over")
				print("season 1 done after %d fights: %s" % [_fights, JSON.stringify(career.history[-1]).substr(0, 300)])
				_t0 = Time.get_ticks_msec()
				cs.call("do_next_season")
				_step = 3
				_wait = 1.0
				return false
			if cs.get("summary") != null:
				cs.call("do_continue")
				return false
			if career.get("pit") != null:
				# Through the pit screen itself: the crew's plan, sent out.
				var pit = cs.get("_pit")
				if cs.get("view") != "pit":
					current_scene.call("go", "career/pit")
					return false
				var r = Career.do_pit(Registry.shared(), career, pit.get("plan"))
				if r.get("ok") != true: Career.skip_pit(career)
				cs.call("save")
				current_scene.call("go", "career")
				return false
			if Career.next_fight(Registry.shared(), career) != null:
				cs.call("do_simulate")
				_fights += 1
			else:
				cs.call("show_screen")
			return false
		3:
			if _overlay_up():
				if _fights >= 0:
					_shot("offseason")
					_fights = -1
				_wait = 0.5
				return false
			print("off-season took %d ms" % (Time.get_ticks_msec() - _t0))
			_wait = 1.0
		4:
			var career = _cs().get("career")
			_shot("season2")
			print("now season %s (%s), cash %s, league %s" % [career.seasonIndex, career.season.kind, career.cash, Career.player_league(career)])
			current_scene.call("go", "career/workshop")
			_wait = 2.0
		5:
			_t0 = Time.get_ticks_msec()
			_cs().get("_workshop").call("ask", "season")
			_wait = 1.0
		6:
			if _overlay_up():
				_wait = 0.5
				return false
			var adv = _cs().get("_workshop").get("advice")
			print("advisor took %d ms: %s" % [Time.get_ticks_msec() - _t0, str(adv.get("title")) if adv != null else "nothing"])
			_wait = 1.0
		7:
			_shot("advice")
			return true
	_step += 1
	return false
