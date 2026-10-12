## gfx_shots.gd - the same pictures of the same fight, for before and after.
##
## Runs the real fight scene (AI against AI, a fixed seed) and saves a picture
## of the intro card, of the fight from each camera at fixed match times, and
## of the replay after the bell.
##   Godot --path . -s tests/gfx_shots.gd -- out_prefix [venue] [layout] [red] [blue] [setting=value ...] [shots=N]
## Settings given here are for this run only - nothing is saved.
extends SceneTree

# [match seconds, camera, name]
const PLAN := [[4.0, "chase", "chase"], [5.5, "overhead", "top"], [7.0, "arena_a", "arena"], [9.5, "arena_b", "corner"], [12.0, "stands", "stands"],
	[14.0, "overhead", "overhead"], [16.5, "chase", "chase2"]]

var _prefix := "user://shots"
var _booted := false
var _step := 0                 # 0 intro, 1 fight, 2 waiting for the reel, 3 in the reel
var _t := 0.0
var _next := 0
var _stop := 99                # "shots=N": only the first N fight pictures, no replay

func _shot(name: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, name])

func _process(dt: float) -> bool:
	if not _booted:
		_booted = true
		var plain := []
		var game := root.get_node("Game")
		var settings: Dictionary = game.get("settings")
		settings["sound"] = false
		settings["commentary"] = "captions"
		for a in OS.get_cmdline_user_args():
			if a.contains("="):
				var v := a.get_slice("=", 1)
				if a.begins_with("shots="):
					_stop = int(v)
					continue
				settings[a.get_slice("=", 0)] = (v == "true") if (v == "true" or v == "false") else v
			else: plain.append(a)
		game.call("apply_settings")
		# The whole screen: a borderless window the size of the display.
		root.borderless = true
		root.position = Vector2i.ZERO
		root.size = DisplayServer.screen_get_size()
		if plain.size() > 0: _prefix = plain[0]
		game.start_fight({"venue": plain[1] if plain.size() > 1 else "world", "layout": plain[2] if plain.size() > 2 else "classic",
			"red": plain[3] if plain.size() > 3 else "grim_reaper", "blue": plain[4] if plain.size() > 4 else "gorefest", "seed": 7, "driver": "ai"})
		return false
	var scene := current_scene
	# Untyped on purpose: this script is compiled before the autoloads exist.
	if scene == null or scene.get("_ready_to_run") != true: return false
	var fs = scene
	_t += dt
	match _step:
		0:
			if _t < 2.0: return false
			_shot("intro")
			fs.do_action("start")
			fs.cam.select(PLAN[0][1])
			_step = 1
		1:
			if fs.fight.bout.phase != "live": return false
			var mt: float = 180.0 - fs.fight.bout.clockS
			if mt < PLAN[_next][0]: return false
			_shot(PLAN[_next][2])
			_next += 1
			if _next >= _stop: return true
			if _next < PLAN.size(): fs.cam.select(PLAN[_next][1])
			else:
				fs.fight.bout.tap_out(fs.fight.red.id)
				_step = 2
				_t = 0.0
		2:
			if fs.fight.replay.playing:
				_step = 3
				_t = 0.0
			elif _t > 8.0:
				print("no reel to picture")
				return true
		3:
			if _t < 2.3: return false
			_shot("replay")
			print("shots saved: ", _prefix)
			return true
	return false
