## scene_test.gd - runs the real fight scene in a window and saves pictures.
##   Godot --path . -s tests/scene_test.gd -- out_prefix [red] [blue] [layout] [venue] [camera] [seconds] [driver]
extends SceneTree

var _t := 0.0
var _prefix := "user://scene"
var _seconds := 16.0
var _cam := ""
var _started := false
var _shots := 0
var _booted := false

func _process(dt: float) -> bool:
	if not _booted:
		_booted = true
		var args := OS.get_cmdline_user_args()
		if args.size() > 0: _prefix = args[0]
		var game := root.get_node("Game")
		var req := {"red": args[1] if args.size() > 1 else "player_default", "blue": args[2] if args.size() > 2 else "grim_reaper",
			"layout": args[3] if args.size() > 3 else "classic", "venue": args[4] if args.size() > 4 else "pro", "seed": 7}
		_cam = args[5] if args.size() > 5 else ""
		_seconds = float(args[6]) if args.size() > 6 else 16.0
		if args.size() > 7 and args[7] == "ai": req.driver = "ai"
		# A ninth word "touch": the on-screen controls, as on a phone.
		if args.size() > 8 and args[8] == "touch":
			game.set("touch", true)
			load("res://scripts/ui/hud.gd").set("touch", true)
		game.start_fight(req)
		return false
	_t += dt
	var scene := current_scene
	# Untyped on purpose: this script is compiled before the autoloads exist.
	if scene == null or scene.get("_ready_to_run") != true: return false
	var fs = scene
	if not _started:
		_started = true
		_t = 0.0
		if _cam != "": fs.cam.select(_cam)
		return false
	var due := [1.0, 2.5, 5.0, _seconds * 0.6, _seconds]
	if _shots == 1 and fs.fight.bout.phase == "idle": fs.do_action("start")
	if _shots < due.size() and _t >= due[_shots]:
		root.get_texture().get_image().save_png("%s_%d.png" % [_prefix, _shots])
		_shots += 1
		if _shots == due.size():
			print("fps %.0f, sim %.1fs, phase %s, booth said %d lines" % [Engine.get_frames_per_second(), fs.fight.sim_time, fs.fight.bout.phase, fs.booth.said.size()])
			for l in fs.booth.said.slice(0, 6): print("   ", l.who, ": ", l.text)
			return true
	return false
