// A career played through by the resolver, as reference for tests/run_tests.gd.
//   cd ~/Projects/robo-league && jsc -m ../robo-league-godot/tools/golden/dump2.js -- 3 > ../robo-league-godot/tests/golden/career.json
import { loadRegistrySync } from "/Users/collin/Projects/robo-league/js/data/load.js";
import * as C from "/Users/collin/Projects/robo-league/js/logic/career.js";
import { marketOf, sparesOffers, robotOffer, borrow } from "/Users/collin/Projects/robo-league/js/logic/market.js";
import { scoutReport } from "/Users/collin/Projects/robo-league/js/logic/scouting.js";
import { rivalsList, storyline } from "/Users/collin/Projects/robo-league/js/logic/rivalry.js";

const args = globalThis.arguments ?? globalThis.scriptArgs ?? [];
const SEASONS = Number(args[0] ?? 3);
const reg = loadRegistrySync((p) => JSON.parse(readFile(p)), "data");
const career = C.newCareer(reg, { seed: 7, difficulty: "hard" });
const out = { seasons: [], steps: [] };
const t0 = Date.now();
borrow(reg, career, reg.economy.loans.lenders[0].id, 3000);
let guard = 0;
while (out.seasons.length < SEASONS && guard++ < 5000) {
  C.advanceCareer(reg, career);
  const nf = C.nextFight(reg, career);
  if (nf) {
    const step = { fixture: nf.fixture.id, opp: nf.oppId, changes: nf.oppChanges, arena: nf.arena, seed: nf.seed,
      scout: scoutReport(reg, career, nf.oppId, { nameOf: (id) => reg.robot(id).name, myClass: "static" }).lines,
      story: storyline(reg, career, nf.oppId, { names: { them: reg.robot(nf.oppId).name } }) };
    const lf = C.simulatePlayerFight(reg, career);
    step.won = lf.won; step.method = lf.result.method; step.earned = lf.earned; step.repair = lf.repair.total;
    const plan = C.pitAutoPlan(reg, career);
    const q = C.pitQuote(reg, career, plan);
    step.plan = plan; step.pitCost = q.cost; step.pitMinutes = q.minutes;
    C.doPit(reg, career, plan);
    step.cash = career.cash;
    const m = marketOf(reg, career);
    step.market = m.listings.map((l) => `${l.partId}:${l.sellerId}:${l.price}`);
    step.offers = sparesOffers(reg, career).map((o) => `${o.partId}:${o.price}:${o.robotId}`);
    const ro = robotOffer(reg, career);
    step.robotOffer = ro.ok ? `${ro.buyerId}:${ro.price}:${ro.net}` : ro.reason;
    out.steps.push(step);
    continue;
  }
  if (career.seasonOver) {
    const s = career.season;
    const copy = (x) => JSON.parse(JSON.stringify(x));
    const snap = copy({
      index: s.index, kind: s.kind, cash: career.cash, history: career.history[career.history.length - 1],
      stats: career.stats, sponsors: career.sponsors, trophies: career.trophies,
      champions: s.kind === "league" ? Object.fromEntries(Object.entries(s.leagues).map(([k, v]) => [k, v.champion])) : { giantNut: s.giantNut.champion },
      rankings: s.kind === "league" ? Object.fromEntries(Object.entries(s.leagues).map(([k, v]) => [k, v.ranking])) : { giantNut: s.giantNut.ranking },
      wearCount: Object.keys(career.wear).length,
      ai: Object.fromEntries(Object.entries(career.ai).slice(0, 12)),
      rivals: rivalsList(reg, career).map((r) => `${r.id}:${r.heat}:${r.w}-${r.l}`),
    });
    C.startNextSeason(reg, career);
    snap.after = copy({
      cash: career.cash, membership: career.membership, moves: career.offseason.moves,
      ratings: Object.fromEntries(Object.entries(career.evolution).map(([k, v]) => [k, v.rating])),
      builds: Object.fromEntries(Object.entries(career.evolution).filter(([, v]) => v.build).map(([k, v]) => [k, v.build])),
      banks: Object.fromEntries(Object.entries(career.evolution).map(([k, v]) => [k, v.bank])),
      field: career.offseason.field, newcomers: Object.values(career.newcomers).map((n) => ({ id: n.id, name: n.name, team: n.team, build: n.build, body: n.body, rating: n.rating, livery: n.livery, personality: n.personality })),
      drivers: Object.fromEntries(Object.entries(career.drivers).slice(0, 20)),
      notices: career.notices, ledger: career.ledger.slice(-12),
      fixtures: career.season.fixtures.slice(0, 40).map((f) => f.id),
    });
    out.seasons.push(snap);
  }
}
out.ms = Date.now() - t0;
out.save = JSON.parse(C.serialize(career));
print(JSON.stringify(out));
