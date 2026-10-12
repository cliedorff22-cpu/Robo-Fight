## view_test.gd - a line-up of robots in a real window, saved as a picture.
##   Godot --path . -s tests/view_test.gd -- out.png [first] [count]
extends SceneTree

var _frames := 0
var _out := "user://view_test.png"
var _shop: PaintShop

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _out = args[0]
	var first := int(args[1]) if args.size() > 1 else 0
	var count := int(args[2]) if args.size() > 2 else 8
	var reg := Registry.shared()
	var t0 := Time.get_ticks_msec()
	var mats := Mats.shared(reg.arena.get("style", {}))
	print("materials: %d ms" % (Time.get_ticks_msec() - t0))
	var world := Node3D.new()
	root.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#14161b")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#8892a8")
	env.ambient_light_energy = 0.5
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = ImageTexture.create_from_image(Mats.studio_panorama())
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	world.add_child(sun)
	var floor_mi := Geo.box(30, 0.1, 30).translate(0, -0.05, 0).instance(mats.lib.steelFloor)
	world.add_child(floor_mi)

	var bots := reg.all_robots()
	var cols := 4
	for i in count:
		var def: Dictionary = bots[(first + i) % bots.size()]
		t0 = Time.get_ticks_msec()
		var asm := Build.assemble_robot(reg, def)
		var rig := RobotRig.at_rest(asm)
		var view := RobotView.new(asm, rig, mats)
		world.add_child(view)
		view.position = Vector3((i / cols) * -1.9, rig.layout.spawnY, ((i % cols) - (cols - 1) / 2.0) * 1.6)
		print("%s: %d ms" % [def.id, Time.get_ticks_msec() - t0])
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.fov = 40
	var rows := ceili(count / float(cols))
	cam.look_at_from_position(Vector3(3.6, 3.0 + rows * 0.4, 3.4), Vector3(-(rows - 1) * 0.95, 0.1, 0))
	cam.current = true

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames == 90:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("saved ", _out)
		return true
	return false
