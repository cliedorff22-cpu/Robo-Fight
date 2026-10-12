## extras_test.gd - every body extra the workshop offers on each body shape,
## in a real window: one picture of the fronts and one of the backs per shape.
##   Godot --path . -s tests/extras_test.gd -- out_prefix [weapon part id|-] [shape,shape...]
extends SceneTree

var _frames := 0
var _prefix := "user://extras"
var _templates: Array = []
var _at := 0
var _back := false
var _bots: Array = []
var _world: Node3D
var _mats
var _base: Dictionary
var _kinds: Array = []
var _cam: Camera3D

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _prefix = args[0]
	var reg := Registry.shared()
	_base = reg.robot(reg.playerId).duplicate(true)
	if args.size() > 1 and args[1] != "-": _base.build = Workshop.set_slot(reg, _base.build, "weapon", args[1])
	_templates = Array(args[2].split(",")) if (args.size() > 2 and args[2] != "-") else Workshop.TEMPLATES.duplicate()
	if args.size() > 3: _kinds = Array(args[3].split(","))
	_mats = Mats.shared(reg.arena.get("style", {}))
	_world = Node3D.new()
	root.add_child(_world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#14161b")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#8892a8")
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	_world.add_child(sun)
	_world.add_child(Geo.box(30, 0.1, 30).translate(0, -0.05, 0).instance(_mats.lib.steelFloor))
	_cam = Camera3D.new()
	_world.add_child(_cam)
	_cam.fov = 36
	_cam.look_at_from_position(Vector3(3.9, 3.7, 2.6), Vector3(-1.75, 0.1, 0))
	_cam.current = true
	_line_up()

func _line_up() -> void:
	for b in _bots: b.queue_free()
	_bots.clear()
	var reg := Registry.shared()
	var tpl: String = _templates[_at]
	var kinds: Array = _kinds if not _kinds.is_empty() else [""] + Workshop.EXTRAS
	var cols := 4 if kinds.size() > 4 else 2
	# A few of them: closer in.
	if kinds.size() <= 4: _cam.look_at_from_position(Vector3(2.6, 1.9, 1.5) if not _back else Vector3(2.6, 1.9, 1.5), Vector3(-0.85, 0.1, 0))
	for i in kinds.size():
		var def: Dictionary = _base.duplicate(true)
		def.body = Workshop.fit_body(reg, {"template": tpl, "extras": [{"type": kinds[i]}] if kinds[i] != "" else []}, def.build)
		var asm := Build.assemble_robot(reg, def)
		var rig := RobotRig.at_rest(asm)
		var view := RobotView.new(asm, rig, _mats)
		_world.add_child(view)
		view.position = Vector3((i / cols) * -1.75, rig.layout.spawnY, ((i % cols) - (cols - 1) / 2.0) * 1.5)
		if _back: view.rotation.y = PI * 0.8
		var tag := Label3D.new()
		tag.text = "%s · %s" % [tpl, kinds[i] if kinds[i] != "" else "plain"]
		if kinds.size() <= 4: tag.font_size = 26
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.font_size = 40
		tag.pixel_size = 0.003
		tag.position = Vector3(0, 0.62, 0)
		view.add_child(tag)
		_bots.append(view)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 40: return false
	_frames = 0
	var out := "%s_%s_%s.png" % [_prefix, _templates[_at], "back" if _back else "front"]
	root.get_texture().get_image().save_png(out)
	print("saved ", out)
	if not _back: _back = true
	else:
		_back = false
		_at += 1
		if _at >= _templates.size(): return true
	_line_up()
	return false
