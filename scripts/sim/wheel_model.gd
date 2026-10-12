## wheel_model.gd - the tyre and suspension maths for one wheel, as pure
## arithmetic.
##
## Deliberately separated from robot_sim.gd, which does the engine plumbing
## (raycasts, force application). Everything that decides how the bot FEELS
## lives here.
##
## Frame convention: `fwd` is along the wheel's rolling direction projected
## onto the contact plane, `lat` is perpendicular to it in that plane.
## Positive load pushes along the contact normal.
class_name WheelModel

## Default sideways grip as a fraction of forward grip. Below 1.0 because a
## scrubbing tyre bites less sideways than it does rolling - but not far
## below, or a skid-steer bot pivots like a fidget spinner.
const LATERAL_GRIP_FRACTION := 0.85
## Rolling resistance of an undriven wheel, as a fraction of the load it
## carries. Small: a freewheeling wheel should coast, not act as a brake.
const ROLLING_RESIST_COEFF := 0.04
## Below this speed, rolling resistance fades out linearly instead of
## flipping sign every step and buzzing the wheel.
const ROLL_DEADBAND_MPS := 0.1
## Same idea for the brake.
const BRAKE_DEADBAND_MPS := 0.15
## Fraction of the suspension travel compressed at rest.
const SUSPENSION_PRELOAD := 0.5

# One wheel's answer, reused between calls (no allocation in the step).
class Forces:
	var grounded := false
	var loadN := 0.0
	var compression := 0.0
	var fLong := 0.0
	var fLat := 0.0
	var saturated := false

## One wheel's contribution for one step, written into `out`.
##   ray_distance      anchor-to-ground distance, or < 0 if airborne
##   compression_rate  m/s, POSITIVE WHILE COMPRESSING - the contact velocity
##                     measured ALONG the downward ray
##   v_fwd, v_lat      contact-point speed along `fwd` and `lat`
##   cmd               commanded track speed, -1..1
static func compute(out: Forces, ray_distance: float, wheel_radius: float, rest_length: float, spring_k: float, spring_c: float,
		compression_rate: float, v_fwd: float, v_lat: float, grip: float, lateral_grip_fraction: float, cmd: float, powered: bool,
		top_speed: float, force_per_wheel: float, drive_gain: float, lat_gain: float, brake: bool) -> void:
	out.grounded = false
	out.loadN = 0.0
	out.compression = 0.0
	out.fLong = 0.0
	out.fLat = 0.0
	out.saturated = false
	if ray_distance < 0.0: return
	out.grounded = true

	# ---- 1. suspension. The ray runs from the mount to the ground;
	# subtracting the radius gives where the wheel centre sits, and the
	# shortfall against rest length is the compression.
	var compression := clampf(rest_length - (ray_distance - wheel_radius), 0.0, rest_length)
	out.compression = compression
	# Spring plus damper, never pulling the bot down.
	var load_n := maxf(0.0, spring_k * compression + spring_c * compression_rate)
	if load_n <= 0.0: return
	out.loadN = load_n

	# ---- 2. longitudinal. A proportional chase of the target track speed:
	# hard pull far from it, tailing off as it gets there, and engine braking
	# at zero throttle (which is how these bots actually stop).
	var f_long: float
	if powered:
		f_long = clampf((cmd * top_speed - v_fwd) * drive_gain, -force_per_wheel, force_per_wheel)
	else:
		# Rolling resistance scales with the load, not the speed.
		f_long = -clampf(v_fwd / ROLL_DEADBAND_MPS, -1.0, 1.0) * ROLLING_RESIST_COEFF * load_n
	# Braking locks the wheels, so it is limited by GRIP, not by motor torque.
	if brake: f_long = -clampf(v_fwd / BRAKE_DEADBAND_MPS, -1.0, 1.0) * grip * load_n

	# ---- 3. lateral: resist sideways scrub, capped at the sideways grip limit.
	var mu_lat := grip * lateral_grip_fraction
	var f_lat := clampf(-v_lat * lat_gain, -mu_lat * load_n, mu_lat * load_n)

	# ---- 4. friction circle. Grip is a budget shared between driving and
	# cornering, so a bot at full throttle cannot also turn at full bite.
	var cap := grip * load_n
	f_long = clampf(f_long, -cap, cap)
	var mag := sqrt(f_long * f_long + f_lat * f_lat)
	if mag > cap and mag > 1e-9:
		# Scale BOTH components by the same factor, so the tyre keeps
		# pointing where it was pointing and simply delivers less of it.
		var s := cap / mag
		f_long *= s
		f_lat *= s
		out.saturated = true
	out.fLong = f_long
	out.fLat = f_lat

## Spring rate and damping sized so the suspension's preload exactly carries
## the bot's static weight: ride height is derived, never guessed.
## Returns { perWheelN, springK, springC }.
static func suspension_rates(mass_kg: float, wheel_count: int, rest_length: float, preload_frac: float, damping_ratio: float, gravity := 9.81) -> Dictionary:
	var per_wheel_n := (mass_kg * gravity) / wheel_count
	var spring_k := per_wheel_n / (rest_length * preload_frac)
	var spring_c := 2.0 * sqrt(spring_k * (mass_kg / wheel_count)) * damping_ratio
	return {"perWheelN": per_wheel_n, "springK": spring_k, "springC": spring_c}

## Taper steering authority as the bot approaches its yaw-rate limit.
## Steering INTO the current rotation loses authority near the limit, while
## counter-steering keeps full authority: the driver can always stop a spin,
## they just cannot wind one up indefinitely.
static func taper_steer_for_yaw_rate(steer: float, yaw_rate: float, max_yaw_rate: float) -> float:
	if not (max_yaw_rate > 0.0): return steer
	if not (steer * yaw_rate > 0.0): return steer
	var ratio := absf(yaw_rate) / max_yaw_rate
	# Quadratic, so it stays full-authority until the limit is close.
	return steer * clampf(1.0 - ratio * ratio, 0.0, 1.0)

## Skid steer: one throttle and one steer input become two track commands
## (x = left, y = right).
static func skid_steer_mix(throttle: float, steer: float) -> Vector2:
	var t := clampf(throttle, -1.0, 1.0)
	var s := clampf(steer, -1.0, 1.0)
	return Vector2(clampf(t + s, -1.0, 1.0), clampf(t - s, -1.0, 1.0))

## Where the four wheel mounts sit on the body, and the body's height above
## the floor at rest - pure arithmetic from the build, so the physics, the
## renderer and the menu's turntable preview all place wheels identically.
## Returns { anchorY, restLength, clearance, spawnY, wheels: [{ id, side, axle, anchor: Vector3 }] }
static func wheel_layout(assembled: Dictionary) -> Dictionary:
	var dims: Dictionary = assembled.dims
	var stats: Dictionary = assembled.stats
	var rest_length: float = stats.suspensionTravelM
	var clearance: float = maxf(0.008, stats.groundClearanceM)
	var anchor_y: float = -dims.heightM / 2.0 - clearance + rest_length * SUSPENSION_PRELOAD + stats.wheelRadiusM
	var x: float = stats.wheelbaseHalfM   # axles inboard of the ends
	var z: float = Shape.wheel_track(assembled)   # just outboard of the side armour
	return {
		"anchorY": anchor_y, "restLength": rest_length, "clearance": clearance,
		# The body centre's height when it sits on its springs.
		"spawnY": dims.heightM / 2.0 + clearance,
		"wheels": [
			{"id": "FL", "side": "left", "axle": "front", "anchor": Vector3(x, anchor_y, z)},
			{"id": "FR", "side": "right", "axle": "front", "anchor": Vector3(x, anchor_y, -z)},
			{"id": "RL", "side": "left", "axle": "rear", "anchor": Vector3(-x, anchor_y, z)},
			{"id": "RR", "side": "right", "axle": "rear", "anchor": Vector3(-x, anchor_y, -z)},
		],
	}
