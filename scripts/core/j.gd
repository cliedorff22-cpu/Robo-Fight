## j.gd - small helpers that keep ported logic behaving exactly as the
## JavaScript original did: Math.round's half-up rule, toFixed, a stable sort
## with a numeric comparator, number formatting without a trailing ".0", and
## safe reads of optional dictionary fields.
class_name J

## Math.round: halves round up (towards +infinity), even when negative.
static func rnd(x: float) -> float:
	return floor(x + 0.5)

static func rndi(x: float) -> int:
	return int(floor(x + 0.5))

## Number.prototype.toFixed.
static func fixed(x: float, digits: int = 0) -> String:
	if is_inf(x): return "Infinity" if x > 0 else "-Infinity"
	if is_nan(x): return "NaN"
	if digits <= 0:
		return str(int(rnd(x)))
	return ("%." + str(digits) + "f") % x

## A number as JavaScript's String(n) would print it: 3 not 3.0.
static func num(x) -> String:
	if x == null: return "null"
	if typeof(x) == TYPE_INT: return str(x)
	if typeof(x) != TYPE_FLOAT: return str(x)
	if is_inf(x): return "Infinity" if x > 0 else "-Infinity"
	if is_nan(x): return "NaN"
	if x == floor(x) and absf(x) < 1e15: return str(int(x))
	var s := str(x)
	return s

## Any value as a JavaScript template string would print it (`${x}`).
static func s(x) -> String:
	if typeof(x) == TYPE_FLOAT: return num(x)
	if x == null: return "null"
	if typeof(x) == TYPE_BOOL: return "true" if x else "false"
	return str(x)

## A number as JavaScript's bitwise operators leave it: wrapped to a signed
## 32-bit integer (so `x ^ y` on two big seeds can come out negative).
static func i32(x: int) -> int:
	x &= 0xFFFFFFFF
	return x - 0x100000000 if x >= 0x80000000 else x

## Thousands separators, for money ($12,500).
static func commas(x) -> String:
	var n := rndi(float(x))
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out

## Optional read: d[k] if d is a dictionary holding k (and not null), else def.
static func g(d, k, def = null):
	if d is Dictionary:
		var v = d.get(k)
		return def if v == null else v
	if d is Object and d != null:
		var v = d.get(k)
		return def if v == null else v
	return def

## Optional chained read: J.path(d, ["a", "b", "c"], def).
static func path(d, keys: Array, def = null):
	var cur = d
	for k in keys:
		if cur is Dictionary:
			if not cur.has(k): return def
			cur = cur[k]
		elif cur is Array and typeof(k) == TYPE_INT:
			if k < 0 or k >= cur.size(): return def
			cur = cur[k]
		else:
			return def
		if cur == null: return def
	return cur

## JavaScript truthiness (an empty array or dictionary is truthy; 0, "", null,
## false and NaN are not).
static func truthy(v) -> bool:
	match typeof(v):
		TYPE_NIL: return false
		TYPE_BOOL: return v
		TYPE_INT: return v != 0
		TYPE_FLOAT: return v != 0.0 and not is_nan(v)
		TYPE_STRING, TYPE_STRING_NAME: return v != ""
		_: return true

## A stable sort with a JavaScript-style comparator (negative = a first).
## Returns a new array.
static func sorted(arr: Array, cmp: Callable) -> Array:
	var a := arr.duplicate()
	var n := a.size()
	if n < 2: return a
	var b := a.duplicate()
	var width := 1
	while width < n:
		var i := 0
		while i < n:
			var mid := mini(i + width, n)
			var hi := mini(i + 2 * width, n)
			var l := i
			var r := mid
			var k := i
			while l < mid and r < hi:
				if float(cmp.call(a[r], a[l])) < 0.0:
					b[k] = a[r]; r += 1
				else:
					b[k] = a[l]; l += 1
				k += 1
			while l < mid:
				b[k] = a[l]; l += 1; k += 1
			while r < hi:
				b[k] = a[r]; r += 1; k += 1
			i += 2 * width
		var t := a
		a = b
		b = t
		width *= 2
	return a

## Sort in place (stable), returning the same array for chaining.
static func sort_in_place(arr: Array, cmp: Callable) -> Array:
	var s := sorted(arr, cmp)
	for i in s.size(): arr[i] = s[i]
	return arr

## Comparator helper: ascending by a key function.
static func by(key: Callable, desc := false) -> Callable:
	return func(x, y):
		var kx = key.call(x)
		var ky = key.call(y)
		var c := 0.0
		if kx < ky: c = -1.0
		elif kx > ky: c = 1.0
		return -c if desc else c

## String comparison as JavaScript's `x < y ? -1 : 1` idiom.
static func strcmp(x, y) -> int:
	var sx := str(x)
	var sy := str(y)
	if sx < sy: return -1
	if sx > sy: return 1
	return 0

## localeCompare, near enough (case-insensitive, then case).
static func locale_compare(x, y) -> int:
	var c := str(x).nocasecmp_to(str(y))
	if c != 0: return c
	return str(x).casecmp_to(str(y))

static func sum(arr: Array, key: Callable = Callable()) -> float:
	var s := 0.0
	for v in arr:
		s += float(key.call(v)) if key.is_valid() else float(v)
	return s

static func max_of(arr: Array, key: Callable = Callable(), def := -INF) -> float:
	var m := def
	var first := true
	for v in arr:
		var x := float(key.call(v)) if key.is_valid() else float(v)
		if first or x > m:
			m = x
			first = false
	return m

static func min_of(arr: Array, key: Callable = Callable(), def := INF) -> float:
	var m := def
	var first := true
	for v in arr:
		var x := float(key.call(v)) if key.is_valid() else float(v)
		if first or x < m:
			m = x
			first = false
	return m

static func find(arr: Array, pred: Callable):
	for v in arr:
		if pred.call(v): return v
	return null

static func find_index(arr: Array, pred: Callable) -> int:
	for i in arr.size():
		if pred.call(arr[i]): return i
	return -1

static func some(arr: Array, pred: Callable) -> bool:
	for v in arr:
		if pred.call(v): return true
	return false

static func every(arr: Array, pred: Callable) -> bool:
	for v in arr:
		if not pred.call(v): return false
	return true

## Array.prototype.slice with JavaScript's negative indices.
static func slice(arr: Array, start: int = 0, end = null) -> Array:
	var n := arr.size()
	var s := start
	if s < 0: s = maxi(0, n + s)
	var e: int = n if end == null else int(end)
	if e < 0: e = maxi(0, n + e)
	s = mini(s, n)
	e = mini(e, n)
	if e <= s: return []
	return arr.slice(s, e)

## Merge dictionaries left to right into a new one ({...a, ...b}).
static func merge(a, b = null, c = null, d = null) -> Dictionary:
	var out := {}
	for src in [a, b, c, d]:
		if src is Dictionary:
			for k in src: out[k] = src[k]
	return out

## A deep copy of JSON-shaped data.
static func clone(v):
	if v is Dictionary or v is Array:
		return v.duplicate(true)
	return v

## Clamp, the argument order JavaScript code used.
static func clamp01(x: float) -> float:
	return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)

## String.prototype.padStart for numbers and strings.
static func pad(v, width: int, ch := " ") -> String:
	var s := str(v)
	while s.length() < width: s = ch + s
	return s

## Capitalise the first letter.
static func cap(s) -> String:
	var t := str(s)
	return t.substr(0, 1).to_upper() + t.substr(1) if t != "" else t

## A unique-ish id from a string, lower case with underscores.
static func slug(s) -> String:
	var t := str(s).to_lower()
	var out := ""
	var prev_us := false
	for i in t.length():
		var ch := t[i]
		var ok := (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")
		if ok:
			out += ch
			prev_us = false
		elif not prev_us:
			out += "_"
			prev_us = true
	return out

## JSON for saves: Infinity and NaN become null, as JSON.stringify does.
static func to_json(v, indent := "") -> String:
	return JSON.stringify(_json_safe(v), indent, false)

static func _json_safe(v):
	if typeof(v) == TYPE_FLOAT:
		if is_inf(v) or is_nan(v): return null
		return v
	if v is Dictionary:
		var o := {}
		for k in v:
			var x = v[k]
			if typeof(x) == TYPE_CALLABLE or typeof(x) == TYPE_OBJECT: continue
			o[str(k)] = _json_safe(x)
		return o
	if v is Array:
		var a := []
		for x in v: a.append(_json_safe(x))
		return a
	return v

## JSON.parse, or null on junk.
static func parse_json(text: String):
	var j := JSON.new()
	if j.parse(text) != OK: return null
	return j.data
