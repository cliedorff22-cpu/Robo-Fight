# Robo League (Godot)

Robo League: build a 250 lb combat robot and fight it through four leagues.
This Godot 4 project is the game. It began as a port of a browser prototype
(`~/Projects/robo-league`), which is no longer maintained; saves and backups
made there still load here.

## Opening it

1. Open Godot 4.7 (or newer), **Import**, and pick this folder's `project.godot`.
2. Press **F5** (Run Project). It opens on the main menu.

Nothing else to install: there are no art or sound files. Every texture, paint
job and sound is made by the code when the game starts.

**F11** toggles full screen. Saves live in Godot's user-data folder for the
project (`Project > Open User Data Folder` in the editor).

## What is where

```
project.godot      the project (Jolt physics, 120 physics ticks a second)
scenes/            main.tscn (the menus) and fight.tscn (the arena) - each is one node with a script
data/              the game's JSON: parts, robots, rules, arenas, the leagues and the economy
fonts/             drop the game's .ttf fonts here (see below)
scripts/
  game.gd          the autoload: settings, what the next scene was asked to do
  core/            maths and helpers (seeded random numbers, hulls, the event bus, replays)
  data/            the registry (parsed JSON, indexed) and the save store
  logic/           every rule of the game - no graphics, no physics
  sim/             the physics side: arena, hazards, robot body + wheel model, combat, referee
  render/          3D: robots, paint jobs, the arena, the venue, cameras, effects
  audio/           synthesised sound and the commentators' speech
  input/           keyboard, gamepad and touch as one drive input
  ui/              the HUD, the fight scene, the menus (ui/menu/)
tests/             checks and picture tests
tools/check.sh     runs the checks
```

The layers only look downward: `logic` knows nothing about Godot's physics or
rendering, `sim` and `render` read `logic`, and `ui` wires them together.

## Checks

```bash
tools/check.sh
```

loads every script, then runs the logic tests. Each suite plays a fixed script
through the game's rules - every robot built and shaped, 600 simulated fights,
three career seasons with their off-seasons, tournaments, the workshop, the
advisor, the commentary - and compares everything that came out (about 50,000
values) with what was recorded last time (`tests/golden/`). Nothing in the
rules can change without a test saying so.

When a change is MEANT to alter the rules' output, run the check, read the
differences it lists, and if they are the ones you expected record the new
reference:

```bash
tools/check.sh record          # or: tools/check.sh record core
```

Picture tests run the real game in a window and save screenshots:

```bash
G=/Applications/Godot.app/Contents/MacOS/Godot
$G --path . -s tests/flow_test.gd -- /tmp/flow        # menu -> Quick Fight -> fight -> pause -> menu
$G --path . -s tests/career_test.gd -- /tmp/career    # the career's screens
$G --path . -s tests/season_test.gd -- /tmp/season    # a whole season, the off-season, the advisor
$G --path . -s tests/handoff_test.gd -- /tmp/handoff  # tournament, and a career fight in the arena
$G --path . -s tests/saves_test.gd -- /tmp/saves      # two careers: switch, restart, delete
$G --path . -s tests/extras_test.gd -- /tmp/extras [weapon|-] [shapes] [extras]   # every body extra on every body shape
$G --headless --path . -s tools/extras_audit.gd -- [weapon|roster]   # the same, measured: floating or buried extras
$G --path . -s tests/scene_test.gd -- /tmp/fight red_id blue_id layout venue camera seconds ai
$G --path . -s tests/view_test.gd -- /tmp/robots.png 0 8   # a line-up of robots
$G --headless --fixed-fps 10 --path . -s tests/fight_test.gd -- red_id blue_id seed layout   # AI v AI in the physics, no window
```

The career and tournament tests keep their saves apart from yours (they are
written with a `test.` prefix).

## Fonts

The design's four fonts are in `fonts/`: Teko (headlines), Barlow Condensed
(labels), Barlow (body) and JetBrains Mono (numbers), downloaded from Google
Fonts, where the browser game loads them from. All four are under the SIL
Open Font License, which allows shipping them with a game. If a file is ever
missing, the nearest font on the computer stands in.

## How it differs from the browser prototype

- **Physics.** The browser game uses Rapier; this uses Godot's Jolt. The wheel
  model, combat, referee and hazards are the same code, but the two engines
  resolve collisions differently, so a fight in the arena will not play out
  blow for blow the same. Simulated fights (your AI driver, the rest of the
  league) use the game's own resolver and ARE identical.
- **One surface per robot.** Godot has no per-piece friction, so a robot with
  a wedge is slick all over (0.3) and the rest are 0.45.
- **Pause really pauses.** Esc freezes the physics as well as the clock.
- **The off-season and the advisor run in the background** behind a progress
  card (GDScript is slower than the browser's JavaScript engine: an off-season
  is about 25 seconds).
- **Two players on one keyboard:** blue's weapon is `/` or Ctrl, brake `.` or
  Alt (Godot cannot tell the two Shift keys apart the way a browser can).
- **Not ported:** the browser game's developer pages and scripts (the robot
  gallery page, the self-test page, data validation, the headless bout tool).
  `tests/` covers the same ground here.
- **Added:** a Quit entry on the main menu and F11 for full screen.
- **Several careers.** Career opens on a list of six saves, each its own
  career (team, robot, money, field): Continue, Restart (the same team and
  starting money, from the beginning) or Delete, and New Career in an empty
  one. The hub's CAREERS button comes back to the list. The first save is the
  browser game's single one (`robo-league.career`); the others are
  `robo-league.career.2` to `.6`. Export and import (Settings) work on the
  career last played.
- **Body extras stand on the body.** The browser game places forks, fins,
  cages and the rest as if every body were a flat box, so on a tent, a dome,
  a cab, a twin or a pointed nose some float, sink in or vanish. Here each one
  measures the body under it (`Shape.surface_at` and friends in
  `logic/shape.gd`), keeps clear of the weapon on the nose, and a hammer bot's
  fin and spines go either side of the arm.
