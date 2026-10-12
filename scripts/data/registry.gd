## registry.gd - the parsed JSON documents, indexed. Read-only by convention.
##
## Built once from res://data (Registry.load_all()); everything in logic takes
## it as `reg`. A career registers its own robots with add_robot() whenever it
## is loaded - the data files never change.
class_name Registry
extends RefCounted

var rules: Dictionary
var arena: Dictionary
var partsDoc: Dictionary
var league = null
var economy = null
var matchups = null
var arenas = null
var index = null
var playerId: String = "player_default"

## Derived data that depends only on the data files (assembled builds, body
## shapes) is kept here by the logic that computes it - see Build.assemble_robot.
## Go through cache_get / cache_set: simulated fights run on worker threads.
var cache := {}
var _cache_mutex := Mutex.new()

func cache_get(key: String):
	_cache_mutex.lock()
	var v = cache.get(key)
	_cache_mutex.unlock()
	return v

func cache_set(key: String, value) -> void:
	_cache_mutex.lock()
	cache[key] = value
	_cache_mutex.unlock()

var _parts_by_id := {}
var _parts_by_category := {}
var _robots_by_id := {}
var _base_robots := {}               # the data files' robots, as loaded

static var _shared: Registry = null

## The game's registry, loaded once.
static func shared() -> Registry:
	if _shared == null:
		_shared = load_all()
	return _shared

static func read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var j := JSON.new()
	if j.parse(text) != OK:
		push_error("bad JSON in %s line %d: %s" % [path, j.get_error_line(), j.get_error_message()])
		return null
	return j.data

static func load_all(base := "res://data") -> Registry:
	var idx = read_json(base + "/robots/index.json")
	var robots := []
	var ids: Array = idx.roster.duplicate()
	ids.append_array(idx.get("exhibition", []))
	for id in ids:
		var r = read_json("%s/robots/%s.json" % [base, id])
		if r != null: robots.append(r)
	return Registry.new({
		"rules": read_json(base + "/rules.json"),
		"arena": read_json(base + "/arena.json"),
		"parts": read_json(base + "/parts.json"),
		"robots": robots,
		"index": idx,
		"league": read_json(base + "/league.json"),
		"economy": read_json(base + "/economy.json"),
		"matchups": read_json(base + "/matchups.json"),
		"arenas": read_json(base + "/arenas.json"),
	})

func _init(docs: Dictionary = {}) -> void:
	if docs.is_empty(): return
	rules = docs.rules
	arena = docs.arena
	partsDoc = docs.parts
	league = docs.get("league")
	economy = docs.get("economy")
	matchups = docs.get("matchups")
	arenas = docs.get("arenas")
	index = docs.get("index")
	for p in partsDoc.parts:
		assert(not _parts_by_id.has(p.id), "duplicate part id: %s" % p.id)
		_parts_by_id[p.id] = p
	for c in partsDoc.categories:
		_parts_by_category[c] = []
	for p in partsDoc.parts:
		if not _parts_by_category.has(p.category): _parts_by_category[p.category] = []
		_parts_by_category[p.category].append(p)
	for r in docs.get("robots", []):
		assert(not _robots_by_id.has(r.id), "duplicate robot id: %s" % r.id)
		_robots_by_id[r.id] = r
	_base_robots = _robots_by_id.duplicate()
	if index != null and index.get("player") != null:
		playerId = index.player

func part(id) -> Dictionary:
	assert(_parts_by_id.has(id), "unknown part id: %s" % str(id))
	return _parts_by_id[id]

func has_part(id) -> bool: return id != null and _parts_by_id.has(id)
func parts_in(category: String) -> Array: return _parts_by_category.get(category, []).duplicate()
func all_parts() -> Array: return _parts_by_id.values()

func robot(id) -> Dictionary:
	assert(_robots_by_id.has(id), "unknown robot id: %s" % str(id))
	return _robots_by_id[id]

func has_robot(id) -> bool: return id != null and _robots_by_id.has(id)

## Add a robot made during a career (a new team joining the field - see
## logic/field.gd). Re-adding the same id replaces it.
func add_robot(def: Dictionary) -> Dictionary:
	_robots_by_id[def.id] = def.duplicate()
	return def

## Back to the data files' robots: drop everything a career or a tournament
## added (before another career's robots are registered).
func reset_robots() -> void:
	_robots_by_id = _base_robots.duplicate()

func all_robots() -> Array: return _robots_by_id.values()

## The league field: every robot in the index's roster (the player's included).
func roster() -> Array:
	var ids: Array = index.roster if index != null else _robots_by_id.keys()
	var out := []
	for id in ids:
		if _robots_by_id.has(id): out.append(_robots_by_id[id])
	return out

func hazard(id):
	for h in arena.hazards:
		if h.id == id: return h
	return null

func camera_def(id):
	for c in arena.cameras:
		if c.id == id: return c
	return null

func spawn(id):
	for s in arena.spawns:
		if s.id == id: return s
	return null
