// Tournament mode, the Hall of Fame, the commentary and the build advisor,
// as reference for tests/run_tests.gd.
//   cd ~/Projects/robo-league && jsc -m ../robo-league-godot/tools/golden/dump3.js > ../robo-league-godot/tests/golden/extras.json
import { loadRegistrySync } from "/Users/collin/Projects/robo-league/js/data/load.js";
import { makeRng } from "/Users/collin/Projects/robo-league/js/core/rng.js";
import * as C from "/Users/collin/Projects/robo-league/js/logic/career.js";
import { makeCup, advanceCup, cupRanking, cupTables, cupArena, nextCupFight, simulateCupFight, cupStageLabel } from "/Users/collin/Projects/robo-league/js/logic/cup.js";
import { careerEntry, induct, emptyHall } from "/Users/collin/Projects/robo-league/js/logic/halloffame.js";
import { makeCommentary } from "/Users/collin/Projects/robo-league/js/logic/commentary.js";
import { advise, parseBrief } from "/Users/collin/Projects/robo-league/js/logic/advisor.js";
import { makeBackup, readBackup, describeBackup } from "/Users/collin/Projects/robo-league/js/logic/savefile.js";
import { catalog, filterCatalog, specCard, scouting } from "/Users/collin/Projects/robo-league/js/logic/catalog.js";
import { candidates, slotsOf, summarize } from "/Users/collin/Projects/robo-league/js/logic/workshop.js";
import { applyDesign, garageOf, sellPart, spares } from "/Users/collin/Projects/robo-league/js/logic/garage.js";
import { conditionReport } from "/Users/collin/Projects/robo-league/js/logic/condition.js";
import { assembleRobot } from "/Users/collin/Projects/robo-league/js/logic/build.js";

const reg = loadRegistrySync((p) => JSON.parse(readFile(p)), "data");
const out = {};
const copy = (x) => JSON.parse(JSON.stringify(x));

// ---- cups
out.cups = [];
for (const o of [
  { format: "knockout", size: 16, fill: "top", seed: 5 },
  { format: "groups", size: 16, fill: "random", seed: 9 },
  { format: "knockout", size: 8, fill: "rookie", seed: 2, players: [{ name: "Ann", robot: "grim_reaper" }, { name: "Bo", robot: "coldsnap" }] },
  { format: "giantNut", seed: 4 },
]) {
  const cup = makeCup(reg, o);
  advanceCup(reg, cup);
  const steps = [];
  let guard = 0;
  while (!cup.done && guard++ < 200) {
    const f = nextCupFight(cup);
    if (!f) break;
    steps.push({ id: f.id, label: cupStageLabel(cup, f), arena: cupArena(reg, cup, f), r: simulateCupFight(reg, cup, f.id).winnerId });
  }
  out.cups.push({ o, entrants: cup.entrants, champion: cup.champion, ranking: cupRanking(cup).slice(0, 12), log: cup.log.length,
    tables: copy(cupTables(cup)), steps, totalRounds: cup.totalRounds });
}

// ---- catalog and workshop
out.catalog = catalog(reg).slice(0, 15).map((e) => `${e.id}|${e.league}|${e.archetype}`);
out.filtered = filterCatalog(catalog(reg), { league: "elite", query: "spin" }).map((e) => e.id);
out.cards = ["grim_reaper", "castor_pollux", "player_default", "hex_physician", "bricklayer"].map((id) => specCard(reg, id));
out.scouting = ["grim_reaper", "coldsnap", "valhalla", "molar_patrol"].map((id) => scouting(reg, reg.robot(id)));
const base = reg.robot(reg.playerId);
const design = { name: base.name, body: { template: "wedge", mount: "front", extras: [] }, build: base.build, livery: base.livery, personality: base.personality };
out.slots = slotsOf(reg, design.build).map((s) => `${s.key}|${s.partId}|${s.label}|${s.optional}`);
out.candidates = {};
for (const key of ["weapon", "motor", "armor:front:0", "chassis"]) {
  out.candidates[key] = candidates(reg, null, design, key).map((c) => ({ id: c.part.id, fitted: c.fitted, legal: c.legal, delta: c.delta, price: c.price, w: c.after && c.after.weightLb }));
}
out.summary = summarize(reg, reg.robot("grim_reaper"));

// ---- a career: garage, hall of fame, backup, advisor
const career = C.newCareer(reg, { seed: 3, team: "Scrap Yard" });
const g = garageOf(reg, career);
const a1 = applyDesign(reg, career, { build: { ...g.build, weapon: "spinner_v_small", weaponMotor: "wmotor_light" }, name: "  Buzzkill  " });
out.apply1 = { ok: a1.ok, errors: a1.errors, cost: a1.cost, cash: career.cash, version: g.version, log: copy(g.log), owned: copy(g.owned) };
const a2 = applyDesign(reg, career, { build: { ...g.build, armor: ["armor_ar500_front", "armor_ar500_front"] } });
out.apply2 = { ok: a2.ok, errors: a2.errors };
out.spares = copy(spares(reg, career));
const firstSpare = Object.keys(spares(reg, career))[0];
out.sell = firstSpare ? sellPart(reg, career, firstSpare) : null;
let guard = 0;
while (!career.seasonOver && guard++ < 400) {
  C.advanceCareer(reg, career);
  if (C.nextFight(reg, career)) { C.simulatePlayerFight(reg, career); C.doPit(reg, career, C.pitAutoPlan(reg, career)); }
}
out.entry = copy(careerEntry(reg, career));
out.hall = copy(induct(reg, emptyHall(), career));
const text = makeBackup({ career, hall: out.hall, settings: { difficulty: "hard", bloom: false, volume: 0.5, junk: 1 } }, "2026-01-01T00:00:00.000Z");
const back = readBackup(text);
out.backup = { describe: describeBackup(back), settings: back.settings, savedAt: back.savedAt, cash: back.career.cash };
C.startNextSeason(reg, career);
C.advanceCareer(reg, career);
const nf = C.nextFight(reg, career);
out.briefs = ["a low wedge with a lifter", "fast drum, lots of armour, under $15,000", "invertible vertical spinner called Molar", "big hammer that hits hard, self-righting",
  "cheap horizontal bar with forks", "round shell spinner for 12k dollars", "", "an undercutter named Low Blow, with a plow"].map((b) => parseBrief(b));
out.advice = {
  design: advise(reg, { kind: "design", brief: "a fast vertical spinner with lots of armour", career }),
  designNone: advise(reg, { kind: "design", brief: "something nice", career }),
  opponent: advise(reg, { kind: "opponent", career, oppId: nf.oppId }),
  fight: advise(reg, { kind: "fight", career, oppId: nf.oppId }),
  season: advise(reg, { kind: "season", career }),
  sandbox: advise(reg, { kind: "design", brief: "a hammer that is tough" }),
};

// ---- commentary
{
  const rng = makeRng(42);
  const c = makeCommentary({ names: { r: "Red Bot", b: "Blue Bot" }, corners: { r: "red", b: "blue" }, weapons: { r: "vertical disc", b: "hammer" },
    story: { level: 2, series: { w: 1, l: 2, fights: 3 }, last: { won: false, method: "ko" }, grudge: true, asked: "them" }, playerId: "r", where: { venue: "Ironworks Hall" }, rng });
  const lines = [...c.intro()];
  const ev = [
    ["countdown", {}, 0], ["live", {}, 0],
    ["hit", { attackerId: "r", defenderId: "b", severity: "heavy", kind: "weapon", deliveredJ: 9000 }, 4],
    ["hit", { attackerId: "b", defenderId: "r", severity: "hit", kind: "weapon", deliveredJ: 2000 }, 7],
    ["hit", { attackerId: "r", defenderId: "b", severity: "catastrophic", kind: "weapon", deliveredJ: 30000 }, 12],
    ["failed", { botId: "b", category: "armor" }, 12], ["failed", { botId: "b", category: "battery" }, 13],
    ["hit", { attackerId: "r", defenderId: "b", severity: "heavy", kind: "ram" }, 20],
    ["hit", { attackerId: null, defenderId: "b", severity: "heavy", kind: "hazard", hazardType: "pulverizer" }, 25],
    ["hazard", { type: "pit" }, 30], ["hazard", { type: "killsaw" }, 31], ["hazard", { type: "killsaw" }, 32],
    ["count", { botId: "b", count: 1, of: 10 }, 40], ["count", { botId: "b", count: 7, of: 10 }, 46], ["recovered", { botId: "b" }, 47],
    ["pin", { botId: "r", pinnedId: "b" }, 60], ["separate", {}, 70],
    ["hit", { attackerId: "r", defenderId: "b", severity: "heavy", kind: "weapon", deliveredJ: 25000 }, 80],
    ["hit", { attackerId: "r", defenderId: "b", severity: "hit", kind: "weapon", deliveredJ: 100 }, 81],
    ["hit", { attackerId: "r", defenderId: "b", severity: "hit", kind: "weapon", deliveredJ: 100 }, 82],
  ];
  for (const [type, e, t] of ev) lines.push(...c.event(type, e, t));
  for (let i = 0; i < 300; i++) lines.push(...c.tick({ clockS: 100 - i * 0.4, live: true, dt: 0.4 }));
  lines.push(...c.event("end", { method: "decision", decision: "split", winnerId: "r", loserId: "b" }, 180));
  c.reset();
  lines.push(...c.event("end", { method: "ko", winnerId: "b", loserId: "r" }, 90));
  out.commentary = lines;
}
print(JSON.stringify(out));
