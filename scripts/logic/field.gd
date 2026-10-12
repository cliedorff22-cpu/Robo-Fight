## field.gd - the field changes over the years: drivers age and retire, teams
## retire robots and build new ones, and new teams come up through Rookie.
##
## Every AI robot has a DRIVER with a career length drawn when they start
## (`careerSpan`: most around 30 seasons, a few short, none past 60) and a
## count of seasons driven; the robot itself has a working life. Each
## off-season (Career.start_next_season -> age_field):
##   - every driver gets a season older: improving early, slipping late;
##   - a driver at the end of their span RETIRES. Their team either puts a new
##     driver in the robot, or folds - and a NEW TEAM joins the Rookie league;
##   - a robot past its working life is retired by its team, who build a new one;
##   - the leagues are put back to 30 each.
##
## New robots (make_newcomer) are generated from the field's own proven
## designs with their own name, team, paint and driver, and kept in the
## career (`career.newcomers`); a career registers them with the registry
## whenever it loads (register_career_robots). The data files never change.
class_name Field

const FIRST := ["Alex", "Sam", "Jordan", "Casey", "Riley", "Morgan", "Taylor", "Jamie", "Drew", "Quinn", "Avery", "Reese", "Rowan", "Kai", "Sasha",
	"Dana", "Robin", "Jesse", "Emerson", "Hayden", "Parker", "Skyler", "Logan", "Charlie", "Frankie", "Remy", "Noor", "Mika", "Ari", "Toni",
	"Marisol", "Dev", "Priya", "Tomas", "Ines", "Kenji", "Lena", "Omar", "Bea", "Hugo", "Yara", "Felix", "Zoe", "Ravi", "Mei", "Otto", "Nia", "Luca"]
const LAST := ["Reyes", "Okafor", "Lindqvist", "Nakamura", "Brennan", "Castillo", "Hargreaves", "Moreau", "Patel", "Kowalski", "Adeyemi", "Fischer",
	"Delgado", "Whitlock", "Sorensen", "Achebe", "Marchetti", "Haddad", "Kim", "Novak", "Quintero", "Abernathy", "Takahashi", "Mbeki", "Larsen",
	"Petrov", "Oyelaran", "Vance", "Iwata", "Carvalho", "Bishop", "Ferreira", "Gallagher", "Dubois", "Ortega", "Schmidt", "Sato", "Kaur", "Rossi"]
const ADJ := ["Iron", "Rust", "Static", "Molten", "Hollow", "Crimson", "Feral", "Silent", "Brutal", "Copper", "Thunder", "Savage", "Neon", "Grim",
	"Velvet", "Rabid", "Frozen", "Gravel", "Scrap", "Wicked", "Mighty", "Lucky", "Rogue", "Cobalt", "Tungsten", "Riot", "Jagged", "Furious", "Spare"]
const NOUN := ["Badger", "Anvil", "Gremlin", "Piston", "Hornet", "Wrecker", "Guillotine", "Kodiak", "Ratchet", "Cyclone", "Mantis", "Bulldozer",
	"Banshee", "Raptor", "Gauntlet", "Grinder", "Thresher", "Warthog", "Comet", "Jackal", "Sprocket", "Ironside", "Havoc", "Lockjaw", "Torque",
	"Marauder", "Specter", "Wolverine", "Monsoon", "Zealot", "Clamshell", "Brick", "Tempest", "Viper", "Ox", "Juggernaut", "Goliath", "Pinball"]
const SOLO := ["Bedlam", "Kerfuffle", "Mayhem", "Ruckus", "Tantrum", "Shrapnel", "Wreckoning", "Clatter", "Bonkers", "Haywire", "Kablooey",
	"Malarkey", "Gizmo", "Pandemonium", "Hullabaloo", "Ballyhoo", "Calamity", "Rumpus", "Fracas", "Skirmish", "Smithereens", "Kaboodle"]
const TEAM := ["Robotics", "Garage", "Works", "Fabrication", "Racing", "Machine Shop", "Engineering", "Combat Labs", "Collective", "Foundry"]
const PATTERNS := ["stripes", "band", "flames", "split", "hazard", "checker", "camo", "teeth", "chevron", "bolt", "spots", "scales", "tiger", "pixels", "bricks"]
const PALETTES := [
	["#c0392b", "#17191d", "#f1c40f"], ["#1f6feb", "#0d1117", "#f0f6fc"], ["#2ecc71", "#111a14", "#e8f5e9"], ["#8e44ad", "#16101c", "#f39c12"],
	["#e67e22", "#1b120a", "#ecf0f1"], ["#16a085", "#0c1615", "#f4d03f"], ["#d35400", "#212121", "#bdc3c7"], ["#2c3e50", "#ecf0f1", "#e74c3c"],
	["#f1c40f", "#1a1a1a", "#c0392b"], ["#ff4fa3", "#14101a", "#7ee6ff"], ["#7f8c8d", "#111111", "#ff6b00"], ["#00b894", "#2d3436", "#fdcb6e"],
]
const WEAPON_MIX := [["spinner_v", 22], ["spinner_h", 16], ["drum", 12], ["hammer", 12], ["static", 10], ["flipper", 10], ["lifter", 9], ["crusher", 9]]

## Field tunables (league.json `field`), with defaults.
static func field_config(reg: Registry) -> Dictionary:
	var f: Dictionary = J.g(reg.league, "field", {})
	return {
		"driverSpan": J.merge({"min": 4, "mode": 30, "max": 60}, f.get("driverSpan", {})),
		"robotSpan": J.merge({"min": 5, "mode": 12, "max": 28}, f.get("robotSpan", {})),
		"foldChance": J.g(f, "foldChance", 0.45),          # a driver retiring takes the robot with them
		# A driver's POTENTIAL - how good they can become - is their own.
		"potential": J.merge({"min": 30, "mode": 62, "max": 99}, f.get("potential", {})),
		"startShare": J.g(f, "startShare", [0.5, 0.75]),
		"aging": J.merge({"learnYears": 0.25, "declineYears": 0.8, "decline": 2.5}, f.get("aging", {})),
	}

## A triangular draw: most often near `mode`, never below `min` or above `max`.
static func triangular(rng: Rng, o: Dictionary) -> float:
	var mn: float = o.min
	var mode: float = o.mode
	var mx: float = o.max
	var u := rng.next()
	var c := (mode - mn) / (mx - mn)
	var x := mn + sqrt(u * (mx - mn) * (mode - mn)) if u < c else mx - sqrt((1.0 - u) * (mx - mn) * (mx - mode))
	return J.rnd(x)

static func _pick(rng: Rng, arr: Array):
	return arr[int(floor(rng.next() * arr.size()))]

## A driver starting out: a name, a career span and a potential.
static func _new_driver(rng: Rng, cfg: Dictionary) -> Dictionary:
	var name := driver_name(rng)
	var span := triangular(rng, cfg.driverSpan)
	var potential := triangular(rng, cfg.potential)
	return {"name": name, "span": span, "years": 0, "gen": 1, "potential": potential}

## Where a new driver starts: a share of their potential.
static func _start_rating(rng: Rng, cfg: Dictionary, potential: float) -> float:
	return J.rnd(potential * (cfg.startShare[0] + rng.next() * (cfg.startShare[1] - cfg.startShare[0])))

static func driver_name(rng: Rng) -> String:
	var first: String = _pick(rng, FIRST)
	var last: String = _pick(rng, LAST)
	return "%s %s" % [first, last]

static func _robot_name(rng: Rng, taken: Dictionary) -> String:
	for i in 40:
		var n: String
		if rng.next() < 0.35: n = _pick(rng, SOLO)
		else:
			var adj: String = _pick(rng, ADJ)
			var noun: String = _pick(rng, NOUN)
			n = "%s %s" % [adj, noun]
		if not taken.has(n.to_lower()): return n
	return "Unit %d" % int(floor(rng.next() * 9000.0 + 1000.0))

# ---------------------------------------------------------------- drivers

## Everyone in the field gets a driver: a name, a career length and how far
## into it they are (a field already racing has veterans and new faces).
static func seed_drivers(reg: Registry, career: Dictionary) -> void:
	var cfg := field_config(reg)
	if career.get("drivers") == null: career.drivers = {}
	if career.get("robotLife") == null: career.robotLife = {}
	for id in career.membership.keys():
		if id == career.playerId: continue
		var rng := Rng.new(Rng.hash_seed("%s:driver:%s" % [J.s(career.seed), id]))
		if career.drivers.get(id) == null:
			var span := triangular(rng, cfg.driverSpan)
			# The field's drivers are as good as their robot files say, with room to grow.
			var potential: float = minf(99.0, reg.robot(id).rating + J.path(reg.league, ["evolution", "rating", "talent"], 12.0))
			var name := driver_name(rng)
			career.drivers[id] = {"name": name, "span": span, "years": floor(rng.next() * span * 0.9), "gen": 1, "potential": potential}
		if career.robotLife.get(id) == null:
			var span := triangular(rng, cfg.robotSpan)
			career.robotLife[id] = {"span": span, "age": floor(rng.next() * span * 0.85)}

## A driver's rating change for a season of age: learning early, slipping late.
static func aging_delta(reg: Registry, d: Dictionary) -> float:
	var a: Dictionary = field_config(reg).aging
	var f: float = d.years / maxf(1.0, d.span)
	if f < a.learnYears: return 2.0
	if f > a.declineYears: return -a.decline * (1.0 + (f - a.declineYears) * 4.0)
	return 0.0

# ---------------------------------------------------------------- the off-season

## Age the field, retire who is due, bring in the new, and put every league
## back to 30. Mutates the career; returns the report lines for the results.
static func age_field(reg: Registry, career: Dictionary, season: Dictionary) -> Dictionary:
	var cfg := field_config(reg)
	seed_drivers(reg, career)
	var rng_teams := Rng.new(Rng.hash_seed("%s:field:%s:newteams" % [J.s(career.seed), J.s(season.index)]))
	var report := {"retiredDrivers": [], "newDrivers": [], "retiredRobots": [], "newRobots": [], "promoted": []}
	if career.get("evolution") == null: career.evolution = {}
	if career.get("retired") == null: career.retired = []

	for id in career.membership.keys():
		if id == career.playerId: continue
		# Each robot's off-season draws from its own stream, so one team's
		# news never shifts another's.
		var rng := Rng.new(Rng.hash_seed("%s:field:%s:%s" % [J.s(career.seed), J.s(season.index), id]))
		var d: Dictionary = career.drivers[id]
		var life: Dictionary = career.robotLife[id]
		d.years += 1
		life.age += 1
		# The driver's age moves their rating (evolution.gd handles results).
		if career.evolution.get(id) == null: career.evolution[id] = {"version": 1, "bank": 0, "history": []}
		var e: Dictionary = career.evolution[id]
		var r0: float = J.g(e, "rating", reg.robot(id).rating)
		e.rating = J.rnd(maxf(5.0, minf(99.0, r0 + aging_delta(reg, d))))

		if d.years >= d.span:
			report.retiredDrivers.append({"id": id, "name": d.name, "years": d.years, "robot": reg.robot(id).name})
			career.retired.append({"kind": "driver", "season": season.index, "name": d.name, "years": d.years, "robot": id})
			if rng.next() < cfg.foldChance:
				# The team folds: the robot goes with its driver.
				_retire_robot(reg, career, id, season, report, "its team folded when " + d.name + " retired")
				continue
			# A new driver takes the controls.
			var nd := _new_driver(rng, cfg)
			nd.gen = _nz(d.get("gen"), 1) + 1
			career.drivers[id] = nd
			e.rating = _start_rating(rng, cfg, nd.potential)
			var mem = J.path(career, ["ai", id])
			if mem != null:
				# A new driver has to learn the robot.
				for v in mem.get("vs", {}).values():
					if v.get("t") != null:
						for k in v.t.keys(): v.t[k] *= 0.4
			report.newDrivers.append({"id": id, "name": nd.name, "robot": reg.robot(id).name, "follows": d.name})
			continue
		if life.age >= life.span:
			# The robot has had its day: the team builds a new one and keeps its place.
			var league = career.membership[id]
			var rating = e.rating
			var old_name: String = reg.robot(id).name
			var old_team = reg.robot(id).get("team")
			_retire_robot(reg, career, id, season, report, "replaced by its team's new robot")
			# Same team, same driver (and their rating), new robot.
			var nc := make_newcomer(reg, career, {"league": league, "team": old_team, "driver": d, "rating": rating, "rng": rng, "season": season})
			career.membership[nc.id] = league
			report.newRobots.append({"id": nc.id, "name": nc.name, "team": nc.team, "league": league, "replaces": old_name, "replacesId": id})
	_rebalance(reg, career, season, rng_teams, report)
	return report

static func _nz(v, def: float) -> float:
	if v == null: return def
	var f := float(v)
	return def if f == 0.0 else f

static func _retire_robot(reg: Registry, career: Dictionary, id, season: Dictionary, report: Dictionary, why: String) -> void:
	var def := reg.robot(id)
	report.retiredRobots.append({"id": id, "name": def.name, "why": why})
	career.retired.append({"kind": "robot", "season": season.index, "id": id, "name": def.name, "why": why, "league": career.membership.get(id)})
	if career.retired.size() > 400: career.retired = career.retired.slice(career.retired.size() - 400)
	career.membership.erase(id)
	# A retired robot keeps only its name (the history and the Hall of Fame
	# still mention it); everything about how it fought goes.
	for k in ["wear", "ai", "drivers", "robotLife", "evolution"]:
		if career.get(k) is Dictionary: career[k].erase(id)
	var n = J.path(career, ["newcomers", id])
	if n != null:
		career.newcomers[id] = {"id": id, "name": n.name, "team": n.get("team"), "newcomer": true, "retired": season.index, "livery": n.get("livery"), "joined": n.get("joined")}
		reg.add_robot(career.newcomers[id])

static func _count(career: Dictionary, lg) -> int:
	var n := 0
	for v in career.membership.values():
		if v == lg: n += 1
	return n

## Every league back to 30: from the top down, a league that is short takes
## the best robots of the one below (by current rating); Rookie takes new teams.
static func _rebalance(reg: Registry, career: Dictionary, season: Dictionary, rng: Rng, report: Dictionary) -> void:
	var leagues: Array = reg.league.leagues                       # bottom to top
	var size: int = int(J.path(reg.league, ["league", "groups"], 6) * J.path(reg.league, ["league", "groupSize"], 5))
	for i in range(leagues.size() - 1, 0, -1):
		var lg = leagues[i]
		var below = leagues[i - 1]
		while _count(career, lg) < size:
			var cands := []
			for id in career.membership:
				if career.membership[id] == below and id != career.playerId:
					cands.append({"id": id, "r": J.path(career, ["evolution", id, "rating"], reg.robot(id).rating)})
			cands = J.sorted(cands, func(a, b): return b.r - a.r)
			if cands.is_empty(): break
			career.membership[cands[0].id] = lg
			report.promoted.append({"id": cands[0].id, "name": reg.robot(cands[0].id).name, "to": lg})
	var rookie = leagues[0]
	while _count(career, rookie) < size:
		var nc := make_newcomer(reg, career, {"league": rookie, "rng": rng, "season": season})
		career.membership[nc.id] = rookie
		report.newRobots.append({"id": nc.id, "name": nc.name, "team": nc.team, "league": rookie, "newTeam": true})

# ---------------------------------------------------------------- new robots

static func _taken_names(reg: Registry, career: Dictionary, except_id = null) -> Dictionary:
	var taken := {}
	for r in reg.roster():
		if r.id != except_id: taken[str(r.name).to_lower()] = true
	for r in career.newcomers.values():
		if r.id != except_id: taken[str(r.name).to_lower()] = true
	return taken

static func _build_part_ids(build: Dictionary) -> Array:
	var out := []
	for v in build.values():
		if v is Array: out.append_array(v)
		else: out.append(v)
	return out

## A new robot for the field, built from a design that already works: a robot
## of the chosen weapon class from the field, re-armoured, re-shaped and
## repainted, with its own name, team and driver.
##   o: { league = "rookie", team, driver, rating, rng, season }
static func make_newcomer(reg: Registry, career: Dictionary, o: Dictionary) -> Dictionary:
	var league: String = J.g(o, "league", "rookie")
	var team = o.get("team")
	var driver = o.get("driver")
	var rating = o.get("rating")
	var season: Dictionary = o.season
	var rng: Rng = o.rng
	if career.get("newcomers") == null: career.newcomers = {}
	if career.get("drivers") == null: career.drivers = {}
	if career.get("robotLife") == null: career.robotLife = {}
	var cfg := field_config(reg)
	var n: int = career.newcomers.size() + 1
	var id := "nc%s_%d" % [J.s(season.index), n]
	# Names are unique within this career's field.
	var taken := _taken_names(reg, career)
	rng = Rng.new(Rng.hash_seed("%s:newcomer:%s:%d" % [J.s(career.seed), id, int(floor(rng.next() * 1e9))]))
	# The weapon, weighted toward what the sport actually builds.
	var total := 0.0
	for wm in WEAPON_MIX: total += wm[1]
	var roll := rng.next() * total
	var cls: String = WEAPON_MIX[0][0]
	for wm in WEAPON_MIX:
		roll -= wm[1]
		if roll <= 0:
			cls = wm[0]
			break
	var tier: float = {"rookie": 1, "pro": 2, "elite": 3, "world": 3}.get(league, 1)
	var plain := reg.roster().filter(func(r): return r.get("partner") == null and Workshop.weapon_class_of(reg, r.build) == cls)
	var pool := plain.filter(func(r):
		for pid in _build_part_ids(r.build):
			if reg.has_part(pid) and J.g(reg.part(pid), "tier", 1) > tier: return false
		return true)
	if pool.is_empty(): pool = plain
	var seed_bot: Dictionary
	var pick_i := int(floor(rng.next() * pool.size()))
	if pool.size() > 0: seed_bot = pool[pick_i]
	else: seed_bot = reg.robot(reg.playerId)
	var build: Dictionary = J.clone(seed_bot.build)
	# Its own armour: each panel swapped for another of the same face, at random.
	var new_armor := []
	for pid in build.get("armor", []):
		var face: String = reg.part(pid).spec.slot
		var opts := Workshop.parts_for(reg, "armor", face).filter(func(p): return J.g(p, "tier", 1) <= tier)
		if opts.size() > 0 and rng.next() < 0.6: new_armor.append(opts[int(floor(rng.next() * opts.size()))].id)
		else: new_armor.append(pid)
	build.armor = new_armor
	# Its own shape.
	var mounts: Array = Workshop.MOUNTS.get(cls, ["front"])
	var tpl: String = _pick(rng, Workshop.TEMPLATES)
	var mnt: String = _pick(rng, mounts)
	var body := {"template": tpl, "mount": mnt, "extras": []}
	var seed_mount = J.path(seed_bot, ["body", "mount"])
	if seed_mount == "shell" or seed_mount == "lid" or seed_mount == "overhead":
		body.mount = seed_mount
		body.template = seed_bot.body.get("template")
	if rng.next() < 0.3:
		var ex_type: String = ["forks", "plow", "spikes", "fin", "horns", "eyes", "bumper"][int(floor(rng.next() * 7.0))]
		body.extras = Workshop.uniq_extras([{"type": ex_type}])
	body = Workshop.fit_body(reg, body, build)
	var design = Workshop.fit_within(reg, {"build": build, "body": body}, ["rear", "top", "side"])
	if design == null: design = {"build": seed_bot.build, "body": seed_bot.get("body")}
	var pal: Array = _pick(rng, PALETTES)
	var name := _robot_name(rng, taken)
	var driver_nm: String = driver.name if (driver != null and J.truthy(driver.get("name"))) else driver_name(rng)
	var surname: String = driver_nm.split(" ")[-1]
	var personality: String = ["aggressive", "defensive", "opportunistic"][int(floor(rng.next() * 3.0))]
	var team_name: String
	if J.truthy(team): team_name = team
	else:
		var first_word: String = surname if rng.next() < 0.5 else _pick(rng, NOUN)
		var second: String = _pick(rng, TEAM)
		team_name = "%s %s" % [first_word, second]
	var pattern: String = _pick(rng, PATTERNS)
	var def := {
		"schema": "robot/1", "id": id, "name": name, "number": 200 + n, "origin": "newcomer", "newcomer": true,
		"archetype": "wedge" if cls == "static" else cls, "league": league,
		"rating": 50,   # replaced below from the driver's potential
		"personality": personality,
		"team": team_name,
		"inspiredBy": null, "joined": season.index,
		"livery": {"primary": pal[0], "secondary": pal[1], "accent": pal[2], "pattern": pattern},
		"body": design.body, "build": design.build,
	}
	career.drivers[id] = driver.duplicate() if driver != null else _new_driver(rng, cfg)
	def.rating = rating if rating != null else _start_rating(rng, cfg, J.g(career.drivers[id], "potential", 60.0))
	career.newcomers[id] = def
	reg.add_robot(def)
	career.robotLife[id] = {"span": triangular(rng, cfg.robotSpan), "age": 0}
	return def

## A team brings in a robot it bought (the player's, sold on the market -
## market.gd): its own robot is retired and the bought one takes its place,
## its league and its driver. `design` is { name, body, build, livery,
## personality, archetype, partner }. Returns the new robot def.
static func adopt_robot(reg: Registry, career: Dictionary, old_id, design: Dictionary, season: Dictionary, report: Dictionary, why: String) -> Dictionary:
	if career.get("newcomers") == null: career.newcomers = {}
	var league = career.membership[old_id]
	var old := reg.robot(old_id)
	var od = J.path(career, ["drivers", old_id])
	var driver = od.duplicate() if od != null else null
	var rating = J.path(career, ["evolution", old_id, "rating"], old.get("rating"))
	_retire_robot(reg, career, old_id, season, report, why)
	var n: int = career.newcomers.size() + 1
	while career.newcomers.has("nc%s_%d" % [J.s(season.index), n]): n += 1
	var id := "nc%s_%d" % [J.s(season.index), n]
	# Its name stays its own unless the field already has one like it.
	var taken := _taken_names(reg, career, id)
	var name: String = "%s II" % design.name if taken.has(str(design.name).to_lower()) else str(design.name)
	var def := {
		"schema": "robot/1", "id": id, "name": name, "number": 200 + n, "origin": "newcomer", "newcomer": true, "formerPlayer": true,
		"archetype": design.get("archetype"), "league": league, "rating": rating,
		"personality": design.personality if J.truthy(design.get("personality")) else old.get("personality"),
		"team": old.get("team"), "inspiredBy": null, "joined": season.index,
		"livery": J.g(design, "livery", {}), "body": design.get("body"), "build": design.build,
	}
	if design.get("partner") != null: def.partner = design.partner
	if career.get("drivers") == null: career.drivers = {}
	if career.get("robotLife") == null: career.robotLife = {}
	career.drivers[id] = driver if driver != null else _new_driver(Rng.new(Rng.hash_seed("%s:driver:%s" % [J.s(career.seed), id])), field_config(reg))
	career.robotLife[id] = {"span": triangular(Rng.new(Rng.hash_seed("%s:life:%s" % [J.s(career.seed), id])), field_config(reg).robotSpan), "age": 0}
	career.newcomers[id] = def
	reg.add_robot(def)
	career.membership[id] = league
	return def

## Register a career's own robots with the registry (call whenever a career is loaded).
static func register_career_robots(reg: Registry, career) -> void:
	if not (career is Dictionary): return
	for def in career.get("newcomers", {}).values(): reg.add_robot(def)
