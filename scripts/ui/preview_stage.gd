## preview_stage.gd - a small turntable that shows one robot (or both halves
## of a multibot) in the menus.
##
## Its own little 3D world in an offscreen viewport: a three-point studio rig
## for showing robots off. The camera sits front-right of the robot (+X +Z),
## so the key comes from above its right shoulder, a cool fill from the left,
## and a rim from behind to pick the silhouette out of the dark.
##
## It is the same geometry the fight uses (render/robot_view.gd, posed at
## rest with no physics), so the bot you pick is the bot that turns up.
class_name PreviewStage
extends SubViewportContainer

## Turn on its own.
var auto_spin := true
## Drag to turn it, click to pick parts (the workshop).
var interactive := false
var angle := -0.6
## Called with the part key under a click ("weapon", "armor.1"...), or "".
var on_pick: Callable
## Called after every frame (the workshop moves its hotspot labels).
var on_frame: Callable

var _vp: SubViewport
var _cam: Camera3D
var _turn: Node3D
var _views: Array[RobotView] = []
var _weapons := []
var _radius := 1.0
var _snaps := []                 # [{ node, base, t }] - parts dropping into place
var _highlight := []             # overlay meshes on the highlighted part
var _glow: StandardMaterial3D
var _drag = null                 # { x, moved } while turning it by hand

## opts: { spin (default true), interactive, angle }
func _init(opts: Dictionary = {}) -> void:
	auto_spin = opts.get("spin", true)
	interactive = opts.get("interactive", false)
	angle = opts.get("angle", -0.6)
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.gui_disable_input = true
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("a8b0c4")
	env.ambient_light_energy = 0.3
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = Mats.studio_sky()
	pano.energy_multiplier = 0.6
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	for spec in [[Vector3(3, 5, 1.2), Color.WHITE, 1.25, true], [Vector3(0.5, 2.2, 4), Color("c8dcff"), 0.55, false], [Vector3(-3.5, 2.5, -2.5), Color("e8eeff"), 0.62, false]]:
		var l := DirectionalLight3D.new()
		l.light_color = spec[1]
		l.light_energy = spec[2]
		l.shadow_enabled = spec[3]
		l.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		l.directional_shadow_max_distance = 14.0
		l.shadow_bias = 0.02
		_vp.add_child(l)
		l.look_at_from_position(spec[0], Vector3.ZERO)

	# The turntable: a dark disc with a yellow ring, like a corner pad.
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color("15181e")
	disc_mat.roughness = 0.85
	disc_mat.metallic = 0.1
	disc_mat.metallic_specular = 0.12
	_vp.add_child(Geo.cylinder(1.25, 1.3, 0.04, 64).translate(0, -0.02, 0).instance(disc_mat, false))
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color("f0c419")
	ring_mat.roughness = 0.4
	ring_mat.emission_enabled = true
	ring_mat.emission = Color("6a5208")
	_vp.add_child(Geo.torus(1.26, 0.012, 8, 96).rotate_x(PI / 2.0).instance(ring_mat, false))

	_cam = Camera3D.new()
	_cam.fov = 32.0
	_cam.near = 0.05
	_cam.far = 40.0
	_vp.add_child(_cam)
	_cam.current = true
	_turn = Node3D.new()            # the robots ride on this
	_vp.add_child(_turn)
	_glow = StandardMaterial3D.new()
	_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow.albedo_color = Color(0.94, 0.77, 0.1, 0.32)
	_glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

func _clear() -> void:
	clear_highlight()
	_snaps.clear()
	for v in _views:
		_turn.remove_child(v)
		v.queue_free()
	_views.clear()
	_weapons.clear()

func clear_highlight() -> void:
	for m in _highlight:
		if is_instance_valid(m): m.queue_free()
	_highlight.clear()

static func _bounds_under(node: Node, xf: Transform3D, box) -> Variant:
	if node is Node3D: xf = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var b: AABB = xf * (node as MeshInstance3D).get_aabb()
		box = b if box == null else (box as AABB).merge(b)
	for c in node.get_children(): box = _bounds_under(c, xf, box)
	return box

## Show these assembled units (one robot, or a multibot's pair).
func show_units(units: Array) -> void:
	_clear()
	var mats := Mats.shared(Game.reg.arena.get("style", {}))
	var spacing := 0.55 if units.size() > 1 else 0.0
	for k in units.size():
		var a: Dictionary = units[k]
		var rig := RobotRig.at_rest(a)
		var view := RobotView.new(a, rig, mats)
		view.position = Vector3(0, rig.layout.spawnY, (k - (units.size() - 1) / 2.0) * spacing * 2.0)
		_turn.add_child(view)
		# Show the damage it carries (the pit): worn parts darken, destroyed
		# ones are gone - the same as in the arena.
		var cond: Dictionary = a.get("condition", {})
		for key in cond:
			if cond[key] < 0.999: view.set_panel_condition(key, cond[key])
		view.apply_condition(cond)
		_views.append(view)
		var w := Weapon.new(a, Game.reg.rules)
		w.omegaRadS = 16.0
		w.phase = Weapon.READY
		_weapons.append(w)
	# Frame on the bounding sphere of everything shown.
	var box = null
	for v in _views: box = _bounds_under(v, Transform3D.IDENTITY, box)
	if box == null: return
	var bb: AABB = box
	_radius = maxf(0.35, bb.size.length() / 2.0)
	# The turntable spins about the robot's middle, not its body origin - a
	# long bar or wedge would otherwise swing round off-centre.
	var c := bb.get_center()
	for v in _views: v.position -= Vector3(c.x, 0, c.z)

## Show a robot definition - any definition, so the workshop can show a
## draft. `conditions`: the damage it is carrying, per unit.
func show_def(def: Dictionary, conditions = null) -> bool:
	if not Build.can_assemble(Game.reg, def): return false
	var units := [Build.assemble_robot(Game.reg, def)]
	if def.get("partner") != null:
		var p = Build.assemble_partner(Game.reg, def)
		if p != null: units.append(p)
	if conditions is Array:
		for i in units.size():
			if i < conditions.size() and conditions[i] is Dictionary: units[i].condition.merge(conditions[i], true)
	show_units(units)
	return true

func show_bot(id, conditions = null) -> bool:
	var def = Game.reg.robot(id)
	return def != null and show_def(def, conditions)

func _process(dt: float) -> void:
	if not is_visible_in_tree(): return
	dt = minf(dt, 0.05)
	if auto_spin and _drag == null: angle += dt * 0.45
	_turn.rotation.y = angle
	for i in _views.size(): _views[i].update_weapon(_weapons[i], dt)
	# Parts snapping in: drop from above, overshoot a touch, settle.
	for i in range(_snaps.size() - 1, -1, -1):
		var sn: Dictionary = _snaps[i]
		var node: Node3D = sn.node
		if not is_instance_valid(node):
			_snaps.remove_at(i)
			continue
		sn.t += dt / 0.42
		var k := minf(1.0, sn.t)
		var e := 1.0 - pow(1.0 - k, 3.0)
		var bounce := sin(k * PI) * 0.06 * (1.0 - k)
		node.position.y = sn.base.y + (1.0 - e) * 0.32 - bounce
		node.scale = Vector3.ONE * (1.0 + (1.0 - e) * 0.12)
		if k >= 1.0:
			node.position = sn.base
			node.scale = Vector3.ONE
			_snaps.remove_at(i)
	# Back the camera off until the whole robot fits, whatever its size.
	var aspect := size.x / maxf(1.0, size.y)
	var fit := _radius / sin(deg_to_rad(_cam.fov / 2.0)) * (1.25 / aspect if aspect < 1.0 else 1.05)
	_cam.position = Vector3(fit * 0.82, fit * 0.42 + 0.1, fit * 0.55)
	_cam.look_at(Vector3(0, _radius * 0.25, 0), Vector3.UP)
	if on_frame.is_valid(): on_frame.call()

func _gui_input(event: InputEvent) -> void:
	if not interactive: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed: _drag = {"x": event.position.x, "moved": 0.0}
		else:
			var was_click: bool = _drag != null and _drag.moved < 4.0
			_drag = null
			if was_click and on_pick.is_valid(): on_pick.call(pick_at(event.position))
	elif event is InputEventMouseMotion and _drag != null:
		var dx: float = event.position.x - _drag.x
		_drag.x = event.position.x
		_drag.moved += absf(dx)
		angle += dx * 0.012

## The part under a point of this control ("weapon", "armor.2"...), or "".
func pick_at(p: Vector2) -> String:
	var from := _cam.project_ray_origin(p)
	var dir := _cam.project_ray_normal(p)
	for v in _views:
		var key := v.pick(from, dir)
		if key != "": return key
	return ""

## Where a point in the (first) robot's own frame is on this control, in
## pixels, and whether it faces the camera: { pos: Vector2, front } or null.
func project(p: Vector3):
	if _views.is_empty(): return null
	var v := _views[0]
	var w := v.global_transform * p
	var out := w - v.global_transform.origin
	return {"pos": _cam.unproject_position(w), "front": out.dot(_cam.global_position - w) > -0.02}

## Drop these parts ("weapon", "wheel", "chassis", "armor.N", or "all") into place.
func snap(keys: Array) -> void:
	for v in _views:
		for key in keys:
			var nodes: Array = [v] if key == "all" else v.part_objects.get(key, [])
			for n in nodes:
				if n is Node3D: _snaps.append({"node": n, "base": (n as Node3D).position, "t": 0.0})

## Outline one part in the accent colour ("" clears it).
func highlight(key: String) -> void:
	clear_highlight()
	if key == "": return
	for v in _views:
		for obj in v.part_objects.get(key, []):
			for mi in v._meshes_under(obj):
				var over := MeshInstance3D.new()
				over.mesh = (mi as MeshInstance3D).mesh
				over.material_override = _glow
				over.scale = Vector3.ONE * 1.015
				over.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.add_child(over)
				_highlight.append(over)
