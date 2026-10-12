## ui.gd - the look of every screen: colours, type and the handful of parts
## the menus and the HUD are built from.
##
## Fight-night broadcast: steel deck plate, bolted gunmetal panels with cut
## corners, yellow-and-black hazard stripes, the red and blue squares, and
## heavy condensed italic type.
##
## Type: the design calls for Teko (display), Barlow Condensed (labels),
## Barlow (body) and JetBrains Mono (numbers). Drop their .ttf files in
## res://fonts and they are used; without them the nearest fonts on the
## machine stand in.
class_name UI

const BG := Color("0b0c0f")
const BG2 := Color("141619")
const PANEL_TOP := Color(0.157, 0.173, 0.2, 0.94)
const PANEL_BOT := Color(0.086, 0.094, 0.114, 0.96)
const PANEL_FLAT := Color("1a1d22")
const LINE := Color(1, 1, 1, 0.08)
const EDGE := Color(1, 1, 1, 0.14)
const TEXT := Color("eceae4")
const DIM := Color("8b8f96")
const ACCENT := Color("ffc81e")
const HOT := Color("ff7a1a")
const RED := Color("e5281f")
const BLUE := Color("2e86ff")
const RED_SOFT := Color("ff6d6d")
const BLUE_SOFT := Color("7fbaf0")
const OK := Color("4ad07a")
const WARN := Color("f0a63c")
const BAD := Color("ff5a52")
const INK := Color("111111")

const FAMILIES := {
	"display": {"file": "Teko", "names": ["Teko", "DIN Condensed", "Avenir Next Condensed", "Impact", "Arial Narrow"], "scale": 1.0},
	"cond": {"file": "BarlowCondensed", "names": ["Barlow Condensed", "Avenir Next Condensed", "DIN Condensed", "Arial Narrow"], "scale": 1.0},
	"body": {"file": "Barlow", "names": ["Barlow", "Avenir Next", "Helvetica Neue", "Arial"], "scale": 1.0},
	"mono": {"file": "JetBrainsMono", "names": ["JetBrains Mono", "Menlo", "SF Mono", "Courier New"], "scale": 1.0},
}

static var _fonts := {}
static var _has_face := {}
static var _theme: Theme = null
static var _grad_shader: Shader = null
static var _key_re: RegEx = null

# Is the design's own font file for this family in res://fonts?
static func has_face(kind: String) -> bool:
	if not _has_face.has(kind):
		var fam: Dictionary = FAMILIES.get(kind, FAMILIES.cond)
		_has_face[kind] = ResourceLoader.exists("res://fonts/%s-SemiBold.ttf" % fam.file) or ResourceLoader.exists("res://fonts/%s-Bold.ttf" % fam.file)
	return _has_face[kind]

static func _weight_name(w: int) -> String:
	if w >= 700: return "Bold"
	if w >= 600: return "SemiBold"
	if w >= 500: return "Medium"
	return "Regular"

## A font: kind is display | cond | body | mono. `spacing` is extra space
## between letters, in pixels.
## The display face (Teko) carries a lot of air above and below its capitals;
## `trim` pixels come off each, so headlines sit as tightly as designed.
static func font(kind := "cond", weight := 600, italic := false, spacing := 0, trim := 0) -> Font:
	var key := "%s|%d|%s|%d|%d" % [kind, weight, italic, spacing, trim]
	if _fonts.has(key): return _fonts[key]
	var fam: Dictionary = FAMILIES.get(kind, FAMILIES.cond)
	var base: Font = null
	var real_italic := false
	for wn in [_weight_name(weight), "SemiBold", "Bold", "Medium", "Regular"]:
		# A real italic where the family has one.
		var ipath := "res://fonts/%s-%sItalic.ttf" % [fam.file, wn]
		if italic and wn == _weight_name(weight) and ResourceLoader.exists(ipath):
			base = load(ipath)
			real_italic = true
			break
		var path := "res://fonts/%s-%s.ttf" % [fam.file, wn]
		if ResourceLoader.exists(path):
			base = load(path)
			break
	var slanted := real_italic
	if base == null:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray(fam.names)
		sf.font_weight = weight
		sf.font_italic = italic
		sf.allow_system_fallback = true
		base = sf
		slanted = italic
	var out: Font = base
	if spacing != 0 or trim != 0 or (italic and not slanted):
		var fv := FontVariation.new()
		fv.base_font = base
		fv.spacing_glyph = spacing
		fv.spacing_top = -trim
		fv.spacing_bottom = -trim
		# The display faces have no italic of their own: slant them.
		if italic and not slanted: fv.variation_transform = Transform2D(Vector2(1, 0.2), Vector2(0, 1), Vector2.ZERO)
		out = fv
	_fonts[key] = out
	return out

## Style a Label (or Button, RichTextLabel): opts are
##   kind, size, weight, italic, color, ls (letter spacing in em), shadow
static func style(c: Control, opts: Dictionary = {}) -> Control:
	var size: int = int(opts.get("size", 15))
	var ls: float = opts.get("ls", 0.0)
	var kind: String = opts.get("kind", "cond")
	var trim := int(round(size * 0.25)) if (kind == "display" and has_face("display")) else 0
	var f := font(kind, int(opts.get("weight", 600)), opts.get("italic", false), int(round(ls * size)), trim)
	var is_rich := c is RichTextLabel
	c.add_theme_font_override("normal_font" if is_rich else "font", f)
	c.add_theme_font_size_override("normal_font_size" if is_rich else "font_size", size)
	if opts.has("color"):
		var col: Color = opts.color
		if c is Button:
			for n in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]: c.add_theme_color_override(n, col)
		else:
			c.add_theme_color_override("default_color" if is_rich else "font_color", col)
	if opts.get("shadow", false):
		c.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		c.add_theme_constant_override("shadow_offset_x", 0)
		c.add_theme_constant_override("shadow_offset_y", maxi(1, size / 14))
		c.add_theme_constant_override("shadow_outline_size", 0)
	return c

## A line of text. opts as style(), plus align (left|center|right), wrap, expand.
static func label(text: String, opts: Dictionary = {}) -> Label:
	var l := Label.new()
	l.text = text
	style(l, opts)
	match opts.get("align", "left"):
		"center": l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		"right": l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if opts.get("wrap", false): l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if opts.get("expand", false): l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if opts.get("clip", false):
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## Text with [b]bold[/b] and [color] runs (key hints, notes).
static func rich(bbcode: String, opts: Dictionary = {}) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if opts.get("wrap", true) else TextServer.AUTOWRAP_OFF
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	style(r, opts)
	var size: int = int(opts.get("size", 15))
	r.add_theme_font_override("bold_font", font(opts.get("bold_kind", "mono"), 700))
	r.add_theme_font_size_override("bold_font_size", int(size * opts.get("bold_scale", 0.92)))
	r.add_theme_font_override("italics_font", font(opts.get("kind", "cond"), int(opts.get("weight", 600)), true))
	r.add_theme_font_size_override("italics_font_size", size)
	match opts.get("align", "left"):
		"center": bbcode = "[center]%s[/center]" % bbcode
		"right": bbcode = "[right]%s[/right]" % bbcode
	r.text = bbcode
	if opts.get("expand", false): r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r

## Key names in the accent colour: UI.keys("[Enter] start  [Esc] pause").
static func keys(text: String) -> String:
	if _key_re == null:
		_key_re = RegEx.new()
		_key_re.compile("\\[([^\\[\\]]+)\\]")
	return _key_re.sub(text, "[b][color=#ffc81e]$1[/color][/b]", true)

static func hex(c: Color) -> String:
	return "#" + c.to_html(false)

## A flat box: opts are border (Color), border_w, cut (px, top-left and
## bottom-right corners), skew, pad (h, v), radius.
static func box(bg: Color, opts: Dictionary = {}) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	var bw: int = int(opts.get("border_w", 1 if opts.has("border") else 0))
	s.set_border_width_all(bw)
	if opts.has("border"): s.border_color = opts.border
	if opts.has("cut"):
		s.corner_radius_top_left = int(opts.cut)
		s.corner_radius_bottom_right = int(opts.cut)
		s.corner_detail = 1
	if opts.has("radius"):
		s.set_corner_radius_all(int(opts.radius))
	if opts.has("skew"): s.skew = Vector2(opts.skew, 0)
	var pad: Array = opts.get("pad", [10, 6])
	s.content_margin_left = pad[0]
	s.content_margin_right = pad[0]
	s.content_margin_top = pad[1]
	s.content_margin_bottom = pad[1] if pad.size() < 3 else pad[2]
	if opts.has("left_bar"):
		s.border_width_left = int(opts.get("left_bar_w", 4))
		s.border_color = opts.left_bar
	s.anti_aliasing = true
	return s

## A button in one of the game's styles:
##   fight  the big yellow go button      ghost  a quiet outlined one
##   back   the top bar's                 chip / seg / tab / choice  toggles
##   row    a list row                    menu   a main-menu line
static func button(text: String, kind := "ghost", opts: Dictionary = {}) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var normal: StyleBox
	var hover: StyleBox
	var pressed: StyleBox
	var fc := TEXT
	var fch := INK
	var fcp := INK
	match kind:
		"fight":
			var small: bool = opts.get("small", false)
			style(b, {"kind": "display", "size": 24 if small else 38, "weight": 700, "italic": true, "ls": 0.08})
			var pad := [28, 8, 4] if small else [28, 10, 4]
			normal = box(ACCENT, {"skew": 0.25, "pad": pad})
			hover = box(Color("ffd84a"), {"skew": 0.25, "pad": pad})
			pressed = box(Color("e8a400"), {"skew": 0.25, "pad": pad})
			fc = INK
		"back":
			style(b, {"kind": "cond", "size": 13, "weight": 700, "ls": 0.14})
			normal = box(Color("2a2e34"), {"border": EDGE, "pad": [14, 7], "cut": 8})
			hover = box(ACCENT, {"pad": [14, 7], "cut": 8})
			pressed = hover
		"chip", "seg", "choice":
			style(b, {"kind": "cond", "size": int(opts.get("size", 13)), "weight": 700, "ls": 0.08})
			var sk := 0.15 if kind == "chip" else 0.0
			normal = box(Color(1, 1, 1, 0.04), {"border": EDGE, "pad": [11, 3], "skew": sk})
			hover = box(Color(1, 1, 1, 0.1), {"border": EDGE, "pad": [11, 3], "skew": sk})
			pressed = box(ACCENT if kind != "choice" else Color(1, 0.78, 0.12, 0.12), {"border": ACCENT, "pad": [11, 3], "skew": sk})
			fc = Color("c8cfda")
			fch = TEXT
			fcp = INK if kind != "choice" else ACCENT
			b.toggle_mode = true
		"tab":
			style(b, {"kind": "cond", "size": 15, "weight": 700, "ls": 0.12})
			normal = box(Color(0, 0, 0, 0), {"pad": [12, 10, 8]})
			hover = box(Color(1, 1, 1, 0.04), {"pad": [12, 10, 8]})
			pressed = box(ACCENT, {"pad": [12, 10, 8], "skew": 0.2})
			fc = DIM
			fch = TEXT
			b.toggle_mode = true
		"row":
			style(b, {"kind": "cond", "size": int(opts.get("size", 16)), "weight": 500, "ls": 0.02})
			var tint: Color = opts.get("tint", ACCENT)
			normal = box(Color(0, 0, 0, 0), {"pad": [10, 3]})
			hover = box(Color(1, 1, 1, 0.06), {"pad": [10, 3]})
			pressed = box(Color(tint, 0.45), {"pad": [10, 3]})
			fch = TEXT
			fcp = Color.WHITE
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_:
			style(b, {"kind": "cond", "size": int(opts.get("size", 13)), "weight": 700, "ls": 0.12})
			normal = box(Color(0, 0, 0, 0.25), {"border": EDGE, "pad": [14, 8]})
			hover = box(ACCENT, {"border": ACCENT, "pad": [14, 8]})
			pressed = hover
			fc = Color("b9b6ad")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Off: the same shape, greyed out.
	var dis: StyleBoxFlat = (normal as StyleBoxFlat).duplicate()
	if kind == "fight": dis.bg_color = Color(1, 1, 1, 0.08)
	b.add_theme_stylebox_override("disabled", dis)
	b.add_theme_color_override("font_color", fc)
	b.add_theme_color_override("font_hover_color", fch)
	b.add_theme_color_override("font_pressed_color", fcp)
	b.add_theme_color_override("font_hover_pressed_color", fcp)
	b.add_theme_color_override("font_focus_color", fc)
	b.add_theme_color_override("font_disabled_color", Color(UI.DIM, 0.6) if kind == "fight" else Color(fc, 0.35))
	return b

## The theme every screen sits under: sensible defaults for the stock
## controls (scroll bars, text fields, drop-downs, sliders, switches).
static func theme() -> Theme:
	if _theme != null: return _theme
	var t := Theme.new()
	t.default_font = font("body", 500)
	t.default_font_size = 15
	t.set_color("font_color", "Label", TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)
	# Scroll bars.
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, box(Color(0, 0, 0, 0.25), {"pad": [4, 4]}))
		t.set_stylebox("grabber", sb, box(Color("3b3f46"), {"pad": [4, 4]}))
		t.set_stylebox("grabber_highlight", sb, box(ACCENT, {"pad": [4, 4]}))
		t.set_stylebox("grabber_pressed", sb, box(ACCENT, {"pad": [4, 4]}))
	# Text fields.
	var field := box(Color("0e1013"), {"border": EDGE, "pad": [10, 6]})
	for cls in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", cls, field)
		t.set_stylebox("focus", cls, box(Color("0e1013"), {"border": ACCENT, "pad": [10, 6]}))
		t.set_stylebox("read_only", cls, field)
		t.set_font("font", cls, font("cond", 500))
		t.set_font_size("font_size", cls, 15)
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_placeholder_color", cls, DIM)
		t.set_color("caret_color", cls, ACCENT)
	# Drop-downs.
	t.set_stylebox("normal", "OptionButton", field)
	t.set_stylebox("hover", "OptionButton", box(Color("15181d"), {"border": ACCENT, "pad": [10, 6]}))
	t.set_stylebox("pressed", "OptionButton", box(Color("15181d"), {"border": ACCENT, "pad": [10, 6]}))
	t.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	t.set_font("font", "OptionButton", font("cond", 600))
	t.set_font_size("font_size", "OptionButton", 15)
	t.set_stylebox("panel", "PopupMenu", box(Color("15181d"), {"border": EDGE, "pad": [6, 6]}))
	t.set_stylebox("hover", "PopupMenu", box(Color(1, 0.78, 0.12, 0.18), {"pad": [6, 2]}))
	t.set_font("font", "PopupMenu", font("cond", 600))
	t.set_font_size("font_size", "PopupMenu", 15)
	t.set_color("font_hover_color", "PopupMenu", ACCENT)
	# Plain buttons default to the quiet style.
	t.set_stylebox("normal", "Button", box(Color(0, 0, 0, 0.25), {"border": EDGE, "pad": [14, 8]}))
	t.set_stylebox("hover", "Button", box(ACCENT, {"pad": [14, 8]}))
	t.set_stylebox("pressed", "Button", box(ACCENT, {"pad": [14, 8]}))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_font("font", "Button", font("cond", 700))
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	# Sliders.
	t.set_stylebox("slider", "HSlider", box(Color(1, 1, 1, 0.12), {"pad": [0, 3]}))
	t.set_stylebox("grabber_area", "HSlider", box(ACCENT, {"pad": [0, 3]}))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(ACCENT, {"pad": [0, 3]}))
	# Tooltips.
	t.set_stylebox("panel", "TooltipPanel", box(Color("15181d"), {"border": EDGE, "pad": [8, 5]}))
	t.set_font("font", "TooltipLabel", font("cond", 500))
	# Separators.
	var sep := StyleBoxLine.new()
	sep.color = LINE
	t.set_stylebox("separator", "HSeparator", sep)
	_theme = t
	return t

## A gradient down the letters (the logo, the big VS): four colours, top to
## bottom of the capitals. A label's own drop shadow would be drawn with the
## gradient too (a doubled image), so the shadow here is a second, black copy
## of the text tucked behind.
static func gradient_text(l: Label, stops: Array) -> Label:
	if _grad_shader == null:
		_grad_shader = Shader.new()
		_grad_shader.code = "shader_type canvas_item;\nuniform vec4 c0 : source_color = vec4(1.0);\nuniform vec4 c1 : source_color = vec4(1.0);\nuniform vec4 c2 : source_color = vec4(1.0);\nuniform vec4 c3 : source_color = vec4(1.0);\nuniform float y0 = 0.0;\nuniform float height = 40.0;\nvarying float vy;\nvoid vertex() { vy = (VERTEX.y - y0) / height; }\nvoid fragment() {\n\tfloat t = clamp(vy, 0.0, 1.0);\n\tvec3 c = t < 0.45 ? mix(c0.rgb, c1.rgb, t / 0.45) : (t < 0.58 ? mix(c1.rgb, c2.rgb, (t - 0.45) / 0.13) : mix(c2.rgb, c3.rgb, (t - 0.58) / 0.42));\n\tCOLOR = vec4(c, texture(TEXTURE, UV).a * COLOR.a);\n}\n"
	var size := float(l.get_theme_font_size("font_size"))
	var m := ShaderMaterial.new()
	m.shader = _grad_shader
	for i in 4: m.set_shader_parameter("c%d" % i, stops[mini(i, stops.size() - 1)])
	# Where the capitals start and how tall they are, in this face.
	var real := has_face("display")
	m.set_shader_parameter("y0", size * (0.08 if real else 0.16))
	m.set_shader_parameter("height", size * (0.64 if real else 0.74))
	l.material = m
	var had_shadow := l.has_theme_color_override("font_shadow_color")
	l.remove_theme_color_override("font_shadow_color")
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	if had_shadow:
		var under := Label.new()
		under.text = l.text
		under.add_theme_font_override("font", l.get_theme_font("font"))
		under.add_theme_font_size_override("font_size", int(size))
		under.add_theme_color_override("font_color", Color(0, 0, 0, 0.9))
		under.horizontal_alignment = l.horizontal_alignment
		under.show_behind_parent = true
		under.mouse_filter = Control.MOUSE_FILTER_IGNORE
		under.position = Vector2(0, maxf(2.0, size / 22.0))
		l.add_child(under)
		under.set_anchors_preset(Control.PRESET_FULL_RECT, true)
		under.position = Vector2(0, maxf(2.0, size / 22.0))
	return l

# ---------------------------------------------------------------- layout helpers

static func hbox(sep := 8, children: Array = []) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	for c in children: h.add_child(c)
	return h

static func vbox(sep := 6, children: Array = []) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	for c in children: v.add_child(c)
	return v

static func margin(child: Control, l: int, t: int, r := -1, b := -1) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", l if r < 0 else r)
	m.add_theme_constant_override("margin_bottom", t if b < 0 else b)
	if child != null:
		# A margin takes up whatever room its content was going to.
		m.size_flags_horizontal = child.size_flags_horizontal
		m.size_flags_vertical = child.size_flags_vertical
		m.add_child(child)
	return m

static func spacer(w := 0, h := 0, expand := false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

static func scroll(child: Control, horizontal := false) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if horizontal else ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s

## Remove and free every child.
static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()

## Hold a control at a point of its parent (anchor 0..1 each way), `offset`
## pixels from it, growing away from that edge as its content needs.
static func pin(c: Control, anchor: Vector2, offset := Vector2.ZERO) -> Control:
	c.grow_horizontal = Control.GROW_DIRECTION_END if anchor.x < 0.25 else (Control.GROW_DIRECTION_BEGIN if anchor.x > 0.75 else Control.GROW_DIRECTION_BOTH)
	c.grow_vertical = Control.GROW_DIRECTION_END if anchor.y < 0.25 else (Control.GROW_DIRECTION_BEGIN if anchor.y > 0.75 else Control.GROW_DIRECTION_BOTH)
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = offset.x
	c.offset_right = offset.x
	c.offset_top = offset.y
	c.offset_bottom = offset.y
	return c

## Ask before doing something: `on_yes` runs if they agree.
static func confirm(parent: Node, text: String, on_yes: Callable, title := "Are you sure?") -> void:
	var d := ConfirmationDialog.new()
	d.title = title
	d.dialog_text = text
	d.dialog_autowrap = true
	d.min_size = Vector2i(480, 150)
	parent.add_child(d)
	d.confirmed.connect(func():
		d.queue_free()
		on_yes.call())
	d.canceled.connect(d.queue_free)
	d.popup_centered()

## Ask for a line of text: `on_ok` gets it.
static func prompt(parent: Node, text: String, start: String, on_ok: Callable, title := "ROBO LEAGUE") -> void:
	var d := ConfirmationDialog.new()
	d.title = title
	d.min_size = Vector2i(480, 170)
	var edit := LineEdit.new()
	edit.text = start
	edit.max_length = 28
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 440
	d.add_child(vbox(8, [l, edit]))
	d.register_text_enter(edit)
	parent.add_child(d)
	d.confirmed.connect(func():
		var t := edit.text
		d.queue_free()
		on_ok.call(t))
	d.canceled.connect(d.queue_free)
	d.popup_centered()
	edit.grab_focus()

## Fill the parent.
static func fill(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c
