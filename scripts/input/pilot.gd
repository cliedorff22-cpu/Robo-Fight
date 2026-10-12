## pilot.gd - who is driving: the human or the AI.
##
## Control can be handed over at any time, including mid-match. Both pilots
## produce the same drive input, so handing over is just swapping which one
## is asked. The AI side is logic/ai.gd, handed in as `brain`; it reads a
## perception of the fight (sim/ai_bridge.gd).
class_name Pilot
extends RefCounted

const HUMAN := "human"
const AI_DRIVER := "ai"

var mode := HUMAN
var brain: AI
var _bus: Bus

func _init(bus: Bus, initial := HUMAN, ai_brain: AI = null) -> void:
	_bus = bus
	mode = initial
	brain = ai_brain

func set_mode(next: String, bot_id) -> void:
	if next == mode: return
	mode = next
	# Taking over from a human, the AI starts with a clean head - no stale
	# stuck timers or opponent history from the last time it drove.
	if mode == AI_DRIVER and brain != null: brain.reset()
	if _bus != null: _bus.emit(Bus.CONTROL_CHANGED, {"botId": bot_id, "pilot": mode})

func toggle(bot_id) -> String:
	set_mode(AI_DRIVER if mode == HUMAN else HUMAN, bot_id)
	return mode

## This step's drive input. `perception` (for the AI) may be null.
func read(human: Dictionary, perception, dt: float) -> Dictionary:
	if mode == HUMAN: return human
	if brain != null and perception != null: return brain.drive(perception, dt)
	return {"throttle": 0.0, "steer": 0.0, "brake": false, "weapon": 0.0}
