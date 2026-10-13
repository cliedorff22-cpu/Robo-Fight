## dress_audit.gd - every robot's hardware (render/dress.gd), tested: nothing
## bolted on may float, cut into a tyre, stand in the weapon's way, dip under
## the floor, or stand taller than the wheels of a robot that drives both
## ways up.
##   Godot --headless --path . -s tools/dress_audit.gd -- [-v] [robot_id ...]
## Prints what each robot was given; -v prints every robot, not just the ones
## with something to say. Exits with an error if anything is wrong.
extends SceneTree

func _init() -> void:
	var reg := Registry.load_all()
	var only := Array(OS.get_cmdline_user_args())
	var verbose := only.has("-v")
	only.erase("-v")
	var faults := 0
	var undriven := []
	var count := 0
	for def in reg.all_robots():
		if not only.is_empty() and not only.has(def.id): continue
		var asm := Build.assemble_robot(reg, def)
		var rig := RobotRig.at_rest(asm)
		if rig.shape.template == "classic": continue
		count += 1
		var c := Dress.context(asm, rig)
		Dress.trace.clear()
		var plan := Dress.plan(asm, rig)
		var wrong := []
		var names := []
		var drive := false
		for item in plan.items:
			names.append(item.id)
			if str(item.id).begins_with("drive"): drive = true
			var held := false
			var hit := false
			for part in item.parts:
				for q in Dress.samples([part]):
					var why := c.check.blocked(q)
					if why != "" and not hit:
						hit = true
						wrong.append("%s (%s) in the %s at %.3f %.3f %.3f" % [item.id, part.mat, why, q.x, q.y, q.z])
					if c.body.depth(q, true) > -0.004 or c.body.depth(q, false) > -0.004: held = true
			# (What the weapon's own mast carries through its hub touches no body.)
			if not held and not item.get("carried", false): wrong.append("%s floats" % item.id)
		# A powered weapon whose drive could not be fitted anywhere.
		var wv = J.path(rig.shape, ["weapon", "visual"])
		var powered: bool = wv is Dictionary and wv.kind != "wedge" and wv.get("style") != "shell"
		if powered and not drive and str(J.path(def, ["body", "look", "drive"], "")) != "none": undriven.append(def.id)
		if not wrong.is_empty(): faults += 1
		if verbose or not wrong.is_empty() or not only.is_empty():
			print("%-22s %s%s" % [def.id, ", ".join(names), ("   FAULT: " + "; ".join(wrong)) if not wrong.is_empty() else ""])
			if not only.is_empty():
				for t in Dress.trace: print("    ", t)
	print("%d robots dressed, %d with a fault. No weapon drive fitted: %d %s" % [count, faults, undriven.size(), str(undriven)])
	quit(1 if faults > 0 else 0)
