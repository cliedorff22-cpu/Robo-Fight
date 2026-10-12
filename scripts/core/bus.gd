## bus.gd - a tiny publish/subscribe event bus.
##
## The seam that keeps logic from knowing rendering exists. The match and
## damage systems emit facts ("hit", "partFailed", "immobilized"); the
## renderer, HUD and audio subscribe.
class_name Bus
extends RefCounted

const DATA_LOADED := "data:loaded"
const MATCH_STATE := "match:state"        # { phase, clockS }
const HAZARD_FIRE := "hazard:fire"        # { id, type }
const BOT_RESET := "bot:reset"            # { botId }
const CAMERA_CHANGED := "camera:changed"  # { id, label }
const REPLAY_START := "replay:start"
const REPLAY_END := "replay:end"
const CONTROL_CHANGED := "control:changed" # { botId, pilot }
const HIT := "combat:hit"                 # { attackerId, defenderId, targetKey, severity, hits }
const PART_FAILED := "combat:partFailed"  # { botId, key, name, category }
const WEAPON_STATE := "weapon:state"      # { botId, phase, spinPct }
const REF_COUNT := "ref:count"            # { botId, count, of }
const KO := "ref:ko"                      # { botId }
const TAP_OUT := "ref:tapOut"             # { botId }
const PIN_WARNING := "ref:pinWarning"     # { botId, pinnedId }
const PIN_PENALTY := "ref:pinPenalty"     # { botId, pinnedId }
const SEPARATE := "ref:separate"          # { a, b }
const MATCH_END := "match:end"            # the full result - see logic/match.gd

var _handlers := {}

## Subscribe. Returns a Callable that unsubscribes.
func on(type: String, fn: Callable) -> Callable:
	if not _handlers.has(type):
		_handlers[type] = []
	_handlers[type].append(fn)
	return func(): _handlers[type].erase(fn)

func emit(type: String, payload = null) -> void:
	if _handlers.has(type):
		for fn in _handlers[type].duplicate():
			if fn.is_valid():
				fn.call(payload)
	if _handlers.has("*"):
		for fn in _handlers["*"].duplicate():
			if fn.is_valid():
				fn.call({"type": type, "payload": payload})

func clear() -> void:
	_handlers.clear()
