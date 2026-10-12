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
	{"id": "gfxGI", "group": "Graphics", "label": "Hall light bounce", "type": "bool", "default": false,
		"help": "The lamps' light carries on off what it lands on: the deck lights the walls and a robot's flanks, and the shadows are filled by that instead of a flat glow. Worked out once as the fight loads (about a second). Off to begin with: it is the dearest thing on this page, about 14 frames a second in the biggest venues."},
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
	{"id": "gfxDecals", "group": "Graphics", "label": "Battle marks on the deck", "type": "bool", "default": true,
		"help": "The fight leaves its marks on the floor: gouges that glow for a second, soot, tyre rubber, and oil from what breaks."},
	{"id": "gfxWear", "group": "Graphics", "label": "Battle damage on the paint", "type": "bool", "default": true,
		"help": "A damaged panel's paint chips back to bare steel and soots up, is scraped bright where it was hit, and the scrape glows for a second."},
	{"id": "gfxTextures", "group": "Graphics", "label": "Scanned surfaces", "type": "bool", "default": true,
		"help": "Steel, rubber, plastic and concrete photographed from the real thing, in place of the drawn textures: the deck's scuffed plate, brushed weapon steel, tyre rubber."},
	{"id": "gfxModels", "group": "Graphics", "label": "Detailed models", "type": "bool", "default": true,
		"help": "Wheels as models - lugged tyres on machined rims - and the hall dressed with its lighting truss, lamps and pit equipment. Robots change from the next fight."},
	{"id": "gfxBlur", "group": "Graphics", "label": "Spinner blur", "type": "bool", "default": true,
		"help": "A weapon at speed is drawn as the blur a camera sees - solid where it fills the turn, see-through where the blades sweep - instead of a bar turning slowly."},
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
