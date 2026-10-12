## phys.gd - what the physics files share: the collision layers, and a few
## helpers for building bodies.
##
## Godot's physics (Jolt) is used HERE and in the other scripts/sim files
## only. Logic never sees it; rendering only reads transforms back out.
##
## How surfaces combine, which differs from the browser game's engine: when
## two bodies touch, friction is the LOWER of the two (unless one is marked
## rough, which then wins) and bounce is their SUM. The numbers below are set
## for that.
class_name Phys

const ARENA := 1
const ROBOT := 2
const HAZARD := 4
const DEBRIS := 8

const GRAVITY := 9.81

static func material(friction: float, bounce: float, rough := false) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = friction
	m.bounce = bounce
	m.rough = rough
	return m

static func yaw_basis(yaw: float) -> Basis:
	return Basis(Vector3.UP, yaw)

static func box(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s

static func cylinder(radius: float, height: float) -> CylinderShape3D:
	var s := CylinderShape3D.new()
	s.radius = radius
	s.height = height
	return s

## Add a shape to a body, placed in the body's frame. Returns its owner id.
static func add_shape(body: CollisionObject3D, shape: Shape3D, xf := Transform3D.IDENTITY) -> int:
	var owner := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner, shape)
	body.shape_owner_set_transform(owner, xf)
	return owner

## A fixed box: arena furniture.
static func static_box(parent: Node, xf: Transform3D, size: Vector3, friction: float, bounce: float) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.transform = xf
	b.collision_layer = ARENA
	b.collision_mask = 0
	b.physics_material_override = material(friction, bounce)
	add_shape(b, box(size))
	parent.add_child(b)
	return b

## A body that is moved by hand each step and cannot be stopped: a hazard.
static func kinematic(parent: Node, xf: Transform3D, friction: float, bounce: float, rough := false, layer := HAZARD) -> AnimatableBody3D:
	var b := AnimatableBody3D.new()
	b.sync_to_physics = false
	b.transform = xf
	b.collision_layer = layer
	b.collision_mask = 0
	b.physics_material_override = material(friction, bounce, rough)
	parent.add_child(b)
	return b
