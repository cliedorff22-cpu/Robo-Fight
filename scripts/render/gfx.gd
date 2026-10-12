## gfx.gd - the graphics upgrades: what they are, their defaults, and reading
## them out of the settings.
##
## Each upgrade is one entry on the Settings page (Graphics), so any of them
## can be switched off. They live here rather than in logic/settings.gd
## because they are the renderer's business alone: the game's rules never read
## one. They are saved in the same file as the other settings.
class_name Gfx

## In the order the Settings page shows them, after the older Graphics entries.
const SETTINGS := [
	{"id": "gfxAA", "group": "Graphics", "label": "Anti-aliasing", "type": "choice", "default": "taa",
		"options": [["msaa", "MSAA 4x"], ["taa", "TAA"], ["fsr2", "FSR 2"]],
		"help": "How edges are smoothed. TAA also calms shimmer on metal and grain in the reflections. FSR 2 sharpens a lower render resolution back up: use it with 75%, at 100% it is the most expensive of the three."},
	{"id": "gfxRigs", "group": "Graphics", "label": "Stage lights with shadows", "type": "bool", "default": true,
		"help": "The overhead rig as spotlights that cast shadows, with the venue's colour washes."},
	{"id": "gfxSoftShadows", "group": "Graphics", "label": "Soft shadows", "type": "bool", "default": true,
		"help": "Four shadow ranges and soft edges from the key light."},
	{"id": "gfxSSAO", "group": "Graphics", "label": "Ambient occlusion", "type": "bool", "default": true,
		"help": "Contact shading where parts meet and under the robots."},
	{"id": "gfxSSIL", "group": "Graphics", "label": "Bounced light", "type": "bool", "default": false,
		"help": "Lit surfaces throw a little of their colour onto what is next to them. Off to begin with: with everything else on it takes the biggest venues under 60 frames a second."},
	{"id": "gfxSSR", "group": "Graphics", "label": "Floor reflections", "type": "bool", "default": true,
		"help": "The deck and polished steel mirror what is on screen."},
	{"id": "gfxProbe", "group": "Graphics", "label": "Arena reflections", "type": "bool", "default": true,
		"help": "Metal reflects the hall it is in - crowd, screens and lights - instead of a studio."},
	{"id": "gfxFog", "group": "Graphics", "label": "Haze and light beams", "type": "bool", "default": true,
		"help": "Volumetric haze in the hall, so the stage lights show as beams."},
	{"id": "gfxGrade", "group": "Graphics", "label": "Broadcast colour grade", "type": "bool", "default": true},
	{"id": "gfxDOF", "group": "Graphics", "label": "Depth of field in intros and replays", "type": "bool", "default": true},
	{"id": "gfxParticles", "group": "Graphics", "label": "Spark showers", "type": "bool", "default": true,
		"help": "Sparks, smoke and flame flown by the graphics card: several times as many, as streaks, with the flash of a big hit on what is round it."},
]

## Every setting the Settings page shows: the game's own, with these after
## the last of its Graphics entries.
static func all_settings() -> Array:
	var out := []
	var placed := false
	for i in Settings.SETTINGS.size():
		var s: Dictionary = Settings.SETTINGS[i]
		out.append(s)
		var last_gfx: bool = s.group == "Graphics" and (i + 1 >= Settings.SETTINGS.size() or Settings.SETTINGS[i + 1].group != "Graphics")
		if last_gfx:
			out.append_array(SETTINGS)
			placed = true
	if not placed: out.append_array(SETTINGS)
	return out

## Add these settings to a complete settings object: what was saved where it
## is valid, the default where it is not.
static func add_saved(settings: Dictionary, saved) -> void:
	for s in SETTINGS:
		settings[s.id] = s.default
		if not (saved is Dictionary) or not saved.has(s.id): continue
		var v = saved[s.id]
		if s.type == "bool":
			if typeof(v) == TYPE_BOOL: settings[s.id] = v
		else:
			for o in s.options:
				if o[0] == str(v): settings[s.id] = o[0]

static func _default(id: String):
	for s in SETTINGS:
		if s.id == id: return s.default
	return null

## One of these settings, as a switch (its default if the settings lack it -
## a backup from before the upgrade has none).
static func on(settings: Dictionary, id: String) -> bool:
	var v = settings.get(id)
	if typeof(v) != TYPE_BOOL: v = _default(id)
	return v == true

## One of these settings, as a choice.
static func choice(settings: Dictionary, id: String) -> String:
	var v = settings.get(id)
	return str(v) if v != null else str(_default(id))
