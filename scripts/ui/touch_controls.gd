## touch_controls.gd - the on-screen controls for the fight on a touch screen.
##
## A thumb stick to drive (it appears wherever the thumb lands on its side of
## the screen), a WEAPON and a BRAKE button, and the buttons a keyboard
## player has keys for: start, pause, camera, highlights, back to the menu.
## The stick hands its throttle and steering to input/drive_input.gd; every
## button asks the fight scene for the action its key would, so the fight
## itself runs exactly as with a keyboard.
##
## Two players on one tablet: red's stick and buttons on the left edge,
## blue's on the right.
class_name TouchControls
extends Control

const RADIUS := 58.0                 # how far the stick travels, in pixels
const DEAD := 0.12

var _scene: FightScene
var _two := false
var _sticks := {}                    # touch index -> { slot, origin }
var _holds := {}                     # touch index -> button name
var _knobs := [Vector2.ZERO, Vector2.ZERO]
var _origins := [Vector2.ZERO, Vector2.ZERO]
var _active := [false, false]
var _buttons := {}                   # name -> Rect2
var _context := HBoxContainer.new()
var _shown := ""

func _init(scene: FightScene, two_player: bool) -> void:
	name = "TouchControls"
	_scene = scene
	_two = two_player
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UI.theme()
	# The bar: pause, camera, sound.
	var bar := UI.hbox(8)
	for spec in [["❚❚", "pause"], ["CAM", "cam_next"], ["♪", "sound"]]:
		var b := UI.button(spec[0], "ghost", {"size": 16})
		b.custom_minimum_size = Vector2(56, 44)
		b.pressed.connect(func(): _scene.do_action(spec[1]))
		bar.add_child(b)
	add_child(bar)
	UI.pin(bar, Vector2(0.5, 0.0), Vector2(0, 118))
	# What to do next: START before the bell, SKIP during a replay, and after
	# the result REMATCH or CONTINUE, HIGHLIGHTS and MENU.
	_context.add_theme_constant_override("separation", 10)
	_context.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_context)
	UI.pin(_context, Vector2(0.5, 1.0), Vector2(0, -28))

func _exit_tree() -> void:
	DriveInput.touch_stick.clear()
	DriveInput.touch_buttons.clear()

func _layout() -> void:
	var s := size
	_buttons.clear()
	if _two:
		_buttons["weapon0"] = Rect2(20, s.y - 250, 120, 84)
		_buttons["brake0"] = Rect2(20, s.y - 350, 120, 70)
		_buttons["weapon1"] = Rect2(s.x - 140, s.y - 250, 120, 84)
		_buttons["brake1"] = Rect2(s.x - 140, s.y - 350, 120, 70)
	else:
		_buttons["weapon0"] = Rect2(s.x - 190, s.y - 190, 160, 110)
		_buttons["brake0"] = Rect2(s.x - 350, s.y - 150, 140, 84)

# Which player's stick a touch at `p` would be.
func _zone(p: Vector2) -> int:
	if p.y < 170.0: return -1
	if _two: return 0 if p.x < size.x * 0.5 else 1
	return 0 if p.x < size.x * 0.5 else -1

func _input(event: InputEvent) -> void:
	if not _scene._ready_to_run or _scene._overlay_open: return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_layout()
			for name_key in _buttons:
				if (_buttons[name_key] as Rect2).has_point(t.position):
					_holds[t.index] = name_key
					DriveInput.touch_buttons[name_key] = true
					queue_redraw()
					return
			var slot := _zone(t.position)
			if slot >= 0 and not _active[slot] and _over_nothing(t.position):
				_sticks[t.index] = slot
				_origins[slot] = t.position
				_active[slot] = true
				_move(slot, t.position)
		else:
			if _holds.has(t.index):
				var nm: String = _holds[t.index]
				_holds.erase(t.index)
				if not _holds.values().has(nm): DriveInput.touch_buttons.erase(nm)
			if _sticks.has(t.index):
				var slot: int = _sticks[t.index]
				_sticks.erase(t.index)
				_active[slot] = false
				DriveInput.touch_stick.erase(slot)
			queue_redraw()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if _sticks.has(d.index): _move(_sticks[d.index], d.position)

# Not on one of the bar or context buttons.
func _over_nothing(p: Vector2) -> bool:
	for c in [_context, get_child(0)]:
		if (c as Control).get_global_rect().grow(6).has_point(p): return false
	return true

func _move(slot: int, p: Vector2) -> void:
	var d: Vector2 = (p - _origins[slot]) / RADIUS
	var m := minf(1.0, d.length())
	if d.length() > 0.0: d = d.normalized() * m
	_knobs[slot] = d * RADIUS
	# A dead zone in the middle, then the full range out to the rim.
	var k := 0.0 if m < DEAD else (m - DEAD) / (1.0 - DEAD) / maxf(m, 1e-6)
	# Up drives forward; left turns left (the sim's steer is +1 = left).
	DriveInput.touch_stick[slot] = Vector2(-d.x * k, -d.y * k)
	queue_redraw()

func _process(_dt: float) -> void:
	if not _scene._ready_to_run: return
	var want := []
	var bout := _scene.fight.bout
	if _scene.fight.replay.playing: want = [["SKIP ▸▸", "replay", true]]
	elif bout.phase == Match.IDLE: want = [["START", "start", true]]
	elif bout.phase == Match.ENDED:
		var mode := _scene._mode
		if mode == "career": want = [["BACK TO YOUR CAREER", "menu", true], ["HIGHLIGHTS", "replay", false]]
		elif mode == "tourney": want = [["BACK TO THE TOURNAMENT", "menu", true], ["HIGHLIGHTS", "replay", false]]
		else: want = [["RUN IT AGAIN" if mode == "scout" else "REMATCH", "start", true], ["HIGHLIGHTS", "replay", false], ["MENU", "menu", false]]
	var key := str(want)
	if key != _shown:
		_shown = key
		UI.clear(_context)
		for w in want:
			var b := UI.button(w[0], "fight" if w[2] else "ghost", {"small": true, "size": 16})
			b.custom_minimum_size.y = 52
			b.pressed.connect(func(): _scene.do_action(w[1]))
			_context.add_child(b)
	var driving: bool = not _scene.fight.replay.playing
	if visible != true: visible = true
	if driving != (_shown != "hidden"): queue_redraw()

func _draw() -> void:
	if _scene == null or not _scene._ready_to_run or _scene.fight.replay.playing: return
	_layout()
	var f := UI.font("cond", 700)
	for name_key in _buttons:
		var r: Rect2 = _buttons[name_key]
		var on: bool = DriveInput.touch_buttons.get(name_key, false)
		var weapon: bool = (name_key as String).begins_with("weapon")
		var col := UI.ACCENT if weapon else Color(1, 1, 1, 0.5)
		if _two and weapon: col = UI.RED if name_key == "weapon0" else UI.BLUE
		draw_rect(r, Color(col, 0.55 if on else 0.2))
		draw_rect(r, Color(col, 0.9), false, 2.0)
		var text := "WEAPON" if weapon else "BRAKE"
		var ts := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
		draw_string(f, r.position + (r.size - ts) / 2.0 + Vector2(0, ts.y * 0.75), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
	for slot in 2:
		if not _active[slot]: continue
		draw_arc(_origins[slot], RADIUS, 0.0, TAU, 40, Color(1, 1, 1, 0.35), 3.0, true)
		draw_circle(_origins[slot] + _knobs[slot], 26.0, Color(1, 1, 1, 0.45))
