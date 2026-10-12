## robot_fx_test.gd - the robot's own shaders, a robot at a time: as built
## with its weapon at speed (the spinner blur), half worn with three fresh
## hits still glowing, and wrecked with the weapon half way into its blur.
##   Godot --path . -s tests/robot_fx_test.gd -- out_prefix robot_id [robot_id ...] [setting=value ...]
extends SceneTree

var _prefix := "user://robot_fx"
var _ids: Array = []
var _at := 0
var _frames := 0
var _world: Node3D
var _bots: Array = []
var _views: Array = []
var _mats

func _initialize() -> void:
	var settings := {}
	for a in OS.get_cmdline_user_args():
		if a.contains("="):
			var v := a.get_slice("=", 1)
			settings[a.get_slice("=", 0)] = (v == "true") if (v == "true" or v == "false") else v
		elif _ids.is_empty() and _prefix == "user://robot_fx": _prefix = a
		else: _ids.append(a)
	RobotFx.apply_settings(settings)
	var reg := Registry.shared()
	_mats = Mats.shared(reg.arena.get("style", {}))
	_world = Node3D.new()
	root.add_child(_world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#2a2f3a")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#aab2c4")
	env.ambient_light_energy = 0.7
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = ImageTexture.create_from_image(Mats.studio_panorama())
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_hdr_threshold = 0.95
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)
	for spec in [[Vector3(-40, 30, 0), 1.3], [Vector3(-20, -150, 0), 0.5], [Vector3(60, 100, 0), 0.5]]:
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = spec[0]
		sun.light_energy = spec[1]
		_world.add_child(sun)
	var cam := Camera3D.new()
	_world.add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.3
	cam.position = Vector3(0, 0, 10)
	cam.current = true
	_show()

func _show() -> void:
	for b in _bots: b.queue_free()
	_bots.clear()
	_views.clear()
	var reg := Registry.shared()
	var asm := Build.assemble_robot(reg, reg.robot(_ids[_at]))
	for k in 3:
		var view := RobotView.new(asm, RobotRig.at_rest(asm), _mats)
		var holder := Node3D.new()
		holder.position = Vector3((k - 1) * 1.3, -0.1, 0)
		holder.rotation = Vector3(0.55, 0, 0)
		view.rotation = Vector3(0, -0.9, 0)
		holder.add_child(view)
		_world.add_child(holder)
		_bots.append(holder)
		_views.append(view)
	_frames = 0

# Wear a robot's armour down to `cond`, with a hit on each of its first panels.
func _batter(view, cond: float, hits: int) -> void:
	var n := 0
	for key in view.panel_meshes:
		if not str(key).begins_with("armor."): continue
		for mi in view.panel_meshes[key]:
			if n < hits:
				var box: AABB = mi.mesh.get_aabb()
				view.dent(key, mi.global_transform * (box.get_center() + box.size * Vector3(0.2, 0.3, 0.15)), 0.016)
				n += 1
		view.set_panel_condition(key, cond)

func _process(dt: float) -> bool:
	_frames += 1
	if _frames == 3:
		_batter(_views[1], 0.55, 3)
		_batter(_views[2], 0.12, 5)
	for k in 3:
		_views[k]._update_blur([400.0, 400.0, 41.0][k], dt)
		_views[k].update_fx(dt * 0.05)
	if _frames < 40: return false
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, _ids[_at]])
	_at += 1
	if _at >= _ids.size(): return true
	_show()
	return false
