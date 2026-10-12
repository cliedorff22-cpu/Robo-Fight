## fight_test.gd - AI v AI in the real physics, with no window.
##   Godot --headless --fixed-fps 10 --path . -s tests/fight_test.gd -- [red] [blue] [seed] [layout] [seconds]
## (--fixed-fps runs it as fast as the machine can, 12 physics ticks a frame.)
extends SceneTree

var fight: Fight
var _ticks := 0
var _limit := 0
var _hits := 0
var _t0 := 0
var _started := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var reg := Registry.shared()
	var red_id: String = args[0] if args.size() > 0 else "player_default"
	var blue_id: String = args[1] if args.size() > 1 else "grim_reaper"
	var match_seed := int(args[2]) if args.size() > 2 else 7
	var layout: String = args[3] if args.size() > 3 else "classic"
	_limit = int((float(args[4]) if args.size() > 4 else 200.0) * 120.0)
	fight = Fight.new(reg, {"red": reg.robot(red_id), "blue": reg.robot(blue_id), "seed": match_seed, "redAI": true,
		"where": {"venue": "pro", "layout": layout}})
	root.add_child(fight)
	fight.bus.on(Bus.HIT, func(e):
		_hits += 1
		if _hits <= 12 or e.severity != "scratch":
			var hp := 0.0
			for h in e.hits: hp += h.hpLost
			print("  %6.2fs %-6s %s -> %s [%s] %.0f hp %s" % [fight.sim_time, e.kind, e.get("attackerId", e.get("hazardId")), e.defenderId, e.targetKey, hp, e.severity]))
	fight.bus.on(Bus.MATCH_END, func(r): print("END: ", JSON.stringify(r).substr(0, 600)))
	fight.bus.on(Bus.HAZARD_FIRE, func(e): print("  %6.2fs hazard %s" % [fight.sim_time, e.id]))
	fight.bus.on(Bus.REF_COUNT, func(e): print("  %6.2fs count %s" % [fight.sim_time, JSON.stringify(e)]))
	Engine.max_fps = 0
	Engine.physics_ticks_per_second = 120
	Engine.max_physics_steps_per_frame = 12
	_t0 = Time.get_ticks_msec()

func _physics_process(_dt: float) -> bool:
	_ticks += 1
	if not _started and _ticks > 60:
		_started = true
		for u in fight.units:
			var p: Vector3 = u.sim.global_position
			print("settled %s: y=%.3f (spawn %.3f) wheels=%d up=%.2f" % [u.id, p.y, u.sim.spawn_pos.y, u.sim.grounded_count, u.sim.uprightness()])
		fight.start_match(false)
	if _ticks % 1200 == 0:
		var line := "t=%5.1f clock=%5.1f %s" % [fight.sim_time, fight.bout.clockS, fight.bout.phase]
		for u in fight.units:
			var p: Vector3 = u.sim.global_position
			line += " | %s (%.1f,%.2f,%.1f) v=%.1f h=%.2f %s" % [u.id.substr(0, 8), p.x, p.y, p.z, u.sim.speed_mps(), AIBridge.health_of(u.assembled), u.weapon.phase]
		print(line)
	if fight.bout.phase == Match.ENDED or _ticks > _limit:
		print("stats: ", fight.combat.stats, " clamped: ", fight.units.map(func(u): return u.sim.clamped))
		print("%d ticks in %d ms" % [_ticks, Time.get_ticks_msec() - _t0])
		return true
	return false
