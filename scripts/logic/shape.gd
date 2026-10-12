## shape.gd - what a robot LOOKS like, as convex pieces both physics and the
## renderer build from.
##
## Every robot in the field is sculpted to what it does: a wedge is a wedge, a
## shell spinner is a dome, a hammer bot carries its arm over the top. A robot
## file says so with a `body` block:
##
##   "body": { "template": "wedge", "params": { "slope": 0.7 }, "mount": "front",
##             "extras": [{ "type": "forks", "count": 2 }] }
##
## Templates: box, wedge, slab, round, dart, hex, bullet, tent, cab, twin and
## custom (the robot file draws its own lofts). That is GEOMETRY, not stats:
## the template is scaled into the chassis part's envelope.
##
## Output, all in body-local metres (X forward, Y up, Z left, origin at the
## chassis box centre):
##   pieces   [{ id, slot, role, points: [Vector3] }] - convex point sets.
##            `slot` says which fitting a hit on it damages (route_fittings);
##            `role` how it is painted.
##   weapon   { class, mount, colliders, visual } - the weapon's swept volume
##            for physics and a description for the renderer.
##   invertible  whether the wheels stand proud of the body top AND bottom.
##
## Pure logic. sim/robot_sim.gd turns pieces into colliders and
## render/robot_view.gd into meshes, from the SAME points.
class_name Shape

const BODY_TEMPLATES := [
	"classic", "box", "wedge", "slab", "round",
	"dart", "hex", "bullet", "tent", "cab", "twin", "custom",
]
const EXTRA_TYPES := [
	"forks", "wheelGuards", "uprights", "mast", "fin", "spikes", "tail", "stack",
	"eyes", "dome", "plow", "legs", "hump", "cage", "wings",
	"pod", "horns", "ears", "spines", "bumper",
]

static func _in(v) -> float: return float(v) * U.IN_TO_M
static func _n(d, k, def: float) -> float:
	var v = d.get(k) if d is Dictionary else null
	return def if v == null else float(v)
static func _c(v: float, lo: float, hi: float) -> float: return maxf(lo, minf(hi, v))
static func _wclass(assembled: Dictionary):
	var w = assembled.parts.get("weapon")
	return w.spec["class"] if w != null else null

## Returns { template, pieces, weapon, invertible, wheelTopY, groundY, bounds, frontX }
static func build_shape(assembled: Dictionary) -> Dictionary:
	var body: Dictionary = J.g(assembled.get("def"), "body", {})
	var template: String = J.g(body, "template", "classic")
	var p: Dictionary = J.g(body, "params", {})
	var L: float = assembled.dims.lengthM
	var H: float = assembled.dims.heightM
	var W: float = assembled.dims.widthM
	var mount = body.get("mount")
	var ctx := {
		"L": L, "H": H, "W": W, "assembled": assembled, "p": p, "body": body,
		"armour": armour_thickness(assembled),
		"mount": mount if J.truthy(mount) else default_mount(_wclass(assembled)),
	}

	var core: Dictionary
	if template == "classic": core = _classic_core(ctx)
	elif template == "round": core = _round_core(ctx)
	elif BODY_TEMPLATES.has(template): core = _loft_core(template, ctx)
	else:
		push_error("%s: unknown body template \"%s\"" % [assembled.id, template])
		core = _classic_core(ctx)

	# The weapon first: the extras on the nose need to know what is there.
	var weapon = _weapon_geometry(assembled, ctx, core, mount if J.truthy(mount) else null)
	ctx.weapon = weapon
	var pieces: Array = core.pieces.duplicate()
	for ex in body.get("extras", []):
		pieces.append_array(_extra_pieces(ex, ctx, core))
	if weapon != null and weapon.has("pieces"): pieces.append_array(weapon.pieces)

	# Invertible: the tyres stand proud of everything, top and bottom. A body
	# or weapon above the tyre tops lands on that instead, and it is stuck.
	var st: Dictionary = assembled.stats
	var ground_y: float = -H / 2.0 - st.groundClearanceM
	var wheel_top_y: float = ground_y + 2.0 * st.wheelRadiusM
	var all := []
	for x in pieces: all.append_array(x.points)
	if weapon != null:
		for c in weapon.colliders: all.append_array(_collider_extremes(c))
	var b := Hull.bounds(all)
	var invertible: bool = b.max.y < wheel_top_y - 0.006

	return {"template": template, "pieces": pieces, "weapon": weapon, "invertible": invertible,
		"wheelTopY": wheel_top_y, "groundY": ground_y, "bounds": b, "frontX": core.frontX}

## Which fitting a hit on each piece damages. Armour slots map to the fitted
## panels in order; a slot with no panel fitted is bare chassis.
## Returns { pieceId: fitting key }.
static func route_fittings(shape: Dictionary, assembled: Dictionary) -> Dictionary:
	var by_slot := {}
	for f in assembled.fittings:
		if f.part.category != "armor": continue
		var s: String = f.part.spec.slot
		if not by_slot.has(s): by_slot[s] = []
		by_slot[s].append(f.key)
	var static_weapon: bool = _wclass(assembled) == "static"
	var out := {}
	for piece in shape.pieces:
		var key = "chassis"
		match piece.slot:
			"front": key = _slot_key(by_slot, "front", 0)
			"top": key = _slot_key(by_slot, "top", 0)
			"rear": key = _slot_key(by_slot, "rear", 0)
			"sideL": key = _slot_key(by_slot, "side", 0)
			"sideR":
				key = _slot_key(by_slot, "side", 1)
				if key == null: key = _slot_key(by_slot, "side", 0)
			"weapon": key = "weapon"
			# Forks and a wedge nose are the wedge's job on a wedge bot, and
			# the front armour's on anything else.
			"wedge": key = "weapon" if static_weapon else _slot_key(by_slot, "front", 0)
			"guard": key = _slot_key(by_slot, "side", 0)
			_: key = "chassis"
		out[piece.id] = key if key != null else "chassis"
	return out

static func _slot_key(by_slot: Dictionary, slot: String, i: int):
	var a: Array = by_slot.get(slot, [])
	return a[i] if i < a.size() else null

# ---------------------------------------------------------------- cores

static func _piece(id: String, slot: String, role: String, points: Array) -> Dictionary:
	return {"id": id, "slot": slot, "role": role, "points": points}

## The original look: a box with a thin panel on each armoured face.
static func _classic_core(ctx: Dictionary) -> Dictionary:
	var L: float = ctx.L
	var H: float = ctx.H
	var W: float = ctx.W
	var pieces := [_piece("core", "core", "body", box_pts(0, 0, 0, L / 2, H / 2, W / 2))]
	var panel_t := 0.012
	var side := 0
	for f in ctx.assembled.fittings:
		if f.part.category != "armor": continue
		var slot: String = f.part.spec.slot
		var id := "armor:%s" % f.key
		if slot == "front":
			pieces.append(_piece(id, "front", "armor", box_pts(L / 2 + panel_t / 2, 0, 0, panel_t / 2, H / 2 * 0.9, W / 2 * 0.95)))
		elif slot == "side":
			var s := 1.0 if side == 0 else -1.0
			side += 1
			pieces.append(_piece(id, "sideL" if s > 0 else "sideR", "armor", box_pts(0, 0, s * (W / 2 + panel_t / 2), L / 2 * 0.9, H / 2 * 0.9, panel_t / 2)))
		elif slot == "top":
			pieces.append(_piece(id, "top", "armor", box_pts(0, H / 2 + panel_t / 2, 0, L / 2 * 0.9, panel_t / 2, W / 2 * 0.95)))
		elif slot == "rear":
			pieces.append(_piece(id, "rear", "armor", box_pts(-L / 2 - panel_t / 2, 0, 0, panel_t / 2, H / 2 * 0.9, W / 2 * 0.95)))
	return {"pieces": pieces, "frontX": L / 2, "topY": H / 2, "frontBottomY": -H / 2, "sections": null, "classic": true,
		"solids": [[sec(-L / 2, -H / 2, H / 2, W / 2), sec(L / 2, -H / 2, H / 2, W / 2)]]}

## Lofted bodies: one or more LOFTS, each a run of cross-sections from tail to
## nose. A section is a trapezoid { x, yb, yt, hw, hwt, zc, zt }. Each loft is
## one convex piece with its own armour skins. The first loft is the main
## body ("core"): the nose the weapon mounts to.
static func _loft_core(template: String, ctx: Dictionary) -> Dictionary:
	var L: float = ctx.L
	var H: float = ctx.H
	var W: float = ctx.W
	var p: Dictionary = ctx.p
	var hw := W / 2
	var hwt := hw * _c(_n(p, "topWidth", 1.0), 0.4, 1.0)
	# A weapon bay shortens the nose across the whole width - only a twin
	# body wants that. Anywhere else a disc or drum sits in a SLOT cut into a
	# full-length nose, and the bay just says how deep it is tucked.
	var wcls = _wclass(ctx.assembled)
	var slotted: bool = (wcls == "spinner_v" or wcls == "drum") and ctx.mount != "high"
	var bay_in := _c(_n(p, "weaponBay", 0.3 if template == "twin" else 0.0), 0.0, 0.45) * L
	var bay := 0.0 if (slotted and template != "twin") else bay_in
	var xf := L / 2 - bay
	var xr := -L / 2
	var length := xf - xr
	var yb := -H / 2
	var c := ctx.duplicate()
	c.hw = hw; c.hwt = hwt; c.bay = bay; c.xf = xf; c.xr = xr; c.len = length; c.yb = yb
	var lofts := _lofts(template, c)

	# A horizontal rotor sweeps a disc across the front. Where it passes, the
	# body has to step down under it (a chin) or up over it (an undercutter).
	# A notch is not convex, so a loft the rotor crosses becomes two pieces.
	var cut = _rotor_cut(ctx, xf, xr, length)
	# A disc or drum runs in a slot down the middle of the nose instead, so
	# the loft ahead of the slot's back wall becomes two cheeks either side.
	var vrot = null
	if slotted and cut == null:
		vrot = _vertical_rotor(ctx, template, lofts, xf, xr, length, yb, 0.0 if template == "twin" else bay_in)
	var pieces := []
	# Every body piece as the run of sections it was made from: what the body
	# really is once the rotor's cut or slot is out of it (surface_at).
	var solids := []
	for k in lofts.size():
		var loft: Dictionary = lofts[k]
		var secs: Array = loft.sections
		var loft_slot: String = J.g(loft, "slot", "core")
		if vrot != null and _crosses(secs, vrot.x0) and _overlaps_slot(secs.filter(func(s): return s.x > vrot.x0), vrot.zHalf):
			var sp := _split_at(secs, {"x0": vrot.x0})
			var rear: Array = sp[0]
			var front: Array = sp[1]
			solids.append(rear)
			pieces.append(_piece("core" if k == 0 else "body:%d" % k, loft_slot, "body", _sections_pts(rear)))
			pieces.append_array(_loft_plates(rear, ctx, "" if k == 0 else ":b%d" % k))
			for sd in [["L", 1.0], ["R", -1.0]]:
				var cheek := _cheek_sections(front, vrot.zHalf, sd[1], vrot.minCheek)
				solids.append(cheek)
				pieces.append(_piece("cheek:%s" % sd[0] if k == 0 else "body:%d:cheek%s" % [k, sd[0]], "front", "body", _sections_pts(cheek)))
				pieces.append_array(_loft_plates(cheek, ctx, ":%dcheek%s" % [k, sd[0]]))
			continue
		var segments: Array = _split_at(secs, cut) if (cut != null and _crosses(secs, cut.x0)) else [secs]
		for j in segments.size():
			var seg: Array = segments[j]
			solids.append(seg)
			var id: String
			if k == 0: id = "core" if j == 0 else "chin"
			else: id = "body:%d%s" % [k, ":chin" if j > 0 else ""]
			pieces.append(_piece(id, loft_slot if j == 0 else "front", "body", _sections_pts(seg)))
			var suffix: String
			if k == 0: suffix = ":chin" if j > 0 else ""
			else: suffix = ":b%d%s" % [k, "chin" if j > 0 else ""]
			pieces.append_array(_loft_plates(seg, ctx, suffix))

	var main: Array = lofts[0].sections
	var nose: Dictionary = main[main.size() - 1]
	var top_y := -INF
	for l in lofts:
		for s in l.sections: top_y = maxf(top_y, s.yt)
	return {
		"pieces": pieces, "sections": main, "lofts": lofts, "vrot": vrot,
		"solids": solids, "cutX": cut.x0 if cut != null else null,
		"frontX": nose.x, "bayX": bay,
		"topY": top_y,
		"frontBottomY": nose.yb,
		"noseTopY": nose.yt,
	}

static func _crosses(secs: Array, x0: float) -> bool:
	return secs[0].x < x0 - 0.02 and secs[secs.size() - 1].x > x0 + 0.02

static func _sections_pts(secs: Array) -> Array:
	var out := []
	for s in secs: out.append_array(_section_pts(s))
	return out

## The top surface of a core at (x, z): the highest loft that covers that
## point. Cores with no lofts (classic, round) answer their flat top.
static func top_at(core: Dictionary, x: float, z: float = 0.0) -> float:
	var lofts = core.get("lofts")
	if lofts == null: return core.topY
	var best := -INF
	for l in lofts:
		var s: Array = l.sections
		if x < s[0].x - 1e-6 or x > s[s.size() - 1].x + 1e-6: continue
		var at := _interp_section(s, x)
		if absf(z - at.zt) <= at.hwt + 1e-6: best = maxf(best, at.yt)
	if best > -INF: return best
	var main: Array = core.sections
	return _interp_section(main, _c(x, main[0].x, main[main.size() - 1].x)).yt

static func _has_top_at(core: Dictionary) -> bool:
	return core.get("lofts") != null

## Section helper: x, bottom, top, half-widths, centre.
static func sec(x: float, yb: float, yt: float, hw: float, hwt = null, zc: float = 0.0, zt = null) -> Dictionary:
	return {"x": x, "yb": yb, "yt": yt, "hw": hw, "hwt": hw if hwt == null else float(hwt), "zc": zc, "zt": zc if zt == null else float(zt)}

## Every loft template: ctx -> [{ sections, slot? }]. Heights in metres.
static func _lofts(template: String, c: Dictionary) -> Array:
	var H: float = c.H
	var L: float = c.L
	var W: float = c.W
	var p: Dictionary = c.p
	var hw: float = c.hw
	var hwt: float = c.hwt
	var xf: float = c.xf
	var xr: float = c.xr
	var length: float = c.len
	var yb: float = c.yb
	match template:
		"box":
			var cf := _c(_n(p, "chamferFront", 0.15), 0.0, 0.7)   # fraction of height cut off the front-top edge
			var cr := _c(_n(p, "chamferRear", 0.1), 0.0, 0.7)
			var hs := _c(_n(p, "height", 1.0), 0.5, 1.0)
			var yt := yb + H * hs
			var run := minf(length * 0.3, H * 0.9)
			return [{"sections": [
				sec(xr, yb, yt - H * hs * cr, hw, hwt),
				sec(xr + run * cr, yb, yt, hw, hwt),
				sec(xf - run * cf, yb, yt, hw, hwt),
				sec(xf, yb, yt - H * hs * cf, hw, hwt),
			]}]
		"wedge":
			var slope := _c(_n(p, "slope", 0.6), 0.15, 1.0)      # fraction of length that slopes
			var rh := _c(_n(p, "rearHeight", 1.0), 0.4, 1.0)
			var nh := _c(_n(p, "noseHeight", 0.08), 0.02, 0.6)
			var y_top := yb + H * rh
			var x_break := xf - length * slope
			var s := [sec(xr, yb, y_top, hw, hwt)]
			if slope < 0.98: s.append(sec(x_break, yb, y_top, hw, hwt))
			s.append(sec(xf, yb, yb + H * nh, hw, hw))
			return [{"sections": s}]
		"slab":
			# Low, flat top and bottom, chamfered ends both ways up - the
			# shape of an invertible bot.
			var ch := _c(_n(p, "chamfer", 0.3), 0.0, 0.45) * H
			var hs := _c(_n(p, "height", 1.0), 0.5, 1.0)
			var yt := yb + H * hs
			var run := minf(length * 0.25, H)
			return [{"sections": [
				sec(xr, yb + ch * 0.5, yt - ch * 0.5, hw, hwt),
				sec(xr + run * 0.5, yb, yt, hw, hwt),
				sec(xf - run, yb, yt, hw, hwt),
				sec(xf, yb + ch, yt - ch, hw, hwt),
			]}]
		"dart":
			# An arrowhead: full width at the back, narrowing in plan as it
			# drops to a pointed nose.
			var slope := _c(_n(p, "slope", 0.55), 0.2, 0.95)
			var nw := _c(_n(p, "noseWidth", 0.35), 0.12, 0.9)
			var rh := _c(_n(p, "rearHeight", 1.0), 0.4, 1.0)
			var nh := _c(_n(p, "noseHeight", 0.12), 0.03, 0.6)
			var x_break := xf - length * slope
			return [{"sections": [
				sec(xr, yb, yb + H * rh, hw * 0.92, hwt * 0.92),
				sec(xr + length * 0.08, yb, yb + H * rh, hw, hwt),
				sec(x_break, yb, yb + H * rh, hw, hwt),
				sec(xf, yb, yb + H * nh, hw * nw, hw * nw),
			]}]
		"hex":
			# Corners clipped off in plan, so from above it is a long hexagon.
			var cn := _c(_n(p, "corner", 0.18), 0.05, 0.4) * length
			var ew := _c(_n(p, "endWidth", 0.6), 0.25, 0.95)
			var cf := _c(_n(p, "chamferFront", 0.2), 0.0, 0.7)
			var hs := _c(_n(p, "height", 1.0), 0.5, 1.0)
			var yt := yb + H * hs
			return [{"sections": [
				sec(xr, yb, yt, hw * ew, minf(hwt, hw * ew)),
				sec(xr + cn, yb, yt, hw, hwt),
				sec(xf - cn, yb, yt, hw, hwt),
				sec(xf, yb, yt - H * hs * cf, hw * ew, minf(hwt, hw * ew)),
			]}]
		"bullet":
			return _loft_bullet(c)
		"tent":
			# Steeply raked sides up to a narrow ridge: an A-frame in cross-section.
			var ridge := _c(_n(p, "ridge", 0.18), 0.05, 0.5) * hw
			var cf := _c(_n(p, "chamferFront", 0.35), 0.0, 0.8)
			var cr := _c(_n(p, "chamferRear", 0.15), 0.0, 0.8)
			var hs := _c(_n(p, "height", 1.0), 0.5, 1.0)
			var yt := yb + H * hs
			var run := minf(length * 0.35, H * 1.2)
			return [{"sections": [
				sec(xr, yb, yt - H * hs * cr, hw, ridge),
				sec(xr + run * cr, yb, yt, hw, ridge),
				sec(xf - run * cf, yb, yt, hw, ridge),
				sec(xf, yb, yt - H * hs * cf, hw, ridge),
			]}]
		"cab":
			# A low deck the full length with a raised cab on the back.
			var deck := _c(_n(p, "deck", 0.5), 0.25, 0.85)
			var cl := _c(_n(p, "cabLength", 0.45), 0.2, 0.8) * length
			var cw := _c(_n(p, "cabWidth", 0.85), 0.4, 1.0)
			var rake := _c(_n(p, "rake", 0.35), 0.0, 0.8)
			var cf := _c(_n(p, "chamferFront", 0.3), 0.0, 0.8)
			var yd := yb + H * deck
			var xc := _c(xr + cl + _n(p, "cabX", 0.0) * length, xr + cl, xf - 0.02)
			var x0 := xc - cl
			return [
				{"sections": [
					sec(xr, yb, yd, hw, hwt),
					sec(xf - H * deck * cf, yb, yd, hw, hwt),
					sec(xf, yb, yd - H * deck * cf, hw, hwt),
				]},
				{"sections": [
					sec(x0, yb, yb + H, hw * cw, hw * cw * 0.9),
					sec(xc - cl * rake, yb, yb + H, hw * cw, hw * cw * 0.9),
					sec(xc, yb, yd + (H - (yd - yb)) * 0.2, hw * cw, hw * cw * 0.9),
				], "slot": "top"},
			]
		"twin":
			# Two armoured pods down the sides, joined by a low bridge that
			# stops short of the nose: the weapon runs in the bay between them.
			var pw := _c(_n(p, "pod", 0.27), 0.12, 0.4) * W
			var bridge := _c(_n(p, "bridge", 0.55), 0.25, 1.0)
			var pc := _c(_n(p, "podChamfer", 0.45), 0.0, 0.9)
			var pl := _c(_n(p, "podLength", 1.0), 0.5, 1.2)
			var inner := hw - pw
			var zc := hw - pw / 2
			var px := L / 2 * pl
			var out := [{"sections": [
				sec(xr, yb, yb + H * bridge, inner + 0.01, inner + 0.01),
				sec(xf - H * bridge * 0.3, yb, yb + H * bridge, inner + 0.01, inner + 0.01),
				sec(xf, yb, yb + H * bridge * 0.6, inner + 0.01, inner + 0.01),
			]}]
			for s in [1.0, -1.0]:
				out.append({"sections": [
					sec(xr, yb, yb + H * 0.9, pw / 2, pw * 0.42, s * zc),
					sec(xr + 0.05, yb, yb + H, pw / 2, pw * 0.42, s * zc),
					sec(px - H * pc, yb, yb + H, pw / 2, pw * 0.42, s * zc),
					sec(px, yb, yb + H * (1 - pc) + 0.01, pw / 2, pw * 0.42, s * zc),
				], "slot": "sideL" if s > 0 else "sideR"})
			return out
		"custom":
			# The robot file draws its own body: lofts in fractions of the
			# chassis envelope. The first loft is the main body.
			#   "custom": { "lofts": [ { "sections": [[x, yb, yt, hw, hwt?, zc?, zt?], ...] } ] }
			var spec = J.path(c.body, ["custom", "lofts"])
			if spec == null or spec.size() == 0:
				var c2 := c.duplicate()
				c2.p = {}
				c2.len = xf - xr
				return _lofts("box", c2)
			var out := []
			for lf in spec:
				var sections := []
				for r in lf.get("sections", []):
					var h: float = r[3]
					var ht: float = r[4] if r.size() > 4 and r[4] != null else h
					var z: float = r[5] if r.size() > 5 and r[5] != null else 0.0
					var zt: float = r[6] if r.size() > 6 and r[6] != null else z
					sections.append(sec(_c(r[0], -0.6, 0.6) * L, _c(r[1], -0.5, 0.5) * H, _c(r[2], -0.5, 0.9) * H,
						maxf(0.003, h * W), maxf(0.003, ht * W), z * W, zt * W))
				var o := {"sections": sections}
				if lf.get("slot") != null: o.slot = lf.slot
				out.append(o)
			return out
	return []

## A rounded nose in plan view (and optionally a rounded tail): a bullet.
static func _loft_bullet(c: Dictionary) -> Array:
	var H: float = c.H
	var p: Dictionary = c.p
	var hw: float = c.hw
	var hwt: float = c.hwt
	var xf: float = c.xf
	var xr: float = c.xr
	var length: float = c.len
	var yb: float = c.yb
	var rn := _c(_n(p, "roundness", 0.35), 0.1, 0.6) * length
	var rt := _c(_n(p, "tailRound", 0.0), 0.0, 0.5) * length
	var hs := _c(_n(p, "height", 1.0), 0.5, 1.0)
	var yt := yb + H * hs
	var drop := _c(_n(p, "noseDrop", 0.3), 0.0, 0.8)
	var out := []
	var arc := func(x0: float, r: float, dir: float):
		# dir +1: nose (x grows to x0 + r), -1: tail
		var steps := 5
		for i in range(steps + 1):
			var th := (float(i) / steps) * PI * 0.44
			var k := cos(th)
			out.append(sec(x0 + dir * r * sin(th), yb, yt - H * hs * drop * ((1.0 - k) if dir > 0 else 0.0) * 1.6,
				hw * maxf(0.3, k), hwt * maxf(0.3, k)))
	if rt > 0.01:
		arc.call(xr + rt, rt, -1.0)
		out.reverse()
	else:
		out.append(sec(xr, yb, yt, hw, hwt))
	arc.call(xf - rn, rn, 1.0)
	# The arc's last section sits short of xf; finish exactly at the nose.
	var last: Dictionary = out[out.size() - 1].duplicate()
	last.x = xf
	out[out.size() - 1] = last
	var sorted := J.sorted(out, func(a, b): return a.x - b.x)
	var kept := []
	for i in sorted.size():
		if i == 0 or sorted[i].x - sorted[i - 1].x > 1e-4: kept.append(sorted[i])
	return [{"sections": kept}]

## Where a front or low horizontal rotor needs the body out of its way:
## { x0, maxTop } (body under the bar) or { x0, minBottom } (body over it).
static func _rotor_cut(ctx: Dictionary, xf: float, xr: float, length: float):
	var wp = ctx.assembled.parts.get("weapon")
	var mount = ctx.mount
	if wp == null: return null
	var w: Dictionary = wp.spec
	if w["class"] != "spinner_h" or not (mount == "front" or mount == "low"): return null
	var r := _in(_nz(w.get("radiusIn"), 6.0))
	var size: Array = J.g(w, "sizeIn", [0, 2, 0])
	var half := maxf(0.01, _in(size[1]) / 2)
	var yb: float = -ctx.H / 2
	var cx := xf + r * (0.3 if mount == "low" else 0.35)
	var yc: float
	if mount == "low": yc = yb + half + _in(1)
	else: yc = yb + ctx.H * float(ctx.p.weaponY) if ctx.p.get("weaponY") != null else 0.0
	var x0 := maxf(xr + length * 0.4, cx - r - 0.01)
	if x0 >= xf - 0.02: return null
	if mount == "low": return {"x0": x0, "minBottom": yc + half + 0.008}
	return {"x0": x0, "maxTop": maxf(yb + 0.025, yc - half - 0.008)}

# `x || default`: zero and null both take the default.
static func _nz(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if f == 0.0 else f

## Split a run of sections at cut.x0, clipping the front run to clear the rotor.
static func _split_at(sections: Array, cut: Dictionary) -> Array:
	var x0: float = cut.x0
	var at := _interp_section(sections, x0)
	var rear := sections.filter(func(s): return s.x < x0 - 1e-6)
	rear.append(at)
	var front_src := [at.duplicate()]
	front_src.append_array(sections.filter(func(s): return s.x > x0 + 1e-6))
	var front := []
	for s in front_src:
		var c: Dictionary = s.duplicate()
		if cut.get("maxTop") != null: c.yt = maxf(c.yb + 0.02, minf(c.yt, cut.maxTop))
		if cut.get("minBottom") != null: c.yb = minf(c.yt - 0.02, maxf(c.yb, cut.minBottom))
		front.append(c)
	return [rear, front]

## Bearing-block sizes for a rotor of radius r: plate thickness, clearances, boss.
static func _mount_gauge(r: float) -> Dictionary:
	return {"st": _in(1.25), "gap": _in(0.4), "clear": _in(0.6), "bossR": maxf(_in(1.6), r * 0.16)}

## Where a disc or drum sits, and the slot cut for it. The rotor runs in a
## slot in the nose or between pods, its axle carried by a support plate on
## each side. Returns the rotor centre, the slot (x0 = its back wall, zHalf =
## its half width) and where the supports go.
static func _vertical_rotor(ctx: Dictionary, template: String, lofts: Array, xf: float, xr: float, length: float, yb: float, tuck: float) -> Dictionary:
	var w: Dictionary = ctx.assembled.parts.weapon.spec
	var r := _in(_nz(w.get("radiusIn"), 6.0))
	var g := _mount_gauge(r)
	var size: Array = J.g(w, "sizeIn", [12, 4, 12])
	var half_w := _c(_in(size[2]) / 2, 0.01, ctx.W / 2 - g.st - g.gap - _in(0.5))
	var x: float
	var z0: float
	var z1 = null
	var pods := []
	if template == "twin":
		pods = lofts.filter(func(l): return l.get("slot") == "sideL" or l.get("slot") == "sideR")
	if pods.size() > 0:
		# Between the pods: the axle runs through their noses.
		var pod_front := -INF
		var inner := INF
		for l in pods:
			for s in l.sections:
				pod_front = maxf(pod_front, s.x)
				inner = minf(inner, absf(s.zc) - s.hw)
		half_w = maxf(0.01, minf(half_w, inner - g.gap - 0.003))
		x = pod_front - g.bossR * 1.3
		# A solid bearing block from the disc's face out into the pod.
		z0 = half_w + g.gap
		z1 = maxf(z0 + g.st, inner + g.st * 0.4)
	else:
		# In a slot in the nose, the axle a little ahead of it on the supports.
		var out_def := 0.3
		if w["class"] == "drum": out_def = 0.4 if w.get("style") == "eggbeater" else 0.45
		var out_f := _n(ctx.p, "axleOut", out_def)
		x = xf + r * out_f - tuck * 0.8
		z0 = half_w + g.gap
	# Keep a real body behind the slot: a big disc goes forward, not deeper.
	var x0: float = x - r - g.clear
	if x0 < xr + length * 0.35:
		x0 = xr + length * 0.35
		x = x0 + r + g.clear
	return {"center": Vector3(x, yb + r, 0), "r": r, "halfW": half_w, "zHalf": half_w + g.gap, "x0": x0, "minCheek": g.st,
		"bossR": g.bossR, "support": {"z0": z0, "z1": z1 if z1 != null else z0 + g.st}}

## A disc or drum on a round body: the rotor stands just off the wall on two
## supports that run back into it.
static func _round_rotor(ctx: Dictionary, core: Dictionary, w: Dictionary, r: float) -> Dictionary:
	var g := _mount_gauge(r)
	var R: float = core.radius
	var size: Array = J.g(w, "sizeIn", [12, 4, 12])
	var half_w := _c(_in(size[2]) / 2, 0.01, R * 0.55)
	var z0: float = half_w + g.gap
	var z1: float = z0 + g.st
	var yb: float = -ctx.H / 2
	return {"center": Vector3(R + r + g.clear * 0.5, yb + r, 0), "r": r, "halfW": half_w, "zHalf": z0,
		"xa": sqrt(maxf(0.0, R * R - z1 * z1)) - 0.02, "bossR": g.bossR, "support": {"z0": z0, "z1": z1}}

## Does any of these sections reach into the slot |z| < zHalf?
static func _overlaps_slot(sections: Array, z_half: float) -> bool:
	for s in sections:
		if (s.zc - s.hw < z_half and s.zc + s.hw > -z_half) or (s.zt - s.hwt < z_half and s.zt + s.hwt > -z_half):
			return true
	return false

## One side's cheek of a slotted loft: each section clipped to |z| >= zHalf on side s.
static func _cheek_sections(sections: Array, z_half: float, s: float, min_w: float) -> Array:
	var clip := func(c: float, h: float) -> Array:
		# In u = s*z, the section spans [u0, u1]; keep what is outside the slot.
		var u0 := maxf(s * c - h, z_half)
		var u1 := s * c + h
		if u1 - u0 < min_w:
			u0 = z_half
			u1 = maxf(u1, z_half + min_w)
		return [s * (u0 + u1) / 2, (u1 - u0) / 2]
	var out := []
	for sc in sections:
		var b: Array = clip.call(sc.zc, sc.hw)
		var t: Array = clip.call(sc.zt, sc.hwt)
		var o: Dictionary = sc.duplicate()
		o.hw = b[1]; o.zc = b[0]; o.hwt = t[1]; o.zt = t[0]
		out.append(o)
	return out

static func _interp_section(sections: Array, x: float) -> Dictionary:
	for i in range(sections.size() - 1):
		var a: Dictionary = sections[i]
		var b: Dictionary = sections[i + 1]
		if x >= a.x and x <= b.x:
			var den: float = b.x - a.x
			if den == 0.0: den = 1.0
			var t: float = (x - a.x) / den
			return {"x": x,
				"yb": a.yb + (b.yb - a.yb) * t, "yt": a.yt + (b.yt - a.yt) * t,
				"hw": a.hw + (b.hw - a.hw) * t, "hwt": a.hwt + (b.hwt - a.hwt) * t,
				"zc": a.zc + (b.zc - a.zc) * t, "zt": a.zt + (b.zt - a.zt) * t}
	var last: Dictionary = sections[sections.size() - 1].duplicate()
	last.x = x
	return last

## Armour skins on a loft: one per armoured face, `t` thick, just proud of it.
static func _loft_plates(sections: Array, ctx: Dictionary, suffix: String = "") -> Array:
	var out := []
	var t: float = ctx.armour
	if t == 0.0: return out
	# Sides: the whole side profile, thickened outward.
	for sd in [["sideL", 1.0], ["sideR", -1.0]]:
		var s: float = sd[1]
		var pts := []
		for sc in sections:
			for off in [0.0, t]:
				pts.append(Vector3(sc.x, sc.yb + 0.004, sc.zc + s * (sc.hw + off)))
				pts.append(Vector3(sc.x, sc.yt - 0.004, sc.zt + s * (sc.hwt + off)))
		out.append(_piece("plate:%s%s" % [sd[0], suffix], sd[0], "armor", pts))
	# Top strips, classified by which way they face.
	var groups := {"top": [], "front": [], "rear": []}
	for i in range(sections.size() - 1):
		var a: Dictionary = sections[i]
		var b: Dictionary = sections[i + 1]
		var dx: float = b.x - a.x
		var dy: float = b.yt - a.yt
		var l := sqrt(dx * dx + dy * dy)
		if l == 0.0: l = 1.0
		var nx := -dy / l
		var ny := dx / l
		var slot := "top" if ny >= 0.8 else ("front" if nx > 0 else "rear")
		for sc in [a, b]:
			for off in [0.0, t]:
				groups[slot].append(Vector3(sc.x + nx * off, sc.yt + ny * off, sc.zt + sc.hwt * 0.98))
				groups[slot].append(Vector3(sc.x + nx * off, sc.yt + ny * off, sc.zt - sc.hwt * 0.98))
	# End caps: nose face to the front plate, tail face to the rear.
	var nose: Dictionary = sections[sections.size() - 1]
	var tail: Dictionary = sections[0]
	if nose.yt - nose.yb > 0.02: groups.front.append_array(_cap_pts(nose, 1.0, t))
	if tail.yt - tail.yb > 0.02: groups.rear.append_array(_cap_pts(tail, -1.0, t))
	for slot in groups:
		var pts: Array = groups[slot]
		if pts.size() >= 8: out.append(_piece("plate:%s%s" % [slot, suffix], slot, "armor", pts))
	return out

static func _cap_pts(sc: Dictionary, dir: float, t: float) -> Array:
	var pts := []
	for off in [0.0, t]:
		var x: float = sc.x + dir * off
		pts.append(Vector3(x, sc.yb + 0.004, sc.zc + sc.hw * 0.97))
		pts.append(Vector3(x, sc.yb + 0.004, sc.zc - sc.hw * 0.97))
		pts.append(Vector3(x, sc.yt, sc.zt + sc.hwt * 0.97))
		pts.append(Vector3(x, sc.yt, sc.zt - sc.hwt * 0.97))
	return pts

static func _ring(n: int, r: float, y: float) -> Array:
	var out := []
	for i in n:
		var a := (float(i) / n) * PI * 2.0
		out.append(Vector3(cos(a) * r, y, sin(a) * r))
	return out

## Round bodies (shells, domes, turrets): a polygonal drum with a domed lid.
## Armour plates are arcs of the wall by direction, and the lid.
static func _round_core(ctx: Dictionary) -> Dictionary:
	var L: float = ctx.L
	var H: float = ctx.H
	var W: float = ctx.W
	var p: Dictionary = ctx.p
	var armour: float = ctx.armour
	var n := int(J.rnd(_c(_n(p, "sides", 10.0), 6.0, 16.0)))
	# `radius` shrinks the drum inside the chassis envelope, e.g. so a rotor
	# round its middle is exposed.
	var R := (minf(L, W) / 2) * _c(_n(p, "radius", 1.0), 0.5, 1.0)
	var wall_h := H * _c(_n(p, "wall", 0.6), 0.3, 1.0)
	var dome_h := H - wall_h
	var yb := -H / 2
	var yw := yb + wall_h
	# `top`: "dome" (default), "cone" (a puck with a raked edge) or "flat".
	var lid: String = J.g(p, "top", "dome")
	if lid == "": lid = "dome"
	var upper: Array
	if lid == "flat": upper = [[R, 1.0]]
	elif lid == "cone": upper = [[R * 0.55, 1.0]]
	else: upper = [[R * 0.62, 0.75], [R * 0.25, 1.0]]
	var core := _ring(n, R, yb)
	core.append_array(_ring(n, R, yw))
	if dome_h > 0.005:
		for u in upper: core.append_array(_ring(n, u[0], yw + dome_h * u[1]))
	var pieces := [_piece("core", "core", "body", core)]
	if armour != 0.0:
		var arcs := [["front", -45.0, 45.0], ["sideL", 45.0, 135.0], ["rear", 135.0, 225.0], ["sideR", 225.0, 315.0]]
		for arc in arcs:
			var pts := []
			for k in range(5):
				var a := U.deg_to_rad(arc[1] + ((arc[2] - arc[1]) * k) / 4.0)
				for r in [R + 0.002, R + armour]:
					for y in [yb + 0.01, yw]: pts.append(Vector3(cos(a) * r, y, sin(a) * r))
			pieces.append(_piece("plate:%s" % arc[0], arc[0], "armor", pts))
		if dome_h > 0.005:
			var f0: float = upper[0][1]
			var r1: float = upper[upper.size() - 1][0]
			var pts: Array
			if lid == "dome":
				pts = _ring(n, R * 0.62, yw + dome_h * 0.75 + 0.002)
				pts.append_array(_ring(n, R * 0.25, yw + dome_h + armour))
			else:
				pts = _ring(n, r1 * 0.98, yw + dome_h * f0 + 0.002)
				pts.append_array(_ring(n, r1 * 0.98, yw + dome_h + armour))
			pieces.append(_piece("plate:top", "top", "armor", pts))
	# The lid's outline from the rim up to the crown, as [radius, height].
	var profile := [[R, yw]]
	if dome_h > 0.005:
		for u in upper: profile.append([u[0], yw + dome_h * u[1]])
	profile.append([0.0, profile[profile.size() - 1][1]])
	return {"pieces": pieces, "frontX": R, "topY": H / 2, "frontBottomY": yb, "round": true, "radius": R, "wallTopY": yw,
		"profile": profile, "apothem": cos(PI / n)}

# ---------------------------------------------------------------- the body's surface
# Extras stand on the body as it really is - a raked side, a domed lid, a pod,
# a nose that narrows to a point. These answer where that is.

static func _lerp(a: float, b: float, t: float) -> float:
	return a + (b - a) * t

# A round body's radius at height y (0 above its crown).
static func _round_radius_at(core: Dictionary, y: float) -> float:
	var prof: Array = core.profile
	if y <= prof[0][1]: return prof[0][0]
	for i in range(prof.size() - 1):
		var a: Array = prof[i]
		var b: Array = prof[i + 1]
		if y <= b[1] + 1e-9:
			if b[1] - a[1] < 1e-9: return a[0]
			return _lerp(a[0], b[0], (y - a[1]) / (b[1] - a[1]))
	return 0.0

# The run's section at x, or null if x is off its ends.
static func _section_at(run: Array, x: float):
	if x < run[0].x - 1e-6 or x > run[run.size() - 1].x + 1e-6: return null
	return _interp_section(run, _c(x, run[0].x, run[run.size() - 1].x))

## The body's upper surface at (x, z) - raked sides and domed lids included -
## or -INF where there is no body under that point.
static func surface_at(core: Dictionary, x: float, z: float = 0.0) -> float:
	if core.get("round", false):
		# The drum is a polygon: measure to its flats, not its corners.
		var prof: Array = core.profile
		var r: float = sqrt(x * x + z * z) / core.apothem
		if r > prof[0][0] + 1e-6: return -INF
		for i in range(prof.size() - 1):
			var a: Array = prof[i]
			var b: Array = prof[i + 1]
			if r >= b[0] - 1e-9:
				if a[0] - b[0] < 1e-9: return b[1]
				return _lerp(a[1], b[1], (a[0] - r) / (a[0] - b[0]))
		return prof[prof.size() - 1][1]
	var best := -INF
	for run in core.solids:
		var at = _section_at(run, x)
		if at == null: continue
		var t0: float = at.zt - at.hwt
		var t1: float = at.zt + at.hwt
		var b0: float = at.zc - at.hw
		var b1: float = at.zc + at.hw
		if z >= t0 - 1e-6 and z <= t1 + 1e-6: best = maxf(best, at.yt)
		elif z < t0 and z >= b0 - 1e-6 and t0 - b0 > 1e-9: best = maxf(best, _lerp(at.yb, at.yt, (z - b0) / (t0 - b0)))
		elif z > t1 and z <= b1 + 1e-6 and b1 - t1 > 1e-9: best = maxf(best, _lerp(at.yb, at.yt, (b1 - z) / (b1 - t1)))
	return best

## Whether (x, y, z) is inside the body. y NAN: at any height.
static func _solid(core: Dictionary, x: float, y: float, z: float) -> bool:
	if is_nan(y): return surface_at(core, x, z) > -INF
	if core.get("round", false):
		if y < core.frontBottomY - 1e-6: return false
		return sqrt(x * x + z * z) / core.apothem <= _round_radius_at(core, y) + 1e-6 and _round_radius_at(core, y) > 0.0
	for run in core.solids:
		var at = _section_at(run, x)
		if at == null or y < at.yb - 1e-6 or y > at.yt + 1e-6: continue
		var f: float = (y - at.yb) / maxf(1e-9, at.yt - at.yb)
		if z >= _lerp(at.zc - at.hw, at.zt - at.hwt, f) - 1e-6 and z <= _lerp(at.zc + at.hw, at.zt + at.hwt, f) + 1e-6: return true
	return false

## How far out from the centreline the body reaches at station x and height y
## (0: no body there).
static func half_width_at(core: Dictionary, x: float, y: float) -> float:
	if core.get("round", false):
		if y < core.frontBottomY - 1e-6: return 0.0
		var rr: float = _round_radius_at(core, y) * core.apothem
		return sqrt(maxf(0.0, rr * rr - x * x))
	var best := 0.0
	for run in core.solids:
		var at = _section_at(run, x)
		if at == null or y < at.yb - 1e-6 or y > at.yt + 1e-6: continue
		var f: float = (y - at.yb) / maxf(1e-9, at.yt - at.yb)
		best = maxf(best, maxf(absf(_lerp(at.zc - at.hw, at.zt - at.hwt, f)), absf(_lerp(at.zc + at.hw, at.zt + at.hwt, f))))
	return best

## The body's length: [rear x, front x].
static func _x_range(core: Dictionary) -> Array:
	if core.get("round", false): return [-core.radius * core.apothem, core.radius * core.apothem]
	var lo := INF
	var hi := -INF
	for run in core.solids:
		lo = minf(lo, run[0].x)
		hi = maxf(hi, run[run.size() - 1].x)
	return [lo, hi]

## The body's front (dir 1) or rear (dir -1) face along the line (y, z), or
## NAN if the line misses the body. y NAN: at any height.
static func _edge_x(core: Dictionary, y: float, z: float, dir: float) -> float:
	var r := _x_range(core)
	var n := 48
	var step: float = (r[1] - r[0]) / n
	var x: float = r[1] if dir > 0.0 else r[0]
	for i in range(n + 1):
		if _solid(core, x, y, z):
			if i == 0: return x
			var inside := x
			var outside := x + dir * step
			for k in 8:
				var m := (inside + outside) / 2
				if _solid(core, m, y, z): inside = m
				else: outside = m
			return inside
		x -= dir * step
	return NAN

## What a footprint (x ± hx, z ± hz) stands on: the lowest and highest surface
## under it and the surface under its centre. ok: there is body under it.
static func _seat(core: Dictionary, x: float, z: float, hx: float, hz: float) -> Dictionary:
	var lo := INF
	var hi := -INF
	for dx in [-1.0, 0.0, 1.0]:
		for dz in [-1.0, 0.0, 1.0]:
			var y := surface_at(core, x + dx * hx, z + dz * hz)
			if y == -INF: continue
			lo = minf(lo, y)
			hi = maxf(hi, y)
	var c := surface_at(core, x, z)
	return {"lo": lo, "hi": hi, "c": c if c > -INF else hi, "ok": hi > -INF}

# ---------------------------------------------------------------- extras

static func _extra_pieces(ex: Dictionary, ctx: Dictionary, core: Dictionary) -> Array:
	var L: float = ctx.L
	var H: float = ctx.H
	var W: float = ctx.W
	var assembled: Dictionary = ctx.assembled
	var st: Dictionary = assembled.stats
	var top: float = core.topY
	var nose: float = core.frontX
	var yb := -H / 2
	var type: String = ex.type
	var out := []
	var sides := [["L", 1.0], ["R", -1.0]]
	var role_of := func(def: String) -> String:
		var r = ex.get("role")
		return r if J.truthy(r) else def
	# The body's ends, and its ends along the centreline (a round body is
	# shorter than its chassis; a twin's bridge stops short of its pods).
	var ends := _x_range(core)
	var mid_a := _edge_x(core, NAN, 0.0, -1.0)
	var mid_b := _edge_x(core, NAN, 0.0, 1.0)
	if is_nan(mid_a) or is_nan(mid_b):
		mid_a = ends[0]
		mid_b = ends[1]
	# A static wedge on the nose covers whatever is low down behind it.
	var wedge = ctx.weapon.get("wedge") if ctx.get("weapon") is Dictionary else null
	# A height that is inside the nose, to find the nose's outline at.
	var nose_top: float = J.g(core, "noseTopY", top)
	var y_nose: float = core.frontBottomY + minf(0.01, (nose_top - core.frontBottomY) * 0.5)

	match type:
		"forks":
			# Low prongs off the nose: wedgelets that get under the opponent.
			var n := int(J.rnd(_c(_n(ex, "count", 2.0), 1.0, 5.0)))
			var length := _in(_n(ex, "lengthIn", 8.0))
			var w := _in(_n(ex, "widthIn", 2.5))
			var spread := (W / 2) * _c(_n(ex, "spread", 0.8), 0.0, 1.0)
			var rise := minf(_in(_n(ex, "heightIn", 2.5)), H * 0.6)
			# On a nose that narrows (a dart, a bullet, a round body) the outer
			# prongs come in until they start near the front of it.
			for k in 8:
				if n == 1: break
				var e := _edge_x(core, y_nose, spread, 1.0)
				if not is_nan(e) and e >= ends[1] - L * 0.2: break
				spread *= 0.85
			for i in n:
				var z := 0.0 if n == 1 else -spread + (2.0 * spread * i) / (n - 1)
				var y0 := yb
				var x0 := nose - 0.01
				var back := rise
				var x1 := x0 + length
				if wedge != null and absf(z) + w / 2 <= wedge.widthM / 2 + 1e-6:
					# Over a wedge they ride its ramp as ribs and carry on past its edge.
					y0 = wedge.y0
					x0 = wedge.x0 - 0.01
					back = wedge.rise + 0.014
					x1 = wedge.x0 + wedge.run + length * 0.5
				else:
					# Each prong starts where the body ends in front of it.
					var e := _edge_x(core, y_nose, z, 1.0)
					if not is_nan(e):
						x0 = e - 0.01
						x1 = x0 + length
				out.append(_piece("extra:forks:%d" % i, "wedge", "metal", [
					Vector3(x0, y0, z - w / 2), Vector3(x0, y0, z + w / 2),
					Vector3(x0, y0 + back, z - w / 2), Vector3(x0, y0 + back, z + w / 2),
					Vector3(x1, y0, z - w / 2), Vector3(x1, y0, z + w / 2),
					Vector3(x1, y0 + 0.006, z - w / 2), Vector3(x1, y0 + 0.006, z + w / 2),
				]))
		"wheelGuards":
			# Armoured pods round the tyres, the full length of the wheelbase.
			var r: float = st.wheelRadiusM
			var z_out: float = st.trackHalfM + _in(assembled.parts.wheel.spec.widthIn) * 0.6 + 0.01
			var x0: float = -st.wheelbaseHalfM - r * 1.1
			var x1: float = maxf(nose, st.wheelbaseHalfM + r * 1.1) + _in(_n(ex, "forwardIn", 0.0))
			var y_top := minf(top, yb + _c(_n(ex, "height", 0.85), 0.3, 1.0) * H)
			# Its inner edge meets the body where the body is widest at that
			# height (a tent or a dome is narrower up there than its floor).
			var widest := func(y: float) -> float:
				var m := 0.0
				for k in 9: m = maxf(m, half_width_at(core, _lerp(x0, x1, k / 8.0), y))
				return m
			# Where the body draws in a lot by that height (a dome, a tent, a
			# cab narrower than its deck) the pod comes down to its shoulder.
			var floor_w: float = widest.call(yb + 0.012)
			var reach: float = widest.call(y_top - 0.006)
			while reach < floor_w * 0.85 and y_top - H * 0.05 >= yb + H * 0.45:
				y_top -= H * 0.05
				reach = widest.call(y_top - 0.006)
			var z_in := W / 2 if (reach <= 0.0 or reach >= W / 2 - 1e-4) else reach - 0.008
			for sd in sides:
				var s: float = sd[1]
				# Open underneath (the tyre needs the floor), so it is a hood:
				# top plate plus outer wall, as one convex hull.
				var pts := []
				for x in [x0, x1]:
					pts.append(Vector3(x, yb + 0.01, s * z_out)); pts.append(Vector3(x, y_top, s * z_out))
					pts.append(Vector3(x, y_top, s * z_in)); pts.append(Vector3(x, yb + 0.01, s * (z_out - 0.012)))
				out.append(_piece("extra:wheelGuards:%s" % sd[0], "guard", "trim", pts))
		"uprights":
			# Twin posts carrying a front weapon, Tombstone-style. They stand
			# behind the step cut for the bar, not over it.
			var h := _in(_n(ex, "heightIn", 6.0))
			var xp := nose - _in(3)
			if core.get("cutX") != null: xp = minf(xp, core.cutX - _in(2) - 0.004)
			for sd in sides:
				var z: float = sd[1] * W * 0.32
				var seat := _seat(core, xp, z, _in(2), _in(1.5))
				var y0: float = seat.lo if seat.ok else top
				out.append(_piece("extra:uprights:%s" % sd[0], "front", "trim", box_pts(xp, y0 + h / 2 - 0.01, z, _in(2), h / 2, _in(1.5))))
		"mast":
			var h := _in(_n(ex, "heightIn", 8.0))
			var x := _c(_in(_n(ex, "xIn", 0.0)), mid_a + _in(2.5), mid_b - _in(2.5))
			var seat := _seat(core, x, 0.0, _in(2.5), _in(2.5))
			var y0: float = seat.lo if seat.ok else top_at(core, x)
			var y1: float = (seat.c if seat.ok else top_at(core, x)) + h - 0.01
			out.append(_piece("extra:mast:0", "top", "trim", box_corners(x - _in(2.5), y0 - 0.01, _in(2.5), x + _in(2.5), y1, -_in(2.5))))
		"fin":
			var h := _in(_n(ex, "heightIn", 6.0))
			var length := L * _c(_n(ex, "length", 0.5), 0.15, 0.9)
			var x0 := maxf(-L / 2 + L * 0.08, mid_a + 0.01)
			var x1 := minf(-L / 2 + L * 0.08 + length, mid_b - 0.01)
			# Its foot is level with the lowest body under it and its tip
			# clears the highest, so it never hangs over a slope or a step.
			var lo := INF
			var hi := -INF
			for k in 9:
				var y := surface_at(core, _lerp(x0, x1, k / 8.0), 0.0)
				if y == -INF: continue
				lo = minf(lo, y)
				hi = maxf(hi, y)
			if hi == -INF:
				lo = top
				hi = top
			var xp := x0 + (x1 - x0) * 0.2
			out.append(_piece("extra:fin:0", "top", "accent", [
				Vector3(x0, lo - 0.005, _in(0.5)), Vector3(x0, lo - 0.005, -_in(0.5)),
				Vector3(x1, lo - 0.005, _in(0.5)), Vector3(x1, lo - 0.005, -_in(0.5)),
				Vector3(xp, hi + h, _in(0.4)), Vector3(xp, hi + h, -_in(0.4)),
			]))
		"spikes":
			var n := int(J.rnd(_c(_n(ex, "count", 3.0), 1.0, 6.0)))
			var length := _in(_n(ex, "lengthIn", 4.0))
			var r := _in(1.2)
			# Half way up the nose - or, on a nose too thin to carry them (a
			# wedge, a dart), out of the slope above it.
			var want: float = maxf((core.frontBottomY + nose_top) / 2, yb + r + 0.004)
			# Clear of a wedge on the nose, which would swallow them.
			if wedge != null: want = maxf(want, wedge.y0 + wedge.rise + r * 0.4)
			want = maxf(yb + r * 0.5, minf(want, top - r * 0.6))
			# Failing that (a low deck in front of a cab), as high as the front
			# of the body goes.
			var deck := -INF
			for z in [0.0, W * 0.2, -W * 0.2]: deck = maxf(deck, surface_at(core, ends[1] - L * 0.12, z))
			var heights := [want]
			if deck > -INF and deck - r * 0.6 < want: heights.append(maxf(yb + r * 0.5, deck - r * 0.6))
			for y in heights:
				# On a nose that narrows they come in until they are on its face.
				var spread := W * 0.38
				for k in 8:
					if n == 1: break
					var e := _edge_x(core, y, spread, 1.0)
					if not is_nan(e) and e >= ends[1] - L * 0.06: break
					spread *= 0.85
				for i in n:
					var z := 0.0 if n == 1 else -spread + (2.0 * spread * i) / (n - 1)
					# Each one out of the body in front of it. None where there
					# is no nose (the slot a disc or drum runs in).
					var e := _edge_x(core, y, z, 1.0)
					if is_nan(e) or e < ends[1] - L * 0.45: continue
					var x0 := e - 0.01
					out.append(_piece("extra:spikes:%d" % i, "front", "metal", [
						Vector3(x0, y - r, z - r), Vector3(x0, y + r, z - r),
						Vector3(x0, y - r, z + r), Vector3(x0, y + r, z + r),
						Vector3(x0 + 0.01 + length, y, z),
					]))
				if not out.is_empty(): break
		"tail":
			# A scorpion tail curling up over the back, in two segments.
			var h := _in(_n(ex, "heightIn", 14.0))
			var w := _in(2.5)
			var xr := mid_a
			var seat := _seat(core, xr + 0.02, 0.0, 0.015, w / 2)
			var y0: float = seat.lo if seat.ok else top
			var y1: float = seat.hi if seat.ok else top
			out.append(_piece("extra:tail:0", "rear", "trim",
				box_corners(xr + 0.02, y0 - 0.01, w / 2, xr - _in(4), y1 + h * 0.55, -w / 2)))
			out.append(_piece("extra:tail:1", "rear", "accent",
				box_corners(xr - _in(4), y1 + h * 0.5, w * 0.35, xr + _in(3), y1 + h, -w * 0.35)))
		"stack":
			var h := _in(_n(ex, "heightIn", 7.0))
			var r := _in(_n(ex, "radiusIn", 2.2))
			var x := _c(L * 0.22, mid_a + r, mid_b - r)
			var seat := _seat(core, x, 0.0, r * 0.7, r * 0.7)
			var y0: float = (seat.lo if seat.ok else top_at(core, x)) - 0.005
			var y1: float = (seat.c if seat.ok else top_at(core, x)) + h - 0.005
			out.append(_piece("extra:stack:0", "top", "trim", cyl_pts(Vector3(x, (y0 + y1) / 2, 0), "y", r, (y1 - y0) / 2, 10)))
		"eyes":
			var r := _in(_n(ex, "radiusIn", 2.2))
			var x := _c(L * 0.18, ends[0] + r, ends[1] - r)
			for sd in sides:
				var s: float = sd[1]
				# Where it was asked for, or a little further out or in if the
				# body is flatter there (the top of a pod, not its edge).
				var seat = null
				var z := s * W * 0.25
				for cand in [s * W * 0.25, s * W * 0.25 + s * r, s * W * 0.25 - s * r]:
					if surface_at(core, x, cand) == -INF: continue
					var c := _seat(core, x, cand, r * 0.7, r * 0.7)
					if seat == null or (c.hi - c.lo) < (seat.hi - seat.lo) - 0.004:
						seat = c
						z = cand
				if seat == null: continue
				var y0: float = seat.lo - 0.003 if seat.hi - seat.lo > 1e-6 else seat.lo
				var y1: float = seat.c + r * 1.8
				out.append(_piece("extra:eyes:%s" % sd[0], "top", "accent", cyl_pts(Vector3(x, (y0 + y1) / 2, z), "y", r, (y1 - y0) / 2, 10)))
		"dome":
			var R := minf(L, W) * _c(_n(ex, "size", 0.3), 0.1, 0.48)
			var h := _in(_n(ex, "heightIn", 5.0))
			var cx := _in(_n(ex, "xIn", 0.0))
			if mid_b - mid_a > R * 1.2: cx = _c(cx, mid_a + R * 0.6, mid_b - R * 0.6)
			# Its rim goes down to the lowest body under it and its crown
			# stands over the highest, so it is never sunk in a step or a slope.
			var lo := INF
			var hi := surface_at(core, cx, 0.0)
			for i in 8:
				var a := (i / 8.0) * PI * 2.0
				var rim := surface_at(core, cx + cos(a) * R, sin(a) * R)
				if rim > -INF: lo = minf(lo, rim)
				hi = maxf(hi, surface_at(core, cx + cos(a) * R * 0.5, sin(a) * R * 0.5))
			if hi == -INF: hi = top
			lo = minf(lo, hi)
			var pts := []
			for ry in [[R, lo - 0.005], [R * 0.8, hi + h * 0.6], [R * 0.35, hi + h]]:
				for i in 10:
					var a := (i / 10.0) * PI * 2.0
					pts.append(Vector3(cx + cos(a) * ry[0], ry[1], sin(a) * ry[0]))
			out.append(_piece("extra:dome:0", "top", "trim", pts))
		"plow":
			# A scoop wider than the body, raking forward - the wide shovel nose.
			var length := _in(_n(ex, "lengthIn", 9.0))
			var h := minf(_in(_n(ex, "heightIn", 6.0)), H * 0.95)
			var half := W / 2 + _in(_n(ex, "overhangIn", 4.0))
			var x0 := nose - 0.01
			# Round a nose that narrows it reaches back to wrap it.
			var e := _edge_x(core, y_nose, minf(half, W / 2) * 0.45, 1.0)
			var xb := x0 if is_nan(e) else _c(e - 0.005, nose - L * 0.15, x0)
			out.append(_piece("extra:plow:0", "wedge", "metal", [
				Vector3(xb, yb, half), Vector3(xb, yb, -half),
				Vector3(xb, yb + h, half), Vector3(xb, yb + h, -half),
				Vector3(x0 + length, yb, half * 0.92), Vector3(x0 + length, yb, -half * 0.92),
				Vector3(x0 + length, yb + 0.006, half * 0.92), Vector3(x0 + length, yb + 0.006, -half * 0.92),
			]))
		"legs":
			# A walker's legs: three a side, standing in the wheel arches.
			var n := 3
			var leg_h: float = st.wheelRadiusM * 1.6
			var w := _in(2)
			for i in n:
				var x := _c(-L * 0.35 + (L * 0.7 * i) / (n - 1), ends[0] + w, ends[1] - w)
				# Out of the body's side where it is at that station.
				var reach := half_width_at(core, x, yb + leg_h * 0.5)
				var z_in := W / 2 if (reach <= 0.0 or reach >= W / 2 - 1e-4) else reach - 0.008
				for sd in sides:
					var s: float = sd[1]
					out.append(_piece("extra:legs:%s%d" % [sd[0], i], "guard", "trim",
						box_corners(x - w, yb + leg_h * 0.15, s * z_in, x + w, yb + leg_h * 0.9, s * (z_in + _in(3)))))
		"hump":
			# A raised cab at the back.
			var h := _in(_n(ex, "heightIn", 4.0))
			var length := L * _c(_n(ex, "length", 0.35), 0.15, 0.6)
			var x1 := -L / 2 + length
			var x0 := maxf(-L / 2, ends[0]) + 0.01
			var seat := _seat(core, (x0 + x1) / 2, 0.0, (x1 - x0) / 2, W * 0.36)
			var y0: float = (seat.lo if seat.ok else top) - 0.005
			var y1: float = (seat.hi if seat.ok else top) + h
			var pts := box_corners(x0, y0, W * 0.36, x1, y1, -W * 0.36)
			pts.append(Vector3(x1 + h * 0.8, y0, W * 0.3))
			pts.append(Vector3(x1 + h * 0.8, y0, -W * 0.3))
			out.append(_piece("extra:hump:0", "top", "trim", pts))
		"cage":
			# A roll hoop over the top, so the bot lands on its cage when
			# flipped. Each hoop stands on the body at both ends and clears
			# the highest point between them.
			var h := _in(_n(ex, "heightIn", 5.0))
			var w := _in(1.5)
			for kx in [["F", L * 0.2], ["R", -L * 0.3]]:
				var x: float = _c(kx[1], ends[0] + w + 0.01, ends[1] - w - 0.01)
				var half := W * 0.42
				var reach := half_width_at(core, x, yb + 0.012)
				if reach > 0.0: half = minf(half, reach * 0.96)
				# On a body that falls away steeply to the sides (a tent) the
				# hoop comes in to hug the ridge rather than stand as a wall.
				var ridge := surface_at(core, x, 0.0)
				for k in 8:
					var edge := minf(surface_at(core, x, half), surface_at(core, x, -half))
					if ridge == -INF or edge >= ridge - H * 0.35: break
					half *= 0.88
				var foot := [top, top]
				var hi := -INF
				for k in 9:
					var z := _lerp(-half, half, k / 8.0)
					hi = maxf(hi, maxf(surface_at(core, x - w, z), surface_at(core, x + w, z)))
				if hi == -INF: hi = top
				for j in 2:
					var z := half if j == 0 else -half
					var y := minf(surface_at(core, x - w, z), surface_at(core, x + w, z))
					foot[j] = y if y > -INF else hi
				# Over a flat top it is a plain bar; where the body falls away
				# to the sides its legs splay out to reach it.
				var flat: bool = hi - minf(foot[0], foot[1]) < 0.006
				var crown := half if flat else half * 0.8
				var pts := []
				for xx in [x - w, x + w]:
					pts.append(Vector3(xx, foot[0] - 0.005, half)); pts.append(Vector3(xx, foot[1] - 0.005, -half))
					pts.append(Vector3(xx, hi + h, crown)); pts.append(Vector3(xx, hi + h, -crown))
				out.append(_piece("extra:cage:%s" % kx[0], "top", "metal", pts))
		"wings":
			# Flat side wings out over the wheels, like a hydroplane.
			var length := L * _c(_n(ex, "length", 0.6), 0.2, 0.95)
			var reach := _in(_n(ex, "reachIn", 4.0))
			var y := minf(top, yb + 2.0 * st.wheelRadiusM - st.groundClearanceM + 0.01)
			# Rooted in the body's side where it is at that height - and no
			# higher than the body is along them (a nose that drops away).
			var side := 0.0
			for k in 9: side = maxf(side, half_width_at(core, _lerp(-length / 2, length / 2, k / 8.0), y - 0.006))
			if side <= 0.0:
				var roof := -INF
				for k in 9: roof = maxf(roof, surface_at(core, _lerp(-length / 2, length / 2, k / 8.0), 0.0))
				if roof > -INF: y = minf(y, roof)
				for k in 9: side = maxf(side, half_width_at(core, _lerp(-length / 2, length / 2, k / 8.0), y - 0.006))
			var z_in := W / 2 - 0.01 if (side <= 0.0 or side >= W / 2 - 1e-4) else side - 0.01
			for sd in sides:
				var s: float = sd[1]
				out.append(_piece("extra:wings:%s" % sd[0], "guard", "accent", box_corners(-length / 2, y - 0.012, s * z_in, length / 2, y, s * (st.trackHalfM + reach))))
		"pod":
			# Built with the weapon, which knows where the hub is (_weapon_geometry).
			pass
		"horns":
			# A pair of horns off the top front corners, raking up and forward.
			var h := _in(_n(ex, "heightIn", 7.0))
			var r := _in(_n(ex, "baseIn", 2.2))
			var x0 := minf(nose - _in(_n(ex, "backIn", 5.0)), ends[1] - r)
			var want := W * _c(_n(ex, "spread", 0.32), 0.1, 0.48)
			# Back along a nose that narrows until it is wide enough for the pair.
			for k in 8:
				if half_width_at(core, x0, yb + 0.012) >= want * 0.7 + r * 0.6 or x0 - L * 0.06 < ends[0] + r: break
				x0 -= L * 0.06
			var reach := half_width_at(core, x0, yb + 0.012)
			for sd in sides:
				var s: float = sd[1]
				var z := s * (minf(want, maxf(r * 0.5, reach - r * 0.6)) if reach > 0.0 else want)
				var seat := _seat(core, x0, z, r, r)
				var y0: float = seat.lo if seat.ok else top_at(core, x0, z)
				var y1: float = seat.c if seat.ok else top_at(core, x0, z)
				var pts := box_corners(x0 - r, y0 - 0.005, z - r, x0 + r, y1 - 0.005 + r * 0.8, z + r)
				pts.append(Vector3(x0 + _in(_n(ex, "forwardIn", 4.0)), y1 + h, z + s * _in(_n(ex, "outIn", 2.0))))
				out.append(_piece("extra:horns:%s" % sd[0], "top", role_of.call("metal"), pts))
		"ears":
			# Two upright triangles on the top, for the animal bots.
			var h := _in(_n(ex, "heightIn", 4.0))
			var b := _in(_n(ex, "baseIn", 3.0))
			var t := _in(1)
			var x := _c(L * _c(_n(ex, "x", 0.15), -0.45, 0.45), ends[0] + b / 2, ends[1] - b / 2)
			var reach := half_width_at(core, x, yb + 0.012)
			for sd in sides:
				var s: float = sd[1]
				var z := s * W * _c(_n(ex, "spread", 0.3), 0.05, 0.48)
				if reach > 0.0: z = s * minf(absf(z), maxf(t, reach - t * 1.5))
				var seat := _seat(core, x, z, b / 2, t)
				var y0: float = seat.lo if seat.ok else top_at(core, x, z)
				var y1: float = seat.c if seat.ok else top_at(core, x, z)
				out.append(_piece("extra:ears:%s" % sd[0], "top", role_of.call("accent"), [
					Vector3(x - b / 2, y0 - 0.005, z - t), Vector3(x - b / 2, y0 - 0.005, z + t),
					Vector3(x + b / 2, y0 - 0.005, z - t), Vector3(x + b / 2, y0 - 0.005, z + t),
					Vector3(x - b * 0.15, y1 + h, z), Vector3(x - b * 0.15, y1 + h, z + 0.001),
				]))
		"spines":
			# A row of low pyramids down the spine.
			var n := int(J.rnd(_c(_n(ex, "count", 4.0), 1.0, 8.0)))
			var h: float = _in(_n(ex, "heightIn", 3.5)) + ctx.armour
			var b := _in(_n(ex, "baseIn", 3.5))
			var x0 := maxf(-L / 2 + L * 0.15, mid_a + b / 2 + 0.004)
			var x1 := minf(-L / 2 + L * _c(_n(ex, "length", 0.7), 0.2, 0.95), mid_b - b / 2 - 0.004)
			if x1 < x0:
				x0 = (mid_a + mid_b) / 2
				x1 = x0
			for i in n:
				var x := (x0 + x1) / 2 if n == 1 else x0 + ((x1 - x0) * i) / (n - 1)
				var seat := _seat(core, x, 0.0, b / 2, b / 2)
				var y0: float = seat.lo if seat.ok else top_at(core, x)
				var y1: float = seat.c if seat.ok else top_at(core, x)
				var pts := box_pts(x, y0 - 0.003, 0, b / 2, 0.003, b / 2)
				pts.append(Vector3(x - b * 0.2, y1 + h, 0))
				out.append(_piece("extra:spines:%d" % i, "top", role_of.call("accent"), pts))
		"bumper":
			# A rear bumper across the tail, low.
			var d := _in(_n(ex, "depthIn", 1.5))
			var h := H * _c(_n(ex, "height", 0.4), 0.15, 0.9)
			var half := W * 0.44
			var y := yb + h * 0.6
			var tail := _edge_x(core, y, 0.0, -1.0)
			if is_nan(tail): tail = ends[0]
			# Across a tail that narrows (a round body, a clipped corner) it
			# comes in until its ends still reach the body.
			var face := tail
			for k in 7:
				var e := _edge_x(core, y, half * 0.85, -1.0)
				if not is_nan(e) and e <= tail + L * 0.12:
					face = maxf(tail, e)
					break
				half *= 0.82
			out.append(_piece("extra:bumper:0", "rear", role_of.call("trim"),
				box_corners(tail - d, yb + 0.012, half, face + 0.01, yb + h, -half)))
		_:
			push_error("%s: unknown body extra \"%s\"" % [assembled.id, type])
	return out

# ---------------------------------------------------------------- weapons

## Where the weapon sits and what it sweeps.
##
## colliders: { type: "cylinder", center, axis, radius, halfHeight }
##          | { type: "cuboid", center, half }
##          | { type: "hull", points }
static func _weapon_geometry(assembled: Dictionary, ctx: Dictionary, core: Dictionary, mount_in):
	var weapon = assembled.parts.get("weapon")
	if weapon == null: return null
	var w: Dictionary = weapon.spec
	var cls: String = w["class"]
	var H: float = ctx.H
	var W: float = ctx.W
	var size: Array = J.g(w, "sizeIn", [12, 4, 12])
	var wl := _in(size[0])
	var wh := _in(size[1])
	var ww := _in(size[2])
	var nose: float = core.frontX
	var top: float = core.topY
	var yb := -H / 2
	var mount: String = mount_in if mount_in != null else default_mount(cls)
	var classic: bool = core.get("classic", false)
	var is_round: bool = core.get("round", false)
	var out := {"class": cls, "mount": mount, "colliders": [], "visual": null, "pieces": []}

	if cls == "static":
		# The wedge: a triangular prism off the nose, its rear meeting the body.
		var ramp := U.deg_to_rad(_nz(w.get("rampAngleDeg"), 15.0))
		var run := wl * cos(ramp)
		var rise := wl * sin(ramp)
		var x0 := nose
		var y0: float = J.g(core, "frontBottomY", yb)
		var hw := minf(ww, W * 1.1) / 2
		var points := [
			Vector3(x0, y0, hw), Vector3(x0 + run, y0, hw), Vector3(x0, y0 + rise, hw),
			Vector3(x0, y0, -hw), Vector3(x0 + run, y0, -hw), Vector3(x0, y0 + rise, -hw),
		]
		out.pieces.append(_piece("weapon:wedge", "weapon", "metal", points))
		out.visual = {"kind": "wedge"}
		out.wedge = {"lengthM": wl, "heightM": wh, "widthM": hw * 2, "rampRad": ramp, "run": run, "rise": rise, "x0": x0, "y0": y0}
		return out

	if not J.truthy(w.get("powered")): return out

	var r := _in(_nz(w.get("radiusIn"), 6.0))
	if cls == "spinner_h":
		var half := maxf(0.01, wh / 2)
		var center: Vector3
		if mount == "shell": center = Vector3(0, yb + H * 0.35, 0)
		elif mount == "overhead": center = Vector3(nose - r * 0.55, top + _in(3) + half, 0)
		elif mount == "low": center = Vector3(nose + r * 0.3, yb + half + _in(1), 0)
		else: center = Vector3(nose + r * 0.35, yb + H * float(ctx.p.weaponY) if ctx.p.get("weaponY") != null else 0.0, 0)
		if classic: center = Vector3(nose + r * 0.35, 0, 0)
		var half_h := maxf(half, H * 0.32) if mount == "shell" else half
		out.colliders.append({"type": "cylinder", "center": center, "axis": "y", "radius": r, "halfHeight": half_h})
		out.visual = {"kind": "rotor", "axis": "y", "center": center, "radius": r, "thickness": half_h * 2, "style": _rotor_style(w, mount, wl, r)}
		if (mount == "front" or mount == "low" or classic) and not is_round:
			# The bar's shaft is carried in bearings above and below it,
			# Tombstone-style: plates from the body out over (and under) the
			# hub, clear of the sweep. A `pod` extra tunes the top one; an
			# undercutter has only the top one, as its bar runs at the floor.
			var pod: Dictionary = {}
			for e in ctx.body.get("extras", []):
				if e.type == "pod":
					pod = e
					break
			var hub_r := maxf(_in(2.5), r * 0.2)
			var x0 := maxf(-ctx.L / 2, center.x - r - 0.03)
			var x1 := center.x + hub_r * 1.1
			var hw0 := minf(W * 0.3, hub_r * _n(pod, "width", 1.3))
			var hw1 := hub_r * 1.05
			var pod_role: String = pod.get("role") if J.truthy(pod.get("role")) else "metal"
			var plate := func(id: String, y0: float, y1: float) -> Dictionary:
				return _piece(id, "front", pod_role, [
					Vector3(x0, y0, hw0), Vector3(x0, y0, -hw0), Vector3(x0, y1, hw0), Vector3(x0, y1, -hw0),
					Vector3(x1, y0, hw1), Vector3(x1, y0, -hw1), Vector3(x1, y1, hw1), Vector3(x1, y1, -hw1),
				])
			var y_top := center.y + half + 0.006
			out.pieces.append(plate.call("extra:pod:0", y_top, y_top + _in(_n(pod, "thickIn", 1.2))))
			var y_bot := center.y - half - 0.006
			var shaft := {"y0": center.y - half - 0.004, "y1": y_top + 0.002, "r": hub_r * 0.42}
			if mount == "front" and y_bot - (yb + 0.004) > 0.012:
				out.pieces.append(plate.call("weapon:bearing", yb + 0.004, y_bot))
				shaft.y0 = y_bot - 0.002
			out.visual.shaft = shaft
		if mount == "overhead":
			# The mast it spins on.
			var base := top_at(core, center.x) if _has_top_at(core) else top
			var mast_h := center.y - base
			out.pieces.append(_piece("weapon:mast", "top", "trim", box_pts(center.x, base + mast_h / 2 - 0.005, 0, _in(2), mast_h / 2, _in(2))))
	elif cls == "spinner_v" or cls == "drum":
		var half_w := maxf(0.01, ww / 2)
		var bay: float = J.g(core, "bayX", 0.0)
		# Discs and drums ride just off the floor in front of (or in) the nose.
		var center := Vector3(nose + r * (0.6 if cls == "drum" else 0.5), yb + r, 0)
		if classic: center = Vector3(nose + r * 0.5, yb + r, 0)
		elif bay > 0: center = Vector3(nose + minf(bay, r) * 0.8, yb + r + 0.004, 0)
		if mount == "high": center.y = maxf(center.y, top - r * 0.3)
		# Sculpted bodies carry the rotor on an axle between two supports: in
		# the slot _loft_core cut for it, or standing off a round body's wall.
		var vr = core.get("vrot")
		if vr == null and is_round and mount != "high": vr = _round_rotor(ctx, core, w, r)
		if vr != null:
			center = vr.center
			half_w = vr.halfW
		out.colliders.append({"type": "cylinder", "center": center, "axis": "z", "radius": r, "halfHeight": half_w})
		var style = w.get("style")
		out.visual = {"kind": "rotor", "axis": "z", "center": center, "radius": r, "thickness": half_w * 2,
			"style": style if J.truthy(style) else ("drum" if cls == "drum" else "disc")}
		if vr != null:
			var z0: float = vr.support.z0
			var z1: float = vr.support.z1
			# From inside the body (where the slot starts) up or down to the
			# boss round the axle. Outside the rotor's width, so it never cuts
			# the sweep.
			var xa: float = vr.xa if vr.get("xa") != null else maxf(vr.x0 + 0.005, center.x - r * 0.8)
			for sd in [["L", 1.0], ["R", -1.0]]:
				var s: float = sd[1]
				var zm := s * (z0 + z1) / 2
				var ya_src: float = top_at(core, xa, zm) if _has_top_at(core) else J.g(core, "wallTopY", top)
				var ya := maxf(ya_src, yb + 0.03)
				var pts := []
				for z in [s * z0, s * z1]:
					pts.append(Vector3(xa, yb + 0.004, z)); pts.append(Vector3(xa, ya, z)); pts.append(Vector3(center.x - vr.bossR * 0.3, yb + 0.004, z))
					for i in 12:
						var a := (i / 12.0) * PI * 2.0
						pts.append(Vector3(center.x + cos(a) * vr.bossR, center.y + sin(a) * vr.bossR, z))
				out.pieces.append(_piece("weapon:support:%s" % sd[0], "front", "trim", pts))
			out.visual.axle = {"halfLen": z1 + 0.004, "radius": maxf(0.01, vr.bossR * 0.42), "bossR": vr.bossR}
	elif cls == "hammer":
		var reach := _in(_nz(w.get("reachIn"), 20.0))
		var pivot: Vector3
		var head: Vector3
		if classic:
			pivot = Vector3(nose * 0.2, H / 2, 0)
			head = Vector3(nose + reach * 0.45, H / 2, 0)
			out.colliders.append({"type": "cuboid", "center": head, "half": Vector3(wl / 2 * 0.3, wh / 2 * 0.25, ww / 2)})
		else:
			# Pivot over the back, head parked forward over the nose where it lands.
			pivot = Vector3(maxf(-ctx.L / 2 + 0.05, nose - reach * 0.85), top + _in(2), 0)
			head = Vector3(pivot.x + reach, pivot.y, 0)
			out.colliders.append({"type": "cuboid", "center": head, "half": Vector3(wl / 2 * 0.3, wh / 2 * 0.25, ww / 2)})
			# The pivot block stands on whatever is under it (a deck, a cab roof).
			var base := minf(top, top_at(core, pivot.x)) if _has_top_at(core) else top
			out.pieces.append(_piece("weapon:pivot", "top", "trim", box_pts(pivot.x, (base + pivot.y) / 2 + 0.01, 0, _in(2.5), (pivot.y - base) / 2 + _in(1.5), _in(3))))
		var style = w.get("style")
		out.visual = {"kind": "arm", "pivot": pivot, "reach": head.x - pivot.x, "head": {"l": wl * 0.3, "h": wh * 0.3, "w": ww}, "style": style if J.truthy(style) else "axe"}
	else:
		# Flipper, lifter, crusher: a plate or jaw across the nose.
		var center: Vector3
		if classic: center = Vector3(nose + wl * 0.12, yb + wh / 2, 0)
		else: center = Vector3(nose + wl * 0.12, J.g(core, "frontBottomY", yb) + wh / 2, 0)
		var half := Vector3(wl / 2 * 0.25, maxf(0.01, wh / 2), minf(ww, W) / 2)
		out.colliders.append({"type": "cuboid", "center": center, "half": half})
		var style = w.get("style")
		out.visual = {
			"kind": "jaw" if cls == "crusher" else "plate", "center": center, "size": {"l": wl * 0.5, "h": maxf(0.02, wh), "w": half.z * 2},
			"strokeM": _in(_n(w, "strokeIn", 1.2)), "style": style if J.truthy(style) else cls, "lid": mount == "lid", "top": top,
			# A lid flipper's plate covers the top of the bot back to its hinge.
			"hingeX": -ctx.L / 2 + ctx.L * 0.15,
		}
	return out

static func default_mount(cls) -> String:
	if cls == "hammer": return "top"
	return "front"

static func _rotor_style(w: Dictionary, mount: String, wl: float, r: float) -> String:
	if J.truthy(w.get("style")): return w.style
	if mount == "shell": return "shell"
	return "bar" if wl > r * 1.6 else "disc"

# ---------------------------------------------------------------- geometry helpers

static func armour_thickness(assembled: Dictionary) -> float:
	var mx := -INF
	for a in assembled.parts.armor:
		mx = maxf(mx, _in(_n(a.spec, "thicknessIn", 0.25)))
	if assembled.parts.armor.size() == 0: return 0.0
	return maxf(0.008, minf(0.02, mx))

static func _section_pts(s: Dictionary) -> Array:
	return [
		Vector3(s.x, s.yb, s.zc + s.hw), Vector3(s.x, s.yb, s.zc - s.hw),
		Vector3(s.x, s.yt, s.zt + s.hwt), Vector3(s.x, s.yt, s.zt - s.hwt),
	]

static func box_pts(cx: float, cy: float, cz: float, hx: float, hy: float, hz: float) -> Array:
	var out := []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				out.append(Vector3(cx + sx * hx, cy + sy * hy, cz + sz * hz))
	return out

## Box from two opposite corners.
static func box_corners(x0: float, y0: float, z0: float, x1: float, y1: float, z1: float) -> Array:
	return box_pts((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2,
		absf(x1 - x0) / 2, absf(y1 - y0) / 2, absf(z1 - z0) / 2)

## A polygonal cylinder as points, axis "x" | "y" | "z".
static func cyl_pts(c: Vector3, axis: String, r: float, half_h: float, n: int = 12) -> Array:
	var out := []
	for i in n:
		var a := (float(i) / n) * PI * 2.0
		var u := cos(a) * r
		var v := sin(a) * r
		for h in [-half_h, half_h]:
			if axis == "y": out.append(Vector3(c.x + u, c.y + h, c.z + v))
			elif axis == "x": out.append(Vector3(c.x + h, c.y + u, c.z + v))
			else: out.append(Vector3(c.x + u, c.y + v, c.z + h))
	return out

## Bounding points of a weapon collider, for the invertibility check.
static func _collider_extremes(c: Dictionary) -> Array:
	if c.type == "cylinder": return cyl_pts(c.center, c.axis, c.radius, c.halfHeight, 8)
	if c.type == "cuboid": return box_pts(c.center.x, c.center.y, c.center.z, c.half.x, c.half.y, c.half.z)
	return c.points
