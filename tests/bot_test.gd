## bot_test.gd - one robot at a time from every side, in a real window: a
## picture per robot with six views of it (front quarter, side, head on, from
## above, rear quarter, from below).
##   Godot --path . -s tests/bot_test.gd -- out_prefix robot_id [robot_id ...]
## For looking a robot over: what floats, what cuts into what.
extends SceneTree

const VIEWS := [
	# [where it stands (x across the picture, y up), yaw, pitch]
	[Vector2(-1.5, 0.62), -0.9, 0.35],            # front quarter, from a little above
	[Vector2(0.0, 0.62), 0.0, 0.0],               # side on, nose to the right
	[Vector2(1.5, 0.62), -PI / 2.0, 0.0],         # head on
	[Vector2(-1.5, -0.62), 0.0, PI / 2.0],        # from above
	[Vector2(0.0, -0.62), PI - 0.9, 0.3],         # rear quarter
	[Vector2(1.5, -0.62), 0.0, -PI / 2.0],        # from below
]

var _prefix := "user://bot"
var _ids: Array = []
var _at := 0
var _frames := 0
var _world: Node3D
var _bots: Array = []
var _mats

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _prefix = args[0]
	_ids = args.slice(1)
	var reg := Registry.shared()
	_mats = Mats.shared(reg.arena.get("style", {}))
	_world = Node3D.new()
	root.add_child(_world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#3a4150")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#aab2c4")
	env.ambient_light_energy = 0.9
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = Mats.studio_sky()
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
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
	cam.size = 2.6
	cam.position = Vector3(0, 0, 10)
	cam.current = true
	_show()

func _show() -> void:
	for b in _bots: b.queue_free()
	_bots.clear()
	var reg := Registry.shared()
	var asm := Build.assemble_robot(reg, reg.robot(_ids[_at]))
	for v in VIEWS:
		var view := RobotView.new(asm, RobotRig.at_rest(asm), _mats)
		# Robot forward is +X: yaw turns it about its own up, pitch tips the
		# whole thing toward the camera (+) or away (-).
		var holder := Node3D.new()
		holder.position = Vector3(v[0].x, v[0].y, 0)
		holder.rotation = Vector3(v[2], 0, 0)
		view.rotation = Vector3(0, v[1], 0)
		holder.add_child(view)
		_world.add_child(holder)
		_bots.append(holder)
	_frames = 0

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 40: return false
	root.get_texture().get_image().save_png("%s_%s.png" % [_prefix, _ids[_at]])
	_at += 1
	if _at >= _ids.size():
		print("saved ", _ids.size(), " robots: ", _prefix)
		return true
	_show()
	return false
