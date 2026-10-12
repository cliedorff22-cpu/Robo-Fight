## booth.gd - the commentary booth on screen and out loud.
##
## Takes the lines logic/commentary.gd writes and plays them one at a time:
## spoken (audio/speech.gd) and/or as a caption bar at the foot of the
## screen, depending on the Commentary setting. A knockout interrupts
## chatter; chatter that has waited too long is dropped rather than said
## late. Lines about the arena's hazards are spoken only - never captioned.
class_name Booth
extends Control

const NAMES := {"pbp": "Rex Gearhart", "color": "Dottie Volt"}
const STALE_S := 4.0

var mode := "both"
## Everything the booth has said this session (the checks read it).
var said := []

var _speech: Speech
var _who: Label
var _text: Label
var _box: PanelContainer
var _queue := []
var _current = null
var _show_t := 0.0
var _now := 0.0
var _gen := 0

func _init(speech: Speech, start_mode := "both") -> void:
	name = "Booth"
	_speech = speech
	mode = start_mode
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box = PanelContainer.new()
	var sb := UI.box(Color(0.04, 0.043, 0.055, 0.82), {"pad": [40, 8]})
	sb.border_width_top = 2
	sb.border_color = Color(1, 0.78, 0.12, 0.6)
	_box.add_theme_stylebox_override("panel", sb)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_who = UI.label("", {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": Color("ffb02e")})
	_text = UI.label("", {"kind": "cond", "size": 20, "weight": 600, "color": Color("f4f1ea"), "shadow": true, "align": "center", "wrap": true})
	_text.custom_minimum_size.x = 560
	var row := UI.hbox(12, [_who, _text])
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_box.add_child(row)
	var holder := CenterContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.anchor_left = 0.0
	holder.anchor_right = 1.0
	holder.anchor_top = 1.0
	holder.anchor_bottom = 1.0
	holder.offset_top = -150
	holder.offset_bottom = -74
	holder.add_child(_box)
	add_child(holder)
	_box.modulate.a = 0.0

func _voice_on() -> bool:
	return (mode == "voice" or mode == "both") and _speech != null and _speech.available

func _captions_on() -> bool:
	return mode == "captions" or mode == "both"

func _next() -> void:
	_current = null
	_queue = _queue.filter(func(l): return l.pri >= 3 or _now - l.at < STALE_S)
	if _queue.is_empty():
		if _show_t <= 0.0: _box.modulate.a = 0.0
		return
	# In the order the booth said them, except that must-say lines jump the queue.
	var i := 0
	for k in _queue.size():
		if _queue[k].pri >= 3:
			i = k
			break
	var l: Dictionary = _queue[i]
	_queue.remove_at(i)
	_play(l)

func _play(l: Dictionary) -> void:
	_current = l
	_gen += 1
	var my := _gen
	if _captions_on() and not J.truthy(l.get("hazard")):
		_who.text = str(NAMES.get(l.get("who"), "")).to_upper()
		_who.add_theme_color_override("font_color", Color("7fbaf0") if l.get("who") == "color" else Color("ffb02e"))
		_text.text = l.text
		_box.modulate.a = 1.0
		_show_t = 1.6 + str(l.text).length() * 0.055
	var spoken := _voice_on() and _speech.say(l, func(): if my == _gen: _next())
	if not spoken:
		# Captions only (or a hazard line with no voice): pace by reading time.
		l.until = _now + (1.4 + str(l.text).length() * 0.05 if (_captions_on() and not J.truthy(l.get("hazard"))) else 0.0)

## Lines from commentary.gd: [{ text, who, pri, hazard }].
func push(lines) -> void:
	if lines == null or mode == "off": return
	for line in lines:
		said.append(line)
		if said.size() > 200: said.pop_front()
		if not _voice_on() and J.truthy(line.get("hazard")): continue
		var item: Dictionary = line.duplicate()
		item.at = _now
		if not item.has("pri"): item.pri = 1
		if item.pri >= 3 and _current != null and _current.pri < 3:
			# Cut the chatter off for the big moment.
			if _speech != null: _speech.cancel()
			_queue = _queue.filter(func(x): return x.pri >= 2)
			_queue.push_front(item)
			_gen += 1
			_next()
			continue
		if item.pri == 0 and (_current != null or not _queue.is_empty()): continue      # chatter only into silence
		if _queue.size() >= 3:
			var low: Dictionary = _queue[0]
			for x in _queue:
				if x.pri < low.pri: low = x
			if low.pri < item.pri: _queue.erase(low)
			else: continue
		_queue.append(item)
	if _current == null: _next()

func update(dt: float) -> void:
	_now += dt
	if _speech != null: _speech.update(dt)
	if _show_t > 0.0: _show_t -= dt
	if _current != null and _current.has("until") and _now >= _current.until: _next()
	if _show_t <= 0.0 and (_current == null or not _captions_on()): _box.modulate.a = 0.0

func set_mode(m: String) -> void:
	mode = m
	if m == "off": clear()
	if not _captions_on(): _box.modulate.a = 0.0

func clear() -> void:
	_queue = []
	_current = null
	_gen += 1
	if _speech != null: _speech.cancel()
	_box.modulate.a = 0.0
	_show_t = 0.0
