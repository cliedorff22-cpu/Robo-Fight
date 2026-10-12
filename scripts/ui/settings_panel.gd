## settings_panel.gd - one settings panel, used on the main menu, in the
## career and in the fight's pause overlay. It changes the saved settings
## (logic/settings.gd says what they are, render/gfx.gd adds the graphics upgrades) and tells its host what changed, so
## the host can apply it on the spot.
class_name SettingsPanel
extends VBoxContainer

## Called with (settings, id) after a change is saved.
var on_change: Callable

var _groups = null
var _buttons := {}             # id -> { value: Button }

## `groups`: only these groups (default: all). `note`: a line under the title.
func _init(groups = null, note := "", changed: Callable = Callable()) -> void:
	_groups = groups
	on_change = changed
	add_theme_constant_override("separation", 0)
	if note != "": add_child(UI.label(note, {"kind": "cond", "size": 13, "weight": 500, "color": UI.DIM}))
	var last_group := ""
	for x in Gfx.all_settings():
		if _groups != null and not _groups.has(x.group): continue
		if x.group != last_group:
			last_group = x.group
			add_child(UI.spacer(0, 12))
			add_child(UI.label(str(x.group).to_upper(), {"kind": "cond", "size": 13, "weight": 700, "ls": 0.2, "color": UI.HOT}))
			add_child(UI.spacer(0, 2))
		add_child(_row(x))

func _row(x: Dictionary) -> Control:
	var text := UI.vbox(1, [UI.label(x.label, {"kind": "cond", "size": 17, "weight": 500, "ls": 0.02})])
	if x.has("help"):
		text.add_child(UI.label(x.help, {"kind": "cond", "size": 12, "weight": 500, "color": UI.DIM, "wrap": true}))
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var control: Control
	var value = Game.settings.get(x.id)
	if x.type == "bool":
		var sw := Switch.new(J.truthy(value))
		sw.toggled.connect(func(on: bool): _apply(x.id, on))
		control = sw
	else:
		var row := UI.hbox(4)
		_buttons[x.id] = {}
		for o in x.options:
			var b := UI.button(str(o[1]).to_upper(), "choice", {"size": 13})
			b.button_pressed = str(value) == o[0]
			b.pressed.connect(func(): _apply(x.id, o[0]))
			_buttons[x.id][o[0]] = b
			row.add_child(b)
		control = row
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var line := PanelContainer.new()
	var sb := UI.box(Color(0, 0, 0, 0), {"pad": [0, 7]})
	sb.border_width_bottom = 1
	sb.border_color = Color(1, 1, 1, 0.06)
	line.add_theme_stylebox_override("panel", sb)
	line.add_child(UI.hbox(14, [text, control]))
	return line

func _apply(id: String, value) -> void:
	Game.set_setting(id, value)
	if _buttons.has(id):
		for k in _buttons[id]: (_buttons[id][k] as Button).button_pressed = k == str(value)
	if on_change.is_valid(): on_change.call(Game.settings, id)
