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

It then measures every robot's wheels (`tools/wheel_audit.gd`): the wheels
stand outboard of the side armour, and no plate, guard, wing or leg may cut
into a tyre. A wheel that stands clear of a narrow body is carried on arms in
the picture (`render/robot_view.gd`).

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
$G --path . -s tests/bot_test.gd -- /tmp/bot robot_id [robot_id ...]   # one robot from six sides: what floats, what cuts into what
$G --headless --path . -s tools/wheel_audit.gd -- [robot_id ...]     # every robot's wheels, measured (part of tools/check.sh)
$G --path . -s tests/keys_test.gd                          # a quick fight driven by real key presses, out with M and O
$G --headless --fixed-fps 10 --path . -s tests/fight_test.gd -- red_id blue_id seed layout   # AI v AI in the physics, no window
```

The career and tournament tests keep their saves apart from yours (they are
written with a `test.` prefix).

## Graphics

The fight has a set of renderer upgrades, each with its own switch under
**Settings > Graphics** (they also apply live from the pause screen). They are
listed in `scripts/render/gfx.gd` and applied in `scripts/render/stage.gd`;
with every one of them off the picture is the plain one the port started with.

| Setting | What it does | Cost a frame* |
| --- | --- | --- |
| Anti-aliasing | MSAA 4x, TAA (the default) or FSR 2 | TAA and MSAA cost the same; FSR 2 at 100% +4.6 ms, at 75% -1 ms |
| Stage lights with shadows | the overhead rig as spotlights (two of the four cast shadows, from what moves), plus the venue's colour washes | 1.1 ms |
| Soft shadows | four shadow ranges and a wider filter on the key light | 0.6 ms |
| Ambient occlusion | contact shading (SSAO, half size) | 0.7 ms |
| Bounced light | screen-space indirect light - **off by default** | 1.2 ms |
| Floor reflections | screen-space reflections (half size); the deck gets a smoother finish to show them | 2.0 ms |
| Arena reflections | a reflection probe of the hall and the box, without the robots | 0.8 ms |
| Haze and light beams | volumetric fog lit by the rig | 0.3 ms |
| Broadcast colour grade | a colour cube: deeper blacks, cool shadows, warm highlights | 0.2 ms |
| Depth of field | only on the intro card and in replays | 2.3 ms, there only |

\* Measured on an Apple M4 at 1920x1080 in the Titan Dome, one of the two
heaviest venues, as what switching that one setting off saves. With everything
off a frame takes 9.4 ms (107 frames a second); with the defaults 15.4 ms (66 a
second there, 71-80 in the smaller venues); with bounced light as well 16.7 ms
- right on the 60 line, which is why that one starts off.

A second set is about what happens in the fight rather than how the hall is
lit. Nothing in it needs a downloaded file: every texture is drawn at boot,
as the rest of the game's are.

| Setting | What it does | Where |
| --- | --- | --- |
| Spark showers | sparks, smoke and flame flown by the graphics card: six times as many sparks, drawn as streaks along their flight, bouncing off the deck; smoke lit by the hall's lamps that fades where it meets something; fire for a burning battery and for the venue's flame cannons; the flash of a big hit on what is round it | `render/gpu_fx.gd`, called from `render/effects.gd` |
| Battle marks on the deck | decals laid where the fight makes them: gouges that glow for a second, soot, tyre rubber, oil under a part that failed and a trail of it behind a robot that is bleeding | `render/deck_marks.gd` |
| Battle damage on the paint | a damaged panel's own shader: paint chipped back to bare steel as its condition falls, soot, a bright scrape at each place it was hit and a second of orange heat in it | `render/robot_fx.gd` |
| Spinner blur | a weapon at speed drawn as a camera sees it: solid wherever the rotor fills the whole turn, see-through where the blades and teeth sweep. Measured from each rotor's own mesh (it is pictured once from along its axle) | `render/robot_fx.gd` |
| Hall light bounce | VoxelGI: the hall is voxelised as the fight loads (about a second) and the lamps' light carries on off what it lands on - **off by default** | `render/stage.gd` |

The first four together cost about half a millisecond a frame - none of them
measurably more than the run-to-run noise on its own. With them on, the
defaults run at 66 frames a second in the Titan Dome, 65 in the Giant Nut
Coliseum and 73-77 in the smaller venues (same machine and picture size as
above). The hall's bounce is the dearest thing on the page: 4.4 ms, which
takes the Titan Dome to 50 a second, for a change you have to look for. It is
there to be switched on, on a faster machine.

Sparks, smoke and marks roll their own dice (seeded from the match's), so a
seed plays the same fight whatever the graphics are set to.

### Authored surfaces and models

The third stage brings in what is not drawn by the game itself. All of it is
CC0 (public domain); `assets/CREDITS.md` lists every file and where it came
from.

| Setting | What it does | Where |
| --- | --- | --- |
| Scanned surfaces | texture sets photographed from the real thing (ambientCG) in place of the generated maps: the deck's scuffed dark plate - with the plates' seams, bolts, scuffs, rubber and oil laid over it as the material's detail layer, so the scan never shows its repeat - brushed weapon steel, machined hubs, armour steel, tyre rubber, UHMW, and poured concrete on the hall floor; a photographed studio for a robot to reflect in the workshop. The same materials, dressed differently: the switch is live | `render/materials.gd` (`SCANNED`, `set_scanned`) |
| Detailed models | wheels as models (two rows of lugs in a chevron on the tyre; a rim with lips, a five-hole face plate over a dark well, boss and wheel nuts), the lighting rig as laced box truss with fins, barn doors and yokes on the lamps, pit gear round the box - tool carts and chests, barrels, sack trucks, extinguishers, gas bottles, shelving (Poly Haven models) - and the crowd as people with shoulders and round heads instead of blocks (for no more triangles). Robots and the hall change from the next fight | `render/parts.gd` (`_wheel_detailed`), `render/venue_view.gd` (`_truss`, `_lamp_fittings`, `_build_pit_gear`) |

Scanned surfaces cost 0.6 ms a frame and the models 0.5: with both on the
defaults run at 62 frames a second in the Titan Dome and 61 in the Giant Nut
Coliseum (66 and 65 without them). That is all the room there was above 60 -
the next thing added there has to pay for itself.

Two tools measure and picture it, both running the real fight scene (AI
against AI, a fixed seed) over the whole screen, and two more picture the
effects and the robot shaders to order:

```bash
G=/Applications/Godot.app/Contents/MacOS/Godot
$G --disable-vsync --path . -s tests/gfx_bench.gd -- /tmp/bench [venue] [layout] [red] [blue] [camera] [seconds] [setting=value ...]
$G --path . -s tests/gfx_shots.gd -- /tmp/shots [venue] [layout] [red] [blue] [setting=value ...]
$G --path . -s tests/gfx_settings_test.gd -- /tmp/settings     # the Settings page and the pause screen
$G --fixed-fps 60 --path . -s tests/fx_test.gd -- /tmp/fx [venue] [setting=value ...]    # a heavy hit's sparks frame by frame, a fire, the marks left on the deck
$G --path . -s tests/robot_fx_test.gd -- /tmp/robot robot_id [robot_id ...] [setting=value ...]   # a robot as built (weapon at speed), half worn, wrecked
```

`setting=value` (for example `gfxSSR=false gfxAA=msaa`) changes a setting for
that run only. The benchmark prints the average frame rate, the median frame
time and the 1% low; add `--rendering-driver vulkan` to get the time spent on
the graphics card as well, and `--gpu-profile` for where it went. Before and
after pictures are in `screenshots/graphics/`.

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
