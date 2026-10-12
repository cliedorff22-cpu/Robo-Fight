## gpu_fx.gd - sparks, smoke and flame run on the graphics card.
##
## effects.gd decides WHAT a hit throws; with Settings -> Spark showers on,
## this is what draws it. Three particle systems, each one pool that every
## burst in the arena shares: the script hands a particle its start (where,
## how fast, how hot, how long) and the card flies it from there - gravity,
## drag and the bounce off the deck are in the particle shaders below. So a
## shower can be several times thicker than the old one, which moved every
## spark in script, and costs the frame nothing to move.
##
## A spark is drawn as a streak along its own flight, as a camera's shutter
## smears it, not as a round dot. Smoke is lit by the hall's lamps and fades
## out where it meets the deck or a robot instead of cutting through it. A
## big hit also throws its light on what is round it for a few frames.
class_name GpuFx
extends Node3D

const MAX_SPARKS := 4096
const MAX_SMOKE := 1024
const MAX_FLAME := 1024
const FLASHES := 4
# Seconds of flight a spark's streak covers: about a broadcast camera's shutter.
const SHUTTER_S := 0.028
const EMIT_ALL := GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR | GPUParticles3D.EMIT_FLAG_CUSTOM

# A particle carries its own clock in CUSTOM: x age, y life (seconds), then
# two numbers that are the system's own.
const SPARK_FLIGHT := "shader_type particles;
uniform float shutter = 0.028;
void start() {
}
void process() {
	CUSTOM.x += DELTA;
	if (CUSTOM.x >= CUSTOM.y) {
		ACTIVE = false;
	}
	vec3 v = VELOCITY;
	vec3 p = TRANSFORM[3].xyz;
	v.y -= 9.81 * DELTA;
	// Air drag, so they arc and die rather than flying flat.
	v *= max(0.0, 1.0 - 2.2 * DELTA);
	// Off the deck once or twice, losing most of their go each time.
	if (p.y < 0.012 && v.y < 0.0) {
		p.y = 0.012;
		v = vec3(v.x * 0.6, -v.y * 0.35, v.z * 0.6);
	}
	VELOCITY = v;
	// Cooling: white-yellow to orange to a dull red, and thinner as it goes.
	COLOR.g *= exp(-0.9 * DELTA);
	COLOR.b *= exp(-2.45 * DELTA);
	float u = CUSTOM.x / max(CUSTOM.y, 0.001);
	COLOR.a = 1.0 - smoothstep(0.65, 1.0, u);
	float w = CUSTOM.z * (1.0 - 0.45 * u);
	float len = max(w, length(v) * shutter);
	TRANSFORM = mat4(vec4(w, 0.0, 0.0, 0.0), vec4(0.0, len, 0.0, 0.0), vec4(0.0, 0.0, w, 0.0), vec4(p, 1.0));
}
"
# The streak: hot and solid at the head, thinning out behind it.
const SPARK_DRAW := "shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform float gain = 9.0;
void fragment() {
	// A thin white-hot core down the middle and its own glow either side.
	float x = abs(UV.x * 2.0 - 1.0);
	float core = 1.0 - smoothstep(0.0, 0.3, x);
	float halo = (1.0 - x) * (1.0 - x) * 0.22;
	float along = smoothstep(0.0, 0.08, UV.y) * (1.0 - smoothstep(0.25, 1.0, UV.y) * 0.85) * (1.0 - smoothstep(0.92, 1.0, UV.y));
	ALBEDO = mix(COLOR.rgb, vec3(max(COLOR.r, max(COLOR.g, COLOR.b))), core * 0.45) * gain;
	ALPHA = clamp((core + halo) * along * COLOR.a, 0.0, 1.0);
}
"
# CUSTOM: x age, y life, z size at birth, w growth (metres a second).
const SMOKE_FLIGHT := "shader_type particles;
void start() {
}
void process() {
	CUSTOM.x += DELTA;
	if (CUSTOM.x >= CUSTOM.y) {
		ACTIVE = false;
	}
	vec3 v = VELOCITY;
	v.y *= max(0.0, 1.0 - 0.4 * DELTA);
	v.xz *= max(0.0, 1.0 - 0.9 * DELTA);
	VELOCITY = v;
	float s = CUSTOM.z + CUSTOM.w * CUSTOM.x;
	TRANSFORM = mat4(vec4(s, 0.0, 0.0, 0.0), vec4(0.0, s, 0.0, 0.0), vec4(0.0, 0.0, s, 0.0), TRANSFORM[3]);
}
"
# A puff: a soft round of broken-up cloud, each one turned its own way and
# turning slowly. COLOR.a is how thick it is at its thickest.
const SMOKE_DRAW := "shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled, vertex_lighting, skip_vertex_transform;
uniform sampler2D cloud : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float soft_m = 0.3;
varying float v_u;
varying float v_turn;
void vertex() {
	v_u = INSTANCE_CUSTOM.x / max(INSTANCE_CUSTOM.y, 0.001);
	v_turn = INSTANCE_CUSTOM.y * 37.0 + INSTANCE_CUSTOM.x * (fract(INSTANCE_CUSTOM.y * 13.0) - 0.5) * 0.9;
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Lit as a ball would be from above and from the camera's side at once: a
	// flat card facing the lens would take no light from an overhead lamp.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz * 0.8 + vec3(0.0, 0.0, 0.6));
}
void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float c = cos(v_turn);
	float s = sin(v_turn);
	vec2 r = vec2(q.x * c - q.y * s, q.x * s + q.y * c);
	float n = texture(cloud, r * 0.32 + vec2(v_turn * 0.11, 0.37)).r;
	float body = 1.0 - smoothstep(0.25 + 0.5 * n, 1.0, length(q));
	float fade = min(1.0, v_u * 8.0) * (1.0 - v_u);
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 back = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float gap = -back.z / back.w + VERTEX.z;
	ALBEDO = COLOR.rgb * (0.75 + 0.5 * n);
	ALPHA = body * fade * COLOR.a * clamp(gap / soft_m, 0.0, 1.0);
}
"
# Flame is smoke that gives light: the same rise, a colour that runs from
# white-yellow through orange to a dull red as each lick burns out.
const FLAME_DRAW := "shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform sampler2D cloud : repeat_enable, filter_linear_mipmap;
varying float v_u;
varying float v_turn;
void vertex() {
	v_u = INSTANCE_CUSTOM.x / max(INSTANCE_CUSTOM.y, 0.001);
	v_turn = INSTANCE_CUSTOM.y * 37.0;
}
void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float n = texture(cloud, q * 0.3 + vec2(v_turn, v_u * 0.6 + v_turn * 0.5)).r;
	// Narrow at the top: a lick, not a ball.
	float shape = length(vec2(q.x * (1.3 + 0.7 * (0.5 - q.y * 0.5)), q.y));
	float body = 1.0 - smoothstep(0.15 + 0.55 * n, 1.0, shape);
	vec3 hot = mix(vec3(1.0, 0.86, 0.45), vec3(1.0, 0.42, 0.08), smoothstep(0.0, 0.45, v_u));
	hot = mix(hot, vec3(0.55, 0.08, 0.02), smoothstep(0.45, 1.0, v_u));
	ALBEDO = hot * COLOR.rgb;
	ALPHA = body * min(1.0, v_u * 10.0) * (1.0 - v_u) * COLOR.a;
}
"

var _sparks: GPUParticles3D
var _smoke: GPUParticles3D
var _flame: GPUParticles3D
var _flashes: Array[OmniLight3D] = []
var _flash_e := PackedFloat32Array()
var _fire: OmniLight3D
var _fire_e := 0.0
var _t := 0.0

static var _cloud: ImageTexture = null

func _init() -> void:
	name = "GpuFx"
	_sparks = _system(MAX_SPARKS, SPARK_FLIGHT, SPARK_DRAW, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY)
	_smoke = _system(MAX_SMOKE, SMOKE_FLIGHT, SMOKE_DRAW, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD)
	_flame = _system(MAX_FLAME, SMOKE_FLIGHT, FLAME_DRAW, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD)
	for sys in [_smoke, _flame]:
		((sys as GPUParticles3D).draw_pass_1.surface_get_material(0) as ShaderMaterial).set_shader_parameter("cloud", _cloud_texture())
	# The light a big hit throws for a few frames. No shadows: it is gone
	# before one could be read.
	for i in FLASHES:
		var l := _lamp(Color(1.0, 0.78, 0.45), 5.0)
		_flashes.append(l)
		_flash_e.append(0.0)
	# One more for whatever is burning.
	_fire = _lamp(Color(1.0, 0.55, 0.2), 4.0)

func _lamp(color: Color, reach: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = color
	l.omni_range = reach
	l.omni_attenuation = 1.6
	l.shadow_enabled = false
	l.light_energy = 0.0
	l.light_specular = 0.6
	l.light_volumetric_fog_energy = 0.6
	l.light_bake_mode = Light3D.BAKE_DISABLED
	l.visible = false
	add_child(l)
	return l

func _system(count: int, flight: String, draw: String, align: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = count
	# Nothing comes out on its own: every particle is handed over by emit().
	p.emitting = false
	p.one_shot = false
	# A particle ends itself (its flight shader counts its own seconds). The
	# system's own clock is kept far longer than any of them lives, so its
	# cycle never comes round to a place in the pool that is in use.
	p.lifetime = 100000.0
	p.explosiveness = 0.0
	p.fixed_fps = 0
	p.interpolate = false
	p.local_coords = false
	p.transform_align = align
	p.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	p.visibility_aabb = AABB(Vector3(-40, -5, -40), Vector3(80, 30, 80))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var fs := Shader.new()
	fs.code = flight
	var fm := ShaderMaterial.new()
	fm.shader = fs
	p.process_material = fm
	var ds := Shader.new()
	ds.code = draw
	var dm := ShaderMaterial.new()
	dm.shader = ds
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = dm
	p.draw_pass_1 = quad
	add_child(p)
	return p

# Broken cloud, drawn once: what keeps a puff from being a clean disc.
static func _cloud_texture() -> ImageTexture:
	if _cloud != null: return _cloud
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.022
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var img := noise.get_seamless_image(128, 128)
	img.generate_mipmaps()
	_cloud = ImageTexture.create_from_image(img)
	return _cloud

## One spark: `color` is how hot it starts (over 1 is what the bloom picks
## up), `width` its thickness in metres.
func spark(at: Vector3, velocity: Vector3, color: Color, width: float, life: float) -> void:
	_sparks.emit_particle(Transform3D(Basis.IDENTITY, at), velocity, color, Color(0.0, life, width, 0.0), EMIT_ALL)

## One puff of smoke: `grey` its shade, `thick` how much of what is behind it
## it hides at its thickest.
func smoke(at: Vector3, velocity: Vector3, grey: float, size: float, grow: float, life: float, thick := 0.75) -> void:
	_smoke.emit_particle(Transform3D(Basis.IDENTITY, at), velocity, Color(grey, grey, grey * 1.04, thick), Color(0.0, life, size, grow), EMIT_ALL)

## One lick of flame. `glow`: it also lights what is round it (one fire at a
## time does - the last to burn).
func flame(at: Vector3, velocity: Vector3, size: float, life: float, bright := 1.0, glow := false) -> void:
	_flame.emit_particle(Transform3D(Basis.IDENTITY, at), velocity, Color(2.4 * bright, 2.4 * bright, 2.4 * bright, 0.9), Color(0.0, life, size, size * 0.6), EMIT_ALL)
	if not glow: return
	_fire.position = at + Vector3(0, 0.25, 0)
	_fire_e = 1.0

## The light of a hit, on everything round it, for a few frames.
func flash(at: Vector3, energy: float) -> void:
	var weakest := 0
	for i in FLASHES:
		if _flash_e[i] < _flash_e[weakest]: weakest = i
	if _flash_e[weakest] >= energy: return
	_flash_e[weakest] = energy
	_flashes[weakest].position = at + Vector3(0, 0.15, 0)

## Once a frame: the lights die away. (The particles need no telling.)
func update(dt: float) -> void:
	_t += dt
	for i in FLASHES:
		var e := _flash_e[i] * exp(-dt / 0.06)
		if e < 0.02: e = 0.0
		_flash_e[i] = e
		_flashes[i].light_energy = e
		_flashes[i].visible = e > 0.0
	# A fire flickers, and goes out a moment after the last lick of it.
	_fire_e = maxf(0.0, _fire_e - dt * 2.5)
	_fire.light_energy = _fire_e * (1.1 + 0.5 * sin(_t * 31.0) * sin(_t * 17.3))
	_fire.visible = _fire_e > 0.0

## The fight is frozen (the pause screen): everything hangs where it is.
func set_paused(paused: bool) -> void:
	var k := 0.0 if paused else 1.0
	for sys in [_sparks, _smoke, _flame]:
		if not is_equal_approx((sys as GPUParticles3D).speed_scale, k): (sys as GPUParticles3D).speed_scale = k

## Between matches: nothing left in the air.
func clear() -> void:
	for sys in [_sparks, _smoke, _flame]: RenderingServer.particles_restart((sys as GPUParticles3D).get_base())
	for i in FLASHES:
		_flash_e[i] = 0.0
		_flashes[i].visible = false
	_fire_e = 0.0
	_fire.visible = false
