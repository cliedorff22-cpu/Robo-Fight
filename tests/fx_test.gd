## fx_test.gd - pictures of the effects, made to order: a heavy hit's sparks
## a few frames apart, then a robot smoking and burning.
##   Godot --fixed-fps 60 --path . -s tests/fx_test.gd -- out_prefix [venue] [setting=value ...]
## (--fixed-fps: saving a picture takes a tenth of a second, and the sparks must not fly on meanwhile.)
## Settings given here are for this run only - nothing is saved.
extends SceneTree

var _prefix := "user://fx"
var _booted := false
var _step := 0
var _t := 0.0
var _frame := 0
var _at := Vector3.ZERO

func _shot(name: String) -> void:
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, name])

func _process(dt: float) -> bool:
	if not _booted:
		_booted = true
		var plain := []
		var game := root.get_node("Game")
		var settings: Dictionary = game.get("settings")
		settings["sound"] = false
		settings["commentary"] = "off"
		for a in OS.get_cmdline_user_args():
			if a.contains("="):
				var v := a.get_slice("=", 1)
				settings[a.get_slice("=", 0)] = (v == "true") if (v == "true" or v == "false") else v
			else: plain.append(a)
		game.call("apply_settings")
		root.borderless = true
		root.position = Vector2i.ZERO
		root.size = DisplayServer.screen_get_size()
		if plain.size() > 0: _prefix = plain[0]
		game.start_fight({"venue": plain[1] if plain.size() > 1 else "world", "layout": "classic", "red": "grim_reaper", "blue": "gorefest", "seed": 7, "driver": "ai"})
		return false
	var scene := current_scene
	# Untyped on purpose: this script is compiled before the autoloads exist.
	if scene == null or scene.get("_ready_to_run") != true: return false
	var fs = scene
	_t += dt
	match _step:
		0:
			if _t < 1.0: return false
			fs.do_action("start")
			fs.cam.select("chase")
			_step = 1
		1:
			if fs.fight.bout.phase != "live" or 180.0 - fs.fight.bout.clockS < 1.2: return false
			# A heavy hit on blue's nose, as combat would report it.
			var red: Vector3 = fs.fight.red.sim.global_position
			var blue: Vector3 = fs.fight.blue.sim.global_position
			_at = red.lerp(blue, 0.35) + Vector3(0, 0.25, 0)
			fs.fight.bus.emit("combat:hit", {"kind": "weapon", "attackerId": fs.fight.red.id, "defenderId": fs.fight.blue.id, "targetKey": "armor.1",
				"at": _at, "normal": (red - blue).normalized(), "deliveredJ": 9000.0, "severity": "catastrophic", "hits": [], "failures": []})
			_step = 2
			_frame = 0
		2:
			_frame += 1
			if _frame == 1: _shot("hit_f1")
			elif _frame == 4: _shot("hit_f4")
			elif _frame == 10: _shot("hit_f10")
			elif _frame == 24:
				_shot("hit_f24")
				_step = 5
				_t = 0.0
		5:
			# A second one after a quiet spell: a burst must not need a run-up.
			if _t < 3.0: return false
			var red2: Vector3 = fs.fight.red.sim.global_position
			_at = red2 + Vector3(0.0, 0.45, 0.0)
			fs.fight.bus.emit("combat:hit", {"kind": "weapon", "attackerId": fs.fight.blue.id, "defenderId": fs.fight.red.id, "targetKey": "armor.1",
				"at": _at, "normal": Vector3.UP, "deliveredJ": 6000.0, "severity": "heavy", "hits": [], "failures": []})
			_step = 6
			_frame = 0
		6:
			_frame += 1
			if _frame == 1: _shot("hit2_f1")
			elif _frame == 3: _shot("hit2_f3")
			elif _frame == 8: _shot("hit2_f8")
			elif _frame == 20:
				_shot("hit2_f20")
				# What it left on the deck, from above: a part failing, a shove, and the two hits.
				var mid: Vector3 = fs.fight.red.sim.global_position.lerp(fs.fight.blue.sim.global_position, 0.5)
				fs.fight.bus.emit("combat:partFailed", {"botId": fs.fight.blue.id, "key": "motor", "category": "motor", "at": mid + Vector3(0.8, 0.2, 0.6), "normal": Vector3.UP})
				fs.fight.bus.emit("combat:hit", {"kind": "ram", "attackerId": fs.fight.red.id, "defenderId": fs.fight.blue.id, "targetKey": "armor.1",
					"at": mid + Vector3(-0.9, 0.1, -0.5), "normal": Vector3.UP, "deliveredJ": 900.0, "severity": "hit", "hits": [], "failures": []})
				fs.fight.bus.emit("combat:hit", {"kind": "weapon", "attackerId": fs.fight.red.id, "defenderId": fs.fight.blue.id, "targetKey": "armor.1",
					"at": mid + Vector3(0.0, 0.2, -1.4), "normal": Vector3.UP, "deliveredJ": 3000.0, "severity": "heavy", "hits": [], "failures": []})
				fs.cam.select("overhead")
				_step = 7
				_frame = 0
		7:
			_frame += 1
			if _frame == 12: _shot("marks_hot")
			elif _frame == 150:
				_shot("marks")
				# Now set blue alight.
				for key in ["battery", "motor", "electronics"]: fs.views[fs.fight.blue.id].set_panel_condition(key, 0.1)
				fs.cam.select("arena_a")
				_step = 3
				_t = 0.0
		3:
			if _t < 2.5: return false
			_shot("fire")
			fs.cam.select("chase")
			_step = 4
			_t = 0.0
		4:
			if _t < 1.0: return false
			_shot("fire_chase")
			print("fx pictures saved: ", _prefix)
			return true
	return false
