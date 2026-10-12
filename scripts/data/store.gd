## store.gd - what the game keeps between sessions: the career, the Hall of
## Fame, a tournament in progress, the settings.
##
## Each is a named piece of JSON text in the user's data folder (user://),
## under the same names the browser game used in its local storage - so a
## backup made there loads here.
class_name Store

const CAREER := "robo-league.career"
## Which career save is the one being played (1..CAREER_SLOTS).
const CAREER_SLOT := "robo-league.career.slot"
const CAREER_SLOTS := 6
const HALL := "robo-league.halloffame"
const TOURNAMENT := "robo-league.tournament"
const SETTINGS := "robo-league.settings"

## Put in front of every name: the tests keep their saves apart from yours.
static var prefix := ""

static func _path(key: String) -> String:
	return "user://%s%s.json" % [prefix, key.validate_filename()]

## A career save's name. The first keeps the name the browser game uses, so a
## save from before there were several is simply the first one. `slot` 0: the
## one being played.
static func career_key(slot := 0) -> String:
	if slot <= 0: slot = career_slot()
	return CAREER if slot == 1 else "%s.%d" % [CAREER, slot]

## The career being played: the one the menus open, a fight comes back to,
## and Settings backs up.
static func career_slot() -> int:
	var t = read(CAREER_SLOT)
	return clampi(int(str(t)), 1, CAREER_SLOTS) if t != null else 1

static func set_career_slot(slot: int) -> void:
	write(CAREER_SLOT, str(clampi(slot, 1, CAREER_SLOTS)))

## The saved text, or null.
static func read(key: String):
	var p := _path(key)
	if not FileAccess.file_exists(p): return null
	return FileAccess.get_file_as_string(p)

## Whether there is anything saved under a name.
static func has(key: String) -> bool:
	var p := _path(key)
	return FileAccess.file_exists(p) and FileAccess.get_file_as_string(p).strip_edges() != ""

static func write(key: String, text: String) -> bool:
	var f := FileAccess.open(_path(key), FileAccess.WRITE)
	if f == null:
		push_warning("[store] could not write %s: %s" % [key, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(text)
	f.close()
	return true

static func remove(key: String) -> void:
	var p := _path(key)
	if FileAccess.file_exists(p): DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

## The saved value, parsed, or null.
static func read_json(key: String):
	var t = read(key)
	if t == null or t == "": return null
	return J.parse_json(t)

static func write_json(key: String, value) -> bool:
	return write(key, J.to_json(value))
