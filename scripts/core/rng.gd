## rng.gd - seeded, deterministic random numbers.
##
## Every random decision in the game (damage rolls, AI jitter, bracket draws)
## comes from a seeded stream so a season can be replayed or reproduced from a
## save file. randf() is banned in logic.
##
## mulberry32, bit-for-bit the same stream as the JavaScript version: the
## same seed draws the same fights, so saves and seeds carry across.
class_name Rng
extends RefCounted

const M32 := 0xFFFFFFFF

var a: int = 1

func _init(seed_value = 1) -> void:
	a = int(seed_value) & M32

static func make(seed_value = 1) -> Rng:
	return Rng.new(seed_value)

## The low 32 bits of a * b, both unsigned 32-bit (JavaScript's Math.imul).
static func imul(x: int, y: int) -> int:
	x &= M32
	y &= M32
	return ((x * (y & 0xFFFF)) + (((x * (y >> 16)) & 0xFFFF) << 16)) & M32

## [0, 1)
func next() -> float:
	# imul() written out twice: this is the hottest line in a simulated season.
	a = (a + 0x6d2b79f5) & M32
	var t := a
	var x := t ^ (t >> 15)
	var y := t | 1
	t = ((x * (y & 0xFFFF)) + (((x * (y >> 16)) & 0xFFFF) << 16)) & M32
	x = t ^ (t >> 7)
	y = t | 61
	t = (t ^ (t + (((x * (y & 0xFFFF)) + (((x * (y >> 16)) & 0xFFFF) << 16)) & M32))) & M32
	return float((t ^ (t >> 14)) & M32) / 4294967296.0

func float_range(lo: float, hi: float) -> float:
	return lo + next() * (hi - lo)

## Inclusive at both ends.
func int_range(lo: int, hi: int) -> int:
	return lo + int(floor(next() * (hi - lo + 1)))

func bool_p(p: float = 0.5) -> bool:
	return next() < p

func pick(arr: Array):
	return arr[int(floor(next() * arr.size()))]

## Fisher-Yates on a copy, so callers never mutate shared data.
func shuffle(arr: Array) -> Array:
	var out := arr.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := int(floor(next() * (i + 1)))
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

## The state, so a save file can resume the exact same stream.
func get_state() -> int: return a
func set_state(s) -> void: a = int(s) & M32

## Stable string -> seed (FNV-1a), so "season-3-group-B" always draws the same way.
static func hash_seed(s) -> int:
	var st := str(s)
	var h := 2166136261
	for i in st.length():
		h ^= st.unicode_at(i)
		h = imul(h, 16777619)
	return h & M32
