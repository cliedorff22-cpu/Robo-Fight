## sheet_test.gd - contact sheets of the field: six robots to a picture, each
## filling its cell, all from the same side. For looking the whole roster over
## robot by robot.
##   Godot --path . -s tests/sheet_test.gd -- out_prefix view [plain] [robot_id ...]
## view: front | rear | top | side. No ids: every robot, by league. "plain":
## with the robot hardware (Settings) off.
extends SceneTree

const COLS := 3
const ROWS := 2
const VIEWS := {
	"front": [-0.85, 0.42],
	"rear": [PI - 0.85, 0.42],
	"top": [0.0, PI / 2.0],
	"side": [0.0, 0.06],
}

var _prefix := "user://sheet"
var _view := "front"
var _ids: Array = []
var _page := 0
var _frames := 0
var _world: Node3D
var _bots: Array = []
var _labels: Array = []
var _mats
var _layer: CanvasLayer

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _prefix = args[0]
	if args.size() > 1: _view = args[1]
	_ids = Array(args.slice(2))
	# "plain" among the ids: without the robot hardware, for a before picture.
	if _ids.has("plain"):
		_ids.erase("plain")
		Dress.on = false
	var reg := Registry.shared()
	if _ids.is_empty():
		var seen := {}
		for r in reg.roster():
			_ids.append(r.id)
			seen[r.id] = true
		for r in reg.all_robots():
			if not seen.has(r.id): _ids.append(r.id)
	_mats = Mats.shared(reg.arena.get("style", {}))
	_world = Node3D.new()
	root.add_child(_world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#454c5a")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#aab2c4")
	env.ambient_light_energy = 0.75
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = Mats.studio_sky()
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ssao_enabled = true
	env.ssao_radius = 0.25
	env.ssao_intensity = 1.4
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)
	for spec in [[Vector3(-45, 35, 0), 1.25, true], [Vector3(-20, -150, 0), 0.45, false], [Vector3(55, 100, 0), 0.4, false]]:
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = spec[0]
		sun.light_energy = spec[1]
		sun.shadow_enabled = spec[2]
		sun.directional_shadow_max_distance = 30.0
		_world.add_child(sun)
	var cam := Camera3D.new()
	_world.add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = float(ROWS)
	cam.position = Vector3(0, 0, 10)
	cam.current = true
	_layer = CanvasLayer.new()
	root.add_child(_layer)
	_show()

func _show() -> void:
	for b in _bots: b.queue_free()
	for l in _labels: l.queue_free()
	_bots.clear()
	_labels.clear()
	var reg := Registry.shared()
	# (The window has not been sized yet when the first sheet is laid out.)
	var size := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	var cell := Vector2(size.x / COLS, size.y / ROWS)
	var unit := float(ROWS) / size.y           # world units per pixel
	var v: Array = VIEWS.get(_view, VIEWS.front)
	for k in COLS * ROWS:
		var i := _page * COLS * ROWS + k
		if i >= _ids.size(): break
		if not reg.has_robot(_ids[i]): continue
		var asm := Build.assemble_robot(reg, reg.robot(_ids[i]))
		var view := RobotView.new(asm, RobotRig.at_rest(asm), _mats)
		var holder := Node3D.new()
		holder.rotation = Vector3(v[1], 0, 0)
		view.rotation = Vector3(0, v[0], 0)
		holder.add_child(view)
		_world.add_child(holder)
		# Fill the cell: scale by what the robot covers on screen.
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for mi in view.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.mesh == null: continue
			var box := m.mesh.get_aabb()
			var xf: Transform3D = holder.transform * view.transform * view._to_body(m)
			for c in 8:
				var p := xf * box.get_endpoint(c)
				lo = lo.min(Vector2(p.x, p.y))
				hi = hi.max(Vector2(p.x, p.y))
		var span := hi - lo
		var s := minf(cell.x * unit * 0.9 / maxf(span.x, 0.01), cell.y * unit * 0.8 / maxf(span.y, 0.01))
		var col := k % COLS
		var row := k / COLS
		var centre := Vector2((col + 0.5) * cell.x - size.x / 2.0, size.y / 2.0 - (row + 0.54) * cell.y) * unit
		holder.scale = Vector3(s, s, s)
		holder.position = Vector3(centre.x - (lo.x + hi.x) / 2.0 * s, centre.y - (lo.y + hi.y) / 2.0 * s, 0)
		_bots.append(holder)
		var label := Label.new()
		label.text = "%s  (%s)" % [_ids[i], str(reg.robot(_ids[i]).get("inspiredBy", "-"))]
		label.position = Vector2(col * cell.x + 10, row * cell.y + 6)
		label.add_theme_font_size_override("font_size", 20)
		label.add_theme_color_override("font_color", Color.WHITE)
		_layer.add_child(label)
		_labels.append(label)
	_frames = 0

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 45: return false
	root.get_texture().get_image().save_png("%s_%s_%02d.png" % [_prefix, _view, _page])
	_page += 1
	if _page * COLS * ROWS >= _ids.size():
		print("saved ", _page, " sheets: ", _prefix)
		return true
	_show()
	return false
