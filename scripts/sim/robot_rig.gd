## robot_rig.gd - what a robot's picture needs to know about its body: the
## sculpted shape, which fitting each piece belongs to, where the wheels hang
## and how they are sitting right now.
##
## The physics body (sim/robot_sim.gd) keeps one up to date as it drives; the
## menus make one from the build alone (RobotRig.at_rest) to show a robot on
## the turntable with no physics at all. render/robot_view.gd draws either.
class_name RobotRig
extends RefCounted

var assembled: Dictionary
var shape: Dictionary
var routes: Dictionary           # piece id -> fitting key
var layout: Dictionary           # WheelModel.wheel_layout()
var wheels: Array                # [{ id, side, axle, anchor }]
var rest_length := 0.012
var preload_frac := WheelModel.SUSPENSION_PRELOAD
var inverted := false            # running on the other face of its tyres
var inverted_anchors: Array = [] # the mounts, mirrored about the axle
## Per wheel: { grounded, load, compression (0..1), spin (radians), slip }.
var telemetry: Array = []

func _init(assembled_robot: Dictionary) -> void:
	assembled = assembled_robot
	shape = Shape.build_shape(assembled)
	routes = Shape.route_fittings(shape, assembled)
	layout = WheelModel.wheel_layout(assembled)
	wheels = layout.wheels
	rest_length = layout.restLength
	var axle_drop := rest_length * (1.0 - preload_frac)
	for w in wheels:
		var a: Vector3 = w.anchor
		inverted_anchors.append(Vector3(a.x, a.y - 2.0 * axle_drop, a.z))
		# Sitting on its springs, as it does at rest.
		telemetry.append({"grounded": true, "load": 0.0, "compression": preload_frac, "spin": 0.0, "slip": 0.0})

## A robot standing still on its wheels (the menus' previews).
static func at_rest(assembled_robot: Dictionary) -> RobotRig:
	return RobotRig.new(assembled_robot)

## Where wheel i is mounted right now - mirrored while running inverted.
func wheel_anchor(i: int) -> Vector3:
	return inverted_anchors[i] if inverted else wheels[i].anchor
