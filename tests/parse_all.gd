## Loads every script in the project, so a parse error anywhere shows up here
## rather than the first time a screen that uses it opens.
extends SceneTree

# On the first frame, not in _init: the autoloads (Game) exist by then.
func _process(_dt: float) -> bool:
	var bad := 0
	var n := 0
	for path in _scripts("res://scripts") + _scripts("res://tests"):
		n += 1
		var s = load(path)
		if s == null or not (s is GDScript) or not s.can_instantiate():
			bad += 1
			print("  FAILED to load: ", path)
	print("parse: %d scripts, %d failed" % [n, bad])
	quit(1 if bad > 0 else 0)
	return true

func _scripts(dir: String) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null: return out
	for f in d.get_files():
		if f.ends_with(".gd"): out.append(dir + "/" + f)
	for sub in d.get_directories():
		out.append_array(_scripts(dir + "/" + sub))
	return out
