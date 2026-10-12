## materials.gd - the shared materials, with procedurally generated maps.
##
## Every map is drawn at boot (tex_paint.gd); with "Scanned surfaces" on
## (graphics tier 3) the same materials wear photographed texture sets from
## assets/textures instead - see SCANNED and set_scanned below.
## Materials are keyed by the `material` strings used in parts.json and
## arena.json, so data picks the look.
##
## Art direction of the drawn maps: clean panels, readable shapes, a
## restrained amount of wear. Wear levels come from arena.json's `style`
## block, so the whole look is a data edit: `floorWear` 0 is factory-new.
class_name Mats
extends RefCounted

static var _shared: Mats = null

var lib := {}                 # name -> StandardMaterial3D
var style := {}
var _livery := {}             # hex -> material
var _wear_albedo: Texture2D
var _wear_normal: Texture2D
var _nrm := 0.35

# ---- scanned surfaces (graphics tier 3). Texture sets photographed from real
# steel, rubber, plastic and concrete (CC0, see assets/CREDITS.md) take the
# place of the generated maps on the same materials, so the switch is live.
static var _want_scanned := true
const SCAN_PATH := "res://assets/textures/%s/%s.jpg"
# material -> [texture set, repeats, tint, metallic, roughness (times the
# scan's own), normal strength]. A tint above white brightens a scan.
const SCANNED := {
	"steel": ["steel", 2.0, Color(1.0, 1.0, 1.0), 0.6, 1.0, 1.0],
	"darkSteel": ["dark_steel", 2.0, Color(1.25, 1.25, 1.25), 0.45, 0.85, 1.0],
	"augerFlight": ["steel", 2.0, Color(0.9, 0.9, 0.9), 0.6, 1.0, 1.0],
	"sawBlade": ["brushed", 1.0, Color(1.35, 1.37, 1.4), 0.9, 0.55, 0.6],
	"ar500_steel": ["steel", 2.0, Color(0.95, 0.96, 0.98), 0.6, 1.05, 1.0],
	"grade5_ti": ["machined", 2.0, Color(1.05, 1.05, 1.06), 0.65, 0.95, 0.8],
	"hardox": ["steel", 2.0, Color(0.72, 0.74, 0.78), 0.6, 1.1, 1.0],
	"uhmw": ["plastic", 1.4, Color(0.9, 0.88, 0.83), 0.0, 1.0, 1.0],
	"rubber": ["rubber", 3.0, Color(1.0, 1.0, 1.0), 0.0, 1.0, 1.0],
	"hub": ["machined", 2.0, Color(0.95, 0.96, 0.98), 0.75, 0.9, 1.0],
	"hubFine": ["machined", 2.0, Color(0.95, 0.96, 0.98), 0.75, 0.9, 1.0],
	"weaponSteel": ["brushed", 1.5, Color(1.3, 1.31, 1.33), 0.85, 0.8, 0.8],
	"weaponSteelFine": ["brushed", 1.5, Color(1.3, 1.31, 1.33), 0.85, 0.8, 0.8],
	"robotDark": ["machined", 2.0, Color(0.5, 0.51, 0.54), 0.8, 0.95, 1.0],
	"robotDarkFine": ["machined", 2.0, Color(0.5, 0.51, 0.54), 0.8, 0.95, 1.0],
}
# The deck: [texture set, repeats across the floor, tint] and its finish as
# (roughness, metalness), matt and with reflections on (see Stage._floor_finish).
const SCANNED_DECK := ["deck", 9.0, Color(0.78, 0.8, 0.84)]
const DECK_MATT := Vector2(0.76, 0.18)
const DECK_GLOSS := Vector2(0.5, 0.32)
const SCANNED_DECK_MATT := Vector2(1.55, 0.3)
const SCANNED_DECK_GLOSS := Vector2(1.1, 0.42)
var scanned := false
var _plain := {}              # material -> its generated look, to go back to
var _surfaces := []           # [[material, set, repeats, tint, metallic, roughness]] made by surface()
var _arena_repeat := 4.0
var _deck_overlay = null      # { albedo, normal }: seams and stains over the scanned deck

## The one library everything draws with. `style` is arena.json's style block
## (only read the first time).
static func shared(style_block: Dictionary = {}, arena_repeat := 4.0) -> Mats:
	if _shared == null:
		_shared = Mats.new(style_block, arena_repeat)
		_shared.set_scanned(_want_scanned)
	return _shared

## The Graphics settings that are the materials' own: scanned surfaces.
static func apply_settings(settings: Dictionary) -> void:
	_want_scanned = Gfx.on(settings, "gfxTextures")
	if _shared != null: _shared.set_scanned(_want_scanned)

## A material by name ("steel", "rubber", "weaponSteel" ...), or null.
func m(name: String) -> StandardMaterial3D:
	return lib.get(name)

## Look up a material by the string a data file used; falls back to dark steel.
func by_name(name) -> StandardMaterial3D:
	return lib.get(str(name), lib.darkSteel)

static func _std(color: Color, metal: float, rough: float, albedo: Texture2D = null, normal: Texture2D = null, normal_scale := 0.35) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metal
	mat.roughness = rough
	mat.metallic_specular = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if albedo != null: mat.albedo_texture = albedo
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = normal_scale
	return mat

func _init(style_block: Dictionary, arena_repeat: float) -> void:
	style = style_block
	_arena_repeat = arena_repeat
	var floor_wear: float = J.g(style, "floorWear", 0.22)
	var metal_wear: float = J.g(style, "metalWear", 0.3)
	_nrm = J.g(style, "normalStrength", 0.35)
	var nrm := _nrm

	var floor_maps := _steel_floor(floor_wear)
	var steel_m := _grimy_metal(Color.html("#6f757e"), metal_wear, 11)
	var dark_m := _grimy_metal(Color.html("#3d4148"), metal_wear * 0.7, 12)
	# Weapons are kept clean and bright: brushed grain, hardly any rust.
	var clean_m := _grimy_metal(Color.html("#8e959f"), metal_wear * 0.12, 13)
	var stripes := _hazard_stripes(metal_wear)
	var lexan := _lexan(metal_wear)
	var wear := _paint_wear(metal_wear)
	_wear_albedo = wear.albedo
	_wear_normal = wear.normal
	var machined := _machined_roughness()
	var rep := func(mat: StandardMaterial3D, k: float) -> StandardMaterial3D:
		mat.uv1_scale = Vector3(k, k, k)
		return mat

	# --- arena. Low metalness: fully metallic surfaces take all their colour
	# from reflections, which reads as muddy in a dark hall.
	var floor_mat := _std(Color.WHITE, 0.18, 0.76, floor_maps.albedo, floor_maps.normal, nrm)
	floor_mat.roughness_texture = floor_maps.rough
	floor_mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	lib.steelFloor = rep.call(floor_mat, arena_repeat)
	floor_mat.set_meta("matt", DECK_MATT)
	floor_mat.set_meta("gloss", DECK_GLOSS)
	lib.steel = rep.call(_std(Color.html("#aeb4bd"), 0.45, 0.48, steel_m.albedo, steel_m.normal, nrm), 3.0)
	lib.darkSteel = rep.call(_std(Color.html("#8c929b"), 0.4, 0.58, dark_m.albedo, dark_m.normal, nrm * 0.8), 3.0)

	var poly := _std(Color(Color.html("#cfe0ee"), 0.1), 0.0, 0.14, lexan.albedo, lexan.normal, nrm * 0.5)
	poly.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	poly.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	poly.clearcoat_enabled = true
	poly.clearcoat = 0.6
	poly.clearcoat_roughness = 0.2
	poly.shadow_to_opacity = false
	lib.polycarbonate = rep.call(poly, 2.0)

	lib.hazardStripe = rep.call(_std(Color.WHITE, 0.25, 0.66, stripes.albedo, stripes.normal, nrm * 0.7), 4.0)
	# Auger flights: a thin ribbon, so both faces must draw.
	var flight := _std(Color.html("#9aa0a8"), 0.45, 0.5, dark_m.albedo)
	flight.cull_mode = BaseMaterial3D.CULL_DISABLED
	lib.augerFlight = rep.call(flight, 3.0)
	# Killsaw blades: bright, hard, and deliberately a bit shiny so they catch
	# the eye the instant they come up out of the deck.
	lib.sawBlade = _std(Color.html("#d6dbe2"), 0.75, 0.22)

	# --- robot part materials, keyed by `material` in parts.json
	lib.ar500_steel = rep.call(_std(Color.html("#9ea5ae"), 0.4, 0.56, steel_m.albedo, steel_m.normal, nrm), 3.0)
	lib.grade5_ti = rep.call(_std(Color.html("#b4bac3"), 0.38, 0.5, steel_m.albedo, steel_m.normal, nrm * 0.8), 3.0)
	lib.hardox = rep.call(_std(Color.html("#7f878f"), 0.45, 0.5, steel_m.albedo, steel_m.normal, nrm), 3.0)
	lib.uhmw = rep.call(_std(Color.html("#ded9cd"), 0.0, 0.78, wear.albedo, wear.normal, nrm * 0.6), 1.4)
	lib.rubber = rep.call(_std(Color.html("#2a2c31"), 0.0, 0.92, wear.albedo, wear.normal, nrm * 0.5), 1.4)
	lib.hub = rep.call(_std(Color.html("#7e858f"), 0.4, 0.56, steel_m.albedo, steel_m.normal, 1.0), 3.0)

	# --- robot-only materials. Weapons are bright tool steel, so they read
	# against any paint; `robotDark` is hardened inserts, teeth and rails.
	lib.weaponSteel = rep.call(_std(Color.html("#f2f4f7"), 0.72, 0.36, clean_m.albedo, clean_m.normal, nrm * 0.5), 2.0)
	lib.robotDark = rep.call(_std(Color.html("#9aa0a8"), 0.7, 0.42, dark_m.albedo), 3.0)
	# The same three with a machined sheen. The map's mid grey is 0.6, so each
	# roughness here is its plain twin's divided by 0.6.
	for pair in [["weaponSteelFine", "weaponSteel", 0.36], ["robotDarkFine", "robotDark", 0.42], ["hubFine", "hub", 0.56]]:
		var fine: StandardMaterial3D = lib[pair[1]].duplicate()
		fine.roughness_texture = machined
		fine.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		fine.roughness = pair[2] / 0.6
		lib[pair[0]] = fine
	# A power light: every bot on the show has to carry one.
	var lamp := _std(Color.html("#3dff7a"), 0.0, 0.3)
	lamp.emission_enabled = true
	lamp.emission = Color.html("#2bff6a")
	lamp.emission_energy_multiplier = 2.2
	lib.powerLight = lamp

## A livery colour as a painted panel, memoised by colour. The wear map
## multiplies the colour, so every bot's paint is scraped and sooty.
func livery(hex) -> StandardMaterial3D:
	var key := str(hex)
	if not _livery.has(key):
		# Low metalness and a flat-ish roughness, so livery colours stay the
		# colour they were picked as instead of going grey.
		var mat := _std(CanvasRec.css(key), 0.12, 0.6, _wear_albedo, _wear_normal, _nrm * 0.6)
		mat.uv1_scale = Vector3(1.4, 1.4, 1.4)
		_livery[key] = mat
	return _livery[key]

## A robot's own paint job, before its picture is ready: plain `base` colour.
## paint_shop.gd fills in the maps (set_paint_maps) a frame or two later.
func robot_paint(base: Color) -> StandardMaterial3D:
	return _std(base, 0.1, 0.55)

## Give a paint material its painted maps: the colour, and optionally the
## surface detail - a normal map from the height picture, and roughness and
## metalness from the finish map's green and blue, which then carry the
## whole value.
func set_paint_maps(mat: StandardMaterial3D, maps: Dictionary) -> void:
	if maps.get("color") == null: return
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = maps.color
	if maps.get("normal") != null:
		mat.normal_enabled = true
		mat.normal_texture = maps.normal
		mat.normal_scale = J.g(style, "bumpScale", 1.2)
	if maps.get("finish") != null:
		mat.roughness_texture = maps.finish
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.metallic_texture = maps.finish
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		mat.roughness = 1.0
		mat.metallic = 1.0

# ---------------------------------------------------------------- scanned surfaces

static func _scan(set_name: String, map: String) -> Texture2D:
	var path := SCAN_PATH % [set_name, map]
	return load(path) if ResourceLoader.exists(path) else null

## True if the texture sets are there to use (they ship with the game; a
## copy without its assets folder falls back to the generated maps).
static func has_scans() -> bool:
	return ResourceLoader.exists(SCAN_PATH % ["deck", "color"])

const _KEPT := ["albedo_color", "albedo_texture", "normal_enabled", "normal_texture", "normal_scale",
	"roughness_texture", "roughness_texture_channel", "roughness", "metallic", "uv1_scale", "detail_enabled"]

func _keep(mat: StandardMaterial3D) -> void:
	if _plain.has(mat): return
	var d := {}
	for k in _KEPT: d[k] = mat.get(k)
	_plain[mat] = d

func _dress(mat: StandardMaterial3D, set_name: String, repeats: float, tint: Color, metal: float, rough: float, normal := 1.0) -> void:
	_keep(mat)
	mat.albedo_color = Color(tint.r, tint.g, tint.b, mat.albedo_color.a)
	mat.albedo_texture = _scan(set_name, "color")
	mat.normal_enabled = true
	mat.normal_texture = _scan(set_name, "normal")
	mat.normal_scale = normal
	mat.roughness_texture = _scan(set_name, "rough")
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.roughness = rough
	mat.metallic = metal
	mat.uv1_scale = Vector3(repeats, repeats, repeats)

## Switch every material between its scanned texture set and its generated
## maps. The materials stay the same objects, so what is already on screen
## changes with them.
func set_scanned(on: bool) -> void:
	on = on and has_scans()
	if on == scanned: return
	scanned = on
	var deck: StandardMaterial3D = lib.steelFloor
	if not on:
		for mat in _plain:
			for k in _plain[mat]: mat.set(k, _plain[mat][k])
		deck.set_meta("matt", DECK_MATT)
		deck.set_meta("gloss", DECK_GLOSS)
		return
	for name in SCANNED:
		var q: Array = SCANNED[name]
		_dress(lib[name], q[0], q[1], q[2], q[3], q[4], q[5])
	for q in _surfaces: _dress(q[0], q[1], q[2], q[3], q[4], q[5])
	# The deck: scanned steel close up, with the plates' seams and the years
	# of oil, rubber and scuffs laid over it once across each four plates (the
	# detail layer, on the second UV set) so the scan's repeat never shows.
	_dress(deck, SCANNED_DECK[0], SCANNED_DECK[1], SCANNED_DECK[2], SCANNED_DECK_MATT.y, SCANNED_DECK_MATT.x)
	deck.set_meta("matt", SCANNED_DECK_MATT)
	deck.set_meta("gloss", SCANNED_DECK_GLOSS)
	if _deck_overlay == null: _deck_overlay = _deck_marks(J.g(style, "floorWear", 0.22))
	deck.detail_enabled = true
	deck.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	deck.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	deck.detail_albedo = _deck_overlay.albedo
	deck.detail_normal = _deck_overlay.normal
	deck.uv2_scale = Vector3(_arena_repeat, _arena_repeat, _arena_repeat)

## A plain tiling surface for the hall (concrete, painted steel): the scanned
## set when those are on, the flat colour `plain` when not. Memoised by look.
func surface(set_name: String, repeats: float, tint: Color, plain: Color, rough := 0.9, metal := 0.0) -> StandardMaterial3D:
	for q in _surfaces:
		if q[1] == set_name and q[2] == repeats and q[3] == tint and q[6] == plain: return q[0]
	var mat := _std(plain, metal, rough)
	_surfaces.append([mat, set_name, repeats, tint, metal, 1.0, plain])
	if scanned: _dress(mat, set_name, repeats, tint, metal, 1.0)
	return mat

## What lies over the scanned deck, on a clear ground: the seams between the
## plates and their bolts, broad darker and lighter patches, oil, scorch,
## rubber and the pale scuffs robots leave. And its height, as a normal map.
func _deck_marks(wear: float) -> Dictionary:
	var S := 1024
	var g := TexPaint.new(S, Color(0.08, 0.08, 0.09, 0.0), 111)
	var h := TexPaint.new(S, Color.html("#808080"), 112)
	# Patches of tone, so no two plates are the same grey.
	for i in 46:
		var light := g.rnd(0, 1) > 0.62
		g.blob(g.rnd(0, S), g.rnd(0, S), g.rnd(80, 300), TexPaint.rgba(150, 156, 168, g.rnd(0.05, 0.14)) if light else TexPaint.rgba(8, 8, 10, g.rnd(0.12, 0.34)))
	# Pale scuffs: where steel slid over paint.
	for i in int(round(260 * (0.4 + wear))):
		var a0 := g.rnd(0, TAU)
		var v := g.rnd(120, 190)
		g.arc(g.rnd(0, S), g.rnd(0, S), g.rnd(30, 420), a0, a0 + g.rnd(0.08, 0.7), g.rnd(1.5, 4.0), TexPaint.rgba(v, v, v + 6, g.rnd(0.08, 0.3)))
	# Rubber laid down by spinning wheels.
	for i in int(round(70 * (0.4 + wear))):
		var a0 := g.rnd(0, TAU)
		g.arc(g.rnd(0, S), g.rnd(0, S), g.rnd(16, 150), a0, a0 + g.rnd(0.3, 2.4), g.rnd(3, 11), TexPaint.rgba(6, 6, 7, g.rnd(0.2, 0.5)))
	# Oil, with a slick middle, and scorch.
	for i in int(round(30 * wear)):
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var r := g.rnd(22, 78)
		g.blotch(x, y, r, TexPaint.rgba(5, 5, 7, g.rnd(0.35, 0.7)))
		h.blotch(x, y, r, TexPaint.rgba(128, 128, 128, 0.8))
	for i in int(round(16 * wear)):
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var r := g.rnd(26, 90)
		g.blob(x, y, r, TexPaint.rgba(20, 16, 13, 0.55))
		g.blob(x, y, r * 0.6, TexPaint.rgba(4, 4, 4, 0.7))
	# Gouges: a bright scrape cut into the plate.
	for i in int(round(40 * wear)):
		var sc := _gouge(g, S, g.rnd(30, 170), g.rnd(1.0, 3.0))
		h.line(sc[0], sc[1], sc[2], sc[3], maxf(1.5, sc[4] * 1.5), Color.html("#303030"))
	# The seams of a 4 x 4 plate grid: a dark gap with a worn bright edge, and
	# countersunk bolts along it.
	for i in 4:
		var p := (S / 4.0) * i
		g.rect(p - 7, 0, 14, S, TexPaint.rgba(4, 4, 5, 0.22 + 0.2 * wear))
		g.rect(0, p - 7, S, 14, TexPaint.rgba(4, 4, 5, 0.22 + 0.2 * wear))
		g.rect(p - 3.5, 0, 1.5, S, TexPaint.rgba(150, 154, 162, 0.5))
		g.rect(0, p - 3.5, S, 1.5, TexPaint.rgba(150, 154, 162, 0.5))
		g.rect(p - 2, 0, 4, S, TexPaint.rgba(3, 3, 4, 0.95))
		g.rect(0, p - 2, S, 4, TexPaint.rgba(3, 3, 4, 0.95))
		h.rect(p - 4, 0, 8, S, Color.html("#7a7a7a"))
		h.rect(0, p - 4, S, 8, Color.html("#7a7a7a"))
		h.rect(p - 2, 0, 4, S, Color.html("#2c2c2c"))
		h.rect(0, p - 2, S, 4, Color.html("#2c2c2c"))
		var q := S / 32.0
		while q < S:
			for off in [-13.0, 13.0]:
				for at in [Vector2(p + off, q), Vector2(q, p + off)]:
					g.disc(at.x, at.y, 4.2, TexPaint.rgba(10, 10, 12, 0.9))
					g.disc(at.x, at.y, 2.8, TexPaint.rgba(96, 100, 108, 0.95))
					h.disc(at.x, at.y, 4.2, Color.html("#505050"))
					h.disc(at.x, at.y, 2.6, Color.html("#8c8c8c"))
			q += S / 16.0
	return {"albedo": g.texture(), "normal": h.normal_texture(2.4)}

# ---------------------------------------------------------------- the maps

## Battered steel deck: seams, welds, rust, oil, scorch, rubber, gouges.
func _steel_floor(wear: float) -> Dictionary:
	var S := 1024
	var g := TexPaint.new(S, Color.html("#565d68"), 101)
	var scars := []
	# Broad tonal variation so it never reads as flat grey.
	for i in int(round(70 * (0.4 + wear))):
		var light := g.rnd(0, 1) > 0.5
		var c := TexPaint.rgba(70, 74, 82, g.rnd(0.08, 0.3)) if light else TexPaint.rgba(26, 28, 33, g.rnd(0.08, 0.3))
		g.blob(g.rnd(0, S), g.rnd(0, S), g.rnd(60, 260), c)
	# Fine grain.
	for i in 5000:
		var v := g.rnd(80, 125)
		g.rect(g.rnd(0, S), g.rnd(0, S), 3, 3, TexPaint.rgba(v, v + 2, v + 7, 0.16))
	# Plate seams on a 4-plate grid, with weld beads and grime in the gaps.
	for i in 4:
		var p := (S / 4.0) * i
		g.rect(p - 5, 0, 10, S, TexPaint.rgba(26, 24, 22, 0.1 + 0.18 * wear))
		g.rect(0, p - 5, S, 10, TexPaint.rgba(26, 24, 22, 0.1 + 0.18 * wear))
		g.rect(p - 2, 0, 4, S, TexPaint.rgba(28, 30, 36, 0.75))
		g.rect(0, p - 2, S, 4, TexPaint.rgba(28, 30, 36, 0.75))
		var q := 0.0
		while q < S:
			var bead := TexPaint.rgba(g.rnd(120, 165), g.rnd(115, 160), g.rnd(110, 150), 0.55)
			g.disc(p + g.rnd(-1, 1), q, g.rnd(1.6, 3), bead)
			g.disc(q, p + g.rnd(-1, 1), g.rnd(1.6, 3), bead)
			q += 13.0
	# Rust, only where the wear level asks for it.
	for i in int(round(46 * wear)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(14, 64), TexPaint.rgba(g.rnd(96, 150), g.rnd(50, 80), g.rnd(22, 40), g.rnd(0.1, 0.34)))
	# Oil and hydraulic stains - dark, slick, with a faint rainbow edge.
	for i in int(round(20 * wear)):
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var r := g.rnd(22, 78)
		g.blotch(x, y, r, TexPaint.rgba(10, 9, 12, g.rnd(0.3, 0.62)))
		g.blotch(x, y, r * 0.62, TexPaint.rgba(g.rnd(30, 70), g.rnd(40, 80), g.rnd(50, 90), 0.18))
	# Scorch marks where something burned.
	for i in int(round(12 * wear)):
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var r := g.rnd(26, 90)
		g.blob(x, y, r, TexPaint.rgba(28, 22, 18, 0.5))
		g.blob(x, y, r * 0.6, TexPaint.rgba(8, 7, 7, 0.7))
	# Rubber laid down by spinning wheels.
	for i in int(round(46 * wear)):
		var a0 := g.rnd(0, TAU)
		g.arc(g.rnd(0, S), g.rnd(0, S), g.rnd(16, 150), a0, a0 + g.rnd(0.3, 2.4), g.rnd(3, 11), TexPaint.rgba(14, 13, 14, g.rnd(0.12, 0.42)))
	# Spinner gouges: a handful reads as "fights happen here"; a thousand
	# reads as noise.
	for i in int(round(26 * wear)): scars.append(_gouge(g, S, g.rnd(30, 150), g.rnd(1.0, 3.0)))
	for i in int(round(6 * wear)): scars.append(_gouge(g, S, g.rnd(90, 240), g.rnd(3, 6)))

	# Height: seams recessed, welds proud, gouges cut in. Half size on
	# purpose - a normal map carries fine detail perfectly well at 512.
	var HS := S / 2
	var k := 0.5
	var h := TexPaint.new(HS, Color.html("#808080"), 102)
	for i in 1200:
		var v := h.rnd(110, 150)
		h.disc(h.rnd(0, HS), h.rnd(0, HS), h.rnd(2, 16), TexPaint.rgba(v, v, v, 0.5))
	for i in 4:
		var p := (HS / 4.0) * i
		h.rect(p - 2.5, 0, 5, HS, Color.html("#4a4a4a"))
		h.rect(0, p - 2.5, HS, 5, Color.html("#4a4a4a"))
		var q := 0.0
		while q < HS:
			h.disc(p, q, 2.4, Color.html("#b4b4b4"))
			h.disc(q, p, 2.4, Color.html("#b4b4b4"))
			q += 13.0
	for sc in scars:
		h.line(sc[0] * k, sc[1] * k, sc[2] * k, sc[3] * k, maxf(1.0, sc[4] * 1.5 * k), Color.html("#3a3a3a"))
	for i in int(round(90 * wear)):
		h.blob(h.rnd(0, HS), h.rnd(0, HS), h.rnd(5, 26), TexPaint.rgba(60, 60, 60, 0.75))

	# Roughness: a gentle variation, not a patchwork. Green carries it,
	# multiplied by the material's own roughness.
	var r := TexPaint.new(512, TexPaint.rgba(154, 154, 154), 103)
	for i in int(round(500 * (0.3 + wear))):
		var slick := r.rnd(0, 1) > 0.55
		r.disc(r.rnd(0, 512), r.rnd(0, 512), r.rnd(4, 46), TexPaint.rgba(40, 40, 40, 0.4) if slick else TexPaint.rgba(215, 215, 215, 0.35))
	return {"albedo": g.texture(), "normal": h.normal_texture(2.6), "rough": r.texture()}

# A gouge: a bright scrape with a dark shadow beside it.
func _gouge(g: TexPaint, S: int, length: float, width: float) -> Array:
	var x := g.rnd(0, S)
	var y := g.rnd(0, S)
	var a := g.rnd(0, TAU)
	var ex := x + cos(a) * length
	var ey := y + sin(a) * length
	g.line(x, y, ex, ey, width * 1.8, TexPaint.rgba(16, 16, 19, g.rnd(0.35, 0.7)))
	g.line(x, y, ex, ey, width, TexPaint.rgba(g.rnd(180, 225), g.rnd(180, 225), g.rnd(190, 235), g.rnd(0.3, 0.65)))
	return [x, y, ex, ey, width]

## Brushed metal that has been hit a lot: streaks, rust, chips, spatter.
func _grimy_metal(tint: Color, rust: float, rng_seed: int) -> Dictionary:
	var S := 512
	var g := TexPaint.new(S, tint, rng_seed)
	# brush grain
	for i in 1000:
		var a := g.rnd(0.02, 0.07)
		g.rect(0, g.rnd(0, S), S, g.rnd(1, 2.4), Color(1, 1, 1, a) if g.rnd(0, 1) > 0.5 else Color(0, 0, 0, a))
	# rust creep
	for i in int(40 * rust):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(8, 46), TexPaint.rgba(g.rnd(100, 155), g.rnd(52, 84), g.rnd(24, 44), g.rnd(0.12, 0.4)))
	# grime in the low spots
	for i in int(round(26 * rust)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(12, 60), TexPaint.rgba(18, 17, 18, g.rnd(0.1, 0.3)))
	# impact chips and scrapes
	for i in int(round(46 * rust)): _gouge(g, S, g.rnd(8, 50), g.rnd(0.8, 2))
	var h := TexPaint.new(S, Color.html("#808080"), rng_seed + 50)
	for i in 60:
		h.blob(h.rnd(0, S), h.rnd(0, S), h.rnd(6, 30), TexPaint.rgba(55, 55, 55, 0.8))
	for i in 700:
		var v := h.rnd(105, 150)
		h.rect(h.rnd(0, S), h.rnd(0, S), h.rnd(1, 4), h.rnd(1, 3), TexPaint.rgba(v, v, v, 0.4))
	return {"albedo": g.texture(), "normal": h.normal_texture(1.8)}

## Worn hazard stripes: chipped paint over rusty steel.
func _hazard_stripes(wear: float) -> Dictionary:
	var S := 256
	var g := TexPaint.new(S, Color.html("#d9a316"), 21)
	# Diagonal black bands: each row is the same strip, slid along by one.
	var period := S / 4.0
	for y in S:
		var x := -period + fposmod(float(y), period)
		while x < S:
			g.img.fill_rect(Rect2i(int(x), y, int(period / 2.0), 1), Color.html("#17171b"))
			x += period
	# chip the paint back to the substrate
	for i in int(round(160 * wear)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(2, 11), TexPaint.rgba(g.rnd(95, 140), g.rnd(58, 86), g.rnd(28, 48), g.rnd(0.3, 0.85)))
	for i in int(round(40 * wear)): _gouge(g, S, g.rnd(6, 40), g.rnd(0.8, 2))
	for i in int(round(14 * wear)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(8, 30), TexPaint.rgba(14, 13, 14, g.rnd(0.15, 0.4)))
	var h := TexPaint.new(S, Color.html("#808080"), 22)
	for i in 160:
		var v := h.rnd(55, 95)
		h.disc(h.rnd(0, S), h.rnd(0, S), h.rnd(2, 10), TexPaint.rgba(v, v, v, 0.6))
	return {"albedo": g.texture(), "normal": h.normal_texture(1.6)}

## Scratched, hazed polycarbonate - years of spinner hits.
func _lexan(wear: float) -> Dictionary:
	var S := 512
	var h := TexPaint.new(S, Color.html("#808080"), 31)
	# fine scratch haze
	for i in int(round(420 * (0.3 + wear))):
		var v := h.rnd(100, 150)
		var x := h.rnd(0, S)
		var y := h.rnd(0, S)
		var a := h.rnd(0, TAU)
		var l := h.rnd(8, 90)
		h.line(x, y, x + cos(a) * l, y + sin(a) * l, h.rnd(1.0, 1.8), TexPaint.rgba(v, v, v, 0.5))
	# impact stars
	for i in int(round(16 * wear)):
		var x := h.rnd(0, S)
		var y := h.rnd(0, S)
		for k in 9:
			var a := h.rnd(0, TAU)
			var l := h.rnd(6, 34)
			h.line(x, y, x + cos(a) * l, y + sin(a) * l, h.rnd(1.0, 2.2), TexPaint.rgba(60, 60, 60, 0.9))
	# Grime that actually tints the glass, mostly near the bottom of the panel.
	var g := TexPaint.new(S, Color.WHITE, 32)
	for i in 40:
		g.blotch(g.rnd(0, S), g.rnd(S * 0.45, S), g.rnd(10, 60), TexPaint.rgba(120, 112, 96, g.rnd(0.05, 0.22)))
	for i in 18:
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(6, 26), TexPaint.rgba(60, 55, 50, g.rnd(0.06, 0.2)))
	return {"albedo": g.texture(), "normal": h.normal_texture(1.1)}

## Scuffed paint, used to grime up every robot's livery colours.
func _paint_wear(wear: float) -> Dictionary:
	var S := 512
	var g := TexPaint.new(S, Color.WHITE, 41)
	# dirt film
	for i in int(round(70 * wear)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(14, 80), TexPaint.rgba(g.rnd(96, 140), g.rnd(90, 128), g.rnd(84, 118), g.rnd(0.06, 0.26)))
	# scrapes down to bare metal
	for i in int(round(110 * wear)):
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var a := g.rnd(0, TAU)
		var l := g.rnd(10, 120)
		g.line(x, y, x + cos(a) * l, y + sin(a) * l, g.rnd(1.0, 3.4), TexPaint.rgba(g.rnd(150, 210), g.rnd(150, 210), g.rnd(155, 215), g.rnd(0.15, 0.55)))
	# soot
	for i in int(round(20 * wear)):
		g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(10, 46), TexPaint.rgba(26, 24, 24, g.rnd(0.08, 0.3)))
	var h := TexPaint.new(S, Color.html("#808080"), 42)
	for i in int(round(70 * wear)):
		h.blob(h.rnd(0, S), h.rnd(0, S), h.rnd(5, 24), TexPaint.rgba(58, 58, 58, 0.7))
	return {"albedo": g.texture(), "normal": h.normal_texture(1.5)}

## Machined steel's sheen, as a roughness map (green channel; grey 153 is the
## material's own roughness): brushed streaks, a few polished scratches and
## duller smudges, so a highlight breaks up as it slides along a bar instead
## of sitting on it like a sticker.
func _machined_roughness() -> Texture2D:
	var S := 512
	var g := TexPaint.new(S, TexPaint.rgba(153, 153, 153), 51)
	for i in 700:
		var v := 153.0 + g.rnd(-26, 26)
		g.rect(0, g.rnd(0, S), S, g.rnd(1, 2.5), TexPaint.rgba(v, v, v, g.rnd(0.2, 0.6)))
	for i in 14: g.blotch(g.rnd(0, S), g.rnd(0, S), g.rnd(20, 70), TexPaint.rgba(205, 205, 205, g.rnd(0.15, 0.35)))
	for i in 60:
		var x := g.rnd(0, S)
		var y := g.rnd(0, S)
		var a := g.rnd(0, TAU)
		var l := g.rnd(8, 60)
		g.line(x, y, x + cos(a) * l, y + sin(a) * l, g.rnd(1.0, 1.8), TexPaint.rgba(80, 80, 80, g.rnd(0.3, 0.7)))
	var t := g.texture()
	return t

## A photo studio, as an equirectangular picture for reflections: a dark
## room, a big softbox overhead, a cool strip on one side, a warm one on the
## other, and a dim floor. What makes a bar or a disc read as polished steel.
static func studio_panorama() -> Image:
	var w := 512
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	var stops := [[0.0, Color.html("#4a5263")], [0.48, Color.html("#2c313b")], [0.52, Color.html("#121418")], [1.0, Color.html("#08090b")]]
	for y in h:
		var t := float(y) / (h - 1)
		var c: Color = stops[stops.size() - 1][1]
		for i in range(stops.size() - 1):
			if t <= stops[i + 1][0]:
				c = (stops[i][1] as Color).lerp(stops[i + 1][1], (t - stops[i][0]) / maxf(1e-6, stops[i + 1][0] - stops[i][0]))
				break
		img.fill_rect(Rect2i(0, y, w, 1), c.srgb_to_linear())
	# The lights are brighter than white, so they still read after a rough
	# surface has smeared them out.
	var boxes := [
		[0, 0, 512, 22, "#f4f6ff", 3.0],      # overhead softbox
		[60, 60, 70, 46, "#ffffff", 5.0],     # key
		[300, 72, 120, 26, "#b9d2ff", 3.5],   # cool strip
		[190, 84, 50, 60, "#ffd9a0", 3.0],    # warm practical
		[0, 150, 512, 8, "#2a2f38", 1.0],     # floor horizon
	]
	for b in boxes:
		var c := Color.html(b[4]).srgb_to_linear() * float(b[5])
		c.a = 1.0
		img.fill_rect(Rect2i(b[0], b[1], b[2], b[3]), c)
	return img
