# Files the 12 S-tier build tasks (published) per the review's ranked backlog.
import json, urllib.request, sys

SERVER = "https://guerrilla.barkpark.cloud"
TOKEN = json.load(open("/Users/pelle/.config/barkpark/config.json"))["token"]
cands = {c["id"]: c for c in json.load(open("cands.json"))}

def call(path, payload):
    req = urllib.request.Request(SERVER + path, data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try: return e.code, json.load(e)
        except Exception: return e.code, {"raw": e.read().decode(errors="replace")[:400]}

# (bid, slug, score, cost, build_path, prereq)
ST = [
 ("B093","toc","4.75","STATIC","scaffy add-block-type (STATIC; compose.ex emitter, zero client JS)","none"),
 ("B043","steps","4.75","STATIC","scaffy add-block-type (STATIC; compose.ex emitter, REAL email render)","none"),
 ("B003","bar-chart","4.60","STATIC","scaffy add-block-type (STATIC; new Render.DataViz emitter)","none"),
 ("B025","equation","4.60","STATIC","scaffy add-block-type (STATIC; server-side TeX->MathML, no client lib)","none"),
 ("B075","api-endpoint","4.50","STATIC","scaffy add-block-type (STATIC; compose.ex emitter)","none"),
 ("B077","code-tabs","4.45","I1","I1 dual hydration (client.ts + Phoenix hook) + real-browser test; asciicast precedent 30-40 files","none"),
 ("B052","tabs","4.35","I1","I1 dual hydration; TUI side generalizes the PROVEN internal/pdrender/dashboard.go {label,blocks} renderer","none"),
 ("B062","video","4.20","STATIC","scaffy add-block-type (STATIC; native <video> element)","none"),
 ("B085","field-number","4.20","STATIC+STUDIO-EDIT","scaffy add-block-type for the atom + E4a Studio control (STUDIO-EDIT surcharge ~514 lines/8 files per D6)","none"),
 ("B053","expandable","4.15","I0","reuse callout's SHIPPED native-<details> pattern (walk.ex:1415-1434) minus the callout chrome","none"),
 ("B040","footnote","4.15","STATIC","scaffy add-block-type (STATIC; inline marker + notes list wired both ways)","none"),
 ("B034","criteria-progress","4.00","STATIC","rides the EXISTING task resolver (rows already carry acceptance_criteria) - shaping + render only","none - the one live-data S pick that needs no new plumbing"),
]

created = []
for bid, slug, sc, cost, path, prereq in ST:
    c = cands[bid]
    pitch = c["paras"][0] if c["paras"] else ""
    meta = c["paras"][1] if len(c["paras"]) > 1 else ""
    shape = (c.get("code") or "").strip()
    tid = "pbw-stier-" + slug
    desc = (
        f"S-tier block build ({bid}, usefulness {sc}, rank per the Usefulness Review). PITCH: {pitch}\n\n"
        f"DATA SHAPE (Attrs-contract sketch from the wishlist paper):\n{shape}\n\n"
        f"SURFACES (graded per charter D2-D4, verbatim from the wishlist entry): {meta}\n\n"
        f"COST TIER: {cost}. BUILD PATH: {path}. PREREQUISITES: {prereq}. "
        "If using scaffy, read the LIVE count pins (React/parity toHaveLength + EXPECTED_COUNT at their current values), never the stale scaffy corpus EXAMPLES (charter D18).\n\n"
        "POINTERS: wishlist entry /papers/block-wishlist-100 (anchor " + bid + "); ranking + tier justification "
        "/papers/block-wishlist-100-review (S-tier table + family section). Epic charter: .claude/workflows/bp-pd-block-wishlist-charter.md."
    )
    doc = {
        "_id": tid,
        "_type": "task",
        "title": f"S-tier block: {slug} ({bid}) - " + pitch.split(".")[0][:90],
        "kind": "task",
        "lifecycle_status": "open",
        "priority": 2,
        "parent_id": "pd-block-wishlist-epic",
        "wave_paper": "block-wishlist-wave-2026-07-18",
        "description": desc,
        "main_tag": "portabledoc",
        "tags": [
            {"tag": "portabledoc", "strength": 90, "rationale": "New PortableDoc block type build."},
            {"tag": "block", "strength": 70, "rationale": "S-tier wishlist candidate " + bid + "."},
            {"tag": "scaffy", "strength": 40, "rationale": "Suggested build path rides scaffy add-block-type where STATIC."},
        ],
        "acceptance_criteria": [
            {"criterion": f"Block type '{slug}' renders on View (walk/compose path) with an honest empty state; per-surface behavior matches the wishlist grade line for {bid} (TUI + React ports, Email render or degrade badge as graded)", "met": False, "evidence": ""},
            {"criterion": "Count pins updated wherever the build path requires (React registry / parity toHaveLength / EXPECTED_COUNT read at their live values per charter D18) and all touched-surface gates green", "met": False, "evidence": ""},
            {"criterion": "PR merged", "met": False, "evidence": ""},
        ],
    }
    st, body = call("/v1/data/mutate/production", {"mutations": [{"createOrReplace": doc}]})
    if st != 200:
        print(tid, "MUTATE FAIL", st, json.dumps(body)[:300]); sys.exit(1)
    st2, body2 = call("/v1/data/mutate/production", {"mutations": [{"publish": {"id": tid, "type": "task"}}]})
    if st2 != 200:
        print(tid, "PUBLISH FAIL", st2, json.dumps(body2)[:300]); sys.exit(1)
    created.append(tid)
    print("ok", tid)

print(len(created), "tasks published:", created)
