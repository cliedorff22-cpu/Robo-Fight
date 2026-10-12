## stage.gd - the lighting rig and the look of the picture.
##
## Reads its setup from arena.json so the look is data-driven: a dim cold
## ambient, one hard key light for the shadows, a low fill and warm overhead
## practicals, with fog, a little bloom on what is genuinely bright and a
## vignette to pull the eye into the middle of the box.
##
## On top of that sit the renderer upgrades (render/gfx.gd lists them, one
## Settings entry each): the overhead rig as spotlights that cast shadows,
## with the venue's colour washes; softer key shadows over four ranges;
## ambient occlusion and bounced light; reflections, from the screen and from
## a probe of the hall; haze that shows the lights as beams; a broadcast
## colour grade; and depth of field for the intro and the replays. Each one
## switches on and off live in apply_settings().
##
## And the hall's own bounce (Settings -> Hall light bounce): the building is
## voxelised once as the fight loads, and from then on every lamp's light
## carries on off what it lands on - the deck lights the robots' flanks from
## below, a colour wash tints the wall behind it, the screens and the LED
## band light the people next to them.
class_name Stage
extends Node3D

## How the browser game's light intensities map onto this engine's: its
## lights are divided by pi on the way to the surface, this engine's are not.
const LIGHT_SCALE := 1.0 / PI
## The render layer of everything that never moves - the hall and the box.
## The reflection probe pictures that layer alone (no robots painted into the
## reflections), and the rig's spotlights leave it out of their shadows: only
## what moves - robots, debris, the hazards' arms - casts those.
const STATIC_LAYER := 2
const MOVING_LAYER := 1
## With the rig casting its own light and shadow, the old key, fill and
## ambient come down, so the box is lit in pools from above.
const RIG_KEY := 0.72
const RIG_FILL := 0.6
const RIG_AMBIENT := 0.6
## With the hall's bounce on, the flat ambient steps back for it: what fills
## the shadows then is light that came off something.
const BOUNCE_AMBIENT := 0.55

var env: Environment
var key_light: DirectionalLight3D
var _world_env: WorldEnvironment
var _vignette: ColorRect
var _fill: DirectionalLight3D
var _omnis: Array[OmniLight3D] = []
var _spots: Array[SpotLight3D] = []
var _casters: Array[SpotLight3D] = []
var _washes: Array[SpotLight3D] = []
var _probe: ReflectionProbe = null
var _gi: VoxelGI = null
var _gi_key := ""
var _gi_from: Node = null
var _half := Vector2(7.3, 7.3)
var _key_energy := 1.0
var _fill_energy := 1.0
var _ambient_energy := 1.0
var _fog_color := Color.BLACK
var _lens: CameraAttributesPractical
var _focus_m := 8.0
var _settings := {}
var _applied := false

static var _grade_lut: ImageTexture3D = null
## The hall, voxelised, by venue and layout: a rematch need not do it again.
static var _gi_baked := {}

## `venue`: the building's entry in arenas.json (its beam colours wash the box).
func _init(arena: Dictionary, venue = null) -> void:
	name = "Stage"
	var L: Dictionary = arena.lighting
	_half = Vector2(U.ft_to_m(arena.floor.size[0]) / 2.0, U.ft_to_m(arena.floor.size[1]) / 2.0)
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = CanvasRec.css(L.background)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = CanvasRec.css(L.ambient.color)
	_ambient_energy = L.ambient.intensity * LIGHT_SCALE * 1.6
	env.ambient_light_energy = _ambient_energy
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
	_fog_color = CanvasRec.css(fog.color)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = _fog_color
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
	_setup_upgrades()
	_world_env = WorldEnvironment.new()
	_world_env.environment = env
	add_child(_world_env)

	# Key light casts the shadows.
	key_light = DirectionalLight3D.new()
	key_light.light_color = CanvasRec.css(L.key.color)
	_key_energy = L.key.intensity * LIGHT_SCALE * 2.2
	key_light.light_energy = _key_energy
	key_light.shadow_enabled = true
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key_light.directional_shadow_max_distance = 60.0
	key_light.shadow_bias = 0.03
	key_light.shadow_normal_bias = 1.2
	# The haze is lit by the rig, not by the key: a key-lit hall is one flat glow.
	key_light.light_volumetric_fog_energy = 0.0
	add_child(key_light)
	key_light.look_at_from_position(U.ft3(L.key.pos), Vector3.ZERO)
	_fill = DirectionalLight3D.new()
	_fill.light_color = CanvasRec.css(L.fill.color)
	_fill_energy = L.fill.intensity * LIGHT_SCALE * 2.2
	_fill.light_energy = _fill_energy
	_fill.shadow_enabled = false
	_fill.light_volumetric_fog_energy = 0.0
	add_child(_fill)
	_fill.look_at_from_position(U.ft3(L.fill.pos), Vector3.ZERO)
	# Overhead rigs, for the TV-studio look and specular highlights on armour.
	# Twice over: as plain lamps (the old picture) and as spotlights that cast
	# shadows (Settings -> Stage lights); only one set is lit at a time.
	for r in L.get("rigs", []):
		var p := OmniLight3D.new()
		p.light_color = CanvasRec.css(r.color)
		p.light_energy = r.intensity * LIGHT_SCALE * 0.12
		p.omni_range = U.ft_to_m(r.distance)
		p.omni_attenuation = 2.0
		p.shadow_enabled = false
		p.light_volumetric_fog_energy = 0.0
		p.position = U.ft3(r.pos)
		add_child(p)
		_omnis.append(p)
		var at: Vector3 = U.ft3(r.pos)
		var s := SpotLight3D.new()
		s.light_color = CanvasRec.css(r.color)
		s.light_energy = r.intensity * LIGHT_SCALE * 0.1
		# No further than the deck needs: every pixel a lamp reaches pays for it.
		s.spot_range = at.y * 2.0
		s.spot_attenuation = 0.9
		s.spot_angle = 44.0
		s.spot_angle_attenuation = 0.7
		s.light_size = 0.35
		s.shadow_enabled = false
		s.shadow_bias = 0.06
		s.shadow_normal_bias = 1.5
		s.shadow_blur = 1.6
		s.shadow_caster_mask = MOVING_LAYER
		# Little glare of their own: seen from the overhead camera the deck
		# mirrors a lamp straight back, and four of them white it out.
		s.light_specular = 0.15
		s.light_volumetric_fog_energy = 1.3
		s.visible = false
		add_child(s)
		# Each lamp is aimed at its own quarter of the deck, a little in from
		# straight down, so the pools overlap in the middle.
		s.look_at_from_position(at, Vector3(at.x * 0.55, 0.0, at.z * 0.55), Vector3(0, 0, -1) if absf(at.x) < 0.01 else Vector3.UP)
		# Shadows from one lamp in two - opposite corners of the rig. All four
		# cost another 0.6 ms a frame for shadows that land under the robots,
		# where the first two and the contact shading already are.
		if _spots.size() % 3 == 0: _casters.append(s)
		_spots.append(s)
	_build_washes(venue)

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

	_lens = CameraAttributesPractical.new()
	_lens.dof_blur_amount = 0.07

# The upgrades' fixed numbers; apply_settings() only switches them.
func _setup_upgrades() -> void:
	# Contact shading: tight, so it reads as parts meeting rather than as a
	# dark halo round everything.
	env.ssao_radius = 0.9
	env.ssao_intensity = 3.0
	env.ssao_power = 1.6
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.45
	env.ssil_radius = 3.5
	env.ssil_intensity = 1.1
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0
	env.ssr_max_steps = 32
	env.ssr_fade_in = 0.12
	env.ssr_fade_out = 2.2
	env.ssr_depth_tolerance = 0.25
	# Haze: thin enough that the far stand still reads, thick enough that a
	# spotlight draws its cone.
	env.volumetric_fog_density = 0.006
	env.volumetric_fog_albedo = Color(0.9, 0.92, 1.0)
	env.volumetric_fog_emission = _fog_color
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 70.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.0
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_gi_inject = 0.0
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.9
	env.adjustment_color_correction = _grade()
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_LOW, true, 0.5, 2, 50.0, 300.0)
	RenderingServer.environment_set_ssil_quality(RenderingServer.ENV_SSIL_QUALITY_VERY_LOW, true, 0.5, 4, 50.0, 300.0)
	RenderingServer.environment_set_ssr_half_size(true)
	RenderingServer.environment_set_volumetric_fog_volume_size(48, 48)
	RenderingServer.environment_set_volumetric_fog_filter_active(true)
	RenderingServer.camera_attributes_set_dof_blur_quality(RenderingServer.DOF_BLUR_QUALITY_LOW, true)
	RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(RenderingServer.DOF_BOKEH_HEXAGON)
	# The bounce is soft light: traced with few cones, at half the picture's size.
	RenderingServer.voxel_gi_set_quality(RenderingServer.VOXEL_GI_QUALITY_LOW)
	RenderingServer.gi_set_use_half_resolution(true)

# The colour washes: a venue whose rig has coloured beams throws two of them
# across the deck from opposite corners, as the real box does.
func _build_washes(venue) -> void:
	if not (venue is Dictionary): return
	var L: Dictionary = venue.get("lights", {})
	if not J.truthy(L.get("beams")): return
	var colors: Array[Color] = []
	for c in L.get("beamColors", []):
		var col := CanvasRec.css(c)
		if col.s > 0.3: colors.append(col)
	if colors.is_empty(): return
	if colors.size() == 1: colors.append(colors[0])
	var reach := maxf(_half.x, _half.y) + 2.5
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var at := Vector3(side * reach, 9.5, -side * reach)
		var w := SpotLight3D.new()
		w.light_color = colors[i]
		w.light_energy = 1.0
		w.spot_range = reach * 3.2
		w.spot_attenuation = 0.25
		w.spot_angle = 30.0
		w.spot_angle_attenuation = 0.9
		w.shadow_enabled = false
		w.light_specular = 1.4
		w.light_volumetric_fog_energy = 0.45
		w.visible = false
		add_child(w)
		# Aimed past the middle, so its own corner is not burned out.
		w.look_at_from_position(at, Vector3(-side * _half.x * 0.3, 0.0, side * _half.y * 0.3))
		_washes.append(w)

# The broadcast grade, as a colour cube: deeper blacks with a cool cast, a
# gentle shoulder with a warm one, and a touch more colour in the mid-tones.
static func _grade() -> ImageTexture3D:
	if _grade_lut != null: return _grade_lut
	var n := 24
	var slices: Array[Image] = []
	for b in n:
		var img := Image.create(n, n, false, Image.FORMAT_RGB8)
		for g in n:
			for r in n:
				var c := Vector3(r, g, b) / float(n - 1)
				var luma := c.dot(Vector3(0.2126, 0.7152, 0.0722))
				# Contrast: an S-curve about the mid-tones.
				var curved := luma * luma * (3.0 - 2.0 * luma)
				var k := lerpf(luma, curved, 0.38)
				c *= k / maxf(luma, 1e-4)
				# Colour: richer mid-tones, less so at the two ends.
				var sat := 1.0 + 0.2 * (1.0 - absf(k * 2.0 - 1.0))
				c = Vector3(k, k, k).lerp(c, sat)
				# Cool shadows, warm highlights.
				var sh := 1.0 - smoothstep(0.0, 0.45, k)
				var hi := smoothstep(0.55, 1.0, k)
				c *= Vector3(1.0 - 0.07 * sh + 0.035 * hi, 1.0 - 0.01 * sh + 0.01 * hi, 1.0 + 0.09 * sh - 0.05 * hi)
				img.set_pixel(r, g, Color(clampf(c.x, 0.0, 1.0), clampf(c.y, 0.0, 1.0), clampf(c.z, 0.0, 1.0)))
		slices.append(img)
	_grade_lut = ImageTexture3D.new()
	_grade_lut.create(Image.FORMAT_RGB8, n, n, n, false, slices)
	return _grade_lut

func _ready() -> void:
	if not _applied: apply_settings({})

## The hall and the box, once they are built: what the reflection probe
## pictures. Robots are left out, or they would be painted into every
## reflection where they stood at the bell. `moving` are the parts of those
## that move (the hazards' arms, screws and blades): they stay with the robots.
func reflect(roots: Array, moving: Array = [], key := "") -> void:
	for root in roots:
		for n in (root as Node).find_children("*", "GeometryInstance3D", true, false):
			if not moving.has(n): (n as GeometryInstance3D).layers = STATIC_LAYER
	_probe = ReflectionProbe.new()
	_probe.update_mode = ReflectionProbe.UPDATE_ONCE
	_probe.box_projection = true
	_probe.interior = false
	_probe.enable_shadows = false
	_probe.cull_mask = STATIC_LAYER
	# The room's own ambient light stays as it was; the probe adds reflections only.
	_probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	_probe.intensity = 1.0
	var reach := 16.0
	_probe.size = Vector3((_half.x + reach) * 2.0, 26.0, (_half.y + reach) * 2.0)
	_probe.position = Vector3(0, 12.0, 0)
	# Pictured from head height in the middle of the deck.
	_probe.origin_offset = Vector3(0, -10.4, 0)
	_probe.max_distance = 160.0
	_probe.blend_distance = 2.0
	_probe.visible = Gfx.on(_settings, "gfxProbe")
	add_child(_probe)
	# The same hall is what light bounces round in. What moves takes that light
	# but gives none back (a robot would leave its shadow in the bounce where it
	# stood at the bell); nor does anything see-through, or the lexan would
	# wall the box in.
	for n in moving:
		if n is GeometryInstance3D: (n as GeometryInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for root in roots:
		for n in (root as Node).find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh == null or mi.mesh.get_surface_count() == 0: continue
			var m := mi.mesh.surface_get_material(0)
			if m is ShaderMaterial or (m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED):
				mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_gi_from = get_parent()
	_gi_key = key
	if Gfx.on(_settings, "gfxGI"): _bounce(true)

# The hall's bounce on or off. It is voxelised the first time it is wanted
# (about a second), then kept.
func _bounce(on: bool) -> void:
	if not on:
		if _gi != null: _gi.visible = false
		return
	if _gi == null:
		if _gi_from == null: return
		_gi = VoxelGI.new()
		_gi.subdiv = VoxelGI.SUBDIV_128
		# The box, and the first rows of the stands round it.
		var reach := 7.0
		_gi.size = Vector3((_half.x + reach) * 2.0, 13.0, (_half.y + reach) * 2.0)
		_gi.position = Vector3(0, 5.5, 0)
		add_child(_gi)
		if _gi_baked.has(_gi_key):
			_gi.data = _gi_baked[_gi_key]
		else:
			var t0 := Time.get_ticks_msec()
			_gi.bake(_gi_from)
			if _gi.data != null:
				_gi.data.interior = false
				_gi.data.energy = 2.4
				_gi.data.propagation = 0.6
				_gi.data.use_two_bounces = true
				_gi.data.dynamic_range = 3.0
				_gi.data.bias = 1.6
				_gi.data.normal_bias = 0.6
				if _gi_key != "": _gi_baked[_gi_key] = _gi.data
			print("[stage] hall voxelised for light bounce in %d ms" % (Time.get_ticks_msec() - t0))
	_gi.visible = true

## The window's own share of the settings: how edges are smoothed and at what
## resolution the 3D picture is drawn. (The menus have no 3D of their own on
## the window, so this is the fight's.)
static func apply_viewport(vp: Viewport, settings: Dictionary) -> void:
	var aa := Gfx.choice(settings, "gfxAA")
	vp.msaa_3d = Viewport.MSAA_4X if aa == "msaa" else Viewport.MSAA_DISABLED
	# FSR 2 does its own smoothing over time and will not run beside TAA: one
	# off before the other on.
	vp.use_taa = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if aa == "fsr2" else Viewport.SCALING_3D_MODE_BILINEAR
	vp.use_taa = aa == "taa"
	vp.scaling_3d_scale = clampf(float(settings.get("renderScale", "1")), 0.25, 1.0)
	# The two that build the picture up over several frames keep textures
	# crisp by reading them a little sharper than the pixel grid asks for.
	vp.texture_mipmap_bias = -0.5 if aa != "msaa" else 0.0
	# A quarter of the shadow atlas for each of the rig's lamps.
	vp.positional_shadow_atlas_size = 2048
	for q in 4: vp.set_positional_shadow_atlas_quadrant_subdiv(q, Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1)

## Everything on the Settings page that is the picture's, applied at once.
func apply_settings(settings: Dictionary) -> void:
	_applied = true
	_settings = settings
	var shadows: bool = J.truthy(settings.get("shadows", true))
	var rigs := Gfx.on(settings, "gfxRigs")
	var soft := Gfx.on(settings, "gfxSoftShadows")
	env.glow_enabled = J.truthy(settings.get("bloom", true))

	# The rig: spotlights with shadows, or the old plain lamps.
	for o in _omnis: o.visible = not rigs
	for s in _spots:
		s.visible = rigs
		s.shadow_enabled = shadows and _casters.has(s)
	for w in _washes: w.visible = rigs
	key_light.light_energy = _key_energy * (RIG_KEY if rigs else 1.0)
	# Less of the key's own glare on the deck: the rig makes the highlights now.
	key_light.light_specular = 0.35 if rigs else 1.0
	_fill.light_energy = _fill_energy * (RIG_FILL if rigs else 1.0)
	env.ambient_light_energy = _ambient_energy * (RIG_AMBIENT if rigs else 1.0) * (BOUNCE_AMBIENT if Gfx.on(settings, "gfxGI") else 1.0)

	# The key's shadow: four ranges with soft edges, or the old two.
	key_light.shadow_enabled = shadows
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if soft else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key_light.directional_shadow_blend_splits = soft
	key_light.directional_shadow_max_distance = 48.0 if soft else 60.0
	# Softness from a wider, better filter. (A true penumbra - the light's
	# angular size - costs 1.5 ms a frame here, three times what this does.)
	key_light.shadow_blur = 2.2 if soft else 1.0
	# The lamps' own shadows are filtered the cheap way: they are faint, and
	# four lamps' worth of the better filter is paid on every pixel of the deck.
	RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM if soft else RenderingServer.SHADOW_QUALITY_SOFT_LOW)

	env.ssao_enabled = Gfx.on(settings, "gfxSSAO")
	env.ssil_enabled = Gfx.on(settings, "gfxSSIL")
	env.ssr_enabled = Gfx.on(settings, "gfxSSR")
	env.volumetric_fog_enabled = Gfx.on(settings, "gfxFog")
	env.adjustment_enabled = Gfx.on(settings, "gfxGrade")
	_floor_finish(Gfx.on(settings, "gfxSSR") or Gfx.on(settings, "gfxProbe"))
	if _probe != null:
		_probe.visible = Gfx.on(settings, "gfxProbe")
		# Moved a hair, the probe pictures the hall again - under the new lights.
		_probe.position.y = 12.0 + (0.001 if is_equal_approx(_probe.position.y, 12.0) else 0.0)
	if not Gfx.on(settings, "gfxDOF"): _blur(false)
	if _gi_from != null: _bounce(Gfx.on(settings, "gfxGI"))

# A reflection needs something to show in: with reflections on, the deck is
# worn smooth rather than matt, as a floor that robots slide across is.
func _floor_finish(glossy: bool) -> void:
	var deck: StandardMaterial3D = Mats.shared().lib.get("steelFloor")
	if deck == null: return
	# The material is shared by every fight: its own finish is kept on it.
	if not deck.has_meta("matt"): deck.set_meta("matt", Vector2(deck.roughness, deck.metallic))
	var matt: Vector2 = deck.get_meta("matt")
	deck.roughness = 0.5 if glossy else matt.x
	deck.metallic = 0.32 if glossy else matt.y

func _blur(on: bool) -> void:
	_lens.dof_blur_far_enabled = on
	_lens.dof_blur_near_enabled = on

## Once a frame: the lens. `cinematic` is the intro and the replays, where
## the camera holds focus on `subject` and lets the hall fall soft behind it.
func focus(cam: Camera3D, subject: Vector3, cinematic: bool, dt: float) -> void:
	if cam.attributes != _lens: cam.attributes = _lens
	var on := cinematic and Gfx.on(_settings, "gfxDOF")
	_blur(on)
	if not on: return
	var d := cam.global_position.distance_to(subject)
	_focus_m = lerpf(_focus_m, d, 1.0 - exp(-dt / 0.15))
	# Sharp from a little in front of the robot to well behind it; the far
	# stand and anything right under the lens go soft.
	_lens.dof_blur_far_distance = _focus_m + 3.5
	_lens.dof_blur_far_transition = maxf(6.0, _focus_m * 1.2)
	_lens.dof_blur_near_distance = maxf(0.4, _focus_m * 0.45)
	_lens.dof_blur_near_transition = maxf(0.3, _focus_m * 0.3)
