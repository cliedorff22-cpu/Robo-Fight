## effects.gd - sparks, smoke and the marks a hit leaves.
##
## Subscribes to the bus and nothing else. The logic layer emits facts ("this
## fitting took a heavy hit, here, with this normal"); this file decides what
## that looks like. That is the whole reason combat carries a contact point.
##
## Sparks and smoke are each one pooled multimesh of camera-facing quads, so
## a busy exchange costs one draw call. Sparks are deliberately bright: the
## bloom is what turns them from white dots into sparks.
class_name Effects
extends Node3D

const MAX_SPARKS := 900
const MAX_SMOKE := 700
# On-screen size of a particle, in metres per unit of its size.
const SPRITE_M := 0.2
const SPARKS_BY_SEVERITY := {"scratch": 0, "glance": 6, "hit": 14, "heavy": 30, "catastrophic": 55}
# Which material a failing part sheds, so debris matches what broke.
const MATERIAL_FOR := {"armor": "ar500_steel", "chassis": "ar500_steel", "wheel": "rubber", "weapon": "hub", "weaponMotor": "hub",
	"motor": "hub", "drive": "hub", "battery": "uhmw", "electronics": "uhmw"}

var _rng: Rng
var _views: Dictionary          # robot id -> RobotView
var _debris: Debris
var _offs := []

# sparks
var _sp_mm: MultiMesh
var _sp_pos := PackedVector3Array()
var _sp_vel := PackedVector3Array()
var _sp_col := PackedColorArray()
var _sp_size := PackedFloat32Array()
var _sp_life := PackedFloat32Array()
var _sp_cursor := 0
# smoke
var _sm_mm: MultiMesh
var _sm_pos := PackedVector3Array()
var _sm_vel := PackedVector3Array()
var _sm_grey := PackedFloat32Array()
var _sm_size := PackedFloat32Array()
var _sm_grow := PackedFloat32Array()
var _sm_life := PackedFloat32Array()
var _sm_max := PackedFloat32Array()
var _sm_cursor := 0
var _owed := {}                 # robot:key -> puffs owed

func _init(bus: Bus, robot_views: Dictionary, debris: Debris, random: Rng) -> void:
	name = "Effects"
	_rng = random
	_views = robot_views
	_debris = debris
	_sp_mm = _pool(MAX_SPARKS, _sprite([[0.0, Color(1, 1, 1, 1)], [0.35, Color(1, 0.9, 0.67, 0.85)], [1.0, Color(1, 0.63, 0.24, 0)]]), true)
	_sm_mm = _pool(MAX_SMOKE, _sprite([[0.0, Color(1, 1, 1, 0.9)], [0.5, Color(1, 1, 1, 0.45)], [1.0, Color(1, 1, 1, 0)]]), false)
	for a in [_sp_pos, _sp_vel]: a.resize(MAX_SPARKS)
	_sp_col.resize(MAX_SPARKS)
	_sp_size.resize(MAX_SPARKS)
	_sp_life.resize(MAX_SPARKS)
	for a in [_sm_pos, _sm_vel]: a.resize(MAX_SMOKE)
	for a in [_sm_grey, _sm_size, _sm_grow, _sm_life, _sm_max]: a.resize(MAX_SMOKE)
	_offs.append(bus.on(Bus.HIT, _on_hit))
	_offs.append(bus.on(Bus.PART_FAILED, _on_failed))

# A round, soft sprite drawn once - no asset file needed.
static func _sprite(stops: Array) -> ImageTexture:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			var t := clampf(Vector2(x + 0.5 - s / 2.0, y + 0.5 - s / 2.0).length() / (s / 2.0), 0.0, 1.0)
			var c: Color = stops[stops.size() - 1][1]
			for i in range(stops.size() - 1):
				if t <= stops[i + 1][0]:
					c = (stops[i][1] as Color).lerp(stops[i + 1][1], (t - stops[i][0]) / maxf(1e-6, stops[i + 1][0] - stops[i][0]))
					break
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

func _pool(count: int, tex: Texture2D, additive: bool) -> MultiMesh:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	mat.disable_fog = additive
	if additive: mat.albedo_color = Color(2.2, 2.2, 2.2)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = count
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -1000, 0))
	for i in count: mm.set_instance_transform(i, hidden)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-40, -5, -40), Vector3(80, 30, 80))
	add_child(mmi)
	return mm

## Throw `count` sparks from a point, biased along a normal.
func spark_burst(at, normal := Vector3.UP, count := 18, speed := 7.0, hot := 1.0) -> void:
	if at == null: return
	var p: Vector3 = at
	for i in count:
		var c := _sp_cursor
		_sp_pos[c] = p
		var spread := 1.15
		var s := speed * (0.35 + _rng.next() * 1.0)
		_sp_vel[c] = Vector3(normal.x * s + (_rng.next() - 0.5) * s * spread, absf(normal.y) * s * 0.4 + _rng.next() * s * 0.8,
			normal.z * s + (_rng.next() - 0.5) * s * spread)
		# Hot white-yellow core cooling to orange, scaled by how big the hit was.
		var heat := 0.55 + _rng.next() * 0.45
		_sp_col[c] = Color(1.6 * hot, (0.75 + heat * 0.5) * hot, (0.2 + heat * 0.3) * hot, 1.0)
		_sp_size[c] = (0.6 + _rng.next() * 1.5) * hot
		_sp_life[c] = 0.25 + _rng.next() * 0.5
		_sp_cursor = (_sp_cursor + 1) % MAX_SPARKS

# ---- smoke and fire. A robot hurt inside smokes from where it hurts
# (RobotView.damage_sources): grey puffs that rise, spread and thin out; a
# battery near the end burns.
func _emit_smoke(at: Vector3, dark := 0.3, size := 0.12, life := 2.2, rise := 0.6) -> void:
	var i := _sm_cursor
	_sm_pos[i] = Vector3(at.x + (_rng.next() - 0.5) * 0.05, at.y, at.z + (_rng.next() - 0.5) * 0.05)
	_sm_vel[i] = Vector3((_rng.next() - 0.5) * 0.25, rise * (0.7 + _rng.next() * 0.6), (_rng.next() - 0.5) * 0.25)
	_sm_grey[i] = dark + _rng.next() * 0.12
	_sm_size[i] = size * (0.8 + _rng.next() * 0.4)
	_sm_grow[i] = 0.35 + _rng.next() * 0.3
	_sm_max[i] = life * (0.8 + _rng.next() * 0.4)
	_sm_life[i] = _sm_max[i]
	_sm_cursor = (_sm_cursor + 1) % MAX_SMOKE

func _damage_smoke(dt: float) -> void:
	for id in _views:
		var view: RobotView = _views[id]
		if not is_instance_valid(view) or not view.visible: continue
		for src in view.damage_sources():
			var k := "%s:%s" % [id, src.key]
			var owed: float = _owed.get(k, 0.0) + dt * (4.0 + 22.0 * src.rate)
			while owed >= 1.0:
				owed -= 1.0
				_emit_smoke(src.pos, 0.12 if src.fire else 0.42 - src.rate * 0.28, 0.1 + src.rate * 0.12, 1.6 + src.rate * 1.4)
				# Flames: short-lived, upward (the spark pool, slowed down).
				if src.fire and _rng.next() < 0.45:
					spark_burst(src.pos + Vector3((_rng.next() - 0.5) * 0.05, 0, (_rng.next() - 0.5) * 0.05), Vector3.UP, 1, 1.1, 0.42)
			if src.sparks and _rng.next() < dt * 3.0: spark_burst(src.pos, Vector3.UP, 6, 3.0, 0.8)
			_owed[k] = owed

func _on_hit(e: Dictionary) -> void:
	var n: int = SPARKS_BY_SEVERITY.get(e.severity, 8)
	if n <= 0 or e.get("at") == null: return
	var hot := 1.0 if e.kind == "weapon" else (0.9 if e.kind == "hazard" else 0.6)
	var speed := 5.0 + minf(12.0, J.g(e, "deliveredJ", 0.0) / 1200.0)
	spark_burst(e.at, e.get("normal", Vector3.UP), n, speed, hot)
	# Dent and darken whatever got hit.
	var view: RobotView = _views.get(e.defenderId)
	if view == null or not is_instance_valid(view): return
	for h in e.get("hits", []):
		if h.category == "armor" or h.category == "chassis":
			view.dent(h.key, e.at, 0.016 if Damage.SEVERITY_ORDER[e.severity] >= 3 else 0.007)
		view.set_panel_condition(h.key, h.conditionAfter)

func _on_failed(e: Dictionary) -> void:
	# A part giving way throws real chunks of itself across the arena.
	var armor: bool = e.get("category") == "armor"
	var normal: Vector3 = e.normal if e.get("normal") is Vector3 else Vector3.UP
	if _debris != null and e.get("at") != null:
		_debris.burst(e.at, normal, 6000.0, MATERIAL_FOR.get(e.get("category"), "ar500_steel"), 7 if armor else 4, 0.09 if armor else 0.06)
	spark_burst(e.get("at"), normal, 40, 11.0, 1.2)
	var view: RobotView = _views.get(e.get("botId"))
	if view != null and is_instance_valid(view): view.set_panel_condition(e.key, 0.0)

## Advance sparks and smoke. Once per rendered frame.
func update(dt: float) -> void:
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -1000, 0))
	var drag := 1.0 - 2.2 * dt
	for i in MAX_SPARKS:
		if _sp_life[i] <= 0.0: continue
		_sp_life[i] -= dt
		if _sp_life[i] <= 0.0:
			_sp_mm.set_instance_transform(i, hidden)
			continue
		var v := _sp_vel[i]
		v.y -= 9.81 * dt
		# Air drag, so they arc and die rather than flying flat.
		v *= drag
		var p := _sp_pos[i] + v * dt
		# Bounce off the deck once, which looks far better than sinking through.
		if p.y < 0.01 and v.y < 0.0:
			p.y = 0.01
			v = Vector3(v.x * 0.6, -v.y * 0.35, v.z * 0.6)
		_sp_vel[i] = v
		_sp_pos[i] = p
		# Cool and shrink as they die.
		var c := _sp_col[i]
		c.g *= 0.985
		c.b *= 0.96
		_sp_col[i] = c
		_sp_size[i] *= 0.985
		var s := _sp_size[i] * SPRITE_M
		_sp_mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(s, s, s)), p))
		_sp_mm.set_instance_color(i, c)
	_damage_smoke(dt)
	for i in MAX_SMOKE:
		if _sm_life[i] <= 0.0: continue
		_sm_life[i] -= dt
		if _sm_life[i] <= 0.0:
			_sm_mm.set_instance_transform(i, hidden)
			continue
		var u := 1.0 - _sm_life[i] / _sm_max[i]          # 0 born .. 1 gone
		var v := _sm_vel[i]
		_sm_pos[i] += v * dt
		v.y *= 1.0 - 0.4 * dt
		_sm_vel[i] = v
		_sm_size[i] += _sm_grow[i] * dt
		var s := _sm_size[i] * SPRITE_M * 2.2
		var g := _sm_grey[i]
		_sm_mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(s, s, s)), _sm_pos[i]))
		_sm_mm.set_instance_color(i, Color(g, g, g * 1.04, minf(1.0, u * 8.0) * (1.0 - u) * 0.75))

## Between matches.
func clear() -> void:
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -1000, 0))
	for i in MAX_SPARKS:
		_sp_life[i] = 0.0
		_sp_mm.set_instance_transform(i, hidden)
	for i in MAX_SMOKE:
		_sm_life[i] = 0.0
		_sm_mm.set_instance_transform(i, hidden)
	_owed.clear()

func _exit_tree() -> void:
	for off in _offs:
		if (off as Callable).is_valid(): off.call()
