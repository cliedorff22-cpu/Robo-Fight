## arena_test.gd - a live AI v AI fight in a real window, with pictures saved
## along the way.
##   Godot --path . -s tests/arena_test.gd -- out_prefix [red] [blue] [layout] [camera] [seconds]
extends SceneTree

var fight: Fight
var arena_view: ArenaView
var cam: CameraRig
var effects: Effects
var views := {}
var _t := 0.0
var _shots := 0
var _prefix := "user://arena"
var _seconds := 14.0
var _started := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _prefix = args[0]
	var reg := Registry.shared()
	var red_id: String = args[1] if args.size() > 1 else "player_default"
	var blue_id: String = args[2] if args.size() > 2 else "grim_reaper"
	var layout: String = args[3] if args.size() > 3 else "classic"
	var cam_id: String = args[4] if args.size() > 4 else "chase"
	_seconds = float(args[5]) if args.size() > 5 else 14.0
	var mats := Mats.shared(reg.arena.get("style", {}))
	fight = Fight.new(reg, {"red": reg.robot(red_id), "blue": reg.robot(blue_id), "seed": 7, "redAI": true,
		"where": {"venue": "pro", "layout": layout}, "mats": mats})
	root.add_child(fight)
	root.add_child(Stage.new(fight.arena))
	arena_view = ArenaView.new(fight.arena, fight.world, fight.hazards, mats)
	root.add_child(arena_view)
	for u in fight.units:
		var v := RobotView.new(u.assembled, u.sim.rig, mats)
		root.add_child(v)
		views[u.id] = v
	effects = Effects.new(fight.bus, views, fight.debris, fight.rng)
	root.add_child(effects)
	cam = CameraRig.new(fight.arena, fight.bus)
	root.add_child(cam)
	cam.select(cam_id)

func _process(dt: float) -> bool:
	_t += dt
	if not _started and _t > 0.5:
		_started = true
		fight.start_match(false)
	for u in fight.units:
		var v: RobotView = views[u.id]
		v.sync(u.sim.global_transform)
		v.update_weapon(u.weapon, dt)
	arena_view.update(dt)
	effects.update(dt)
	cam.update(dt, fight.red.sim.global_transform, false, [fight.red.sim.global_position, fight.blue.sim.global_position])
	arena_view.set_viewpoint(cam.global_position)
	var due := [1.5, _seconds * 0.5, _seconds]
	if _shots < due.size() and _t >= due[_shots]:
		root.get_texture().get_image().save_png("%s_%d.png" % [_prefix, _shots])
		_shots += 1
		if _shots == due.size():
			print("fps %.0f, sim %.1fs" % [Engine.get_frames_per_second(), fight.sim_time])
			return true
	return false
