## gfx_bench.gd - the frame rate of a real fight, in a real window.
##
## Runs the fight scene (AI against AI, a fixed seed) over the whole screen
## with its refresh lock off, measures every frame of the live fight and saves
## pictures.
##   Godot --disable-vsync --path . -s tests/gfx_bench.gd -- out_prefix [venue] [layout] [red] [blue] [camera] [seconds] [setting=value ...] [bench=intro]
## Settings given here are for this run only - nothing is saved.
extends SceneTree

var _prefix := "user://gfx"
var _cam := ""
var _seconds := 20.0
var _overrides := {}
var _booted := false
var _started := false
var _measuring := false
var _t := 0.0
var _frames := PackedFloat32Array()
var _gpu := PackedFloat32Array()
var _cpu := PackedFloat32Array()
var _shots := 0
var _last_usec := 0
var _slow := []                # [seconds in, ms] of every frame over 25 ms
var _skip := false             # the frame after a picture was saved is not the game's
var _proc := 0.0
var _phys := 0.0
var _intro := false

func _process(_dt: float) -> bool:
	if not _booted:
		_booted = true
		var args := OS.get_cmdline_user_args()
		var plain := []
		for a in args:
			if a.contains("="): _overrides[a.get_slice("=", 0)] = a.get_slice("=", 1)
			else: plain.append(a)
		if plain.size() > 0: _prefix = plain[0]
		var req := {"venue": plain[1] if plain.size() > 1 else "world", "layout": plain[2] if plain.size() > 2 else "classic",
			"red": plain[3] if plain.size() > 3 else "grim_reaper", "blue": plain[4] if plain.size() > 4 else "gorefest",
			"seed": 7, "driver": "ai"}
		_cam = plain[5] if plain.size() > 5 else "chase"
		_seconds = float(plain[6]) if plain.size() > 6 else 20.0
		var game := root.get_node("Game")
		var settings: Dictionary = game.get("settings")
		# Quiet, and no reel at the end: this measures the fight.
		settings["sound"] = false
		settings["commentary"] = "off"
		var bench: String = _overrides.get("bench", "")
		for k in _overrides:
			if k == "bench": continue
			var v = _overrides[k]
			settings[k] = (v == "true") if (v == "true" or v == "false") else v
		game.call("apply_settings")
		# The whole screen, whatever else is on it: a borderless window the
		# size of the display (full screen proper needs the app in front).
		_overrides.erase("bench")
		_intro = bench == "intro"
		root.borderless = true
		root.position = Vector2i.ZERO
		root.size = DisplayServer.screen_get_size()
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
		game.start_fight(req)
		return false
	var scene := current_scene
	# Untyped on purpose: this script is compiled before the autoloads exist.
	if scene == null or scene.get("_ready_to_run") != true: return false
	var fs = scene
	var now := Time.get_ticks_usec()
	var dt := (now - _last_usec) / 1e6
	_last_usec = now
	if not _started:
		_started = true
		if _cam != "": fs.cam.select(_cam)
		# "bench=intro": the intro card (depth of field on), not the fight.
		if not _intro: fs.do_action("start")
		return false
	if not _measuring and _intro:
		_t += dt
		if _t >= 1.5:
			_measuring = true
			_t = 0.0
		return false
	if not _measuring:
		# The countdown is over and the first second's hitches (shaders
		# compiling, textures arriving) are behind us.
		if fs.fight.bout.phase == "live":
			_t += dt
			if _t >= 1.5:
				_measuring = true
				_t = 0.0
		return false
	_t += dt
	if _skip: _skip = false
	else:
		_frames.append(dt * 1000.0)
		if dt > 0.025: _slow.append("%.1fs %.0fms" % [_t, dt * 1000.0])
		_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var vp := root.get_viewport_rid()
	_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
	var due := [_seconds * 0.25, _seconds * 0.6, _seconds * 0.95]
	if _shots < due.size() and _t >= due[_shots]:
		root.get_texture().get_image().save_png("%s_%d.png" % [_prefix, _shots])
		_shots += 1
		_skip = true
	if _t < _seconds: return false
	var sorted := _frames.duplicate()
	sorted.sort()
	var n := sorted.size()
	var total := 0.0
	for f in _frames: total += f
	var worst := 0.0
	var k := maxi(1, n / 100)
	for i in k: worst += sorted[n - 1 - i]
	var gpu := 0.0
	for g in _gpu: gpu += g
	var cpu := 0.0
	for c in _cpu: cpu += c
	var size := root.size
	print("BENCH %s  %dx%d  avg %.1f fps  median %.2f ms  1%% low %.1f fps  gpu %.2f ms  render-cpu %.2f ms  frames %d  draws %d  prims %d  %s" % [
		_prefix.get_file(), size.x, size.y, n / (total / 1000.0), sorted[n / 2], 1000.0 / (worst / k), gpu / n, cpu / n, n,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME), str(_overrides)])
	print("      p90 %.2f ms  p99 %.2f ms  max %.1f ms  over 33 ms: %d  over 16.7 ms: %d" % [sorted[n * 9 / 10], sorted[n * 99 / 100], sorted[n - 1],
		Array(sorted).filter(func(f): return f > 33.4).size(), Array(sorted).filter(func(f): return f > 16.7).size()])
	print("      script+engine per frame %.2f ms, per physics step %.2f ms (120 steps a second)" % [_proc / n, _phys / n])
	print("      slow frames: ", ", ".join(_slow.slice(0, 40)))
	return true
