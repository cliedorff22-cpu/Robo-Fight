## camera_rig.gd - the camera rig: chase, overhead, fixed arena cams, versus
## and replay.
##
## Camera definitions live in arena.json, so adding a broadcast angle is a
## data edit. All modes drive this one camera; switching is instant.
class_name CameraRig
extends Camera3D

var defs: Array
var index := 0

var _bus: Bus
# The chase cam carries its own yaw so a spinning bot does not whip the view
# around. It eases toward the bot's heading instead of locking to it.
var _chase_yaw := 0.0
var _chase_init := false
var _cam_pos := Vector3.ZERO
var _replay_clock := 0.0
var _versus_init := false

func _init(arena: Dictionary, bus: Bus) -> void:
	name = "CameraRig"
	defs = arena.cameras
	_bus = bus
	near = 0.15
	far = 220.0
	fov = J.g(defs[0], "fov", 60.0)
	# Somewhere sensible, so frame one is not at the origin.
	_cam_pos = Vector3(-U.ft_to_m(14), U.ft_to_m(6), 0)
	position = _cam_pos
	current = true

func _current() -> Dictionary:
	return defs[index]

func cam_id() -> String: return _current().id
func cam_label() -> String: return _current().label
func is_replay_cam() -> bool: return _current().type == "replay"

func _announce() -> void:
	var d := _current()
	fov = J.g(d, "fov", 60.0)
	if _bus != null: _bus.emit(Bus.CAMERA_CHANGED, {"id": d.id, "label": d.label})

func next_cam() -> void:
	index = (index + 1) % defs.size()
	_announce()

func prev_cam() -> void:
	index = (index - 1 + defs.size()) % defs.size()
	_announce()

func select(id: String) -> void:
	for i in defs.size():
		if defs[i].id == id and i != index:
			index = i
			_announce()

func select_index(i: int) -> void:
	if i >= 0 and i < defs.size() and i != index:
		index = i
		_announce()

func list() -> Array:
	return defs.map(func(d): return {"id": d.id, "label": d.label})

func reset_chase() -> void:
	_chase_init = false

static func _aim(cam: Camera3D, at: Vector3, target: Vector3) -> void:
	cam.position = at
	var dir := target - at
	if dir.length_squared() < 1e-8: return
	# Looking straight down, "up" has to be something else.
	var up := Vector3.UP if absf(dir.normalized().y) < 0.999 else Vector3(0, 0, -1)
	cam.look_at(target, up)

## `focus`: the transform of the bot to follow. `replaying`: a replay is
## being shown. `pair`: both corners' positions, for the Versus cam.
func update(dt: float, focus: Transform3D, replaying := false, pair: Array = []) -> void:
	var d := _current()
	var target := focus.origin
	var look := Vector3(target.x, target.y + 0.25, target.z)
	var type: String = d.type

	if type == "chase" or (type == "replay" and not replaying):
		var f := focus.basis.x
		var bot_yaw := atan2(-f.z, f.x)
		if not _chase_init:
			_chase_yaw = bot_yaw
			_chase_init = true
		# Shortest-arc easing, frame-rate independent.
		var delta := wrapf(bot_yaw - _chase_yaw, -PI, PI)
		var k := 1.0 - exp(-dt / maxf(0.01, J.g(d, "lag", 0.12)))
		_chase_yaw = wrapf(_chase_yaw + delta * k, -PI, PI)
		var dist := U.ft_to_m(d.distance)
		var h := U.ft_to_m(d.height)
		# Bot forward is local +X, so world heading is (cos, -sin) in XZ.
		var desired := Vector3(target.x - cos(_chase_yaw) * dist, target.y + h, target.z + sin(_chase_yaw) * dist)
		_cam_pos = _cam_pos.lerp(desired, 1.0 - exp(-dt / 0.1))
		_aim(self, _cam_pos, look)
	elif type == "overhead":
		_aim(self, Vector3(0, U.ft_to_m(d.height), 0.001), Vector3.ZERO)
	elif type == "fixed":
		var la: Vector3 = U.ft3(d.lookAt) if d.get("lookAt") != null else Vector3(0, 0.6, 0)
		# Fixed cams gently track the action rather than staring at the centre.
		_aim(self, U.ft3(d.pos), Vector3(la.x * 0.35 + target.x * 0.65, la.y * 0.4 + (target.y + 0.3) * 0.6, la.z * 0.35 + target.z * 0.65))
	elif type == "versus" and pair.size() == 2:
		# Both robots in frame, side-on to the line between them - the
		# two-player camera. It stays on whichever side of that line it is
		# already on, so it never whips across the arena.
		var a: Vector3 = pair[0]
		var b: Vector3 = pair[1]
		var mx := (a.x + b.x) / 2.0
		var mz := (a.z + b.z) / 2.0
		var dx := b.x - a.x
		var dz := b.z - a.z
		var sep := maxf(0.001, Vector2(dx, dz).length())
		var px := -dz / sep
		var pz := dx / sep
		# It starts with red on the left, as the HUD has it; after that it
		# only crosses over once the robots have clearly swapped round.
		if not _versus_init:
			_versus_init = true
			_cam_pos = Vector3(mx + px * 6.0, U.ft_to_m(d.height), mz + pz * 6.0)
		if (_cam_pos.x - mx) * px + (_cam_pos.z - mz) * pz < -1.0:
			px = -px
			pz = -pz
		var dist: float = U.ft_to_m(d.distance) + sep * J.g(d, "spread", 0.9)
		var desired := Vector3(mx + px * dist, U.ft_to_m(d.height) + sep * J.g(d, "rise", 0.3), mz + pz * dist)
		# Never into the stands: hold it within reach of the box.
		var lim := U.ft_to_m(J.g(d, "limit", 32.0))
		desired.x = clampf(desired.x, -lim, lim)
		desired.z = clampf(desired.z, -lim, lim)
		_cam_pos = _cam_pos.lerp(desired, 1.0 - exp(-dt / 0.35))
		_aim(self, _cam_pos, Vector3(mx, 0.3, mz))
	elif type == "replay":
		_replay_clock += dt
		var dist := U.ft_to_m(d.distance)
		var h := U.ft_to_m(d.height)
		var a := _replay_clock * deg_to_rad(J.g(d, "orbitRpm", 6.0) * 6.0)
		_aim(self, Vector3(target.x + cos(a) * dist, target.y + h, target.z + sin(a) * dist), look)
