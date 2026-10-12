## settings.gd - the game's settings: what they are, their defaults, and
## turning saved text back into a complete, valid set.
##
## Pure: the menus and the fight screen read and write the text (kept in
## user://settings.json); everything that USES a setting gets it handed in.
## Difficulty is the one the game logic reads.
class_name Settings

const SETTINGS_KEY := "robo-league.settings"

## Every setting, in the order the settings pages show them.
const SETTINGS := [
	{"id": "difficulty", "group": "Gameplay", "label": "Difficulty", "type": "choice", "default": "medium",
		"options": [["easy", "Easy"], ["medium", "Medium"], ["hard", "Hard"], ["ultimate", "Ultimate"]],
		"help": "How sharp the AI drivers are against you, how much they adapt and learn, and how much money you earn. Change it at any time."},
	{"id": "advisor", "group": "Gameplay", "label": "Build advisor", "type": "bool", "default": true,
		"help": "Show the optional build advisor in the workshop and the career hub."},
	{"id": "replays", "group": "Gameplay", "label": "Highlight reel after the bell", "type": "bool", "default": true},
	{"id": "camera", "group": "Gameplay", "label": "Starting camera", "type": "choice", "default": "chase",
		"options": [["chase", "Chase"], ["overhead", "Overhead"], ["arena", "Arena cam"]]},
	{"id": "bloom", "group": "Graphics", "label": "Bloom (sparks glow)", "type": "bool", "default": true},
	{"id": "shadows", "group": "Graphics", "label": "Shadows", "type": "bool", "default": true},
	{"id": "renderScale", "group": "Graphics", "label": "Render resolution", "type": "choice", "default": "1",
		"options": [["0.5", "50% (fastest)"], ["0.75", "75%"], ["1", "100%"]]},
	{"id": "hudDamage", "group": "Display", "label": "Damaged parts under the health bars", "type": "bool", "default": true},
	{"id": "sound", "group": "Sound", "label": "Sound", "type": "bool", "default": true,
		"help": "Motors, weapons, hits, hazards and the crowd. N mutes it in a fight."},
	{"id": "volume", "group": "Sound", "label": "Volume", "type": "choice", "default": "0.75",
		"options": [["0.25", "25%"], ["0.5", "50%"], ["0.75", "75%"], ["1", "100%"]]},
	{"id": "crowd", "group": "Sound", "label": "Crowd", "type": "choice", "default": "1",
		"options": [["0", "Off"], ["0.5", "Quiet"], ["1", "Normal"], ["1.5", "Loud"]]},
	{"id": "commentary", "group": "Sound", "label": "Commentary", "type": "choice", "default": "both",
		"options": [["off", "Off"], ["captions", "Captions"], ["voice", "Voice"], ["both", "Voice + captions"]],
		"help": "Two commentators call the fight. The voice uses your device's built-in speech; captions never name the arena's hazards."},
	{"id": "steering", "group": "Controls", "label": "Steering sensitivity", "type": "choice", "default": "1",
		"options": [["0.7", "Gentle"], ["1", "Normal"], ["1.3", "Sharp"]]},
]

static func defaults() -> Dictionary:
	var out := {}
	for s in SETTINGS: out[s.id] = s.default
	return out

## A complete settings object from saved text (unknown keys dropped, bad values reset).
static func read_settings(text) -> Dictionary:
	var saved = J.parse_json(text if text is String and text != "" else "{}")
	return from_saved(saved)

## The same, from an already-parsed object.
static func from_saved(saved) -> Dictionary:
	if not (saved is Dictionary): saved = {}
	var out := defaults()
	for s in SETTINGS:
		if not saved.has(s.id): continue
		var v = saved[s.id]
		if s.type == "bool" and typeof(v) == TYPE_BOOL:
			out[s.id] = v
		elif s.type == "choice":
			var sv := J.num(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else str(v)
			for o in s.options:
				if o[0] == sv:
					out[s.id] = sv
					break
	return out

## What a difficulty level does (rules.json `difficulty`), medium if unknown.
static func difficulty_of(reg: Registry, level) -> Dictionary:
	var d: Dictionary = reg.rules.get("difficulty", {})
	var out := {"level": level if (level != null and d.get(level) != null) else "medium"}
	out.merge(d.get("medium", {}), true)
	if level != null and d.get(level) != null: out.merge(d[level], true)
	return out
