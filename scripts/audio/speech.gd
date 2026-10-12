## speech.gd - the commentators' voices, from the computer's own speech
## synthesis (no audio files, no network). Two voices: play-by-play is
## quicker and higher, colour slower and lower; if the computer has more than
## one English voice they get different ones.
class_name Speech
extends RefCounted

# macOS ships joke voices (Bubbles, Zarvox...) alongside the real ones.
const NOVELTY := ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Organ", "Superstar", "Trinoids",
	"Whisper", "Wobble", "Zarvox", "Junior", "Ralph", "Kathy", "Fred", "Grandma", "Grandpa", "Rocko", "Shelley", "Sandy", "Flo", "Eddy", "Reed"]
const PBP := ["Daniel", "Alex", "Google UK English Male", "Microsoft Guy", "Microsoft David", "Arthur", "Oliver", "Tom"]
const COLOR := ["Samantha", "Karen", "Moira", "Tessa", "Google US English", "Microsoft Aria", "Microsoft Zira", "Serena", "Allison"]

var available := false
var volume := 1.0

var _pbp := ""
var _color := ""
var _serial := 0
var _waiting := {}             # utterance id -> [Callable, give-up time]
var _clock := 0.0

func _init() -> void:
	if DisplayServer.get_name() == "headless" or not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH): return
	var voices := []
	for v in DisplayServer.tts_get_voices():
		var lang: String = str(v.get("language", ""))
		var vname: String = str(v.get("name", ""))
		if not lang.to_lower().begins_with("en"): continue
		var joke := false
		for n in NOVELTY:
			if vname.contains(n): joke = true
		if not joke: voices.append(v)
	if voices.is_empty(): return
	available = true
	_pbp = _find(voices, PBP, "")
	_color = _find(voices, COLOR, _pbp)
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _ended)
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_CANCELED, _ended)

static func _find(voices: Array, names: Array, not_id: String) -> String:
	for n in names:
		for v in voices:
			if str(v.name).begins_with(n) and v.id != not_id: return v.id
	for v in voices:
		if v.id != not_id: return v.id
	return voices[0].id

func _ended(id: int) -> void:
	if not _waiting.has(id): return
	var fn: Callable = _waiting[id][0]
	_waiting.erase(id)
	if fn.is_valid(): fn.call()

func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)

## Say a line ({ text, who, pri }); `done` is called when it finishes (or
## fails). Returns false if nothing will be said.
func say(line: Dictionary, done: Callable) -> bool:
	if not available or volume <= 0.0: return false
	var text := str(line.text)
	while text.contains("!!") or text.contains("??") or text.contains("!?") or text.contains("?!"):
		text = text.replace("!!", "!").replace("??", "!").replace("!?", "!").replace("?!", "!")
	var color: bool = line.get("who") == "color"
	var excited: bool = line.get("pri", 0) >= 3 or text.contains("!")
	var rate := 1.02 if color else (1.22 if excited else 1.12)
	var pitch := 0.82 if color else (1.15 if excited else 1.0)
	_serial += 1
	# Some engines never report the end: do not let the booth hang.
	_waiting[_serial] = [done, _clock + 0.9 + text.length() * 0.095]
	DisplayServer.tts_speak(text, _color if color else _pbp, int(volume * 100.0), pitch, rate, _serial, false)
	return true

func cancel() -> void:
	if not available: return
	_waiting.clear()
	DisplayServer.tts_stop()

## Once a frame: give up on lines whose end was never reported.
func update(dt: float) -> void:
	_clock += dt
	for id in _waiting.keys():
		if _clock >= _waiting[id][1]: _ended(id)
