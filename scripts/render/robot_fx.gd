## robot_fx.gd - the robot's own shaders: paint that wears, metal that glows
## where it was just hit, and a spinning weapon drawn as a blur.
##
## robot_view.gd builds the robot and decides when; this file is how each of
## the two looks. Both are Settings entries (render/gfx.gd), read here once so
## the workshop's previews follow them as the fight does.
##
## WEAR. A panel that has taken damage gets its own copy of its material, as
## before - but as this shader, which does what the standard material did and
## then: chips the paint back to bare steel in a pattern that spreads as the
## panel's condition falls, lays soot over it, and scrapes it bright at each
## place it was actually hit (the same points the dents are pushed in at),
## with the scrape glowing orange for a second after the blow.
##
## BLUR. A rotor turning faster than a camera can freeze is not a bar going
## round: it is a disc you can partly see through. Above a certain speed the
## rotor's own mesh gives way to two surfaces of revolution worked out from
## it: a solid one wherever the rotor fills the whole turn (a disc's body, a
## drum's barrel, a hub) and a see-through one wherever it fills only part of
## it (the blades, the teeth), as thick as the share of the turn they fill.
## That share is measured, not guessed: the rotor is pictured once from along
## its axle and each ring of the picture counted.
class_name RobotFx

const MAX_SCARS := 8
const BINS := 36
const PICTURE := 144
# Rotor speeds (rad/s) the blur comes in over. Below, the mesh turns as it is.
const BLUR_FROM := 24.0
const BLUR_FULL := 58.0
# A ring this full of rotor is drawn solid.
const SOLID := 0.9

## Settings -> Battle damage on the paint / Spinner blur.
static var wear_on := true
static var blur_on := true

static var _wear: Shader = null
static var _ghost: Shader = null
static var _noise: ImageTexture = null
static var _profiles := {}     # key -> { r, cov, y0, y1, mat } measured rotor profiles
static var _waiting := {}      # key -> [Callable] while its picture is being taken

static func apply_settings(settings: Dictionary) -> void:
	wear_on = Gfx.on(settings, "gfxWear")
	blur_on = Gfx.on(settings, "gfxBlur")

# ---------------------------------------------------------------- wear

const WEAR_SHADER := "shader_type spatial;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D tex_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform sampler2D tex_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_scale = 0.0;
uniform sampler2D tex_finish : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
// 1: roughness (green) and metalness (blue) come from the finish map.
uniform float rough_map = 0.0;
uniform float metal_map = 0.0;
uniform float roughness = 0.6;
uniform float metallic = 0.1;
uniform float specular = 0.5;
uniform vec3 uv_scale = vec3(1.0);
// 0 as built .. 1 wrecked.
uniform float wear = 0.0;
uniform float seed = 0.0;
// Where the panel's own middle went when it came loose (the pattern stays put).
uniform vec3 origin = vec3(0.0);
uniform sampler2D tex_chips : filter_linear_mipmap, repeat_enable;
// Each hit: where (the panel's own space) and how wide (metres); and how hot it still is.
uniform vec4 hits[8];
uniform float heat[8];
varying vec3 v_pos;
varying vec3 v_nrm;

void vertex() {
	v_pos = VERTEX + origin;
	v_nrm = NORMAL;
	UV = UV * uv_scale.xy;
}

float grain(vec3 p) {
	vec3 w = abs(v_nrm) + 0.001;
	w /= w.x + w.y + w.z;
	return texture(tex_chips, p.yz).r * w.x + texture(tex_chips, p.xz).r * w.y + texture(tex_chips, p.xy).r * w.z;
}

void fragment() {
	vec3 col = texture(tex_albedo, UV).rgb * albedo.rgb;
	vec3 finish = texture(tex_finish, UV).rgb;
	float rough = roughness * mix(1.0, finish.g, rough_map);
	float metal = metallic * mix(1.0, finish.b, metal_map);

	float broad = grain(v_pos * 1.7 + seed * 7.0);
	float fine = grain(v_pos * 9.0 + seed * 3.0);
	float n = broad * 0.72 + fine * 0.28;
	// Chips: where the pattern stands above a level that sinks as the panel wears.
	float level = 0.9 - wear * 0.3;
	float worn = step(0.001, wear);
	float chip = smoothstep(level, level + 0.03, n) * worn;
	float rim = smoothstep(level - 0.07, level, n) * worn - chip;

	float scar = 0.0;
	float soot = 0.0;
	vec3 glow = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		float r = hits[i].w;
		if (r > 0.0) {
			float d = distance(v_pos, hits[i].xyz) / r;
			float ragged = d + (fine - 0.5) * 0.9;
			float core = 1.0 - smoothstep(0.3, 0.62, ragged);
			scar = max(scar, core);
			soot = max(soot, 1.0 - smoothstep(0.5, 1.5, d + (broad - 0.5) * 0.6));
			float h = heat[i];
			glow += mix(vec3(1.0, 0.14, 0.01), vec3(1.0, 0.5, 0.12), h) * h * h * 3.2 * (1.0 - smoothstep(0.0, 0.6, ragged));
		}
	}
	float bare = max(chip, scar);
	// Grime and scorching: more of both as it wears, and round every hit.
	float dirt = max(wear * (0.3 + 0.55 * broad), soot * 0.8);
	col *= 1.0 - dirt * 0.72;
	col = mix(col, col * 0.3, clamp(rim, 0.0, 1.0));
	vec3 steel = vec3(0.4, 0.41, 0.44) * (0.65 + 0.6 * fine);
	ALBEDO = mix(col, steel, bare);
	ROUGHNESS = mix(min(1.0, rough + dirt * 0.4), 0.48 + 0.25 * fine, bare);
	METALLIC = mix(metal * (1.0 - dirt * 0.5), 0.8, bare);
	SPECULAR = specular;
	NORMAL_MAP = texture(tex_normal, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	EMISSION = glow;
}
"

static func _noise_texture() -> ImageTexture:
	if _noise != null: return _noise
	var noise := FastNoiseLite.new()
	noise.seed = 19
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.03
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var img := noise.get_seamless_image(256, 256)
	img.generate_mipmaps()
	_noise = ImageTexture.create_from_image(img)
	return _noise

## A damaged panel's own material: `src` as the wear shader. `seed_value`
## (0..1) makes each panel chip in its own pattern.
static func wear_material(src: StandardMaterial3D, seed_value: float) -> ShaderMaterial:
	if _wear == null:
		_wear = Shader.new()
		_wear.code = WEAR_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _wear
	mat.set_shader_parameter("tex_chips", _noise_texture())
	mat.set_shader_parameter("seed", seed_value)
	copy_look(mat, src)
	return mat

## Carry a standard material's look over (again, when its paint arrives).
static func copy_look(mat: ShaderMaterial, src: StandardMaterial3D) -> void:
	mat.set_shader_parameter("albedo", src.albedo_color)
	mat.set_shader_parameter("tex_albedo", src.albedo_texture)
	mat.set_shader_parameter("tex_normal", src.normal_texture if src.normal_enabled else null)
	mat.set_shader_parameter("normal_scale", src.normal_scale if src.normal_enabled else 0.0)
	mat.set_shader_parameter("tex_finish", src.roughness_texture if src.roughness_texture != null else src.metallic_texture)
	mat.set_shader_parameter("rough_map", 1.0 if src.roughness_texture != null else 0.0)
	mat.set_shader_parameter("metal_map", 1.0 if src.metallic_texture != null else 0.0)
	mat.set_shader_parameter("roughness", src.roughness)
	mat.set_shader_parameter("metallic", src.metallic)
	mat.set_shader_parameter("specular", src.metallic_specular)
	mat.set_shader_parameter("uv_scale", src.uv1_scale)

# ---------------------------------------------------------------- blur

const GHOST_SHADER := "shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;
// Along its length: the rotor's colour at that radius, and (alpha) how much
// of the turn it fills there.
uniform sampler2D rings : source_color, filter_linear, repeat_disable;
uniform float r_max = 0.3;
uniform float fade = 1.0;
uniform float lobes = 2.0;
uniform float phase = 0.0;
varying float v_rho;
varying float v_ang;
void vertex() {
	v_rho = length(VERTEX.xz);
	v_ang = atan(VERTEX.z, VERTEX.x);
}
void fragment() {
	vec4 ring = texture(rings, vec2(v_rho / r_max, 0.5));
	// Streaks round the turn, as anything not quite even on the rotor draws.
	float streak = fract(sin(floor(v_rho * 330.0) * 12.9898) * 43758.5453);
	// And the ghost of the blades a shutter catches, drifting slowly round.
	float strobe = 0.5 + 0.5 * cos(lobes * (v_ang - phase));
	float a = clamp(pow(ring.a, 0.65) * (0.75 + 0.4 * streak) * (0.8 + 0.5 * strobe * strobe), 0.0, 0.97);
	ALBEDO = ring.rgb * (0.8 + 0.35 * streak);
	METALLIC = 0.65;
	ROUGHNESS = 0.32;
	// Seen through two skins (the near and the far side of the sweep).
	ALPHA = (1.0 - sqrt(1.0 - a)) * fade;
}
"

## The rotor's profile if it has been measured (or null): see measure().
static func profile_of(key: String):
	return _profiles.get(key)

## Measure a rotor: picture it from along its axle (its own Y) and count,
## ring by ring, how much of each turn it fills. `host` is any node in the
## scene (the picture needs a frame to be taken); `done` is called with the
## profile, a frame or two later.
static func measure(key: String, host: Node, mesh: ArrayMesh, done: Callable) -> void:
	if _profiles.has(key):
		done.call(_profiles[key])
		return
	var surfaces := mesh.get_surface_count()
	if surfaces == 0 or not host.is_inside_tree(): return
	# Two of the same robot ask for the one picture.
	if _waiting.has(key):
		_waiting[key].append(done)
		return
	_waiting[key] = [done]
	# Its reach, and how high it stands at each radius, from its vertices.
	var r_max := 0.0
	var all := []
	for s in surfaces:
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		all.append(verts)
		for v in verts: r_max = maxf(r_max, Vector2(v.x, v.z).length())
	if r_max < 0.01:
		_waiting.erase(key)
		return
	r_max *= 1.02
	var y0 := PackedFloat32Array()
	var y1 := PackedFloat32Array()
	y0.resize(BINS); y1.resize(BINS)
	y0.fill(INF); y1.fill(-INF)
	for s in surfaces:
		for v in (all[s] as PackedVector3Array):
			var b := mini(BINS - 1, int(Vector2(v.x, v.z).length() / r_max * BINS))
			y0[b] = minf(y0[b], v.y)
			y1[b] = maxf(y1[b], v.y)
	# The picture: the rotor alone on black, straight down its axle, each of
	# its materials in a shade of its own (so a ring knows what it is made of).
	var vp := SubViewport.new()
	vp.size = Vector2i(PICTURE, PICTURE)
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for s in surfaces:
		var flat := StandardMaterial3D.new()
		flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flat.albedo_color = Color8(_shade(s), 255, 0)
		flat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.set_surface_override_material(s, flat)
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = r_max * 2.0
	cam.near = 0.05
	cam.far = 20.0
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 10, 0), Vector3.ZERO, Vector3(0, 0, -1))
	cam.current = true
	host.add_child(vp)
	var tree := host.get_tree()
	await tree.process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var asked: Array = _waiting.get(key, [])
	_waiting.erase(key)
	if not is_instance_valid(vp): return
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty(): return
	img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var seen := PackedInt32Array()
	var full := PackedInt32Array()
	seen.resize(BINS); full.resize(BINS)
	var tally := []
	for i in BINS:
		var row := PackedInt32Array()
		row.resize(surfaces)
		tally.append(row)
	var c := PICTURE / 2.0
	for y in PICTURE:
		for x in PICTURE:
			var b := int(Vector2(x + 0.5 - c, y + 0.5 - c).length() / c * BINS)
			if b >= BINS: continue
			seen[b] += 1
			var at := (y * PICTURE + x) * 3
			if data[at + 1] < 128: continue
			full[b] += 1
			var best := 0
			for s in surfaces:
				if absi(data[at] - _shade(s)) < absi(data[at] - _shade(best)): best = s
			tally[b][best] += 1
	var cov := PackedFloat32Array()
	var mat := PackedInt32Array()
	cov.resize(BINS); mat.resize(BINS)
	for b in BINS:
		cov[b] = float(full[b]) / maxi(1, seen[b])
		var best := 0
		for s in surfaces:
			if tally[b][s] > tally[b][best]: best = s
		mat[b] = best if tally[b][best] > 0 else -1
	# The middle few pixels are too few to trust: a rotor is solid at its axle.
	for b in 2: cov[b] = maxf(cov[b], cov[2])
	# Rings no vertex falls in (the middle of a long flat face) take their
	# height and material from the rings either side.
	_fill_gaps(y0)
	_fill_gaps(y1)
	for b in BINS:
		if mat[b] < 0:
			for step in range(1, BINS):
				if b - step >= 0 and mat[b - step] >= 0:
					mat[b] = mat[b - step]
					break
				if b + step < BINS and mat[b + step] >= 0:
					mat[b] = mat[b + step]
					break
	var profile := {"r": r_max, "cov": cov, "y0": y0, "y1": y1, "mat": mat}
	_profiles[key] = profile
	for fn in asked:
		if (fn as Callable).is_valid(): fn.call(profile)

# The red a material is pictured in, by its place in the mesh.
static func _shade(surface: int) -> int:
	return mini(255, 40 + surface * 40)

static func _fill_gaps(ys: PackedFloat32Array) -> void:
	var known := []
	for b in BINS:
		if is_finite(ys[b]): known.append(b)
	if known.is_empty():
		ys.fill(0.0)
		return
	for b in BINS:
		if is_finite(ys[b]): continue
		var lo := -1
		var hi := -1
		for k in known:
			if k < b: lo = k
			elif hi < 0: hi = k
		if lo < 0: ys[b] = ys[hi]
		elif hi < 0: ys[b] = ys[lo]
		else: ys[b] = lerpf(ys[lo], ys[hi], float(b - lo) / (hi - lo))

# One closed band of the profile, rings a..b, as a surface of revolution.
static func _band(p: Dictionary, a: int, b: int, grow := 0.0) -> Geo:
	var dr: float = p.r / BINS
	var bottom := []
	var top := []
	for j in range(a, b + 2):
		# At a ring's edge: the mean of the two rings meeting there, within the band.
		var i0 := clampi(j - 1, a, b)
		var i1 := clampi(j, a, b)
		bottom.append(Vector2(j * dr, (p.y0[i0] + p.y0[i1]) / 2.0 - grow))
		top.append(Vector2(j * dr, (p.y1[i0] + p.y1[i1]) / 2.0 + grow))
	var prof := bottom.duplicate()
	top.reverse()
	prof.append_array(top)
	if a > 0: prof.append(bottom[0])
	return Geo.lathe(prof, 48)

## The blur's two meshes for a measured rotor, to stand where the rotor does:
## { solid: MeshInstance3D or null, ghost: MeshInstance3D or null }.
## `materials` are the rotor mesh's own, by surface; `lobes` how many blades
## or teeth go round.
static func build_blur(p: Dictionary, materials: Array, lobes: int) -> Dictionary:
	var out := {"solid": null, "ghost": null}
	var cov: PackedFloat32Array = p.cov
	var mat: PackedInt32Array = p.mat
	# Solid: runs of rings the rotor fills, one surface per material.
	var by_mat := {}
	var b := 0
	while b < BINS:
		if cov[b] < SOLID:
			b += 1
			continue
		var e := b
		while e + 1 < BINS and cov[e + 1] >= SOLID and mat[e + 1] == mat[b]: e += 1
		var m: Material = materials[clampi(mat[b], 0, materials.size() - 1)]
		if not by_mat.has(m): by_mat[m] = Geo.new()
		# A hair proud of the rotor's own faces, which it stands in for.
		by_mat[m].append(_band(p, b, e, 0.0005))
		b = e + 1
	if not by_mat.is_empty():
		var mesh := ArrayMesh.new()
		for m in by_mat: (by_mat[m] as Geo).add_to(mesh, m)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.visible = false
		out.solid = mi
	# Ghost: every run of rings it fills only part of.
	var ghost := Geo.new()
	b = 0
	while b < BINS:
		if cov[b] >= SOLID or cov[b] < 0.015:
			b += 1
			continue
		var e := b
		while e + 1 < BINS and cov[e + 1] < SOLID and cov[e + 1] >= 0.015: e += 1
		ghost.append(_band(p, b, e))
		b = e + 1
	if ghost.count() > 0:
		if _ghost == null:
			_ghost = Shader.new()
			_ghost.code = GHOST_SHADER
		var img := Image.create(BINS, 1, false, Image.FORMAT_RGBA8)
		for i in BINS:
			var m: Material = materials[clampi(mat[i], 0, materials.size() - 1)]
			var c := (m as BaseMaterial3D).albedo_color if m is BaseMaterial3D else Color(0.8, 0.8, 0.82)
			# Nothing drawn where the rotor is solid or absent: the band's own
			# ends fade to what is beside them.
			img.set_pixel(i, 0, Color(c.r, c.g, c.b, cov[i] if cov[i] < SOLID else 1.0))
		var sm := ShaderMaterial.new()
		sm.shader = _ghost
		sm.set_shader_parameter("rings", ImageTexture.create_from_image(img))
		sm.set_shader_parameter("r_max", p.r)
		sm.set_shader_parameter("lobes", float(maxi(1, lobes)))
		sm.set_shader_parameter("fade", 0.0)
		var mi := ghost.instance(sm, false)
		mi.visible = false
		out.ghost = mi
	return out
