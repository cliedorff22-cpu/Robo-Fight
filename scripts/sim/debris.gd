## debris.gd - flying parts.
##
## When a part fails, chunks of it come off and bounce around the arena.
## These are REAL dynamic bodies, not a particle effect: they tumble, hit the
## walls, slide to a stop and get in the way, which is most of why debris
## sells a big hit. Bots do not collide with them (they would be a drag on
## the fight), but the arena does.
##
## Each piece carries its own mesh, so there is nothing to mirror. Pooled and
## capped: a long match with a lot of carnage must not end up simulating four
## hundred rigid bodies.
class_name Debris
extends RefCounted

const MAX_PIECES := 48
const DEFAULT_LIFETIME_S := 14.0

var pieces := []               # [{ body, size, materialName, bornS, lifetimeS, id }]
var _parent: Node3D
var _rng: Rng
var _mats: Mats
var _clock := 0.0
var _serial := 0

func _init(parent: Node3D, random: Rng, materials: Mats = null) -> void:
	_parent = parent
	_rng = random
	_mats = materials

func count() -> int:
	return pieces.size()

func _spawn_one(at: Vector3, velocity: Vector3, size: Vector3, material_name: String, lifetime_s := DEFAULT_LIFETIME_S) -> Dictionary:
	var body := RigidBody3D.new()
	body.position = at
	body.linear_velocity = velocity
	body.angular_velocity = Vector3((_rng.next() - 0.5) * 30.0, (_rng.next() - 0.5) * 30.0, (_rng.next() - 0.5) * 30.0)
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.15
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.2
	body.mass = maxf(0.02, 1200.0 * size.x * size.y * size.z)
	body.collision_layer = Phys.DEBRIS
	# Debris collides with the arena and other debris, but NOT with robots.
	body.collision_mask = Phys.ARENA | Phys.HAZARD | Phys.DEBRIS
	body.physics_material_override = Phys.material(0.6, 0.3)
	Phys.add_shape(body, Phys.box(size))
	if _mats != null:
		var mi := Geo.box(size.x, size.y, size.z).instance(_mats.by_name(material_name))
		body.add_child(mi)
	_parent.add_child(body)
	_serial += 1
	var piece := {"body": body, "size": size, "materialName": material_name, "bornS": _clock, "lifetimeS": lifetime_s,
		"id": "%s-%d" % [material_name, _serial]}
	pieces.append(piece)
	return piece

## Throw a handful of fragments off a failed part.
##   at            world point to spawn at
##   normal        surface normal, biases the spray outward
##   energy_j      how hard the hit was - sets how far they fly
##   material_name a key from the material library, so a steel panel sheds
##                 steel and a UHMW one sheds white
##   scale         fragment size in metres
func burst(at, normal := Vector3.UP, energy_j := 2000.0, material_name := "ar500_steel", n := 5, scale := 0.07) -> Array:
	var made := []
	if at == null: return made
	# Speed from energy, capped so a 33 kJ bar does not fire shrapnel at
	# escape velocity.
	var speed := minf(14.0, 2.0 + sqrt(maxf(0.0, energy_j)) * 0.06)
	for i in n:
		if pieces.size() >= MAX_PIECES:
			# Recycle the oldest rather than refusing to show the hit.
			var oldest: Dictionary = pieces.pop_front()
			oldest.body.queue_free()
		var spread := 0.85
		var v := Vector3(
			normal.x * speed + (_rng.next() - 0.5) * speed * spread,
			absf(normal.y) * speed * 0.5 + _rng.next() * speed * 0.8 + 1.5,
			normal.z * speed + (_rng.next() - 0.5) * speed * spread)
		var s := scale * (0.55 + _rng.next() * 0.9)
		var p: Vector3 = at + Vector3((_rng.next() - 0.5) * 0.05, (_rng.next() - 0.5) * 0.05 + 0.02, (_rng.next() - 0.5) * 0.05)
		made.append(_spawn_one(p, v, Vector3(s, s * (0.3 + _rng.next() * 0.5), s * (0.6 + _rng.next() * 0.7)), material_name))
	return made

## Retire expired pieces. Call once per physics step.
func update(dt: float) -> void:
	_clock += dt
	for i in range(pieces.size() - 1, -1, -1):
		var p: Dictionary = pieces[i]
		if _clock - p.bornS < p.lifetimeS: continue
		# Sink out of sight in its last moments rather than popping.
		p.body.queue_free()
		pieces.remove_at(i)

## Live transforms, for a replay to record:
## [{ id, size, materialName, xf, age, lifetimeS }]
func transforms() -> Array:
	var out := []
	for p in pieces:
		out.append({"id": p.id, "size": p.size, "materialName": p.materialName, "xf": p.body.transform, "age": _clock - p.bornS, "lifetimeS": p.lifetimeS})
	return out

func clear() -> void:
	for p in pieces: p.body.queue_free()
	pieces.clear()
	_clock = 0.0
