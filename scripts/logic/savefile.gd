## savefile.gd - save export and import: everything the game keeps on this
## device, in one file you can back up or carry to another. No cloud, no
## account - a plain JSON file, the same one the browser version writes, so a
## backup made there loads here.
##
##   { schema: "robo-league-backup/1", game, savedAt,
##     career, hall, tournament, settings }    each one optional
##
## Every part is checked on the way in by its own loader, so a backup from an
## older version of the game loads into this one. A bare career save imports
## too. Pure: strings and dictionaries in and out.
class_name SaveFile

const BACKUP_SCHEMA := "robo-league-backup/1"

## A backup of what is passed (any of them may be null). Returns the file's text.
##   parts  { career, hall, tournament, settings } - as the game keeps them
static func make_backup(parts: Dictionary, saved_at = null) -> String:
	if saved_at == null: saved_at = Time.get_datetime_string_from_system(true) + "Z"
	var out := {"schema": BACKUP_SCHEMA, "game": "ROBO LEAGUE", "savedAt": saved_at}
	var career = parts.get("career")
	var hall = parts.get("hall")
	var tournament = parts.get("tournament")
	var settings = parts.get("settings")
	if career != null: out.career = career
	if hall is Dictionary and (hall.get("careers", []).size() > 0 or hall.get("legends", []).size() > 0): out.hall = hall
	if tournament != null: out.tournament = tournament
	if settings != null: out.settings = settings
	return J.to_json(out)

## Read a backup (or a bare career save).
## Returns { ok, error, career, hall, tournament, settings, savedAt } - each
## part checked and migrated, or null if the file had none.
static func read_backup(text: String) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "error": msg, "career": null, "hall": null, "tournament": null, "settings": null, "savedAt": null}
	var raw = J.parse_json(text)
	if raw == null: return fail.call("That file is not a ROBO LEAGUE save: it is not JSON.")
	if not (raw is Dictionary): return fail.call("That file is not a ROBO LEAGUE save.")
	# A bare career save.
	if raw.get("schema") == Career.CAREER_SCHEMA:
		var c := Career.from_data(raw)
		if not c.ok: return fail.call(J.cap(c.error) + ".")
		return {"ok": true, "error": "", "career": c.career, "hall": null, "tournament": null, "settings": null, "savedAt": null}
	if raw.get("schema") != BACKUP_SCHEMA:
		if raw.get("schema") is String and raw.schema.begins_with("robo-league-backup/"): return fail.call("That backup is from a newer version of the game (%s)." % raw.schema)
		return fail.call("That file is not a ROBO LEAGUE save.")
	var out := {"ok": true, "error": "", "career": null, "hall": null, "tournament": null, "settings": null, "savedAt": raw.get("savedAt")}
	if raw.get("career") != null:
		var c := Career.from_data(raw.career)
		if not c.ok: return fail.call(J.cap(c.error) + ".")
		out.career = c.career
	if raw.get("hall") != null:
		if not (raw.hall is Dictionary) or raw.hall.get("schema") != HallOfFame.HOF_SCHEMA: return fail.call("The Hall of Fame in that file is not one this game can read.")
		out.hall = raw.hall
	if raw.get("tournament") != null:
		var t := Cup.from_data(raw.tournament)
		if not t.ok: return fail.call("The tournament in that file is not one this game can read.")
		out.tournament = t.cup
	if raw.get("settings") != null: out.settings = Settings.from_saved(raw.settings)
	if out.career == null and out.hall == null and out.tournament == null and out.settings == null: return fail.call("That save file is empty.")
	return out

## Lines on what a backup holds, for the import's "are you sure".
static func describe_backup(b: Dictionary) -> Array:
	var bits := []
	if b.get("career") != null:
		var c: Dictionary = b.career
		bits.append("the career of %s - season %s, %s, %s-%s, $%s" % [c.get("team"), J.num(c.get("seasonIndex")), J.path(c, ["garage", "name"], "your robot"),
			J.num(J.path(c, ["stats", "wins"], 0)), J.num(J.path(c, ["stats", "losses"], 0)), J.commas(J.rnd(c.cash))])
	if b.get("hall") != null:
		var n: int = b.hall.get("careers", []).size()
		bits.append("a Hall of Fame of %d career%s" % [n, "" if n == 1 else "s"])
	if b.get("tournament") != null: bits.append("the tournament \"%s\"%s" % [b.tournament.get("name"), " (finished)" if J.truthy(b.tournament.get("done")) else ""])
	if b.get("settings") != null: bits.append("your settings")
	return bits

## A file name for a backup: robo-league-<team>-s<season>-<date>.json
static func backup_file_name(career = null) -> String:
	var team := J.slug(str(J.g(career, "team", "backup"))).replace("_", "-").trim_prefix("-").trim_suffix("-").substr(0, 24)
	if team == "": team = "backup"
	var d := Time.get_date_dict_from_system()
	return "robo-league-%s%s-%04d-%02d-%02d.json" % [team, "-s%s" % J.num(career.seasonIndex) if career != null else "", d.year, d.month, d.day]
