## game.gd - the autoload: what survives a change of scene (the registry, the
## settings, and what the next scene was asked to do).
extends Node

const MENU_SCENE := "res://scenes/main.tscn"
const FIGHT_SCENE := "res://scenes/fight.tscn"

var reg: Registry
var settings: Dictionary = {}
## What the next scene should do: a fight's corners and hand-offs
## (ui/fight_scene.gd), or the menu screen to open on.
var request: Dictionary = {}
## What the last fight handed back (a career or tournament result), until
## the menu picks it up.
var result = null
## The menus' history, for their back and forward arrows: every screen
## opened this session, and where in it we are.
var nav := {"stack": [], "idx": 0}
## Playing on a touch screen: the on-screen controls show, lighter graphics.
var touch := false
## A career save has been opened this session: Career goes straight to it
## (until then it opens on the list of saves).
var career_open := false

func _ready() -> void:
	reg = Registry.shared()
	touch = OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")
	Hud.touch = touch
	Parts.mobile = touch
	settings = load_settings()
	# Robots that joined the field during the career live in the save.
	Field.register_career_robots(reg, Store.read_json(Store.career_key()))
	apply_settings()
	GameAudio.warm_up()

func _settings_key() -> String:
	# A phone keeps its own, with its own defaults.
	return Store.SETTINGS + (".mobile" if touch else "")

func load_settings() -> Dictionary:
	var saved = Store.read_json(_settings_key())
	if touch:
		# A phone's first visit: lighter graphics, then whatever it has saved.
		var base := {"shadows": false, "bloom": false, "renderScale": "0.75"}
		if saved is Dictionary: base.merge(saved, true)
		saved = base
	var out := Settings.from_saved(saved)
	# The graphics upgrades are the renderer's own settings (render/gfx.gd).
	Gfx.add_saved(out, saved)
	return out

func save_settings() -> void:
	Store.write_json(_settings_key(), settings)

## Change one setting, keep it, and apply what applies everywhere.
func set_setting(id: String, value) -> void:
	settings[id] = value
	save_settings()
	apply_settings()

## The settings that are the whole game's, not one screen's.
func apply_settings() -> void:
	Stage.apply_viewport(get_tree().root, settings)
	Mats.apply_settings(settings)
	Parts.detailed = Gfx.on(settings, "gfxModels")
	# How a robot is drawn, in the workshop as in the fight.
	RobotFx.apply_settings(settings)

## Go to the fight (ui/fight_scene.gd reads `req`).
func start_fight(req: Dictionary) -> void:
	request = req
	result = null
	get_tree().change_scene_to_file(FIGHT_SCENE)

## Back to the menus, opening on `screen` ("quick", "career", "tournament"...).
func to_menu(screen := "") -> void:
	request = {"screen": screen}
	get_tree().change_scene_to_file(MENU_SCENE)

# F11 (or Alt+Enter): full screen and back, from anywhere.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	var e := event as InputEventKey
	if e.keycode == KEY_F11 or (e.keycode == KEY_ENTER and e.alt_pressed):
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	GameAudio.shut_down()
