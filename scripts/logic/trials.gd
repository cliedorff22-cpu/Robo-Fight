## trials.gd - trial fights: a design against some opponents through the fast
## resolver, with paired seeds so two designs tested with the same salt meet
## exactly the same fights. The build advisor uses it to back its advice with
## numbers; the AI teams (ailearn.gd) use it to choose their setup for a fight.
class_name Trials

## Fight `def` against each opponent `seeds` times through the resolver.
## opts: { seeds = 4, salt = "g", cond = null }
static func gauntlet(reg: Registry, def: Dictionary, opps: Array, opts: Dictionary = {}) -> Dictionary:
	var seeds: int = int(opts.get("seeds", 4))
	var salt = opts.get("salt", "g")
	var cond = opts.get("cond")
	var wins := 0
	var n := 0
	var by_opp := []
	for o in opps:
		var w := 0
		for k in seeds:
			var seed_v := Rng.hash_seed("%s:%s:%d" % [J.s(salt), o.id, k]) & 0x7fffffff
			# Alternate corners so neither side keeps the same one.
			# `cond` = { id: [per unit condition] }: robots that turn up damaged.
			var cd = J.g(cond, def.id)
			var co = J.g(cond, o.id)
			var r: Dictionary
			if k % 2 == 1:
				r = Resolver.resolve_fight(reg, o, def, {"seed": seed_v, "conditionA": co, "conditionB": cd})
			else:
				r = Resolver.resolve_fight(reg, def, o, {"seed": seed_v, "conditionA": cd, "conditionB": co})
			if r.winnerId == def.id: w += 1
		wins += w
		n += seeds
		by_opp.append({"id": o.id, "name": o.get("name"), "wins": w, "n": seeds})
	return {"winRate": float(wins) / n if n > 0 else 0.0, "n": n, "byOpp": by_opp}

## A stable sample of up to n from a list.
static func sample(list: Array, n: int, salt) -> Array:
	if list.size() <= n: return list
	var rng := Rng.new(Rng.hash_seed("sample:%s" % J.s(salt)))
	var pool := list.duplicate()
	var out := []
	while out.size() < n and pool.size() > 0:
		out.append(pool.pop_at(int(floor(rng.next() * pool.size()))))
	return out
