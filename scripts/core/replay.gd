## replay.gd - a fixed-size ring buffer of poses, for instant replays.
##
## Records only transforms, not physics state, so playback is a camera trick
## rather than a re-simulation. That keeps it cheap and trivially portable.
class_name Replay
extends RefCounted

var playing := false

var _capacity := 360
var _interval := 1.0 / 30.0
var _hz := 30.0
var _frames := []              # ring of Array[Transform3D], one per sample
var _head := 0                 # next slot to write
var _count := 0                # frames recorded, capped at capacity
var _acc := 0.0                # time since the last sample
var _play_t := 0.0
var _play_from := 0
var _play_len := 0
var _src := []                 # what playback reads from: the ring, or a clip
var _src_cap := 0

func _init(seconds := 12.0, hz := 30.0) -> void:
	_hz = hz
	_capacity = int(ceil(seconds * hz))
	_interval = 1.0 / hz
	_frames.resize(_capacity)

func frame_count() -> int: return _count

## Call every step with the live poses (Array of Transform3D) while the match runs.
func record(dt: float, poses: Array) -> void:
	if playing: return
	_acc += dt
	if _acc < _interval: return
	_acc -= _interval
	_frames[_head] = poses
	_head = (_head + 1) % _capacity
	if _count < _capacity: _count += 1

## Start playing back the last `seconds` of recording.
func play(seconds := 6.0) -> bool:
	var want := mini(_count, int(ceil(seconds * _hz)))
	if want < 2: return false
	_play_len = want
	_play_from = (_head - want + _capacity) % _capacity
	_src = _frames
	_src_cap = _capacity
	_play_t = 0.0
	playing = true
	return true

## Copy the last `seconds` out of the ring into a standalone clip, so a moment
## survives after the ring has recorded over it - the hit of the match.
func capture(seconds := 5.0):
	var n := mini(_count, int(ceil(seconds * _hz)))
	if n < 2: return null
	var out := []
	var from := (_head - n + _capacity) % _capacity
	for i in n: out.append(_frames[(from + i) % _capacity])
	return out

## Play a clip from capture().
func play_clip(clip) -> bool:
	if clip == null or clip.size() < 2: return false
	_src = clip
	_src_cap = clip.size()
	_play_from = 0
	_play_len = clip.size()
	_play_t = 0.0
	playing = true
	return true

func stop() -> void:
	playing = false

## Advance playback. Returns an array of interpolated poses, or null when the
## replay has finished.
func sample(dt: float, speed := 0.5):
	if not playing: return null
	_play_t += dt * speed
	var f := _play_t / _interval
	if f >= _play_len - 1:
		playing = false
		return null
	var i0 := int(floor(f))
	var t := f - i0
	var a: Array = _src[(_play_from + i0) % _src_cap]
	var b: Array = _src[(_play_from + i0 + 1) % _src_cap]
	var out := []
	for i in a.size():
		var xa: Transform3D = a[i]
		out.append(xa.interpolate_with(b[i], t) if i < b.size() else xa)
	return out

## Progress through the current replay, 0..1 - for the HUD scrub bar.
func progress() -> float:
	if not playing or _play_len < 2: return 0.0
	return minf(1.0, (_play_t / _interval) / (_play_len - 1))

func clear() -> void:
	_head = 0
	_count = 0
	_acc = 0.0
	playing = false
