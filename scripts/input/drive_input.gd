## drive_input.gd - keyboard, gamepad and the on-screen stick, normalised into
## one drive input:
##   { throttle: -1..1, steer: -1..1, brake: bool, weapon: 0..1 }
## Nothing downstream knows whether a human or an AI produced it, which is
## what makes mid-match control handoff (pilot.gd) a one-line swap.
##
## The sim's steer is +1 = turn LEFT as seen from behind the robot, so the
## left keys push it positive.
class_name DriveInput

## The two players' halves of the keyboard (read_player).
const SPLIT := [
	{"fwd": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D, "weapon": [KEY_SPACE], "brake": [KEY_SHIFT]},
	{"fwd": KEY_UP, "back": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT, "weapon": [KEY_SLASH, KEY_CTRL], "brake": [KEY_PERIOD, KEY_ALT]},
]

## The on-screen sticks (ui/touch_controls.gd writes them): slot -> Vector2
## (steer, throttle), or absent while no thumb is on it. Its buttons are in
## `touch_buttons`: "weapon0", "brake0", "weapon1", "brake1".
static var touch_stick := {}
static var touch_buttons := {}

static func _down(code: int) -> bool:
	return Input.is_physical_key_pressed(code)

static func _axis(neg: int, pos: int) -> float:
	return (-1.0 if _down(neg) else 0.0) + (1.0 if _down(pos) else 0.0)

static func _deadzone(v: float, dz := 0.12) -> float:
	return 0.0 if absf(v) < dz else signf(v) * ((absf(v) - dz) / (1.0 - dz))

# A pad's drive input, or null if nobody is touching it (so the keyboard
# keeps working with a pad plugged in): left stick or triggers to drive,
# right stick to steer, A weapon, B brake.
static func _pad(slot: int):
	var pads := Input.get_connected_joypads()
	if slot >= pads.size(): return null
	var id: int = pads[slot]
	var ly := -_deadzone(Input.get_joy_axis(id, JOY_AXIS_LEFT_Y))
	var rx := _deadzone(Input.get_joy_axis(id, JOY_AXIS_RIGHT_X))
	if rx == 0.0: rx = _deadzone(Input.get_joy_axis(id, JOY_AXIS_LEFT_X))
	var rt := maxf(0.0, Input.get_joy_axis(id, JOY_AXIS_TRIGGER_RIGHT))
	var lt := maxf(0.0, Input.get_joy_axis(id, JOY_AXIS_TRIGGER_LEFT))
	var a := Input.is_joy_button_pressed(id, JOY_BUTTON_A)
	var b := Input.is_joy_button_pressed(id, JOY_BUTTON_B)
	if not (absf(ly) > 0.0 or absf(rx) > 0.0 or rt > 0.05 or lt > 0.05 or a or b): return null
	# Stick right = turn right = negative steer.
	return {"throttle": clampf(ly + rt - lt, -1.0, 1.0), "steer": -rx, "brake": b, "weapon": 1.0 if a else 0.0}

static func _finish(throttle: float, steer: float, brake: bool, weapon: float, slot: int) -> Dictionary:
	if touch_stick.has(slot):
		var t: Vector2 = touch_stick[slot]
		throttle = t.y
		steer = t.x
	if touch_buttons.get("weapon%d" % slot, false): weapon = 1.0
	if touch_buttons.get("brake%d" % slot, false): brake = true
	# A gamepad overrides when a stick is actually deflected, so you can swap
	# between keyboard and pad without re-selecting anything.
	var p = _pad(slot)
	if p != null:
		throttle = p.throttle
		steer = p.steer
		brake = brake or p.brake
		weapon = maxf(weapon, p.weapon)
	return {"throttle": clampf(throttle, -1.0, 1.0), "steer": clampf(steer, -1.0, 1.0), "brake": brake, "weapon": weapon}

## A lone human's drive input: the whole keyboard.
static func read() -> Dictionary:
	var throttle := _axis(KEY_S, KEY_W) + _axis(KEY_DOWN, KEY_UP)
	var steer := _axis(KEY_D, KEY_A) + _axis(KEY_RIGHT, KEY_LEFT)
	return _finish(throttle, steer, _down(KEY_SHIFT), 1.0 if _down(KEY_SPACE) else 0.0, 0)

## One player's drive input when two share the keyboard. Player 1 (slot 0):
## W A S D, Space weapon, Shift brake. Player 2 (slot 1): the arrows, / or
## Ctrl weapon, . or Alt brake. Gamepads go to players in the order they were
## plugged in.
static func read_player(slot: int) -> Dictionary:
	var k: Dictionary = SPLIT[slot]
	var brake := false
	for c in k.brake: brake = brake or _down(c)
	var weapon := 0.0
	for c in k.weapon:
		if _down(c): weapon = 1.0
	return _finish(_axis(k.back, k.fwd), _axis(k.right, k.left), brake, weapon, slot)
