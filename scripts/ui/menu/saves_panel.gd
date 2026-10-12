## saves_panel.gd - export and import: what is saved on this computer,
## writing a backup file, picking one to load. What a backup is and how it is
## checked is logic/savefile.gd.
class_name SavesPanel
extends Plate

var _on_imported: Callable
var _only = null
var _msg: Label
var _summary: Label
var _export: Button
## Which career save this is about (0: the one being played).
var slot := 0

## What is saved on this computer now, as the game keeps it. `career_slot`:
## which career (0: the one being played).
static func saved_here(career_slot := 0) -> Dictionary:
	var career = null
	var c := Career.from_data(Store.read_json(Store.career_key(career_slot)))
	if c.ok: career = c.career
	var tournament = null
	var t := Cup.from_data(Store.read_json(Store.TOURNAMENT))
	if t.ok: tournament = t.cup
	var hall := HallOfFame.from_data(Store.read_json(Store.HALL))
	var has_hall: bool = not (hall.careers as Array).is_empty() or not (hall.legends as Array).is_empty()
	return {"career": career, "tournament": tournament, "hall": hall if has_hall else null, "settings": Game.settings}

static func _parts(only, career_slot := 0) -> Dictionary:
	var here := saved_here(career_slot)
	if only == null: return here
	var out := {}
	for k in only: out[k] = here.get(k)
	return out

## Load a backup's text into this computer, replacing what it holds of the
## same kind. Returns { ok, reason, what }.
static func import_backup(b: Dictionary, career_slot := 0) -> Dictionary:
	if b.get("career") != null: Store.write_json(Store.career_key(career_slot), b.career)
	if b.get("hall") != null: Store.write_json(Store.HALL, b.hall)
	if b.get("tournament") != null: Store.write_json(Store.TOURNAMENT, b.tournament)
	if b.get("settings") != null:
		Game.settings = b.settings
		Game.save_settings()
	# A hand-off from another computer means nothing here.
	Game.result = null
	return {"ok": true, "reason": "", "what": SaveFile.describe_backup(b)}

## `on_imported` runs after a successful import. `only`: just these parts
## (e.g. ["career"]).
func _init(on_imported: Callable = Callable(), only = null, title := "Saves") -> void:
	super(26, 18)
	_on_imported = on_imported
	_only = only
	_summary = UI.label("", {"kind": "body", "size": 12, "weight": 400, "wrap": true})
	_msg = UI.label("", {"kind": "body", "size": 12, "weight": 400, "wrap": true})
	_export = UI.button("EXPORT TO A FILE", "ghost")
	_export.pressed.connect(_do_export)
	var imp := UI.button("IMPORT A SAVE FILE…", "ghost")
	imp.pressed.connect(_do_import)
	add_child(UI.vbox(8, [
		UI.label(title.to_upper(), {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}),
		UI.label("Everything is saved on this computer. Export it to a file to back it up or move it to another computer; import a file to carry on from it. Backups from the browser version of the game load here too.",
			{"kind": "cond", "size": 13, "weight": 500, "color": UI.DIM, "wrap": true}),
		_summary,
		UI.hbox(8, [_export, imp]),
		_msg,
	]))
	_refresh()

func _refresh() -> void:
	var lines := SaveFile.describe_backup(_parts(_only, slot))
	_summary.text = "On this computer: %s." % "; ".join(lines) if not lines.is_empty() else "Nothing saved on this computer yet."
	_export.disabled = lines.is_empty()

func _say(text: String, good: bool) -> void:
	_msg.text = text
	_msg.add_theme_color_override("font_color", UI.OK if good else UI.BAD)

func _dialog(save: bool, file_name := "") -> FileDialog:
	var d := FileDialog.new()
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	d.filters = PackedStringArray(["*.json ; ROBO LEAGUE saves"])
	d.use_native_dialog = true
	d.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if file_name != "": d.current_file = file_name
	d.size = Vector2i(900, 600)
	add_child(d)
	d.canceled.connect(d.queue_free)
	return d

func _do_export() -> void:
	var parts := _parts(_only, slot)
	var text := SaveFile.make_backup(parts)
	var d := _dialog(true, SaveFile.backup_file_name(parts.get("career")))
	d.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null: _say("Could not write that file.", false)
		else:
			f.store_string(text)
			f.close()
			_say("Saved %s." % path.get_file(), true)
		d.queue_free())
	d.popup_centered()

func _do_import() -> void:
	var d := _dialog(false)
	d.file_selected.connect(func(path: String):
		d.queue_free()
		var text := FileAccess.get_file_as_string(path)
		var b := SaveFile.read_backup(text)
		if not b.ok:
			_say(b.error, false)
			return
		var what := SaveFile.describe_backup(b)
		var here := saved_here(slot)
		var replacing := []
		if b.get("career") != null and here.career != null: replacing.append("your career here")
		if b.get("hall") != null and here.hall != null: replacing.append("the Hall of Fame here")
		if b.get("tournament") != null and here.tournament != null: replacing.append("the tournament here")
		var ask := ConfirmationDialog.new()
		ask.title = "Load this save?"
		ask.dialog_text = "Load %s?%s" % ["; ".join(what), "\n\nThis replaces %s. Export first if you want to keep it." % " and ".join(replacing) if not replacing.is_empty() else ""]
		ask.dialog_autowrap = true
		ask.min_size = Vector2i(520, 160)
		add_child(ask)
		ask.confirmed.connect(func():
			import_backup(b, slot)
			_say("Loaded %s." % "; ".join(what), true)
			_refresh()
			if _on_imported.is_valid(): _on_imported.call()
			ask.queue_free())
		ask.canceled.connect(ask.queue_free)
		ask.popup_centered())
	d.popup_centered()
