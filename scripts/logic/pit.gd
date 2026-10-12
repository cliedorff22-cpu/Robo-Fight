## pit.gd - between fights: what is broken, what fixing it costs in money and
## in crew time, and what gets done before the next fight.
##
## Every robot carries its part condition from fight to fight, and the time
## between fights is the PIT WINDOW: the crew gets `window x crew size`
## crew-minutes to work with. Whatever is not fixed fights damaged.
##
## For each damaged part (a FITTING - left and right panels are separate):
##   patch    get it back to `patchTo` (60%): quick and dirty
##   repair   back to 100%. A part below `totaledBelow` is TOTALED and can
##            only be replaced
##   replace  swap in a fresh one - a spare from the garage if there is one,
##            otherwise bought from the shop; the old part is scrapped for
##            `salvageCreditFraction` of its value as it stands
##
## Pure logic over plain data (rules.json `pit`, parts.json repairCostPerHp
## and repairMinPerHp).
class_name Pit

## The order a crew works in when it cannot do everything: what stops you driving first.
const PRIORITY := ["electronics", "chassis", "drive", "motor", "battery", "wheel", "weaponMotor", "weapon", "srimech", "armor"]

static func pit_config(reg: Registry) -> Dictionary:
	var cached = reg.cache_get("pitCfg")
	if cached != null: return cached
	var p: Dictionary = reg.rules.get("pit", {})
	var windows := {"group": 60, "final": 30, "giantNutGroup": 45, "giantNutFinal": 25}
	var replace_minutes := {"chassis": 120, "drive": 35, "motor": 25, "battery": 8, "electronics": 15, "wheel": 10, "weaponMotor": 25, "weapon": 20, "srimech": 15, "armor": 12}
	var ai_crew := {"rookie": 2, "pro": 3, "elite": 4, "world": 5}
	var cfg := J.merge({
		"totaledBelow": 0.1,
		"totaledRepairCostRatio": 0.75,
		"salvageCreditFraction": 0.4,
		"patchTo": 0.6,
		"patchMinutesFactor": 0.55,
		"offseasonRepairRate": 0.5,
	}, p)
	cfg.windows = J.merge(windows, p.get("windows", {}))
	cfg.replaceMinutes = J.merge(replace_minutes, p.get("replaceMinutes", {}))
	cfg.aiCrew = J.merge(ai_crew, p.get("aiCrew", {}))
	reg.cache_set("pitCfg", cfg)
	return cfg

## Minutes until the next fight after a fight at this stage of a season.
static func pit_window(reg: Registry, fixture) -> float:
	var w: Dictionary = pit_config(reg).windows
	if fixture == null: return w.group
	var gn: bool = fixture.get("league") == "giantNut"
	if fixture.get("stage") == "final": return w.giantNutFinal if gn else w.final
	return w.giantNutGroup if gn else w.group

## Labour on top of the parts price for every repair (economy.json repairs).
static func _labour_of(reg: Registry) -> float:
	return J.path(reg.economy, ["repairs", "labourMultiplier"], 1.0)

static func _price(reg: Registry, ctx: Dictionary, id) -> float:
	var pf = ctx.get("price")
	if pf is Callable: return pf.call(id)
	return reg.part(id).cost

## Every fitting, with what each way of fixing it would take.
##   ctx { spares: {partId: n}, price: Callable(partId), discount 0..1 off repairs }
static func pit_report(reg: Registry, assembled: Dictionary, ctx: Dictionary = {}) -> Array:
	var cfg := pit_config(reg)
	var th: Dictionary = reg.rules.damage.thresholds
	# Labour, less the career's parts discount (sponsors, Giant Nut deals).
	var labour: float = _labour_of(reg) * (1.0 - J.g(ctx, "discount", 0.0))
	var spares: Dictionary = J.g(ctx, "spares", {})
	var out := []
	for f in assembled.fittings:
		var p: Dictionary = f.part
		var c := J.clamp01(J.g(assembled.condition, f.key, 1.0))
		var hp_lost: float = p.hp * (1.0 - c)
		var row := {
			"key": f.key, "partId": p.id, "name": p.name, "category": p.category, "condition": c,
			"status": Condition.part_status(c, th), "damaged": c < 0.999, "options": {},
		}
		out.append(row)
		if not row.damaged: continue
		var full_cost := J.rnd(hp_lost * p.repairCostPerHp * labour)
		row.totaled = c < cfg.totaledBelow
		row.replaceCheaper = full_cost >= cfg.totaledRepairCostRatio * p.cost
		if c < cfg.patchTo:
			var hp: float = p.hp * (cfg.patchTo - c)
			row.options.patch = {"to": cfg.patchTo, "cost": J.rnd(hp * p.repairCostPerHp * labour), "minutes": ceil(hp * p.repairMinPerHp * cfg.patchMinutesFactor)}
		if not row.totaled: row.options.repair = {"to": 1.0, "cost": full_cost, "minutes": ceil(hp_lost * p.repairMinPerHp)}
		var spare: bool = spares.get(p.id, 0) > 0
		row.options.replace = {
			"to": 1.0, "spare": spare, "cost": 0.0 if spare else _price(reg, ctx, p.id), "minutes": J.g(cfg.replaceMinutes, p.category, 20),
			"salvage": J.rnd(cfg.salvageCreditFraction * p.cost * c),
		}
	return out

## What a set of choices adds up to. `plan` = { fittingKey: "patch" | "repair" | "replace" }.
## Returns { cost, salvage, net, minutes, condition (after), replaced: [partId],
##           sparesUsed: {id: n}, bought: {id: n}, lines }
static func plan_totals(reg: Registry, assembled: Dictionary, plan: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var report := pit_report(reg, assembled, ctx)
	var condition: Dictionary = assembled.condition.duplicate()
	var spares_left: Dictionary = J.g(ctx, "spares", {}).duplicate()
	var out := {"cost": 0.0, "salvage": 0.0, "minutes": 0.0, "condition": condition, "replaced": [], "sparesUsed": {}, "bought": {}, "lines": []}
	for row in report:
		var how = plan.get(row.key)
		if not J.truthy(how) or not row.damaged: continue
		var opt = row.options.get(how)
		if opt == null: continue
		if how == "replace":
			# Spares are shared: two damaged panels and one spare means one buys.
			var spare: bool = spares_left.get(row.partId, 0) > 0
			opt = opt.duplicate()
			opt.spare = spare
			opt.cost = 0.0 if spare else _price(reg, ctx, row.partId)
			if spare:
				spares_left[row.partId] -= 1
				out.sparesUsed[row.partId] = out.sparesUsed.get(row.partId, 0) + 1
			else:
				out.bought[row.partId] = out.bought.get(row.partId, 0) + 1
			out.salvage += opt.salvage
			out.replaced.append(row.partId)
		out.cost += opt.cost
		out.minutes += opt.minutes
		condition[row.key] = maxf(row.condition, opt.to)
		out.lines.append({"key": row.key, "name": row.name, "how": how, "cost": opt.cost, "minutes": opt.minutes,
			"salvage": opt.salvage if how == "replace" else 0.0, "spare": J.truthy(opt.get("spare"))})
	out.net = out.cost - out.salvage
	return out

## The crew's best effort with `crewMinutes` and `cash`: what stops the robot
## driving first, then the weapon, then armour; the worst damage first within
## each; a full repair where it fits, a patch where it does not, a
## replacement for anything totaled.
##   o: { crewMinutes = INF, cash = INF, ctx = {}, prefer = null }
static func auto_plan(reg: Registry, assembled: Dictionary, o: Dictionary = {}) -> Dictionary:
	var crew_minutes: float = J.g(o, "crewMinutes", INF)
	var cash: float = J.g(o, "cash", INF)
	var ctx: Dictionary = J.g(o, "ctx", {})
	# `prefer` (ailearn.gd pit_prefer): what the NEXT opponent will go for
	# moves up the list, ahead of the weapon.
	var prefer = o.get("prefer")
	var pref_cats: Array = J.g(prefer, "categories", [])
	var pref_faces: Array = J.g(prefer, "faces", [])
	var rank := func(r: Dictionary) -> float:
		if pref_cats.has(r.category): return 4.5
		if r.category == "armor":
			var face = reg.part(r.partId).spec.slot
			var fi := pref_faces.find(face)
			if fi >= 0: return 5.5 - fi * 0.1
		return float(PRIORITY.find(r.category))
	var report := J.sorted(pit_report(reg, assembled, ctx).filter(func(r): return r.damaged), func(a, b):
		var d: float = rank.call(a) - rank.call(b)
		return d if d != 0.0 else a.condition - b.condition)
	var plan := {}
	var minutes := 0.0
	var money := 0.0
	var spares: Dictionary = J.g(ctx, "spares", {}).duplicate()
	for r in report:
		# Totaled: replace or nothing. Otherwise the cheaper proper fix first,
		# then a patch if time is short.
		var choices: Array = ["replace"] if r.totaled else (["replace", "repair", "patch"] if r.replaceCheaper else ["repair", "patch", "replace"])
		for how in choices:
			var opt = r.options.get(how)
			if opt == null: continue
			var spare: bool = how == "replace" and spares.get(r.partId, 0) > 0
			var cost: float = (0.0 if spare else opt.cost) if how == "replace" else opt.cost
			# Do not replace a part just because a repair did not fit, unless
			# it is something the robot cannot fight without.
			if how == "replace" and not r.totaled and not r.replaceCheaper and r.status != "failed" and r.status != "critical": continue
			if minutes + opt.minutes > crew_minutes or money + cost > cash: continue
			plan[r.key] = how
			minutes += opt.minutes
			money += cost
			if spare: spares[r.partId] -= 1
			break
	return plan

## An AI team's pit after a fight: its crew (by league) works through the
## window. Only their time is limited.
##   conditions  [per unit condition map] -> the same shape, repaired
static func ai_pit(reg: Registry, def: Dictionary, conditions: Array, window_minutes: float, prefer = null) -> Array:
	var cfg := pit_config(reg)
	var crew: float = J.g(cfg.aiCrew, def.get("league"), 2)
	var out := []
	for i in conditions.size():
		var cond = conditions[i]
		if cond == null:
			out.append(cond)
			continue
		if i != 0:
			out.append({})   # a multibot's second unit is rebuilt whole between fights
			continue
		var a := Build.assemble_robot(reg, def)
		for k in cond: a.condition[k] = cond[k]
		# AI crews always have the spare they need (it is in their trailer).
		var spares := {}
		for f in a.fittings: spares[f.part.id] = 9
		var plan := auto_plan(reg, a, {"crewMinutes": window_minutes * crew, "ctx": {"spares": spares}, "prefer": prefer})
		out.append(prune_fresh(plan_totals(reg, a, plan, {"spares": spares}).condition))
	return out

## A condition map with the factory-fresh fittings dropped (keeps saves small).
static func prune_fresh(cond) -> Dictionary:
	var out := {}
	if cond is Dictionary:
		for k in cond:
			if cond[k] < 0.999: out[k] = J.rnd(cond[k] * 1000.0) / 1000.0
	return out

## One line on how battered a robot is, for scouting and the hub.
static func damage_summary(reg: Registry, assembled: Dictionary) -> Dictionary:
	var th: Dictionary = reg.rules.damage.thresholds
	var hurt := []
	for f in assembled.fittings:
		var c: float = J.g(assembled.condition, f.key, 1.0)
		if c < 0.95: hurt.append({"name": f.part.name, "category": f.part.category, "c": c})
	hurt = J.sorted(hurt, func(a, b): return a.c - b.c)
	var worst := []
	for x in hurt.slice(0, 3):
		var o: Dictionary = x.duplicate()
		o.status = Condition.part_status(x.c, th)
		worst.append(o)
	return {"fresh": hurt.size() == 0, "worst": worst, "count": hurt.size()}
