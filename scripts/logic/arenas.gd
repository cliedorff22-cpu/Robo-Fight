## arenas.gd - which arena a fight is in: the box (data/arena.json), one of the
## hazard LAYOUTS and a VENUE round it (data/arenas.json).
##
## Pure. Everything downstream - physics, hazards, the renderer, the AI's
## hazard map - takes the composed arena exactly as it took arena.json, so a
## layout is nothing but data.
class_name Arenas

const DEFAULT_LAYOUT := "classic"
const DEFAULT_VENUE := "pro"

static func _ids(d) -> Array:
	var out := []
	if d is Dictionary:
		for k in d:
			if not str(k).begins_with("_"): out.append(k)
	return out

## Layout ids, in the file's order.
static func layout_ids(reg: Registry) -> Array:
	return _ids(J.g(reg.arenas, "layouts"))

## Venue ids, in the file's order.
static func venue_ids(reg: Registry) -> Array:
	return _ids(J.g(reg.arenas, "venues"))

static func layout_of(reg: Registry, id):
	if id == null: return null
	return J.path(reg.arenas, ["layouts", id])

static func venue_of(reg: Registry, id):
	if id == null: return null
	return J.path(reg.arenas, ["venues", id])

## The hazards a layout runs. `like` copies a hazard from data/arena.json and
## overrides only what is given.
static func layout_hazards(reg: Registry, layout_id) -> Array:
	var base: Array = reg.arena.hazards
	var L = layout_of(reg, layout_id)
	if L == null or L.get("hazards") == null: return base
	var out := []
	for h in L.hazards:
		if h.get("like") == null:
			out.append(h)
			continue
		var src = null
		for b in base:
			if b.id == h.like:
				src = b
				break
		assert(src != null, "layout \"%s\": no hazard \"%s\" in arena.json to copy" % [layout_id, h.like])
		var m: Dictionary = src.duplicate()
		for k in h:
			if k != "like": m[k] = h[k]
		out.append(m)
	return out

## The arena a fight is in: arena.json with the layout's hazards (and killsaw
## settings) and the venue's lighting. The classic layout keeps arena.json's
## id, so its killsaw draws - seeded by the arena id - replay exactly.
## opts: { layout, venue }
static func compose_arena(reg: Registry, opts: Dictionary = {}) -> Dictionary:
	var layout = opts.get("layout", DEFAULT_LAYOUT)
	var venue = opts.get("venue")
	var base: Dictionary = reg.arena
	var L: String = layout if layout_of(reg, layout) != null else DEFAULT_LAYOUT
	var V = venue if venue_of(reg, venue) != null else null
	var lay_v = layout_of(reg, L)
	var lay: Dictionary = lay_v if lay_v != null else {}
	var ven = venue_of(reg, V) if V != null else null
	var lighting: Dictionary = base.lighting.duplicate()
	var vl = J.g(ven, "lighting")
	if vl != null:
		if J.truthy(vl.get("background")): lighting.background = vl.background
		if vl.get("fog") != null: lighting.fog = J.merge(lighting.get("fog", {}), vl.fog)
		if J.truthy(vl.get("rigColor")):
			lighting.rigs = lighting.get("rigs", []).map(func(r):
				var o: Dictionary = r.duplicate()
				o.color = vl.rigColor
				return o)
		if J.truthy(vl.get("exposure")): lighting.exposure = vl.exposure
	# A seat in the crowd: a camera up in the venue's first stand, looking in.
	var cameras: Array = base.cameras
	var tiers = J.path(ven, ["stands", "tiers"], [])
	if tiers.size() > 0:
		var st: Dictionary = ven.stands
		var rows: float = st.tiers[0].rows
		var out_d: float = base.floor.size[1] / 2.0 + st.gap + rows * st.rowDepth * 0.5
		var up: float = 10.0 + rows * st.rowRise * 0.5
		var side := 1.0 if st.sides.has("s") else -1.0
		var stands := {"id": "stands", "label": "Stands Cam", "type": "fixed", "pos": [9.0, up, side * out_d], "lookAt": [0.0, 1.0, 0.0], "fov": 46.0}
		# Before the Versus cam and the replay cam, so it keeps key 5.
		var at := J.find_index(cameras, func(c): return c.type == "versus" or c.type == "replay")
		var nc := cameras.duplicate()
		if at < 0: nc.append(stands)
		else: nc.insert(at, stands)
		cameras = nc
	var out := base.duplicate()
	out.cameras = cameras
	out.id = base.id if L == DEFAULT_LAYOUT else "%s:%s" % [base.id, L]
	out.name = lay.name if J.truthy(lay.get("name")) else base.name
	out.layout = L
	out.venue = V
	out.hazards = layout_hazards(reg, L)
	out.killsaw = J.merge(base.get("killsaw", {}), lay.get("killsaw", {}))
	out.lighting = lighting
	return out

## The venue for a league ("rookie".."world") or the Giant Nut.
static func venue_for_league(reg: Registry, league) -> String:
	if venue_of(reg, league) != null: return league
	for id in venue_ids(reg):
		if venue_of(reg, id).get("league") == league: return id
	return DEFAULT_VENUE

## A layout from the venue's pool, the same one every time for the same key.
static func layout_for_fight(reg: Registry, venue_id, key) -> String:
	var pool: Array = J.g(venue_of(reg, venue_id), "layouts", [DEFAULT_LAYOUT]).filter(func(id): return layout_of(reg, id) != null)
	if pool.is_empty(): return DEFAULT_LAYOUT
	return pool[Rng.hash_seed("layout:%s" % J.s(key)) % pool.size()]

## Where a career fight is: the Giant Nut season at the Giant Nut's venue,
## otherwise the player's league's. The layout is drawn from that venue's
## pool by the fixture, so the scouting card and the fight agree.
## o: { seasonKind, league, fixtureId }
static func career_arena(reg: Registry, o: Dictionary) -> Dictionary:
	var venue := venue_for_league(reg, "giantNut") if o.get("seasonKind") == "giantNut" else venue_for_league(reg, o.get("league"))
	return {"venue": venue, "layout": layout_for_fight(reg, venue, o.get("fixtureId"))}

## Problems with data/arenas.json, as strings.
static func validate_arenas(reg: Registry, validate_arena = null) -> Array:
	var errors := []
	for id in layout_ids(reg):
		var a := compose_arena(reg, {"layout": id})
		var ids: Array = a.hazards.map(func(h): return h.id)
		for i in ids.size():
			if ids.find(ids[i]) != i:
				errors.append("layout \"%s\": hazard id \"%s\" is used twice" % [id, ids[i]])
				break
		if validate_arena is Callable:
			for e in validate_arena.call(a): errors.append("layout \"%s\": %s" % [id, e])
	for id in venue_ids(reg):
		var v: Dictionary = venue_of(reg, id)
		for l in v.get("layouts", []):
			if layout_of(reg, l) == null: errors.append("venue \"%s\": unknown layout \"%s\"" % [id, l])
		if J.path(v, ["stands", "tiers"], []).size() == 0: errors.append("venue \"%s\": no stands" % id)
	return errors
