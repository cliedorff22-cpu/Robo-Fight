## market.gd - money and trading in the career: bank loans, the paddock
## market (AI teams selling spare parts and buying yours) and selling your
## robot to an AI team.
##
## Pure logic over the career save; the numbers are data/economy.json `loans`
## and `market`.
##
##   career.loans       = [{ lender, owed, borrowed, seasonsLeft, since }]
##   career.market      = { key, listings: [...], taken: [partId...] } - one
##                        "market day", regenerated after every fight
##   career.robotSales  = [{ def, buyerId, team, season, price, status, newId }]
##
## Everything that needs chance draws from a seed made of the career seed and
## the market day, so a save reloads to the same listings.
class_name Market

const LEAGUE_TIER := {"rookie": 1, "pro": 2, "elite": 3, "world": 3}
const FITTINGS := ["drive", "wheel", "motor", "battery", "electronics", "weaponMotor", "weapon", "srimech"]

static func money(n) -> String:
	return "$" + J.commas(J.rnd(float(n)))

static func _league_of(career: Dictionary):
	return career.membership[career.playerId]

# ---------------------------------------------------------------- loans

## The lenders, from economy.json.
static func lenders(reg: Registry) -> Array:
	return J.path(reg.economy, ["loans", "lenders"], [])

static func _lender(reg: Registry, id):
	for l in lenders(reg):
		if l.id == id: return l
	return null

static func _loan(career: Dictionary, lender_id):
	for x in career.get("loans", []):
		if x.lender == lender_id: return x
	return null

## Everything owed, across all lenders.
static func debt(career: Dictionary) -> float:
	var t := 0.0
	for l in career.get("loans", []): t += l.owed
	return t

## What each lender will do for the player now: { ...lender, limit, owed, available, seasonsLeft }.
static func loan_offers(reg: Registry, career: Dictionary) -> Array:
	var lg = _league_of(career)
	var out := []
	for l in lenders(reg):
		var loan = _loan(career, l.id)
		var limit: float = J.path(l, ["limit", lg], 0.0)
		var owed: float = loan.owed if loan != null else 0.0
		var o: Dictionary = l.duplicate()
		o.limit = limit
		o.owed = owed
		o.available = maxf(0.0, limit - owed)
		o.seasonsLeft = loan.seasonsLeft if loan != null else null
		out.append(o)
	return out

## Borrow `amount` from a lender. Returns { ok, reason, loan? }.
static func borrow(reg: Registry, career: Dictionary, lender_id, amount) -> Dictionary:
	var l = _lender(reg, lender_id)
	if l == null: return {"ok": false, "reason": "No such lender."}
	var amt := J.rnd(float(amount) if (amount != null and str(amount).is_valid_float()) else 0.0)
	if amt <= 0: return {"ok": false, "reason": "Borrow something."}
	var offer = J.find(loan_offers(reg, career), func(x): return x.id == lender_id)
	if amt > offer.available:
		if offer.available > 0: return {"ok": false, "reason": "%s will lend you up to %s more in the %s league." % [l.name, money(offer.available), _league_of(career)]}
		return {"ok": false, "reason": "%s will not lend you any more until you pay some back or move up a league." % l.name}
	if career.get("loans") == null: career.loans = []
	var loan = _loan(career, lender_id)
	if loan == null:
		loan = {"lender": lender_id, "owed": 0.0, "borrowed": 0.0, "seasonsLeft": l.seasons, "since": career.seasonIndex}
		career.loans.append(loan)
	loan.owed += amt
	loan.borrowed += amt
	loan.seasonsLeft = l.seasons          # a top-up starts the term again
	Ledger.pay(career, amt, "Loan from %s" % l.name)
	return {"ok": true, "reason": "", "loan": loan}

## Pay `amount` off a loan early (no penalty). Returns { ok, paid, reason }.
static func repay(reg: Registry, career: Dictionary, lender_id, amount) -> Dictionary:
	var loan = _loan(career, lender_id)
	if loan == null: return {"ok": false, "paid": 0, "reason": "You owe them nothing."}
	var amt: float = minf(J.rnd(float(amount) if (amount != null and str(amount).is_valid_float()) else 0.0), loan.owed)
	if amt <= 0: return {"ok": false, "paid": 0, "reason": "Pay something."}
	if amt > career.cash: return {"ok": false, "paid": 0, "reason": "You have %s." % money(maxf(0.0, career.cash))}
	loan.owed -= amt
	var l = _lender(reg, lender_id)
	Ledger.pay(career, -amt, "Paid off %s" % (l.name if l != null else lender_id))
	if loan.owed <= 0: career.loans = career.loans.filter(func(x): return not is_same(x, loan))
	return {"ok": true, "paid": amt, "reason": ""}

## The start of a season: every loan's interest is added, then a payment is
## taken - what is owed over the seasons left, so it is clear at the end of
## its term. Taken even if it puts the bank in the red.
## Returns [{ lender, name, interest, payment, owed }]
static func service_loans(reg: Registry, career: Dictionary) -> Array:
	var out := []
	for loan in career.get("loans", []):
		var l = _lender(reg, loan.lender)
		if l == null: continue
		var interest := J.rnd(loan.owed * l.rate)
		loan.owed += interest
		var payment: float = minf(loan.owed, ceil(loan.owed / maxf(1.0, loan.seasonsLeft)))
		loan.owed -= payment
		loan.seasonsLeft = maxf(1.0, loan.seasonsLeft - 1)
		Ledger.pay(career, -payment, "%s: loan payment (%s interest)" % [l.name, money(interest)])
		out.append({"lender": l.id, "name": l.name, "interest": interest, "payment": payment, "owed": loan.owed})
	career.loans = career.get("loans", []).filter(func(x): return x.owed > 0)
	return out

# ---------------------------------------------------------------- the paddock market

## Market tunables, with defaults.
static func market_config(reg: Registry) -> Dictionary:
	var m: Dictionary = J.g(reg.economy, "market", {})
	var cfg := J.merge({"listings": 6, "sellPrice": [0.6, 0.95], "tierAbove": 1, "offerChance": 0.6, "buyPrice": [0.55, 0.85], "robotPrice": 0.55}, m)
	cfg.reputation = J.merge({"win": 250, "ko": 100, "title": 4000, "max": 40000}, m.get("reputation", {}))
	return cfg

## One market day: a new one after every fight the player fights, and every season.
static func _market_key(career: Dictionary) -> String:
	return "%s:%s" % [J.s(career.seasonIndex), J.s(J.path(career, ["stats", "fights"], 0))]

static func _between(rng: Rng, range_v: Array) -> float:
	return range_v[0] + rng.next() * (range_v[1] - range_v[0])

static func _round10(n: float) -> float:
	return maxf(10.0, J.rnd(n / 10.0) * 10.0)

## The AI robots in the field, nearest the player's league first (the teams the player meets).
static func _sellers(reg: Registry, career: Dictionary) -> Array:
	var order: Array = reg.league.leagues
	var mine: int = order.find(_league_of(career))
	var out := []
	for id in career.membership:
		if id != career.playerId and reg.has_robot(id):
			out.append({"id": id, "gap": absi(order.find(career.membership[id]) - mine)})
	return J.sorted(out, func(a, b):
		if a.gap != b.gap: return a.gap - b.gap
		return -1 if a.id < b.id else 1)

## A team's robot as it races now (its off-season upgrades included).
static func _team_def(reg: Registry, career: Dictionary, id) -> Dictionary:
	var d := Evolution.evolved_def(reg, career, id).duplicate()
	d.league = career.membership.get(id)
	return d

static func _build_ids(build: Dictionary) -> Array:
	var out := []
	for v in build.values():
		if v is Array: out.append_array(v)
		else: out.append(v)
	return out

## Today's market, generated on first look each market day (and kept, so a
## part bought is gone).
static func market_of(reg: Registry, career: Dictionary) -> Dictionary:
	var key := _market_key(career)
	if J.path(career, ["market", "key"]) == key: return career.market
	var cfg := market_config(reg)
	var rng := Rng.new(Rng.hash_seed("%s:market:%s" % [J.s(career.seed), key]))
	var shop_tier := Garage.shop_tier(reg, career)
	var max_tier: float = shop_tier + cfg.tierAbove
	var pool := _sellers(reg, career)
	# Mostly teams from the player's own league and the one either side.
	var near := pool.filter(func(s): return s.gap <= 1)
	var listings := []
	var seen := {}
	var tries := 0
	while listings.size() < cfg.listings and tries < 80:
		tries += 1
		var src: Array = near if (near.size() > 0 and rng.next() < 0.85) else pool
		var fi := int(floor(rng.next() * src.size()))
		if src.is_empty(): break
		var from: Dictionary = src[fi]
		var def := _team_def(reg, career, from.id)
		var fitted := []
		for k in FITTINGS:
			if J.truthy(def.build.get(k)): fitted.append(def.build[k])
		fitted.append_array(def.build.get("armor", []))
		var pi := int(floor(rng.next() * fitted.size()))
		var part_id = fitted[pi] if pi < fitted.size() else null
		if not J.truthy(part_id) or seen.has(part_id) or not reg.has_part(part_id): continue
		var part := reg.part(part_id)
		if J.g(part, "tier", 1) > max_tier: continue
		seen[part_id] = true
		# A team with money in the bank holds out for its price; a broke one sells cheap.
		var bank: float = J.path(career, ["evolution", from.id, "bank"], 0.0)
		var f: float = minf(cfg.sellPrice[1], _between(rng, cfg.sellPrice) + (0.08 if bank > 4000 else 0.0))
		listings.append({
			"id": "l%d" % listings.size(), "partId": part_id, "sellerId": from.id,
			"team": def.team if J.truthy(def.get("team")) else reg.robot(from.id).get("team"), "robot": def.name,
			"league": career.membership[from.id], "price": _round10(part.cost * f), "list": part.cost,
			"locked": J.g(part, "tier", 1) > shop_tier,
		})
	career.market = {"key": key, "listings": listings, "taken": []}
	return career.market

## Buy a part an AI team is selling: it goes into the garage as a spare.
static func buy_listing(reg: Registry, career: Dictionary, listing_id) -> Dictionary:
	var m := market_of(reg, career)
	var l = J.find(m.listings, func(x): return x.id == listing_id)
	if l == null: return {"ok": false, "reason": "That part has gone."}
	if l.price > career.cash: return {"ok": false, "reason": "It costs %s; you have %s." % [money(l.price), money(maxf(0.0, career.cash))]}
	var g := Garage.garage_of(reg, career)
	g.owned[l.partId] = g.owned.get(l.partId, 0) + 1
	Ledger.pay(career, -l.price, "Bought a %s from %s" % [reg.part(l.partId).name, l.team])
	m.listings = m.listings.filter(func(x): return x.id != listing_id)
	return {"ok": true, "reason": "", "listing": l}

## What AI teams will pay for the player's spares today: at most one offer a
## part, better than the shop's resale.
## [{ partId, count, price, team, robotId, resale }]
static func spares_offers(reg: Registry, career: Dictionary) -> Array:
	var cfg := market_config(reg)
	var m := market_of(reg, career)
	var pool := _sellers(reg, career)
	var out := []
	var sp := Garage.spares(reg, career)
	var ids := sp.keys()
	ids.sort()
	for part_id in ids:
		var count = sp[part_id]
		if not reg.has_part(part_id): continue
		var rng := Rng.new(Rng.hash_seed("%s:offer:%s:%s" % [J.s(career.seed), m.key, part_id]))
		var resale := Garage.resale_of(reg, part_id)
		var offered: bool = rng.next() < cfg.offerChance and not m.taken.has(part_id) and pool.size() > 0
		if not offered:
			out.append({"partId": part_id, "count": count, "price": null, "team": null, "robotId": null, "resale": resale})
			continue
		# A team that could use one: the same kind of part on its robot if any does.
		var kind: String = reg.part(part_id).category
		var users := pool.filter(func(s):
			if s.gap > 1: return false
			for p in _build_ids(_team_def(reg, career, s.id).build):
				if reg.has_part(p) and reg.part(p).category == kind: return true
			return false)
		var from: Array = users if users.size() > 0 else pool
		var buyer: Dictionary = from[int(floor(rng.next() * from.size()))]
		var price: float = maxf(resale + 10.0, _round10(reg.part(part_id).cost * _between(rng, cfg.buyPrice)))
		var bd := _team_def(reg, career, buyer.id)
		out.append({"partId": part_id, "count": count, "price": price, "team": bd.team if J.truthy(bd.get("team")) else reg.robot(buyer.id).get("team"), "robotId": buyer.id, "resale": resale})
	return out

## Take a team's offer for one spare.
static func sell_to_team(reg: Registry, career: Dictionary, part_id) -> Dictionary:
	var o = J.find(spares_offers(reg, career), func(x): return x.partId == part_id)
	if o == null or not J.truthy(o.price): return {"ok": false, "reason": "Nobody is offering for that today."}
	var g := Garage.garage_of(reg, career)
	g.owned[part_id] -= 1
	if g.owned[part_id] <= 0: g.owned.erase(part_id)
	Ledger.pay(career, o.price, "Sold a %s to %s" % [reg.part(part_id).name, o.team])
	market_of(reg, career).taken.append(part_id)
	return {"ok": true, "reason": "", "price": o.price, "team": o.team}

# ---------------------------------------------------------------- selling the robot

## The stock kit the player fights with after selling their robot: the starting robot's parts.
static func _stock_kit(reg: Registry) -> Dictionary:
	return J.clone(reg.robot(reg.playerId).build)

## What a full repair of the player's robot would cost (list, before any discount).
static func _damage_value(reg: Registry, career: Dictionary) -> float:
	var g := Garage.garage_of(reg, career)
	var def := Garage.player_def(reg, career)
	var total := 0.0
	var units := [[Build.assemble_robot(reg, def), g.get("condition")]]
	if def.get("partner") != null: units.append([Build.assemble_partner(reg, def), g.get("partnerCondition")])
	for u in units:
		var a: Dictionary = u[0]
		if u[1] is Dictionary:
			for k in u[1]: a.condition[k] = u[1][k]
		for r in Condition.condition_report(a, reg.rules): total += r.repairCost
	return J.rnd(total * J.path(reg.economy, ["repairs", "labourMultiplier"], 1.0))

## The best offer for the player's robot as it stands, and what selling it
## means: { buyerId, team, robot, price, parts, reputation, damage,
## kit: { buy, cost }, net, ok, reason }. The buyer is a team in the player's
## league (or below) with a weak robot; it races it from next season.
static func robot_offer(reg: Registry, career: Dictionary) -> Dictionary:
	var cfg := market_config(reg)
	var g := Garage.garage_of(reg, career)
	var order: Array = reg.league.leagues
	var mine: int = order.find(_league_of(career))
	var cands := []
	for id in career.membership:
		if id == career.playerId or not reg.has_robot(id): continue
		var li: int = order.find(career.membership[id])
		if li > mine or li < mine - 1: continue
		if J.some(career.get("robotSales", []), func(s): return s.status == "pending" and s.buyerId == id): continue
		cands.append({"id": id, "r": J.path(career, ["evolution", id, "rating"], reg.robot(id).get("rating"))})
	cands = J.sorted(cands, func(a, b):
		if a.r != b.r: return a.r - b.r
		return -1 if a.id < b.id else 1)
	var rng := Rng.new(Rng.hash_seed("%s:robotbuyer:%s" % [J.s(career.seed), _market_key(career)]))
	var bi := int(floor(rng.next() * mini(3, cands.size())))
	if cands.is_empty(): return {"ok": false, "reason": "No team is buying right now."}
	var buyer: Dictionary = cands[bi]
	var fitted := Garage.fitted_counts(g.build, J.path(g, ["partner", "build"]))
	var parts := 0.0
	for id in fitted:
		if reg.has_part(id): parts += reg.part(id).cost * fitted[id]
	var rec: Dictionary = J.g(g, "record", {"wins": 0, "kos": 0, "titles": 0})
	var reputation: float = minf(cfg.reputation.max, rec.wins * cfg.reputation.win + rec.kos * cfg.reputation.ko + rec.titles * cfg.reputation.title)
	var damage := _damage_value(reg, career)
	var price: float = maxf(500.0, J.rnd((parts * cfg.robotPrice + reputation - damage) / 100.0) * 100.0)
	# The kit to fight with afterwards: spares first, the rest from the shop.
	var left: Dictionary = g.owned.duplicate()
	for id in fitted: left[id] = left.get(id, 0) - fitted[id]
	var buy := []
	var cost := 0.0
	var kit := Garage.count_parts(_stock_kit(reg))
	for id in kit:
		var short: float = kit[id] - maxf(0.0, left.get(id, 0))
		if short > 0:
			buy.append({"id": id, "n": short, "name": reg.part(id).name})
			cost += Garage.price_of(reg, career, id) * short
	var net := price - cost
	var def := _team_def(reg, career, buyer.id)
	var reason := ""
	if career.get("pit") != null: reason = "Close the pit first - nobody buys a robot with the crew still working on it."
	elif career.cash + net < 0: reason = "The stock kit costs %s more than they pay, and you cannot cover it." % money(cost)
	return {"ok": reason == "", "reason": reason, "buyerId": buyer.id, "team": def.team if J.truthy(def.get("team")) else reg.robot(buyer.id).get("team"),
		"robot": def.name, "league": career.membership[buyer.id],
		"price": price, "parts": J.rnd(parts * cfg.robotPrice), "reputation": reputation, "damage": damage, "kit": {"buy": buy, "cost": cost}, "net": net}

## Sell the robot to the team that made the offer. It goes into the museum
## (sold, not retired), its parts go with it, and the player starts again on
## a stock kit named `new_name`. The buying team races it from next season,
## in place of its own robot (Career's deliver_sales, at the off-season).
static func sell_robot(reg: Registry, career: Dictionary, new_name) -> Dictionary:
	var o := robot_offer(reg, career)
	if not o.ok: return {"ok": false, "reason": o.reason}
	var g := Garage.garage_of(reg, career)
	var def := Garage.player_def(reg, career)
	var rec: Dictionary = J.g(g, "record", {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": career.seasonIndex})
	if g.get("museum") == null: g.museum = []
	var piece := {"name": g.name, "version": g.get("version"), "from": rec.get("since"), "to": career.seasonIndex}
	piece.merge(rec, true)
	piece.weapon = reg.part(g.build.weapon).name if J.truthy(g.build.get("weapon")) else "None"
	piece.livery = g.get("livery")
	piece.sold = {"team": o.team, "price": o.price, "season": career.seasonIndex}
	g.museum.append(piece)
	if career.get("robotSales") == null: career.robotSales = []
	career.robotSales.append({
		"def": {"name": def.name, "body": def.get("body"), "build": def.build, "livery": def.get("livery"), "personality": def.get("personality"),
			"archetype": def.get("archetype"), "version": def.get("version"), "partner": def.get("partner")},
		"buyerId": o.buyerId, "team": o.team, "season": career.seasonIndex, "price": o.price, "status": "pending", "newId": null,
	})
	# The parts go with the robot; the kit comes from spares and the shop.
	var fitted := Garage.fitted_counts(g.build, J.path(g, ["partner", "build"]))
	for id in fitted:
		g.owned[id] = g.owned.get(id, 0) - fitted[id]
		if g.owned[id] <= 0: g.owned.erase(id)
	var old_name: String = g.name
	Ledger.pay(career, o.price, "Sold %s to %s" % [old_name, o.team])
	for b in o.kit.buy:
		g.owned[b.id] = g.owned.get(b.id, 0) + b.n
		Ledger.pay(career, -Garage.price_of(reg, career, b.id) * b.n, "Stock kit: %s%s" % ["%sx " % J.num(b.n) if b.n > 1 else "", b.name])
	var fresh := Garage.new_garage(reg)
	var nm := str(new_name if new_name != null else "").strip_edges().substr(0, 28)
	g.name = nm if nm != "" else "%s II" % old_name
	g.body = fresh.body
	g.build = _stock_kit(reg)
	g.partner = null
	g.condition = {}
	g.partnerCondition = {}
	g.version = "1.0"
	g.log = []
	g.record = {"fights": 0, "wins": 0, "kos": 0, "titles": 0, "since": career.seasonIndex}
	career.prep = null
	career.market = null
	career.notices.append({"kind": "sponsor", "text": "%s bought %s for %s. It races for them from next season." % [o.team, def.name, money(o.price)]})
	return {"ok": true, "reason": "", "offer": o}
