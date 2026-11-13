#!/usr/bin/env python3
"""make_diagrams.py — writes the guide's diagrams as SVG files next to this script.

Diagrams are drawn from the small helpers below so that a change (a new service, a
renamed directory) is a one-line edit. Run it, then rebuild the PDF:

    python3 docs/guide/img/make_diagrams.py && docs/guide/build.sh
"""
import os
from html import escape

OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "DejaVu Sans, Liberation Sans, Arial, sans-serif"
MONO = "DejaVu Sans Mono, Liberation Mono, monospace"

# One small palette, used with the same meaning in every diagram.
INK, MUTED, LINE = "#1f2933", "#52606d", "#7b8794"
C = {
    "people":  ("#eef2ff", "#4c51bf"),   # things outside the server
    "public":  ("#e6fffa", "#0f766e"),   # reachable from the network
    "service": ("#f0f9ff", "#0369a1"),   # a running service
    "data":    ("#fff7ed", "#c2410c"),   # data that must be kept
    "tool":    ("#f5f3ff", "#6d28d9"),   # programs/hardware a service uses
    "plain":   ("#f8fafc", "#64748b"),
    "warn":    ("#fef2f2", "#b91c1c"),
}


class Svg:
    def __init__(self, w, h):
        self.w, self.h, self.parts = w, h, []

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=13, weight="normal", fill=INK, anchor="start", mono=False, italic=False):
        fam = MONO if mono else FONT
        style = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{weight}" '
                 f'fill="{fill}" text-anchor="{anchor}"{style}>{escape(s)}</text>')

    def box(self, x, y, w, h, title, lines=(), kind="service", mono_lines=False, title_size=14):
        fill, stroke = C[kind]
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.6"/>')
        cx = x + w / 2
        ty = y + 22
        if title:
            self.text(cx, ty, title, size=title_size, weight="bold", anchor="middle")
            ty += 19
        for ln in lines:
            self.text(cx, ty, ln, size=12, fill=MUTED, anchor="middle", mono=mono_lines)
            ty += 16

    def frame(self, x, y, w, h, label, dashed=True, stroke=LINE, label_at_bottom=False):
        dash = ' stroke-dasharray="7 5"' if dashed else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="none" stroke="{stroke}" stroke-width="1.4"{dash}/>')
        if label:
            self.text(x + 12, (y + h - 9) if label_at_bottom else (y + 18), label, size=12, fill=MUTED, italic=True)

    def arrow(self, x1, y1, x2, y2, label=None, lx=None, ly=None, both=False, dashed=False, anchor="middle"):
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        start = ' marker-start="url(#ah2)"' if both else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{INK}" stroke-width="1.5"{dash} marker-end="url(#ah)"{start}/>')
        if label:
            self.text(lx if lx is not None else (x1 + x2) / 2, ly if ly is not None else (y1 + y2) / 2 - 6,
                      label, size=11.5, fill=MUTED, anchor=anchor)

    def path(self, d, dashed=False):
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        self.add(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="1.5"{dash} marker-end="url(#ah)"/>')

    def save(self, name):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" height="{self.h}">'
                '<defs>'
                f'<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{INK}"/></marker>'
                f'<marker id="ah2" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M10,0 L0,5 L10,10 z" fill="{INK}"/></marker>'
                '</defs>'
                f'<rect width="{self.w}" height="{self.h}" fill="#ffffff"/>')
        with open(os.path.join(OUT, name), "w") as f:
            f.write(head + "".join(self.parts) + "</svg>\n")
        print("wrote", name)


def legend(s, x, y, kinds):
    for kind, label in kinds:
        fill, stroke = C[kind]
        s.add(f'<rect x="{x}" y="{y - 11}" width="16" height="14" rx="3" fill="{fill}" stroke="{stroke}" stroke-width="1.4"/>')
        s.text(x + 23, y, label, size=11.5, fill=MUTED)
        x += 36 + len(label) * 6.9


# ---------------------------------------------------------------------------------
def architecture():
    s = Svg(960, 646)
    s.box(250, 16, 190, 52, "Web browser", ["on the lab network"], "people")
    s.box(470, 16, 190, 52, "iPad app", ["on the lab network"], "people")
    s.arrow(345, 68, 345, 112)
    s.arrow(565, 68, 565, 112)
    s.text(578, 95, "http://10.150.12.82  (port 80 — the only door in)", size=11.5, fill=MUTED)

    s.box(30, 114, 620, 62, "Reverse proxy  (Caddy)", ["one address for everything; sends each request to the right service by its path"], "public")

    s.frame(14, 216, 932, 388, "Inside the server — these listen on the machine itself only; the network cannot reach them directly", label_at_bottom=True)

    s.arrow(125, 176, 125, 240, "address  /", 135, 202, anchor="start")
    s.arrow(330, 176, 330, 240, "address  /viewer/", 340, 202, anchor="start")
    s.arrow(535, 176, 535, 240, "address  /api/", 545, 202, anchor="start")

    s.box(30, 242, 190, 86, "Manager", ["Next.js, port 8100", "cases, uploads,", "progress"], "service")
    s.box(235, 242, 190, 86, "Web viewer files", ["static files, port 5273", "the 3D viewer runs in", "the person's browser"], "service")
    s.box(440, 242, 190, 86, "Gateway", ["Node.js, port 3100", "logins, studies, task", "queue, file storage"], "service")
    s.box(732, 242, 200, 86, "Worker", ["Python, no port", "runs the image pipeline", "on the GPU"], "service")

    s.arrow(730, 290, 632, 290, "asks for work,", 681, 268)
    s.text(681, 282, "moves files", size=11.5, fill=MUTED, anchor="middle")

    s.arrow(500, 328, 455, 398)
    s.arrow(580, 328, 625, 398)
    s.box(360, 400, 180, 84, "PostgreSQL", ["port 5432 (shared cluster)", "vsdb — people, studies", "vsdsdb — file index"], "data")
    s.box(555, 400, 150, 84, "File store", ["images, meshes,", "results", "/srv/valvescope/data"], "data")

    s.arrow(832, 328, 832, 398)
    s.box(712, 400, 220, 66, "Auto-segmentation tool", ["separate Python environment,", "started per task"], "tool")
    s.box(712, 478, 105, 92, "GPU", ["RTX 2080", "8 GB", "(shared)"], "tool")
    s.box(827, 478, 105, 92, "Model files", ["9 GB of", "network", "weights"], "tool")
    s.arrow(765, 466, 765, 477)
    s.arrow(880, 466, 880, 477)

    s.box(30, 400, 300, 84, "systemd", ["starts all five services at boot,", "restarts one if it crashes;", "everything runs as the user “valvescope”"], "plain")
    s.box(30, 498, 675, 72, "Scratch space  /srv/valvescope/work", ["the worker's temporary files for each study — safe to empty when the worker is stopped; not backed up"], "plain")
    legend(s, 30, 628, [("public", "reachable from the network"), ("service", "service"), ("data", "data to keep"), ("tool", "used by the worker"), ("plain", "housekeeping")])
    s.save("architecture.svg")


# ---------------------------------------------------------------------------------
def pipeline():
    s = Svg(960, 420)
    s.box(20, 30, 150, 96, "1  Upload", ["a person creates a", "case and uploads", "a 4D image", "(Manager)"], "people")
    s.box(200, 30, 170, 96, "2  Queue", ["the gateway stores the", "image and lists the", "steps to run", "(database)"], "data")
    s.arrow(170, 78, 198, 78)
    s.arrow(370, 78, 408, 78)
    s.frame(410, 10, 530, 300, "3  The worker runs the steps; each starts when what it needs is completed")
    y = 44
    s.box(430, y, 150, 62, "Phase detection", ["finds open / closed", "valve frames"], "service", title_size=12.5)
    s.box(600, y, 150, 62, "Auto-segmentation", ["outlines the valve", "in those frames"], "service", title_size=12.5)
    s.box(770, y, 150, 62, "Study generator", ["tracks it through the", "heartbeat, builds 3D"], "service", title_size=12.5)
    s.arrow(580, y + 31, 598, y + 31)
    s.arrow(750, y + 31, 768, y + 31)
    for cx in (505, 675, 845):
        s.text(cx, y + 80, "uses the GPU", size=11, fill=C["tool"][1], anchor="middle", weight="bold")
    s.path("M845,134 L845,180")
    s.text(430, 172, "then four measurement steps, at the same time", size=11.5, fill=MUTED)
    s.add(f'<line x1="430" y1="182" x2="916" y2="182" stroke="{INK}" stroke-width="1.5"/>')
    my = 190
    names = [("Global", "measurements"), ("Time-point", "measurements"), ("Root strain", ""), ("Root diameter", "")]
    for i, (a, b) in enumerate(names):
        x = 430 + i * 124
        s.box(x, my, 114, 56, a, [b] if b else [], "service", title_size=12.5)
    s.text(675, 272, "Each step downloads what it needs from the gateway, works in scratch space,", size=11.5, fill=MUTED, anchor="middle")
    s.text(675, 288, "uploads its results, and marks itself completed (or failed, with the reason).", size=11.5, fill=MUTED, anchor="middle")

    s.box(200, 180, 170, 96, "4  View", ["“Open Viewer” unlocks", "when the Study", "generator is done", "(web viewer, iPad)"], "people")
    s.path("M430,218 L372,218")
    s.box(20, 180, 150, 96, "Status", ["the Manager shows", "each step: waiting,", "running, completed,", "failed"], "plain")
    s.path("M198,228 L172,228")
    s.text(20, 340, "A study is finished when all seven steps say “completed”.  On the server:  scripts/study-status.sh <study id>", size=12.5)
    s.text(20, 362, "The 12-frame ultrasound test study took 5 minutes on the RTX 2080 (one run, 2026-11-13).", size=12, fill=MUTED)
    legend(s, 20, 400, [("people", "a person does this"), ("data", "stored"), ("service", "pipeline step"), ("plain", "information")])
    s.save("pipeline.svg")


# ---------------------------------------------------------------------------------
def disk_layout():
    s = Svg(960, 600)
    s.text(20, 26, "Where everything lives, and which account owns it", size=15, weight="bold")
    # column 1: operator
    s.frame(14, 44, 300, 500, "", dashed=False, stroke=C["people"][1])
    s.text(164, 68, "You (the operator)", size=14, weight="bold", anchor="middle")
    s.text(164, 86, "a person with sudo", size=12, fill=MUTED, anchor="middle")
    s.box(28, 102, 272, 150, "/opt/valvescope/valvescope-deploy", ["the deployment repository:", "scripts, pinned versions,", "environment and model lists,", "this guide"], "people", title_size=12.5)
    s.box(28, 266, 272, 88, "config/deploy.env", ["the one settings file you edit;", "holds the generated secrets", "(readable by you only)"], "warn", title_size=12.5)
    s.box(28, 368, 272, 88, "config/accounts.txt", ["people's usernames and their", "initial passwords", "(readable by you only)"], "warn", title_size=12.5)
    s.text(164, 486, "Never read by the services.", size=12, fill=MUTED, anchor="middle")
    s.text(164, 504, "They receive only the files", size=12, fill=MUTED, anchor="middle")
    s.text(164, 522, "generated from deploy.env.", size=12, fill=MUTED, anchor="middle")

    # column 2: valvescope
    s.frame(330, 44, 400, 500, "", dashed=False, stroke=C["service"][1])
    s.text(530, 68, "valvescope (the service account)", size=14, weight="bold", anchor="middle")
    s.text(530, 86, "cannot log in; runs the five services", size=12, fill=MUTED, anchor="middle")
    rows = [
        ("/opt/valvescope/src", "the services' code, at pinned versions (1.3 GB)", "service"),
        ("/opt/valvescope/miniconda3", "two Python environments (19 GB)", "service"),
        ("/opt/valvescope/node", "Node.js for gateway and manager", "service"),
        ("/opt/valvescope/state", "the record of what is installed", "plain"),
        ("/opt/valvescope/etc", "the proxy's configuration", "plain"),
        ("/srv/valvescope/data", "FILE STORE — images and results. Keep.", "data"),
        ("/srv/valvescope/models", "network weights (9 GB), checked by checksum", "tool"),
        ("/srv/valvescope/work", "scratch space; can be emptied", "plain"),
        ("/srv/valvescope/backup", "database dumps (same disk today!)", "data"),
    ]
    y = 100
    for path, what, kind in rows:
        fill, stroke = C[kind]
        s.add(f'<rect x="344" y="{y}" width="372" height="42" rx="6" fill="{fill}" stroke="{stroke}" stroke-width="1.4"/>')
        s.text(356, y + 17, path, size=12, weight="bold", mono=True)
        s.text(356, y + 33, what, size=11.5, fill=MUTED)
        y += 48

    # column 3: system
    s.frame(746, 44, 200, 500, "", dashed=False, stroke=C["plain"][1])
    s.text(846, 68, "The system (root)", size=14, weight="bold", anchor="middle")
    s.text(846, 86, "changed only with sudo", size=12, fill=MUTED, anchor="middle")
    s.box(758, 102, 176, 120, "/etc/systemd/system", ["valvescope.target", "and five", "valvescope-*.service", "files"], "plain", title_size=12.5)
    s.box(758, 236, 176, 120, "PostgreSQL", ["the role “valvescope”", "and two databases:", "vsdb, vsdsdb", "KEEP — back up"], "data", title_size=12.5)
    s.box(758, 370, 176, 86, "Installed packages", ["caddy,", "gcc-12 / g++-12"], "plain", title_size=12.5)
    s.text(846, 486, "The firewall (ufw) is", size=12, fill=MUTED, anchor="middle")
    s.text(846, 504, "switched off on Ludwig;", size=12, fill=MUTED, anchor="middle")
    s.text(846, 522, "the install did not change it.", size=12, fill=MUTED, anchor="middle")
    legend(s, 20, 578, [("warn", "secret"), ("data", "data to keep and back up"), ("service", "can be rebuilt from the repository"), ("tool", "copied by hand once")])
    s.save("disk-layout.svg")


# ---------------------------------------------------------------------------------
def coexistence():
    s = Svg(960, 470)
    s.text(20, 26, "One machine, two installations that must never touch", size=15, weight="bold")
    s.frame(14, 44, 380, 290, "", dashed=False, stroke=C["plain"][1])
    s.text(204, 68, "Developer setup", size=14, weight="bold", anchor="middle")
    s.text(204, 86, "for writing and testing the software", size=12, fill=MUTED, anchor="middle")
    dev = [("Account", "jileihao"), ("Code", "~/dev/avrp-developer"), ("Ports", "3000, 8000, 5173"), ("Databases", "avrpdb, avrpdsdb"),
           ("Python", "~/tk/miniconda3"), ("Node.js", "~/.nvm"), ("Started", "by hand, in terminals")]
    y = 112
    for k, v in dev:
        s.text(34, y, k, size=12.5, weight="bold")
        s.text(130, y, v, size=12.5, mono=True, fill=MUTED)
        y += 30
    s.frame(566, 44, 380, 290, "", dashed=False, stroke=C["service"][1])
    s.text(756, 68, "ValveScope deployment", size=14, weight="bold", anchor="middle")
    s.text(756, 86, "what the lab team uses", size=12, fill=MUTED, anchor="middle")
    dep = [("Account", "valvescope"), ("Code", "/opt/valvescope/src"), ("Ports", "80 (public); 3100, 8100, 5273"), ("Databases", "vsdb, vsdsdb"),
           ("Python", "/opt/valvescope/miniconda3"), ("Node.js", "/opt/valvescope/node"), ("Started", "by systemd, at boot")]
    y = 112
    for k, v in dep:
        s.text(586, y, k, size=12.5, weight="bold")
        s.text(682, y, v, size=12.5, mono=True, fill=MUTED)
        y += 30
    s.text(480, 150, "nothing", size=13, weight="bold", anchor="middle", fill=C["warn"][1])
    s.text(480, 168, "in common", size=13, weight="bold", anchor="middle", fill=C["warn"][1])
    s.add(f'<line x1="480" y1="180" x2="480" y2="318" stroke="{C["warn"][1]}" stroke-width="2" stroke-dasharray="3 5"/>')

    s.box(190, 362, 250, 76, "One PostgreSQL server", ["both keep their databases here,", "under different names and logins"], "data")
    s.box(520, 362, 250, 76, "One GPU (8 GB)", ["two heavy jobs at once can run", "out of memory — see Troubleshooting"], "tool")
    s.arrow(204, 334, 290, 360)
    s.arrow(756, 334, 400, 361)
    s.arrow(250, 334, 590, 361)
    s.arrow(800, 334, 680, 360)
    s.text(480, 460, "Shared on purpose: the database server and the graphics card. Everything else is separate.", size=12, fill=MUTED, anchor="middle")
    s.save("coexistence.svg")


# ---------------------------------------------------------------------------------
def upgrade():
    s = Svg(960, 330)
    s.box(20, 30, 250, 108, "What we WANT", ["versions.lock   (code versions)", "envs/handler.yml   (Python packages)", "models.manifest   (model files)", "kept in git"], "people")
    s.box(20, 178, 250, 108, "What IS installed", ["deployed.lock", "deployed.envs", "deployed.models", "in /opt/valvescope/state"], "plain")
    s.box(340, 96, 190, 124, "scripts/upgrade.sh", ["compares the two", "and lists only", "what differs", "", "--plan: show only"], "service")
    s.arrow(270, 84, 338, 130)
    s.arrow(270, 232, 338, 190)
    s.arrow(530, 158, 578, 158)
    s.frame(580, 20, 360, 280, "For each thing that changed, one at a time", dashed=True)
    steps = ["stop only the services that use it", "fetch the new version", "reinstall its dependencies", "rewrite its settings, rebuild if needed",
             "gateway only: dump the databases,", "    then apply new migrations", "start what was stopped", "write it down as installed"]
    y = 62
    n = 1
    for st in steps:
        if st.startswith("    "):
            s.text(622, y, st.strip(), size=12.5)
        else:
            s.text(598, y, f"{n}.", size=12.5, weight="bold")
            s.text(622, y, st, size=12.5)
            n += 1
        y += 27
    s.text(598, 286, "A failed item is not recorded, so a re-run retries it.", size=11.5, fill=MUTED)
    s.save("upgrade.svg")


if __name__ == "__main__":
    architecture()
    pipeline()
    disk_layout()
    coexistence()
    upgrade()
