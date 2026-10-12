## gallery_test.gd - the robot gallery: every robot in the data files, drawn
## as the game draws it, with its spec card, in ONE web page you can open or
## send to someone (the pictures are inside the file).
##   Godot --path . -s tests/gallery_test.gd -- [out.html] [robot_id ...]
## No ids: the whole field, then the exhibition robots. Default out:
## docs/robot-gallery.html. Run it again after the robots change.
extends SceneTree

const W := 660
const H := 440
const FOV := 30.0
const LEAGUES := ["world", "elite", "pro", "rookie", "exhibition"]

var _out := "res://docs/robot-gallery.html"
var _defs: Array = []
var _cards: Array = []
var _at := -1
var _frames := 0
var _port: SubViewport
var _cam: Camera3D
var _holder: Node3D
var _mats
var _env: Environment

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _out = args[0]
	var reg := Registry.shared()
	var in_roster := {}
	for r in reg.roster(): in_roster[r.id] = true
	if args.size() > 1:
		for id in args.slice(1):
			if reg.has_robot(id): _defs.append(reg.robot(id))
			else: print("no such robot: ", id)
	else:
		_defs = reg.roster()
		for r in reg.all_robots():
			if not in_roster.has(r.id): _defs.append(r)
	for d in _defs:
		var card := Catalog.spec_card(reg, d.id, d)
		card.leagueId = d.get("league") if in_roster.has(d.id) else "exhibition"
		card.number = d.get("number")
		card.isPlayer = d.id == reg.playerId
		card.colors = [J.path(d, ["livery", "primary"], "#888888"), J.path(d, ["livery", "accent"], "#ffffff")]
		_cards.append(card)

	_mats = Mats.shared(reg.arena.get("style", {}))
	# Its own little studio, at the picture's size whatever the window is.
	_port = SubViewport.new()
	_port.size = Vector2i(W, H)
	_port.own_world_3d = true
	_port.msaa_3d = Viewport.MSAA_4X
	_port.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_port)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html("#0e1014")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.html("#8e98ae")
	env.ambient_light_energy = 0.28
	_env = env
	var sky := Sky.new()
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = ImageTexture.create_from_image(Mats.studio_panorama())
	sky.sky_material = pano
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 0.35
	env.ssao_intensity = 1.6
	# The floor fades into the dark behind the robot.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = env.background_color
	env.fog_depth_begin = 5.0
	env.fog_depth_end = 12.0
	env.fog_density = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	_port.add_child(we)
	# A key from the far side of the nose, so the shadow falls toward the
	# camera; a cool fill from the camera's side and a rim from behind.
	for spec in [[Vector3(-45, 124, 0), 1.8, Color.html("#fff4e2"), true], [Vector3(-25, 40, 0), 0.6, Color.html("#b9cdf0"), false],
			[Vector3(-30, -76, 0), 0.6, Color.html("#dfe8ff"), false]]:
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = spec[0]
		sun.light_energy = spec[1]
		sun.light_color = spec[2]
		sun.shadow_enabled = spec[3]
		sun.directional_shadow_max_distance = 16.0
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.shadow_blur = 0.5
		_port.add_child(sun)
	# A plain dark studio floor: the arena's deck plate is too busy this close.
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color.html("#4a4f59")
	floor_mat.roughness = 0.9
	floor_mat.metallic = 0.0
	_port.add_child(Geo.box(80, 0.1, 80).translate(0, -0.05, 0).instance(floor_mat))
	_cam = Camera3D.new()
	_cam.fov = FOV
	_port.add_child(_cam)
	_cam.current = true
	_holder = Node3D.new()
	_port.add_child(_holder)
	# The window only says how far along it is.
	var note := Label.new()
	note.name = "Note"
	note.position = Vector2(30, 30)
	note.add_theme_font_size_override("font_size", 28)
	root.add_child(note)

# Everything drawn under `node`, as one box in the studio's space.
static func _bounds(node: Node, box):
	if node is VisualInstance3D and (node as VisualInstance3D).is_visible_in_tree():
		var vi := node as VisualInstance3D
		var b: AABB = vi.global_transform * vi.get_aabb()
		if b.size.length() > 0.0: box = b if box == null else (box as AABB).merge(b)
	for c in node.get_children(): box = _bounds(c, box)
	return box

func _next() -> void:
	_at += 1
	_frames = 0
	for c in _holder.get_children(): c.queue_free()
	if _at >= _defs.size(): return
	var reg := Registry.shared()
	var def: Dictionary = _defs[_at]
	(root.get_node("Note") as Label).text = "Robot gallery: %d of %d - %s" % [_at + 1, _defs.size(), def.name]
	var units := [Build.assemble_robot(reg, def)]
	if def.get("partner") != null:
		var p = Build.assemble_partner(reg, def)
		if p != null: units.append(p)
	var views := []
	for k in units.size():
		var rig := RobotRig.at_rest(units[k])
		var view := RobotView.new(units[k], rig, _mats)
		# Robot forward is +X; a multibot's partner stands beside it.
		view.position = Vector3(0, rig.layout.spawnY, (k - (units.size() - 1) / 2.0) * 1.1)
		_holder.add_child(view)
		views.append(view)
	var box = null
	for v in views: box = _bounds(v, box)
	if box == null: return
	var bb: AABB = box
	var c := bb.get_center()
	var radius := maxf(0.35, bb.size.length() / 2.0)
	# Front quarter, from a little above, far enough back to fit all of it.
	var dir := Vector3(1.0, 0.5, 0.85).normalized()
	var dist := radius / sin(deg_to_rad(FOV) / 2.0) * 0.8
	_cam.look_at_from_position(c + dir * dist, c + Vector3(0, -radius * 0.06, 0))
	_env.fog_depth_begin = dist + radius * 0.8
	_env.fog_depth_end = dist + radius * 0.8 + 5.0

func _process(_dt: float) -> bool:
	# The first robot goes in here: the studio is not in the tree before this.
	if _at < 0: _next()
	if _at >= _defs.size(): return true
	_frames += 1
	# The first picture waits for the shaders; after that a few frames each.
	if _frames < (40 if _at == 0 else 4): return false
	var img := _port.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	_cards[_at].img = "data:image/jpeg;base64," + Marshalls.raw_to_base64(img.save_jpg_to_buffer(0.84))
	_next()
	if _at >= _defs.size():
		_write()
		return true
	return false

func _write() -> void:
	var path := ProjectSettings.globalize_path(_out) if _out.begins_with("res://") or _out.begins_with("user://") else _out
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var d := Time.get_date_dict_from_system()
	var html := PAGE.replace("/*DATA*/", JSON.stringify(_cards)).replace("/*LEAGUES*/", JSON.stringify(Catalog.LEAGUE_NAMES)) \
		.replace("/*DATE*/", "%04d-%02d-%02d" % [d.year, d.month, d.day])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("could not write %s" % path)
		return
	f.store_string(html)
	f.close()
	print("saved %d robots: %s (%.1f MB)" % [_cards.size(), path, html.length() / 1048576.0])

const PAGE := """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Robo League Robot Gallery</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Teko:wght@500;600;700&family=Barlow+Condensed:wght@500;600;700&display=swap">
<style>
  /* One dark look, the game's own: a sticky bar of filters over a grid of robot cards. */
  :root { color-scheme: dark; --bg: #14161b; --bg2: #1d2024; --ink: #14161b; --btn: #2a2e34; --line: #2e333b; --text: #f1efe8; --dim: #8b8f96; --accent: #ffc81e; --hot: #ff7a1a;
    --display: "Teko", "Barlow Condensed", "Arial Narrow", Impact, sans-serif; --cond: "Barlow Condensed", "Arial Narrow", "Helvetica Neue", Arial, sans-serif; --mono: ui-monospace, Menlo, Consolas, monospace; }
  [hidden] { display: none !important; }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: var(--bg); color: var(--text); font-family: var(--cond); font-weight: 500; }
  header { position: sticky; top: env(safe-area-inset-top, 0px); z-index: 2; background: var(--bg2); border-bottom: 4px solid var(--accent); padding: 12px 16px; }
  h1 { margin: 0 0 6px; font-family: var(--display); font-size: 32px; font-weight: 600; font-style: italic; letter-spacing: 0.06em; line-height: 1; text-wrap: balance; }
  h1 span { color: var(--accent); }
  h1 small { font-family: var(--cond); font-size: 13px; font-style: normal; font-weight: 400; color: var(--dim); letter-spacing: 0.08em; margin-left: 10px; }
  #bar { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
  #bar button { font: inherit; font-size: 14px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--text); background: var(--btn); border: 1px solid var(--line); padding: 6px 12px; cursor: pointer; }
  #bar button.on { background: var(--accent); border-color: var(--accent); color: var(--ink); }
  #bar input, #bar select { font: inherit; font-size: 15px; color: var(--text); background: var(--ink); border: 1px solid var(--line); padding: 6px 10px; }
  #bar input { flex: 1 1 160px; min-width: 120px; }
  #count { color: var(--dim); font-size: 14px; letter-spacing: 0.08em; text-transform: uppercase; }
  main { padding: 16px; display: grid; grid-template-columns: repeat(auto-fill, minmax(min(300px, 100%), 1fr)); gap: 14px; }
  h2 { grid-column: 1 / -1; margin: 10px 0 0; font-size: 15px; letter-spacing: 0.22em; text-transform: uppercase; color: var(--hot); }
  .card { background: var(--bg2); border: 1px solid var(--line); }
  .card img { display: block; width: 100%; max-width: 100%; height: auto; aspect-ratio: 3 / 2; cursor: zoom-in; }
  .stripe { height: 5px; }
  .body { padding: 10px 12px 12px; }
  .name { font-family: var(--display); font-size: 32px; font-weight: 600; font-style: italic; text-transform: uppercase; line-height: 0.95; }
  .name small { font-family: var(--cond); font-size: 14px; font-style: normal; color: var(--dim); margin-left: 6px; }
  .team { font-size: 14px; color: var(--dim); letter-spacing: 0.06em; text-transform: uppercase; margin: 3px 0 6px; }
  .weapon { font-size: 16px; font-weight: 700; color: var(--accent); text-transform: uppercase; letter-spacing: 0.05em; }
  .stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 4px; margin-top: 8px; }
  .stats div { background: var(--ink); padding: 5px 4px; text-align: center; }
  .stats b { display: block; font-size: 16px; font-family: var(--mono); font-variant-numeric: tabular-nums; }
  .stats span { font-size: 11px; color: var(--dim); letter-spacing: 0.1em; text-transform: uppercase; }
  .tags { margin-top: 8px; font-size: 13px; color: var(--dim); }
  .tags i { font-style: normal; border: 1px solid var(--line); padding: 1px 7px; margin-right: 4px; display: inline-block; margin-bottom: 3px; }
  #zoom { position: fixed; inset: 0; z-index: 5; background: rgba(0, 0, 0, 0.9); display: flex; align-items: center; justify-content: center; cursor: zoom-out; }
  #zoom img { max-width: 96vw; max-height: 96vh; }
  @media (max-width: 480px) { h1 small { display: block; margin: 2px 0 0; } }
</style>
</head>
<body>
<header>
  <h1>ROBO <span>LEAGUE</span> · ROBOT GALLERY <small>FROM THE GODOT GAME · /*DATE*/</small></h1>
  <div id="bar"></div>
</header>
<main id="grid"></main>
<div id="zoom" hidden><img alt=""></div>
<script>
const ROBOTS = /*DATA*/;
const LEAGUES = /*LEAGUES*/;
const ORDER = ["world", "elite", "pro", "rookie", "exhibition"];
let league = "all", query = "", weapon = "all", sort = "league";
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
const bar = document.getElementById("bar"), grid = document.getElementById("grid");
function build() {
  bar.innerHTML = "";
  for (const id of ["all", ...ORDER]) {
    const n = id === "all" ? ROBOTS.length : ROBOTS.filter(r => r.leagueId === id).length;
    if (!n) continue;
    const b = document.createElement("button");
    b.textContent = (id === "all" ? "All" : LEAGUES[id]) + " " + n;
    b.className = league === id ? "on" : "";
    b.onclick = () => { league = id; build(); };
    bar.appendChild(b);
  }
  const w = document.createElement("select");
  const classes = [...new Set(ROBOTS.map(r => r.weaponClass))].sort();
  w.innerHTML = '<option value="all">Every weapon</option>' + classes.map(c => `<option${c === weapon ? " selected" : ""}>${esc(c)}</option>`).join("");
  w.onchange = () => { weapon = w.value; draw(); };
  bar.appendChild(w);
  const s = document.createElement("select");
  s.innerHTML = [["league", "By league"], ["name", "By name"], ["rating", "By driver rating"], ["energy", "By weapon energy"], ["speed", "By top speed"]]
    .map(o => `<option value="${o[0]}"${o[0] === sort ? " selected" : ""}>${o[1]}</option>`).join("");
  s.onchange = () => { sort = s.value; draw(); };
  bar.appendChild(s);
  const q = document.createElement("input");
  q.placeholder = "Search name, team or weapon";
  q.value = query;
  q.oninput = () => { query = q.value.toLowerCase(); draw(); };
  bar.appendChild(q);
  const c = document.createElement("span");
  c.id = "count";
  bar.appendChild(c);
  draw();
}
function card(r) {
  const tags = [r.archetype, r.invertible ? "runs inverted" : (r.selfRights ? "self-rights" : "no self-righting"), r.personality];
  if (r.partner) tags.push("multibot: + " + r.partner.name + " (" + r.partner.weapon + ")");
  if (r.isPlayer) tags.push("your starting robot");
  return `<div class="card"><img loading="lazy" src="${r.img}" alt="${esc(r.name)}">
    <div class="stripe" style="background:linear-gradient(90deg, ${esc(r.colors[0])} 70%, ${esc(r.colors[1])} 70%)"></div>
    <div class="body"><div class="name">${esc(r.name)}<small>${r.number != null ? "#" + r.number : ""}</small></div>
    <div class="team">${esc(r.team)} · ${esc(r.league)}</div>
    <div class="weapon">${esc(r.weaponClass)} · ${esc(r.weapon)}</div>
    <div class="stats"><div><b>${r.weightLb}</b><span>lb</span></div><div><b>${r.topSpeedMph}</b><span>mph</span></div>
      <div><b>${r.weaponEnergyKJ}</b><span>kJ</span></div><div><b>${r.rating == null ? "-" : r.rating}</b><span>driver</span></div></div>
    <div class="tags">${tags.filter(Boolean).map(t => "<i>" + esc(t) + "</i>").join("")}</div></div></div>`;
}
function draw() {
  let list = ROBOTS.filter(r => (league === "all" || r.leagueId === league) && (weapon === "all" || r.weaponClass === weapon) &&
    (!query || [r.name, r.team, r.weapon, r.weaponClass, r.archetype].join(" ").toLowerCase().includes(query)));
  const by = {name: (a, b) => a.name.localeCompare(b.name), rating: (a, b) => (b.rating || 0) - (a.rating || 0),
    energy: (a, b) => b.weaponEnergyKJ - a.weaponEnergyKJ, speed: (a, b) => b.topSpeedMph - a.topSpeedMph};
  let html = "";
  if (sort === "league") {
    for (const id of ORDER) {
      const part = list.filter(r => r.leagueId === id).sort((a, b) => (b.rating || 0) - (a.rating || 0));
      if (part.length) html += `<h2>${esc(LEAGUES[id])} · ${part.length}</h2>` + part.map(card).join("");
    }
  } else html = list.sort(by[sort]).map(card).join("");
  grid.innerHTML = html || '<h2>No robots match.</h2>';
  document.getElementById("count").textContent = list.length + " of " + ROBOTS.length + " robots";
}
const zoom = document.getElementById("zoom");
grid.addEventListener("click", e => { if (e.target.tagName === "IMG") { zoom.firstChild.src = e.target.src; zoom.hidden = false; } });
zoom.onclick = () => { zoom.hidden = true; };
document.addEventListener("keydown", e => { if (e.key === "Escape") zoom.hidden = true; });
build();
</script>
</body>
</html>
"""
