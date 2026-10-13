#!/usr/bin/env python3
"""Make docs/robot-gallery.html work without scripts: draw the cards into the
page itself (the page's own script still takes over and adds the filters), and
drop the dev-only test robots. Run after tests/gallery_test.gd.
  python3 tools/gallery_static.py [docs/robot-gallery.html]
"""
import html, json, sys
TEST = {"player_default", "spinner_test", "sparring_dummy"}
LEAGUES = {"world": "World Championship", "elite": "Elite", "pro": "Pro", "rookie": "Rookie", "exhibition": "Exhibition"}
path = sys.argv[1] if len(sys.argv) > 1 else "docs/robot-gallery.html"
s = open(path).read()
a = s.index("const ROBOTS = ") + len("const ROBOTS = ")
robots, end = json.JSONDecoder().raw_decode(s[a:])
robots = [r for r in robots if r["id"] not in TEST]
# The pictures live once, in the cards; the page's script finds them there.
imgs = {r["id"]: r["img"] for r in robots}
for r in robots: r["img"] = ""
s = s[:a] + json.dumps(robots, separators=(",", ":")) + s[a + end:]
s = s.replace('src="${r.img}"', 'src="${IMGS[r.id]}"')
s = s.replace("const bar = document.getElementById", 'const IMGS = {};\ndocument.querySelectorAll("#grid img[data-id]").forEach(i => { IMGS[i.dataset.id] = i.src; });\nconst bar = document.getElementById', 1)
e = html.escape
def card(r, imgs):
    tags = [r["archetype"], "runs inverted" if r["invertible"] else ("self-rights" if r["selfRights"] else "no self-righting"), r["personality"]]
    if r.get("partner"): tags.append("multibot: + %s (%s)" % (r["partner"]["name"], r["partner"]["weapon"]))
    if r.get("isPlayer"): tags.append("your starting robot")
    rating = "-" if r.get("rating") is None else r["rating"]
    return ('<div class="card"><img data-id="%s" src="%s" alt="%s"><div class="stripe" style="background:linear-gradient(90deg, %s 70%%, %s 70%%)"></div>'
            '<div class="body"><div class="name">%s<small>%s</small></div><div class="team">%s · %s</div><div class="weapon">%s · %s</div>'
            '<div class="stats"><div><b>%s</b><span>lb</span></div><div><b>%s</b><span>mph</span></div><div><b>%s</b><span>kJ</span></div>'
            '<div><b>%s</b><span>driver</span></div></div><div class="tags">%s</div></div></div>') % (
        r["id"], imgs[r["id"]], e(r["name"]), e(r["colors"][0]), e(r["colors"][1]), e(r["name"]), "#%s" % r["number"] if r.get("number") is not None else "",
        e(str(r["team"])), e(str(r["league"])), e(str(r["weaponClass"])), e(str(r["weapon"])),
        r["weightLb"], r["topSpeedMph"], r["weaponEnergyKJ"], rating, "".join("<i>%s</i>" % e(str(t)) for t in tags if t))
body = ""
for lid in ["world", "elite", "pro", "rookie", "exhibition"]:
    part = sorted([r for r in robots if r["leagueId"] == lid], key=lambda r: -(r.get("rating") or 0))
    if part: body += "<h2>%s · %d</h2>" % (LEAGUES[lid], len(part)) + "".join(card(r, imgs) for r in part)
i = s.index('<main id="grid">') + len('<main id="grid">')
j = s.index("</main>", i)
s = s[:i] + body + s[j:]
open(path, "w").write(s)
print("%d robots, %.1f MB" % (len(robots), len(s) / 1e6))
