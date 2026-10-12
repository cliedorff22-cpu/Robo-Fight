## doc.gd - a column of text-heavy bits for the menus: headings, paragraphs,
## ledgers and tables. The career's screens are mostly these.
##
## Text is BBCode: [b]bold[/b], and Doc.muted() / pos() / neg() for colour.
## Run anything that came from the player or the data through Doc.esc().
class_name Doc
extends VBoxContainer

const POS := "#4ad07a"
const NEG := "#ff5a52"
const MUTED := "#8b8f96"

func _init(sep := 6) -> void:
	add_theme_constant_override("separation", sep)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

static func esc(s) -> String:
	return str(s if s != null else "").replace("[", "[lb]")

static func muted(s) -> String: return "[color=%s]%s[/color]" % [MUTED, s]
static func pos(s) -> String: return "[color=%s]%s[/color]" % [POS, s]
static func neg(s) -> String: return "[color=%s]%s[/color]" % [NEG, s]
static func accent(s) -> String: return "[color=#ffc81e]%s[/color]" % s
static func small(s) -> String: return "[font_size=12]%s[/font_size]" % s

## Money, signed, in pos or neg colour.
static func cash(n: float) -> String:
	return (neg(Market.money(n)) if n < 0 else pos(Market.money(n)))

static func text(bb: String, opts: Dictionary = {}) -> RichTextLabel:
	var o := {"kind": "cond", "size": 15, "weight": 500, "bold_kind": "cond", "bold_scale": 1.0}
	o.merge(opts, true)
	var r := UI.rich(bb, o)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r

## A small heading in the hot colour.
func sub(title: String, after_bb := "") -> Doc:
	add_child(UI.spacer(0, 4))
	var bb := "[color=#ff7a1a]%s[/color]" % esc(title.to_upper())
	if after_bb != "": bb += "  " + after_bb
	add_child(text(bb, {"size": 13, "weight": 700, "ls": 0.2}))
	return self

## A paragraph. opts.tone: "muted" | "neg" | "pos"; opts.size.
func p(bb: String, opts: Dictionary = {}) -> RichTextLabel:
	var o := opts.duplicate()
	match opts.get("tone", ""):
		"muted": o.color = UI.DIM
		"neg": o.color = Color(NEG)
		"pos": o.color = Color(POS)
	var r := text(bb, o)
	add_child(r)
	return r

func add(c: Control) -> Control:
	add_child(c)
	return c

func row(children: Array, sep := 8) -> HBoxContainer:
	var h := UI.hbox(sep, children)
	add_child(h)
	return h

func gap(h := 8) -> void:
	add_child(UI.spacer(0, h))

## A table: `cols` columns, each row an array of cells (BBCode text or a
## Control). opts:
##   head     column titles
##   expand   index of the column that takes the spare width (default 0)
##   right    indices of right-aligned columns
##   tones    per-row "" | "won" | "lost" | "me" | "total"
##   size     text size
func table(cols: int, rows: Array, opts: Dictionary = {}) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", int(opts.get("hsep", 14)))
	g.add_theme_constant_override("v_separation", int(opts.get("vsep", 3)))
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var expand: int = opts.get("expand", 0)
	var right: Array = opts.get("right", [])
	var size: int = opts.get("size", 15)
	var head: Array = opts.get("head", [])
	if not head.is_empty():
		for i in cols:
			var l := UI.label(str(head[i]).to_upper() if i < head.size() else "", {"kind": "cond", "size": 13, "weight": 600, "ls": 0.12, "color": UI.DIM,
				"align": "right" if right.has(i) else "left"})
			if i == expand: l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			g.add_child(l)
	var tones: Array = opts.get("tones", [])
	for ri in rows.size():
		var r: Array = rows[ri]
		var tone: String = tones[ri] if ri < tones.size() else ""
		for i in cols:
			var cell = r[i] if i < r.size() else ""
			var c: Control
			if cell is Control:
				c = cell
			else:
				var bb := str(cell)
				match tone:
					"won": bb = pos(bb)
					"lost": bb = neg(bb)
					"me": bb = accent(bb)
					"total": bb = "[b]%s[/b]" % bb
				var o := {"size": size, "align": "right" if right.has(i) else "left"}
				if i != expand: o.wrap = false
				c = text(bb, o)
				if i != expand: c.size_flags_horizontal = Control.SIZE_FILL
			if i == expand: c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			g.add_child(c)
	add_child(g)
	return g

## A three-column ledger: what, a note, an amount.
func ledger(rows: Array, tones: Array = []) -> GridContainer:
	return table(3, rows, {"right": [2], "tones": tones})
