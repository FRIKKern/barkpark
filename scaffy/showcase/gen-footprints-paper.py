#!/usr/bin/env python3
"""Generate the command-footprints paper: per command, a native filetree derived from its ops."""
import json, re, glob, urllib.request, collections

SLUG = "scaffy-command-footprints"
SERVER = "https://guerrilla.barkpark.cloud"
TOKEN = json.load(open("/Users/pelle/.config/barkpark/config.json"))["token"]

_n=[0]
def bid(): _n[0]+=1; return f"scf-{_n[0]:03d}"
def t(v): return {"type":"text","value":v}
def para(v): return {"id":bid(),"type":"paragraph","content":[t(v)]}
def h(l,x): return {"id":bid(),"type":"heading","level":l,"text":x}
def divider(): return {"id":bid(),"type":"divider"}

def parse_command(path):
    src = open(path).read()
    tm = re.search(r'^COMMAND "([^"]+)"', src, re.M)
    title = tm.group(1)
    desc = re.search(r'DESCRIPTION "((?:[^"\\]|\\.)*)"', src, re.S).group(1)
    concept = re.search(r'CONCEPT "([^"]+)"', src).group(1)
    variant = re.search(r'VARIANT "([^"]+)"', src).group(1)
    direction = (re.search(r'DIRECTION "([^"]+)"', src) or [None,"add"])[1] if re.search(r'DIRECTION "([^"]+)"', src) else "add"
    nvars = len(re.findall(r'^\s*VARIABLE \d+', src, re.M))
    creates = re.findall(r'^CREATE FILE IF ABSENT "([^"]+)"', src, re.M)
    ins = []
    for m in re.finditer(r'^IN "([^"]+)"\s*\n(?:###\s*(.*))?', src, re.M):
        ins.append((m.group(1), (m.group(2) or "").strip()))
    deletes = re.findall(r'^DELETE FILE IF PRESENT "([^"]+)"', src, re.M)
    removes = re.findall(r'^IN "([^"]+)"\s*\n### .*\n?REMOVE', src, re.M)
    return dict(file=path.split("/")[-1], title=title, desc=desc, concept=concept,
                variant=variant, direction=direction, nvars=nvars,
                creates=creates, ins=ins, deletes=deletes)

def tree_lines(cmd):
    """Build annotated tree lines from the footprint paths."""
    entries = []  # (path, glyph, note)
    for p in cmd["creates"]:
        entries.append((p, "●", "created"))
    seen_in = collections.OrderedDict()
    for p, what in cmd["ins"]:
        seen_in.setdefault(p, []).append(what)
    for p, whats in seen_in.items():
        n = len(whats)
        note = f"injected ×{n}" if n > 1 else "injected"
        entries.append((p, "○", note))
    for p in cmd["deletes"]:
        entries.append((p, "✕", "deleted"))
    if not entries:
        return None
    # group by top-level dir for a tree feel
    by_dir = collections.OrderedDict()
    for p, g, note in entries:
        parts = p.split("/")
        top = "/".join(parts[:-1]) + "/" if len(parts) > 1 else ""
        by_dir.setdefault(top, []).append((parts[-1], g, note))
    lines = []
    dirs = list(by_dir.items())
    for di,(d, files) in enumerate(dirs):
        dlast = di == len(dirs)-1
        if d:
            lines.append(f"{'└── ' if dlast else '├── '}{d}")
            for fi,(f,g,note) in enumerate(files):
                flast = fi == len(files)-1
                pre = "    " if dlast else "│   "
                lines.append(f"{pre}{'└── ' if flast else '├── '}{f} {g} {note}")
        else:
            for fi,(f,g,note) in enumerate(files):
                lines.append(f"{'└── ' if dlast and fi==len(files)-1 else '├── '}{f} {g} {note}")
    return lines

GROUPS = [
    ("Plugin lifecycle", ["plugin--minimal","plugin-bucket--elixir","plugin-route--elixir","cli-verb--read-list","schema-type--minimal-template"]),
    ("PortableDoc & rendering", ["block-type--starter","block-type--tier-classify"]),
    ("API & SDK", ["error-shape--build-clause","sdk-method--ts-read"]),
    ("Infrastructure chores", ["oban-worker--cron","migration--alter-add-index","backfill-task--dry-run-apply","console-helper--js"]),
    ("Docs symmetry pair", ["docs-card--add","docs-card--remove"]),
    ("The ensure family", ["ensure-import--elixir","ensure-cli-noun--go","canonical-marker--plant-above-head"]),
    ("Zone planters", ["ensure-router-zones--elixir","ensure-root-layout-zones--heex","console-hook-zones--js"]),
]

cmds = {}
for f in sorted(glob.glob("scaffy/commands/*.scaffy")):
    c = parse_command(f)
    cmds[f"{c['concept']}--{c['variant']}"] = c

B=[]; A=B.append
A({"id":bid(),"type":"eyebrow","text":"Scaffy · The 21-Command Atlas"})
A(h(1,"Every Command, Every Footprint"))
A({"id":bid(),"type":"ingress","content":[t(
    "All 21 served commands with the exact file footprint each one leaves — ● created, ○ injected "
    "(mark-planted, guarded, reversible), ✕ deleted. Every tree below is DERIVED from the command's "
    "own ops by a parser, not hand-drawn: what you see is what bp scaffy run does, and what "
    "bp scaffy remove takes back byte-clean. Sources, transcripts and full prose: "
    "/papers/scaffy-command-showcase.")]})
total_creates = sum(len(c["creates"]) for c in cmds.values())
total_ins = sum(len(c["ins"]) for c in cmds.values())
A({"id":bid(),"type":"stats","items":[
    {"label":"commands","value":str(len(cmds))},
    {"label":"files created (●)","value":str(total_creates)},
    {"label":"injection sites (○)","value":str(total_ins)},
    {"label":"corpus lines","value":"3576"}]})
A({"id":bid(),"type":"filetree","legend":"● created · ○ injected · ✕ deleted",
   "text":"the legend every tree below shares — reversibility included by construction"})
A(divider())

for gname, keys in GROUPS:
    A(h(2, gname))
    for k in keys:
        c = cmds.get(k)
        if not c: continue
        A(h(3, f"{c['title']}  ·  bp scaffy run {c['file']}"))
        first = re.split(r'(?<=[.!?]) ', c["desc"].replace('\\"','"'))[0]
        vmeta = f"{c['nvars']} variable{'s' if c['nvars']!=1 else ''}" if c['nvars'] else "zero variables"
        A(para(f"{first} ({vmeta}, DIRECTION {c['direction']}.)"))
        lines = tree_lines(c)
        if lines:
            A({"id":bid(),"type":"filetree","text":"\n".join(lines),
               "legend":"● created · ○ injected · ✕ deleted"})
        else:
            A(para("Footprint: no file ops (assert/prose-only) — see the showcase for detail."))
    A(divider())

A({"id":bid(),"type":"callout","tone":"info","title":"Read the trees as contracts","content":[t(
    "A ● file is wholly owned by the command — remove deletes it. A ○ site is a mark-bounded "
    "injection — remove excises exactly the planted span, drift-refusing loudly if the region was "
    "hand-mutated. Zone-planter trees show ○ only: their whole job is planting anchors that make "
    "every FUTURE command's tree possible.")]})

payload={"slug":SLUG,"style":"article","blocks":B,
  "description":("The 21-command atlas: every served Scaffy command with its exact file footprint "
    "(created/injected/deleted) rendered as native filetree blocks — each tree derived mechanically "
    "from the command's own ops, grouped by lifecycle: plugins, PortableDoc, API/SDK, infrastructure, "
    "docs, the ensure family, and the zone planters."),
  "tags":[
    {"tag":"scaffy","strength":90,"rationale":"The complete command atlas with derived footprints."},
    {"tag":"filetree","strength":55,"rationale":"Native filetree blocks carry every footprint — the block demonstrating itself at scale."},
    {"tag":"docs","strength":35,"rationale":"Reference companion to the showcase and benchmark papers."}]}
req=urllib.request.Request(f"{SERVER}/v1/plugins/bulldocs/papers",data=json.dumps(payload).encode(),
  headers={"Authorization":f"Bearer {TOKEN}","Content-Type":"application/json"},method="POST")
try:
    with urllib.request.urlopen(req) as r: print(r.status, r.read().decode()[:250])
except urllib.error.HTTPError as e: print("HTTP",e.code,e.read().decode()[:400])
print("blocks:",len(B),"| commands:",len(cmds),"| creates:",total_creates,"| ins:",total_ins)
