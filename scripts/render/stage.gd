## stage.gd - the lighting rig and the look of the picture.
##
## Reads its setup from arena.json so the look is data-driven: a dim cold
## ambient, one hard key light for the shadows, a low fill and warm overhead
## practicals, with fog, a little bloom on what is genuinely bright and a
## vignette to pull the eye into the middle of the box.
class_name Stage
extends Node3D

## How the browser game's light intensities map onto this engine's: its
## lights are divided by pi on the way to the surface, this engine's are not.
const LIGHT_SCALE := 1.0 / PI

var env: Environment
var key_light: DirectionalLight3D
var _world_env: WorldEnvironment
var _vignette: ColorRect

func _init(arena: Dictionary) -> void:
	name = "Stage"
	var L: Dictionary = arena.lighting
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = CanvasRec.css(L.background)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = CanvasRec.css(L.ambient.color)
	env.ambient_light_energy = L.ambient.intensity * LIGHT_SCALE * 1.6
	# A photo studio to reflect, so steel looks like steel.
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = ImageTexture.create_from_image(Mats.studio_panorama())
	pano.energy_multiplier = 0.55
	sky.sky_material = pano
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	# Exposure is the first dial to reach for if the arena looks too bright
	# or too dim (arena.json).
	env.tonemap_exposure = J.g(L, "exposure", 1.0) * 1.35
	env.tonemap_white = 6.0
	# Fog comes from data so the arena's mood is art-directable without code.
	var fog: Dictionary = L.get("fog", {"color": L.background, "near": 40, "far": 120})
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = CanvasRec.css(fog.color)
	env.fog_depth_begin = U.ft_to_m(fog.near)
	env.fog_depth_end = U.ft_to_m(fog.far)
	env.fog_density = 1.0
	env.fog_sky_affect = 0.0
	# Bloom: only genuinely bright things - the practicals, sparks and hot
	# metal - rather than every pale surface.
	var post: Dictionary = arena.get("post", {})
	var bloom: Dictionary = post.get("bloom", {})
	env.glow_enabled = post.get("enabled") != false
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = J.g(bloom, "threshold", 0.95)
	env.glow_hdr_scale = 2.0
	env.set_meta("bloom", J.g(bloom, "strength", 0.55))
	env.glow_intensity = J.g(bloom, "strength", 0.55) * 1.6
	_world_env = WorldEnvironment.new()
	_world_env.environment = env
	add_child(_world_env)

	# Key light casts the shadows.
	key_light = DirectionalLight3D.new()
	key_light.light_color = CanvasRec.css(L.key.color)
	key_light.light_energy = L.key.intensity * LIGHT_SCALE * 2.2
	key_light.shadow_enabled = true
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key_light.directional_shadow_max_distance = 60.0
	key_light.shadow_bias = 0.03
	key_light.shadow_normal_bias = 1.2
	add_child(key_light)
	key_light.look_at_from_position(U.ft3(L.key.pos), Vector3.ZERO)
	var fill := DirectionalLight3D.new()
	fill.light_color = CanvasRec.css(L.fill.color)
	fill.light_energy = L.fill.intensity * LIGHT_SCALE * 2.2
	fill.shadow_enabled = false
	add_child(fill)
	fill.look_at_from_position(U.ft3(L.fill.pos), Vector3.ZERO)
	# Overhead rigs, for the TV-studio look and specular highlights on armour.
	for r in L.get("rigs", []):
		var p := OmniLight3D.new()
		p.light_color = CanvasRec.css(r.color)
		p.light_energy = r.intensity * LIGHT_SCALE * 0.12
		p.omni_range = U.ft_to_m(r.distance)
		p.omni_attenuation = 2.0
		p.shadow_enabled = false
		p.position = U.ft3(r.pos)
		add_child(p)

	# The vignette: a soft darkening toward the corners, over the 3D picture
	# and under the HUD.
	var vg: Dictionary = post.get("vignette", {})
	if post.get("enabled") != false and vg.get("enabled") != false:
		var layer := CanvasLayer.new()
		layer.layer = -1
		_vignette = ColorRect.new()
		_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
		_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sh := Shader.new()
		sh.code = "shader_type canvas_item;\nuniform float offset = 1.1;\nuniform float darkness = 1.25;\nvoid fragment() {\n\tvec2 uv = (UV - vec2(0.5)) * vec2(offset);\n\tfloat v = smoothstep(0.35, 1.0, dot(uv, uv) * 1.6);\n\tCOLOR = vec4(0.0, 0.0, 0.0, clamp(v * (darkness - 0.55), 0.0, 0.85));\n}\n"
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("offset", J.g(vg, "offset", 1.1))
		sm.set_shader_parameter("darkness", J.g(vg, "darkness", 1.25))
		_vignette.material = sm
		layer.add_child(_vignette)
		add_child(layer)

## Settings -> Bloom and Shadows, applied at once.
func apply_settings(settings: Dictionary) -> void:
	env.glow_enabled = J.truthy(settings.get("bloom", true))
	key_light.shadow_enabled = J.truthy(settings.get("shadows", true))
