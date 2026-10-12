// Reference output from the JavaScript game, for tests/run_tests.gd to match.
//   cd ~/Projects/robo-league && jsc -m ../robo-league-godot/tools/golden/dump1.js > ../robo-league-godot/tests/golden/core.json
import { loadRegistrySync } from "/Users/collin/Projects/robo-league/js/data/load.js";
import { makeRng, hashSeed } from "/Users/collin/Projects/robo-league/js/core/rng.js";
import { assembleRobot } from "/Users/collin/Projects/robo-league/js/logic/build.js";
import { buildShape, routeFittings } from "/Users/collin/Projects/robo-league/js/logic/shape.js";
import { resolveFight } from "/Users/collin/Projects/robo-league/js/logic/resolver.js";
import { aiProfile } from "/Users/collin/Projects/robo-league/js/logic/ai.js";

const reg = loadRegistrySync((p) => JSON.parse(readFile(p)), "data");
const out = { rng: {}, hash: {}, robots: {}, fights: [] };
for (const seed of [1, 12345, 4294967295]) {
  const r = makeRng(seed);
  out.rng[seed] = [r.next(), r.next(), r.next(), r.int(1, 6), r.shuffle([1, 2, 3, 4, 5, 6, 7])];
}
for (const s of ["a", "season:1:1", "resolve:7:grim_reaper:coldsnap", "layout:s1:rookie:A:0:x:y"]) out.hash[s] = hashSeed(s);
const fin = (x) => (Number.isFinite(x) ? x : null);
for (const def of reg.allRobots()) {
  const a = assembleRobot(reg, def);
  const sh = buildShape(a);
  const route = routeFittings(sh, a);
  const prof = aiProfile(def);
  out.robots[def.id] = {
    weightLb: a.weightLb, massKg: a.massKg, top: a.stats.topSpeedMps, fpw: a.stats.forcePerWheelN,
    pivot: fin(a.stats.pivotAuthority), energy: a.stats.weapon.energyJ, spinUp: fin(a.stats.weapon.spinUpS),
    cls: a.stats.weapon.class, selfRight: a.stats.selfRight.via, legal: a.legality.legal,
    errors: a.legality.errors, warnings: a.legality.warnings,
    invertible: sh.invertible, pieces: sh.pieces.map((p) => `${p.id}|${p.slot}|${p.role}|${p.points.length}|${route.get(p.id)}`),
    bmin: [sh.bounds.min.x, sh.bounds.min.y, sh.bounds.min.z], bmax: [sh.bounds.max.x, sh.bounds.max.y, sh.bounds.max.z],
    wcol: (sh.weapon?.colliders || []).map((c) => c.type), visual: sh.weapon?.visual?.kind ?? null,
    skill: prof.skill, herd: prof.herdBias,
  };
}
const bots = reg.allRobots();
const r = makeRng(99);
for (let k = 0; k < 600; k++) {
  const a = bots[Math.floor(r.next() * bots.length)], b = bots[Math.floor(r.next() * bots.length)];
  if (a.id === b.id) continue;
  const f = resolveFight(reg, a, b, { seed: k * 7 + 1 });
  out.fights.push({ a: a.id, b: b.id, seed: k * 7 + 1, w: f.winnerId, m: f.method, c: f.cause, t: f.elapsedS,
    da: f.sides[a.id].hpDealt, db: f.sides[b.id].hpDealt, ha: f.sides[a.id].hitsLanded, fa: f.sides[a.id].flips,
    ca: f.sides[a.id].condition, cb: f.sides[b.id].condition, votes: f.votes });
}
print(JSON.stringify(out));
