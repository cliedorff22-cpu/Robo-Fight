# Robo League (Godot)

The Godot 4 version of Robo League: build a 250 lb combat robot and fight it
through four leagues. It is a port of the browser game in
`~/Projects/robo-league`, which stays the reference - same data files, same
rules, same saves.

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
data/              the game's JSON, exactly as the browser game has it
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

loads every script, then runs the logic tests. Those compare this port with
the browser game's own output (`tests/golden/`): builds, body shapes, simulated
fights, three career seasons with their off-seasons, tournaments, the advisor,
the commentary - 27,279 comparisons, all exact.

Picture tests run the real game in a window and save screenshots:

```bash
G=/Applications/Godot.app/Contents/MacOS/Godot
$G --path . -s tests/flow_test.gd -- /tmp/flow        # menu -> Quick Fight -> fight -> pause -> menu
$G --path . -s tests/career_test.gd -- /tmp/career    # the career's screens
$G --path . -s tests/season_test.gd -- /tmp/season    # a whole season, the off-season, the advisor
$G --path . -s tests/handoff_test.gd -- /tmp/handoff  # tournament, and a career fight in the arena
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

## How it differs from the browser game

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
