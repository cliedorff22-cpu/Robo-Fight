## job_overlay.gd - something long, done off the main thread, behind a card
## that says what is happening and how far along it is.
##
## The off-season is thousands of trial fights (every team tests its
## upgrades); the advisor runs its own. Both take seconds, so they run here:
## the game keeps drawing, and nothing else can be clicked until it is done.
class_name JobOverlay
extends ColorRect

var _thread := Thread.new()
var _mutex := Mutex.new()
var _done := 0
var _total := 0
var _finished := false
var _result = null
var _on_done: Callable
var _bar: Meter
var _note: Label

## `work`: Callable(progress: Callable(done, total)) -> anything, run on a
## thread. `on_done`: Callable(result), back on the main thread.
func _init(title: String, note: String, work: Callable, on_done: Callable) -> void:
	color = Color(0.016, 0.024, 0.04, 0.78)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_on_done = on_done
	var card := Plate.new(30, 24)
	card.cut = 14
	card.bar_top = UI.ACCENT
	card.custom_minimum_size = Vector2(520, 0)
	_bar = Meter.new(10, 400)
	_bar.value = 0.0
	_bar.from = UI.HOT
	_bar.to = UI.ACCENT
	_note = UI.label(note, {"kind": "cond", "size": 15, "weight": 500, "color": UI.DIM, "align": "center", "wrap": true})
	card.add_child(UI.vbox(12, [
		UI.label(title.to_upper(), {"kind": "display", "size": 36, "weight": 600, "italic": true, "align": "center"}),
		_bar, _note,
	]))
	var c := CenterContainer.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(card)
	add_child(c)
	_thread.start(func():
		var r = work.call(_progress)
		_mutex.lock()
		_result = r
		_finished = true
		_mutex.unlock())

func _progress(done: int, total: int) -> void:
	_mutex.lock()
	_done = done
	_total = total
	_mutex.unlock()

func _process(_dt: float) -> void:
	_mutex.lock()
	var fin := _finished
	var d := _done
	var t := _total
	_mutex.unlock()
	if t > 0: _bar.value = float(d) / t
	if not fin: return
	set_process(false)
	_thread.wait_to_finish()
	var cb := _on_done
	var res = _result
	queue_free()
	if cb.is_valid(): cb.call(res)

func _exit_tree() -> void:
	if _thread.is_started(): _thread.wait_to_finish()
