## robot_sim.gd - the physical robot: one rigid body plus a raycast wheel model.
##
## Why not a built-in vehicle? Those assume steered front wheels. Battlebots
## are skid-steer (tank drive): both sides are driven independently and the
## bot pivots by scrubbing its tyres sideways. So this runs its own four-wheel
## model:
##
##   per wheel, each step:
##     1. raycast down from the suspension mount
##     2. spring + damper force along the contact normal   -> ride height, weight transfer
##     3. longitudinal force toward the commanded track speed  -> drive and engine braking
##     4. lateral force opposing sideways scrub, capped      -> lets the bot pivot and drift
##     5. clamp (3) and (4) into the friction circle         -> grip runs out believably
##
## The maths is in wheel_model.gd; this file is the engine plumbing.
##
## Every tunable number comes from the assembled build (logic/build.gd), so
## fitting bigger wheels or stronger motors changes the handling with no code
## edits.
class_name RobotSim
extends RigidBody3D

const DAMPING_RATIO := 0.7

var assembled: Dictionary
var rules: Dictionary
## The body as the picture needs it: shape, wheel mounts, live suspension.
var rig: RobotRig
var shape: Dictionary
var routes: Dictionary
var wheels: Array
## Per-wheel telemetry the renderer and HUD read (load, slip, grounded).
var telemetry: Array
var suspension := {}
var wedge_info = null
var spawn_pos := Vector3.ZERO
var spawn_yaw := 0.0
var grounded_count := 0
## Running on the other face of its tyres right now.
var inverted := false
var invertible := false
var self_rights := 0
var clamped := 0
## Set by whoever registers it for the fight (combat.gd).
var bot_id := ""

var _shape_keys := []          # shape index -> fitting key
var _shape_slots := []         # shape index -> shape slot (a wedge, a fork, armour...)
var _powered := {}      # wheel index -> its rank among the powered wheels
var _spring_k := 0.0
var _spring_c := 0.0
var _drive_gain := 0.0
var _lat_gain := 0.0
var _rest_length := 0.012
var _eff = null
var _drop_rng: Rng
var _right_rng: Rng
var _dropout_until := 0.0
var _clock := 0.0
var _self_right: Dictionary
var _self_right_ready := 0.0
var _upside_down_s := 0.0
var _lim := {}
var _mass := 100.0
var _inertia := Vector3.ONE
var _forces := WheelModel.Forces.new()
var _ray := PhysicsRayQueryParameters3D.new()

## `spawn` is { pos: Vector3 in metres, yaw: radians }. pos.y lifts the bot
## above its rest height (a drop test); 0 is on its wheels.
func _init(assembled_robot: Dictionary, spawn: Dictionary, rulebook: Dictionary, match_seed = 1) -> void:
	assembled = assembled_robot
	rules = rulebook
	name = "bot_%s" % str(assembled.id).validate_node_name()
	# Signal dropouts from failing electronics change how the bot drives, so
	# they change results - they get their own seeded stream.
	_drop_rng = Rng.new(Rng.hash_seed("dropout:%s:%s" % [assembled.id, J.s(match_seed)]))
	_right_rng = Rng.new(Rng.hash_seed("selfright:%s:%s" % [assembled.id, J.s(match_seed)]))
	var stats: Dictionary = assembled.stats
	_mass = assembled.massKg

	# ---- ride height. The chassis floor should clear the ground by the
	# build's ground clearance once the springs have settled to their preload.
	rig = RobotRig.new(assembled)
	shape = rig.shape
	routes = rig.routes
	wheels = rig.wheels
	telemetry = rig.telemetry
	for t in telemetry:
		t.grounded = false
		t.compression = 0.0
	_rest_length = rig.rest_length
	if rig.layout.clearance <= _rest_length * WheelModel.SUSPENSION_PRELOAD:
		push_warning("[sim] %s: ground clearance %d mm is less than the resting suspension compression - the chassis will drag on the floor." % [assembled.id, int(rig.layout.clearance * 1000.0)])
	# Spawn exactly at rest height. Dropping the bot in from above put the
	# wheel mounts beyond their rays' reach, so the first contact arrived as a
	# slam rather than a settle.
	var at: Vector3 = spawn.pos
	spawn_pos = Vector3(at.x, rig.layout.spawnY, at.z)
	spawn_yaw = spawn.get("yaw", 0.0)

	# ---- body. Mass, centre of mass and principal inertia come from the
	# build, so the workshop's numbers are the numbers the physics uses.
	mass = _mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(assembled.comLocalM.x, assembled.comLocalM.y, assembled.comLocalM.z)
	_inertia = Vector3(assembled.inertia.x, assembled.inertia.y, assembled.inertia.z)
	inertia = _inertia
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.08
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.35
	continuous_cd = true
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 32
	collision_layer = Phys.ROBOT
	collision_mask = Phys.ARENA | Phys.ROBOT | Phys.HAZARD
	transform = Transform3D(Phys.yaw_basis(spawn_yaw), Vector3(at.x, rig.layout.spawnY + at.y, at.z))

	# ---- colliders, from the robot's shape (logic/shape.gd): one per convex
	# piece, each routed to the fitting a hit on it damages, plus the weapon's
	# swept volume. The renderer draws the same pieces.
	var slick_body := false
	for piece in shape.pieces:
		var key = "chassis" if piece.id == "core" else routes.get(piece.id)
		var s := _piece_shape(piece)
		if s[0] == null: continue
		_add(s[0], s[1], key, null if piece.id == "core" else piece.get("slot"))
		if piece.get("slot") == "wedge": slick_body = true
	# Powered weapons need a physical presence, or nothing can ever be hit by
	# one. These sit in the weapon's swept volume rather than spinning as
	# separate bodies: for damage routing that is enough, and it keeps a
	# 150 m/s rim from needing its own joint. A bar genuinely sticks out past
	# the chassis, so it catches walls too - which is correct.
	var weapon = shape.get("weapon")
	if weapon is Dictionary:
		for c in weapon.get("colliders", []):
			var xf := Transform3D(Basis.IDENTITY, c.center) if c.get("center") is Vector3 else Transform3D.IDENTITY
			var sh: Shape3D
			if c.type == "cylinder":
				sh = Phys.cylinder(c.radius, c.halfHeight * 2.0)
				# Cylinders run along local Y; a lateral (Z) axle is a quarter turn about X.
				if c.axis == "z": xf.basis = Basis(Vector3.RIGHT, PI / 2.0)
				elif c.axis == "x": xf.basis = Basis(Vector3.BACK, PI / 2.0)
			elif c.type == "cuboid":
				sh = Phys.box(c.half * 2.0)
			else:
				var cv := ConvexPolygonShape3D.new()
				cv.points = PackedVector3Array(c.points)
				sh = cv
			_add(sh, xf, "weapon", "rotor")
		wedge_info = weapon.get("wedge")
		if wedge_info != null: slick_body = true
	# One surface for the whole body here (the engine has no per-piece
	# friction): a wedge is slick so opponents ride up it, armour a touch
	# grippier.
	physics_material_override = Phys.material(0.3 if slick_body else 0.45, 0.05)

	# ---- wheels. Positions come from the chassis footprint; which ones are
	# powered comes from the drive part.
	var driven := int(stats.drivenWheels)
	if driven >= wheels.size():
		for i in wheels.size(): _powered[i] = i
	else:
		# 4WD powers everything; 2WD powers the rear axle.
		var n := 0
		for i in wheels.size():
			if wheels[i].axle == "rear" and n < driven:
				_powered[i] = n
				n += 1
	# Spring rate sized so the preload exactly carries the bot's weight.
	var rates := WheelModel.suspension_rates(_mass, wheels.size(), _rest_length, WheelModel.SUSPENSION_PRELOAD, DAMPING_RATIO, Phys.GRAVITY)
	_spring_k = rates.springK
	_spring_c = rates.springC
	suspension = {"restLength": _rest_length, "springK": _spring_k, "springC": _spring_c, "preload": WheelModel.SUSPENSION_PRELOAD}
	_drive_gain = stats.forcePerWheelN / maxf(0.5, stats.topSpeedMps * 0.25)
	_lat_gain = _mass * Phys.GRAVITY * 1.8

	invertible = J.truthy(shape.get("invertible"))
	_self_right = stats.selfRight if stats.get("selfRight") is Dictionary else {"via": "none"}
	# Sanity limits on the body itself (rules.json `limits`). Nothing a real
	# fight does gets near these, so they only ever catch a glitch.
	_lim = J.merge({"maxSpeedMps": 12.0, "maxUpMps": 6.5, "maxSpinRadS": 28.0}, rules.get("limits", {}))
	_ray.collision_mask = Phys.ARENA | Phys.ROBOT | Phys.HAZARD
	_ray.hit_from_inside = true

# A piece's collider: [shape, transform]. The classic box-and-panels look is
# made of boxes and keeps exact cuboids, so the original bots handle exactly
# as they did.
func _piece_shape(piece: Dictionary) -> Array:
	var pts: Array = piece.points
	if shape.template == "classic" and pts.size() == 8:
		var b := Hull.bounds(pts)
		return [Phys.box(b.max - b.min), Transform3D(Basis.IDENTITY, (b.max + b.min) / 2.0)]
	if pts.size() < 4:
		push_warning("[sim] %s: convex hull failed for piece \"%s\"" % [assembled.id, piece.id])
		return [null, Transform3D.IDENTITY]
	var cv := ConvexPolygonShape3D.new()
	cv.points = PackedVector3Array(pts)
	return [cv, Transform3D.IDENTITY]

func _add(sh: Shape3D, xf: Transform3D, key, slot) -> void:
	Phys.add_shape(self, sh, xf)
	_shape_keys.append(key if key != null else "chassis")
	_shape_slots.append(slot)

func _ready() -> void:
	_ray.exclude = [get_rid()]

# ---------------------------------------------------------------- queries

## Which fitting a collider of this body is (by shape index).
func fitting_for_shape(idx: int) -> String:
	return _shape_keys[idx] if idx >= 0 and idx < _shape_keys.size() else "chassis"

## Which shape slot a collider is - combat asks, because a rotor striking a
## wedge glances off it.
func slot_for_shape(idx: int):
	return _shape_slots[idx] if idx >= 0 and idx < _shape_slots.size() else null

## Effective stats reflect damage (logic/condition.gd). Cached, and
## invalidated whenever something hits the bot.
func effective() -> Dictionary:
	if _eff == null: _eff = Condition.effective_stats(assembled, rules)
	return _eff

## Call after anything changes this robot's condition.
func invalidate() -> void:
	_eff = null

func speed_mps() -> float:
	return linear_velocity.length()

## Horizontal speed only. This is what the immobilisation count watches: a
## bot being bounced by a hazard is not driving anywhere.
func ground_speed_mps() -> float:
	return Vector2(linear_velocity.x, linear_velocity.z).length()

## How upright the bot is: 1 = level, 0 = on its side, -1 = fully inverted.
func uprightness() -> float:
	return global_transform.basis.y.y

func is_grounded() -> bool:
	return grounded_count > 0

## Where wheel i is mounted right now - mirrored while running inverted.
func wheel_anchor(i: int) -> Vector3:
	return rig.wheel_anchor(i)

## The robot's heading: the direction its nose points on the floor, read off
## its forward axis so it stays right when an invertible bot is on its back.
func heading() -> float:
	var f := global_transform.basis.x
	return atan2(-f.z, f.x)

## Can it get itself back over if flipped? (invertible bots never need to)
func can_self_right() -> bool:
	if _self_right.get("via", "none") == "none" or invertible: return false
	if J.truthy(effective().get("immobile")): return false
	return J.g(assembled.condition, _self_right.get("fitting"), 0.0) > 0.0

# ---------------------------------------------------------------- self-righting

## A srimech, or a flipper/hammer/lifter pushing off the floor: a hop and a
## roll put it back on its wheels, from its back or its side.
func try_self_right() -> bool:
	if not can_self_right() or _clock < _self_right_ready: return false
	# An unreliable method (a gyro dance) can fail and still costs its wait.
	if _self_right.get("chance") != null and _right_rng.next() > _self_right.chance:
		_self_right_ready = _clock + _self_right.cooldownS
		return false
	var bb := global_transform.basis
	var up_w := bb.y
	if up_w.y > 0.45: return false             # already on its wheels
	# Roll toward upright: about the axis that carries the robot's up toward
	# the world's, or about its long axis when it is flat on its back. The
	# push off the floor sets how long it is airborne; the twist is sized from
	# the robot's real inertia to turn exactly as far as it needs in that time
	# - a quarter turn from its side, a half turn from its back.
	var axis := up_w.cross(Vector3.UP)
	if axis.length() < 0.05: axis = bb.x
	axis = axis.normalized()
	var j: float = _self_right.impulseNs * (_mass / 100.0)
	var v_up := minf(3.2, j / _mass)
	var air_s := (2.0 * v_up) / Phys.GRAVITY
	var angle := acos(clampf(up_w.y, -1.0, 1.0))
	# Inertia about that axis, from the build's principal moments.
	var a_body := bb.inverse() * axis
	var i_axis := a_body.x * a_body.x * _inertia.x + a_body.y * a_body.y * _inertia.y + a_body.z * a_body.z * _inertia.z
	var omega := (angle / maxf(0.15, air_s)) * 1.05
	apply_central_impulse(Vector3(0, v_up * _mass, 0))
	apply_torque_impulse(axis * (i_axis * omega))
	_self_right_ready = _clock + _self_right.cooldownS
	self_rights += 1
	return true

# ---------------------------------------------------------------- the step

## Apply the sanity limits now - called after the physics step too, so a
## solver spike never shows.
func clamp_motion() -> void:
	var v := linear_velocity
	var sp := v.length()
	var changed := false
	if sp > _lim.maxSpeedMps:
		v *= _lim.maxSpeedMps / sp
		changed = true
	if v.y > _lim.maxUpMps:
		v.y = _lim.maxUpMps
		changed = true
	if changed:
		linear_velocity = v
		clamped += 1
	var w := angular_velocity
	var ws := w.length()
	if ws > _lim.maxSpinRadS:
		angular_velocity = w * (_lim.maxSpinRadS / ws)
		clamped += 1

## Apply one step of drive forces. `input` is { throttle, steer, brake,
## weapon, selfRight }. Call from _physics_process, before the engine steps.
func step(input: Dictionary, dt: float) -> void:
	_clock += dt
	clamp_motion()
	var eff := effective()

	# A destroyed chassis, dead electronics or no wheels left means no drive
	# at all. The bot still slides around; it just cannot do anything about it.
	if J.truthy(eff.get("immobile")):
		grounded_count = 0
		for t in telemetry:
			t.grounded = false
			t.load = 0.0
			t.compression = 0.0
		return

	var throttle: float = input.get("throttle", 0.0)
	var steer_in: float = input.get("steer", 0.0)
	var brake: bool = J.truthy(input.get("brake"))
	var weapon_in: float = input.get("weapon", 0.0)
	var want_right: bool = J.truthy(input.get("selfRight"))
	# Failing electronics drop the signal intermittently. The bot coasts
	# through a dropout, which is exactly how a dying receiver feels.
	if eff.get("dropoutHz", 0.0) > 0.0:
		if _clock < _dropout_until:
			throttle = 0.0; steer_in = 0.0; brake = false; weapon_in = 0.0; want_right = false
		elif _drop_rng.next() < eff.dropoutHz * dt:
			_dropout_until = _clock + eff.dropoutS

	var xf := global_transform
	var pos := xf.origin
	var linvel := linear_velocity
	var angvel := angular_velocity
	var up := xf.basis.y
	var fwd := xf.basis.x

	if invertible:
		if not inverted and up.y < -0.25: inverted = true
		elif inverted and up.y > 0.25: inverted = false
	rig.inverted = inverted
	_upside_down_s = _upside_down_s + dt if up.y < 0.45 else 0.0
	# Self-right on request - the weapon button while flipped, or the AI's
	# explicit call - once it has settled on its back for a moment.
	if (want_right or weapon_in > 0.5) and _upside_down_s > 0.4: try_self_right()

	# Skid steer: mix throttle and steer into a per-side command, after
	# tapering steering authority near the bot's yaw-rate limit. Inverted,
	# the yaw axis is upside down too, so the steer sense flips.
	var flip := -1.0 if inverted else 1.0
	var steer := WheelModel.taper_steer_for_yaw_rate(steer_in * flip, angvel.y * flip, eff.maxYawRateRadS)
	var mix := WheelModel.skid_steer_mix(throttle, steer)

	var space := get_world_3d().direct_space_state
	var down := up if inverted else -up
	var wheel_r: float = eff.wheelRadiusM
	var max_dist := _rest_length + wheel_r
	var grip: float = eff.grip
	var lat_frac: float = eff.lateralGripFraction
	var top_speed: float = eff.topSpeedMps
	var force_per_wheel: float = eff.forcePerWheelN
	var driven: int = int(eff.drivenWheels)
	var res := _forces
	var count := 0

	for i in wheels.size():
		var tele: Dictionary = telemetry[i]
		# --- plumbing: where is the ground under this wheel's mount?
		var anchor_world := pos + xf.basis * rig.wheel_anchor(i)
		_ray.from = anchor_world
		_ray.to = anchor_world + down * max_dist
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			tele.grounded = false; tele.load = 0.0; tele.compression = 0.0; tele.slip = 0.0
			continue
		count += 1
		var contact: Vector3 = hit.position
		var normal: Vector3 = hit.normal
		# Starting inside something: no surface to read, so push straight back.
		if normal.length_squared() < 0.5: normal = -down
		var dist := anchor_world.distance_to(contact)

		# Contact-point velocity, and the tyre's frame on the contact plane.
		var r := contact - pos
		var point_vel := linvel + angvel.cross(r)
		var fwd_on_plane := (fwd - normal * fwd.dot(normal)).normalized()
		var lat_on_plane := normal.cross(fwd_on_plane).normalized()
		var v_fwd := point_vel.dot(fwd_on_plane)
		var v_lat := point_vel.dot(lat_on_plane)

		# --- maths: pure, testable, engine-agnostic (see wheel_model.gd).
		# Compression grows as the mount moves DOWN toward the ground, so the
		# rate is the contact velocity along the ray, not against it.
		WheelModel.compute(res, dist, wheel_r, _rest_length, _spring_k, _spring_c, point_vel.dot(down), v_fwd, v_lat,
			grip, lat_frac, mix.x if wheels[i].side == "left" else mix.y,
			# Wheels are lost as the set is destroyed, so a battered bot loses
			# drive on some corners entirely.
			int(_powered.get(i, 1 << 30)) < driven, top_speed, force_per_wheel, _drive_gain, _lat_gain, brake)

		tele.grounded = true
		tele.load = res.loadN
		tele.compression = res.compression / _rest_length
		tele.slip = absf(v_lat)
		tele.spin += (v_fwd / maxf(1e-3, wheel_r)) * dt

		# --- plumbing: push along the contact normal, then drive/corner in-plane.
		apply_force(normal * res.loadN + fwd_on_plane * res.fLong + lat_on_plane * res.fLat, r)
	grounded_count = count

## Put the bot back on its wheels at its spawn (or at `at`, facing `yaw`).
func reset(at = null, yaw = null) -> void:
	var p: Vector3 = at if at != null else spawn_pos
	var y: float = yaw if yaw != null else spawn_yaw
	global_transform = Transform3D(Phys.yaw_basis(y), Vector3(p.x, spawn_pos.y, p.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	inverted = false
	rig.inverted = false

# ---------------------------------------------------------------- contacts

## What this body is touching, as of the last physics step:
## [{ other: Object, local_shape, other_shape, at: Vector3, normal: Vector3 }]
## The normal points from the other body toward this one.
func contacts() -> Array:
	var out := []
	var st := PhysicsServer3D.body_get_direct_state(get_rid())
	if st == null: return out
	for i in st.get_contact_count():
		out.append({
			"other": st.get_contact_collider_object(i),
			"local_shape": st.get_contact_local_shape(i),
			"other_shape": st.get_contact_collider_shape(i),
			"at": st.get_contact_local_position(i),
			"normal": st.get_contact_local_normal(i),
		})
	return out
