#!/usr/bin/env python3
"""Generate the Block Wishlist 100 paper blocks array (block-wishlist-100)."""
import json

import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "blocks.json")

def t(v): return {"type": "text", "value": v}
def para(id, txt): return {"id": id, "type": "paragraph", "content": [t(txt)]}
def heading(id, level, text): return {"id": id, "type": "heading", "level": level, "text": text}
def code(id, value): return {"id": id, "type": "code", "value": value}
def callout(id, tone, title, txt): return {"id": id, "type": "callout", "tone": tone, "title": title, "content": [t(txt)]}
def cell(v): return [t(v)]
def table(id, head, rows):
    return {"id": id, "type": "table", "head": [cell(h) for h in head],
            "rows": [[cell(c) for c in r] for r in rows]}
def ul(id, items): return {"id": id, "type": "list", "ordered": False, "items": [[t(i)] for i in items]}

# ── profiles: (tier, cost, view, edit, tui, react, email) ────────────────────
P = {
 "dv":   (":widget", "STATIC (scaffy-startable, ~9-14 files; D6)",
          "new Render.DataViz emitter — token palette, honest empty box",
          "E3 — server-paint + JSON island, not WYSIWYG (D3 default for data-viz)",
          "new pdrender renderer (braille / eighth-block vocabulary)",
          "port of the View emitter (@barkpark/react registry +1)",
          "degrade badge: text summary (chart precedent, D4)"),
 "tm":   (":element (existing `diagram` — a new TUI kind renderer, NOT a new type)",
          "STATIC (Go-only; terminal-mermaid wave precedent)",
          "already full — browser is a mermaid.js pass-through (D9)",
          "E0 — unchanged (source editing as today)",
          "THE deliverable: native box-drawing renderer for this kind",
          "n/a — mermaid client already covers it",
          "degrade badge: raw source (as today, D4)"),
 "liveS":(":widget", "STATIC (rides the existing task resolver; D10 count-only)",
          "server-paint via the TaskResolver agg/rows path, fresh per page load",
          "E3 — query JSON island; live preview channel already exists",
          "pdrender port over the same resolved attrs",
          "port of the View emitter",
          "degrade badge: text rollup"),
 "ed":   (":widget", "STATIC (compose.ex emitter + ports)",
          "compose.ex emitter, article typography",
          "E2 — server-painted, no island; E4b in-canvas = STUDIO-EDIT surcharge (D6)",
          "box-drawing port",
          "port of the View emitter",
          "REAL render (static HTML, D4)"),
 "i0":   (":widget", "I0 — zero-JS (native <details>/CSS; collapsible-callout precedent walk.ex:1415-1434, D7)",
          "compose.ex emitter",
          "E2 — server-painted, no island",
          "expanded-by-default port",
          "port of the View emitter",
          "REAL render (expanded state)"),
 "i1":   (":widget", "I1 — dual hydration (client.ts + Phoenix hook) + real-browser test (asciicast cost 30-40 files, D6)",
          "server-paints shell; framework-free DOM-scan hydration (D7 pattern)",
          "E3 — server-paint + island",
          "static/degraded port",
          "port sharing the hydration core",
          "degrade badge: static fallback"),
 "i2":   (":widget", "I2 — I1 + API route + resolver + security surface (D6)",
          "server-paints shell; hydrated client calls a new write route",
          "E3 — server-paint + island",
          "read-only port",
          "port sharing the hydration core",
          "degrade badge: link out"),
 "media":(":element", "STATIC (native browser elements)",
          "native element render",
          "E2 — server-painted; E4a picker control = STUDIO-EDIT surcharge",
          "labeled box + path line (media precedent)",
          "port of the View emitter",
          "degrade badge: poster / link"),
 "field":(":element", "STATIC + STUDIO-EDIT (a field atom's canvas control IS the block)",
          "read-only value render",
          "E4a — control atom (the point of the block)",
          "read-only line",
          "form-control port",
          "degrade badge: value as text"),
 "geo":  (":widget", "I1 — canvas hydration (dep-free Canvas2D precedent already duplicated in web/ + hundesteder)",
          "server-paints frame; client draws Canvas2D",
          "E3 — server-paint + JSON island",
          "coordinate scatter / labeled box",
          "port of the SHARED Canvas2D core (the dedup win)",
          "degrade badge: address / coordinate list"),
 "nav":  (":widget", "STATIC (compose.ex emitter)",
          "compose.ex emitter",
          "E2 — server-painted, no island",
          "box-drawing port",
          "port of the View emitter",
          "REAL render (static links, D4)"),
}

R_FLAG = "blocked on new aggregate/resolver plumbing (only the task-scoped count resolver exists; D10)"
S_FLAG = "needs block-registration seam (plugins cannot register block types today; D10 backlog)"

FAMS = [
 ("data-viz & charts", "dv"), ("diagrams & technical", "tm"),
 ("live-data & task-ops", "liveS"), ("editorial & structure", "ed"),
 ("interactive & disclosure", "i1"), ("media", "media"),
 ("geo & map", "geo"), ("dev & code", "ed"),
 ("fields & schema", "field"), ("navigation & meta", "nav"),
]

# (name, family-index, profile, pitch, attrs, overrides)
C = []
def c(name, fam, prof, pitch, attrs, **ov):
    C.append(dict(name=name, fam=fam, prof=prof, pitch=pitch, attrs=attrs, ov=ov))

# ── data-viz & charts (17) ───────────────────────────────────────────────────
c("radial-dial", 0, "dv",
  "The D9 replacement for the struck linear gauge: a radial % dial for the single-number 'how far along' read (criteria met, budget burned). stat's max-bar and a 1-row gauge-list already own the linear form — the dial is the shape that doesn't exist yet.",
  '{ "type": "radial-dial",\n  "value": 71, "max": 118,      // sweep = value/max, clamped\n  "label": "criteria met",\n  "bands"?: [{"to": 0.5, "tone": "danger"}, {"to": 0.9, "tone": "warning"}] }')
c("sparkline", 0, "dv",
  "A standalone trend strip. stat embeds a spark today, but you cannot place the strip alone beside prose or inside a table cell — the ledger's 23 stats uses show the appetite; this unlocks the bare form.",
  '{ "type": "sparkline",\n  "points": [3, 5, 8, 9, 11, 13, 14],\n  "label"?: "renderers/week",\n  "band"?: {"min": 0, "max": 20}   // pin the y-span like chart axes }')
c("bar-chart", 0, "dv",
  "Horizontal bars for categorical counts — the D9-mandated form. chart draws line series only; gauge-list's horizontal-bar vocabulary is the TUI prior art, but there is no labeled categorical bar block on any surface.",
  '{ "type": "bar-chart",\n  "bars": [{"label": "paragraph", "value": 4969}, {"label": "heading", "value": 3232}],\n  "max"?: 5000,                 // else data max\n  "values"?: true               // print the number after each bar }')
c("pie-chart", 0, "dv",
  "Pie/donut share-of-whole — absent on every surface (D9 confirms). The mermaid pie kind proves terminal feasibility; this is the data-native block (attrs, not diagram source).",
  '{ "type": "pie-chart",\n  "slices": [{"label": "element", "value": 25}, {"label": "widget", "value": 35}, {"label": "section", "value": 2}],\n  "donut"?: true, "values"?: true }')
c("scatter-plot", 0, "dv",
  "An x/y point cloud (correlation, cost-vs-size). Absent everywhere (D9); Observable's chart cell shows the demand for point-level plots in docs. Braille dots are the natural TUI medium.",
  '{ "type": "scatter-plot",\n  "series": [{"label": "PRs", "points": [{"x": 1, "y": 3, "label"?: "w1"}]}],\n  "axes"?: {"min": 0, "max": 100, "xLabel": "files", "yLabel": "lines"} }')
c("area-chart", 0, "dv",
  "Stacked area for composition-over-time (task states by week, storage by kind). chart's line series are the substrate; stacking is a genuinely different read (parts of a whole moving).",
  '{ "type": "area-chart",\n  "series": [{"label": "open", "points": [4, 6, 5]}, {"label": "done", "points": [1, 3, 8]}],\n  "stack"?: true, "axes"?: {"xLabels": ["w1", "", "w3"]} }')
c("histogram", 0, "dv",
  "Distribution of a numeric list with binning (PR sizes, latency). No block bins today — authors pre-chew data into chart points by hand.",
  '{ "type": "histogram",\n  "values": [12, 18, 22, 22, 30, 41, 55],\n  "bins"?: 8, "range"?: {"min": 0, "max": 60} }')
c("box-plot", 0, "dv",
  "Five-number distribution summary per label — the honest way to compare spreads (benchmark runs, review latencies) without hiding outliers in an average.",
  '{ "type": "box-plot",\n  "series": [{"label": "cold", "values": [110, 140, 150, 180, 240]},\n             {"label": "warm", "values": [40, 55, 60, 70, 95]}] }')
c("waterfall-chart", 0, "dv",
  "Additive deltas walking to a total (budget, token spend, latency budget). A staple of cost stories; nothing on any surface draws signed running bars.",
  '{ "type": "waterfall-chart",\n  "steps": [{"label": "base", "delta": 120}, {"label": "cache", "delta": -40}, {"label": "retry", "delta": 15}],\n  "totalLabel"?: "net" }')
c("funnel-chart", 0, "dv",
  "Stage drop-off (signup funnel, task pipeline survival). The Cloud console and onboarding docs hand-describe funnels in prose today.",
  '{ "type": "funnel-chart",\n  "stages": [{"label": "visit", "value": 900}, {"label": "signup", "value": 210}, {"label": "deploy", "value": 80}] }')
c("radar-chart", 0, "dv",
  "Multi-axis profile comparison — score cards like the Cody 14-dimension grade or a per-surface feasibility profile read at a glance.",
  '{ "type": "radar-chart",\n  "axes": ["demand", "frequency", "unlock", "reach"],\n  "series": [{"label": "tabs", "values": [5, 4, 4, 3]}] }')
c("treemap", 0, "dv",
  "Hierarchical share as nested rectangles (disk usage, the 4969-paragraph ledger census itself). Share-of-whole with hierarchy has no home block.",
  '{ "type": "treemap",\n  "nodes": [{"label": "prose", "value": 8960, "children"?: [{"label": "paragraph", "value": 4969}]}] }')
c("sankey", 0, "dv",
  "Flows between stages (traffic sources -> pages, task states -> outcomes). High wow-per-byte for architecture and funnel docs; honest cost: layout is the hard part.",
  '{ "type": "sankey",\n  "links": [{"from": "open", "to": "claimed", "value": 40}, {"from": "claimed", "to": "done", "value": 33}] }')
c("calendar-heatmap", 0, "dv",
  "Date-keyed contribution grid (GitHub-style). heatmap is row x col labels, not date-aware — authors cannot show 'activity by day over a year' without hand-slicing weeks.",
  '{ "type": "calendar-heatmap",\n  "entries": [{"date": "2026-07-01", "value": 4}, {"date": "2026-07-02", "value": 9}],\n  "months"?: 12, "ramp"?: "shade" }')
c("scientific-plot", 0, "dv",
  "Function/log-scale plot with grid and pinned axes — the Typst gap. Sampled points in, honest axes out; unlocks engineering notes that today ship screenshots.",
  '{ "type": "scientific-plot",\n  "series": [{"label": "O(n log n)", "points": [{"x": 1, "y": 0}, {"x": 10, "y": 33}]}],\n  "xScale"?: "log", "yScale"?: "linear", "grid"?: true }')
c("chart-cell", 0, "dv",
  "Observable's pull: a chart with field pickers bound to a live query — pick source, x, y, mark; the block re-shapes itself. The reactive-doc gateway drug.",
  '{ "type": "chart-cell",\n  "query": {"source": "tasks", "groupBy": "status", "agg": {"op": "count"}},\n  "mark": "bar" | "line" | "dot",\n  "pickers"?: true              // render the field controls }',
  cost="I1 — hydrated pickers over the resolver path (D6)", flags=R_FLAG)
c("data-grid", 0, "dv",
  "Observable's data table with inline wrangling: a query-driven grid with client sort/filter. table is static hand-typed cells; the ledger's 207 tables show how often people want tabular reads.",
  '{ "type": "data-grid",\n  "query": {"source": "tasks", "filter": {"status": "open"}},\n  "columns": [{"field": "title"}, {"field": "priority", "sort"?: "asc"}],\n  "pageSize"?: 25 }',
  cost="I1 — hydrated sort/filter (D6)", flags=R_FLAG)

# ── diagrams & technical (11) ────────────────────────────────────────────────
for kind, note in [
  ("gantt", "schedule bars over a date axis — the kind the Projects Board Gantt proves people want in docs too"),
  ("er", "entity-relation boxes + crow's-feet — schema docs read in the terminal"),
  ("class", "class boxes with members + relations — architecture notes for the Go/Elixir internals"),
  ("pie", "share-of-whole in eighth-block arcs — the diagram twin of the pie-chart block"),
  ("gitgraph", "branch/merge topology — release and worktree runbooks"),
  ("state", "state machines with transitions — lifecycle docs (task claim/close, deploy slots)"),
  ("journey", "user-journey lanes with scores — UX and onboarding papers"),
]:
    c(f"diagram-{kind}-tui", 1, "tm",
      f"Per-kind TUI mermaid renderer (D9): {note}. The browser already renders every mermaid kind via pass-through; the terminal renders only the kinds with hand-built renderers (6 waves shipped so far) — this closes the `{kind}` gap.",
      f'{{ "type": "diagram",           // EXISTING block — new pdrender kind\n  "source": "{kind}\\n  ..."      // mermaid `{kind}` source, labels double-quoted\n}}')
c("equation", 1, "tm",
  "Math/equation block — a confirmed Notion AND Typst gap. TeX source in, MathML out (native in every modern browser — zero client JS); the terminal prints aligned unicode or honest raw TeX.",
  '{ "type": "equation",\n  "tex": "E = mc^2",\n  "display"?: true              // block vs inline sizing }',
  tier=":element", cost="STATIC (TeX -> MathML on the server; no client lib)",
  view="server-side TeX -> MathML (native browser math; zero JS)",
  edit="E2 — source textarea; live MathML preview = E3 island later",
  tui="unicode approximation, raw TeX fallback",
  react="port of the same TeX -> MathML transform",
  email="degrade badge: raw TeX source")
c("vector-diagram", 1, "tm",
  "Typst's gap: a declarative primitive canvas — boxes, arrows, labels at coordinates — for the diagrams mermaid's opinionated layouts refuse to draw (annotated architecture, memory layouts).",
  '{ "type": "vector-diagram",\n  "shapes": [{"kind": "box", "at": [0, 0], "size": [12, 3], "label": "API"},\n             {"kind": "arrow", "from": [12, 1], "to": [20, 1], "label": "SSE"}],\n  "grid"?: [40, 12] }',
  tier=":widget", cost="STATIC (SVG emitter + box-drawing port)",
  view="server-painted SVG", edit="E3 — JSON island",
  tui="box-drawing port (the layout-engine solver already speaks rectangles)",
  react="SVG port", email="degrade badge: label list")
c("tree-diagram", 1, "tm",
  "Typst's gap: a tree from nested data (org charts, decision trees, taxonomy). filetree draws paths only; mermaid flowcharts can fake it but never read well in the terminal.",
  '{ "type": "tree-diagram",\n  "root": {"label": "Document", "children": [\n    {"label": "Section", "children": [{"label": "Widget"}, {"label": "Element"}]}]} }',
  tier=":widget", cost="STATIC (SVG + the filetree box-drawing vocabulary)",
  view="server-painted SVG/CSS tree", edit="E3 — JSON island",
  tui="box-drawing port (filetree precedent)", react="port",
  email="degrade badge: indented list (REAL enough to read)")
c("chemfig", 1, "tm",
  "Chemical structure rendering (Typst gap). Honest: the narrowest candidate in the family — include for completeness of the Typst survey, expect a low usefulness rank.",
  '{ "type": "chemfig",\n  "source": "C(-[:90]H)(-[:210]H)=O"   // chemfig/SMILES-style source }',
  tier=":element", cost="STATIC but specialist (dedicated layouter)",
  view="server-painted SVG", edit="E2 — source textarea",
  tui="raw source (honest)", react="port", email="degrade badge: raw source")

# ── live-data & task-ops (11) ────────────────────────────────────────────────
c("timeline-gantt", 2, "liveS",
  "A native gantt over a task query — the Projects Board shipped a bespoke Gantt, proving both demand and renderer; this moves the read into any paper (plans, wave charters).",
  '{ "type": "timeline-gantt",\n  "query": {"source": "tasks", "filter": {"parent_id": "pd-block-wishlist-epic"}},\n  "on"?: ["inserted_at", "closed_at"],  // bar span fields\n  "lanes"?: "assignee" }',
  flags=R_FLAG + " — task rows carry no date span today")
c("burndown-chart", 2, "liveS",
  "Open-count over time with an ideal line — the sprint read. The agg path already supports count + over(closed_at) buckets, so this is nearly free: shape the two series, draw with the existing chart vocabulary.",
  '{ "type": "burndown-chart",\n  "query": {"source": "tasks", "filter": {"parent_id": "epic-x"},\n            "over": {"bucket": "day", "on": "closed_at", "last": 14}},\n  "ideal"?: true }')
c("task-calendar", 2, "liveS",
  "Month grid of tasks by date (due/closed) — the planning read boards do not give. Pairs with calendar-heatmap but shows the tasks, not just intensity.",
  '{ "type": "task-calendar",\n  "query": {"source": "tasks", "filter": {"labels": ["wave-1"]}},\n  "on"?: "closed_at", "month"?: "2026-07" }',
  flags=R_FLAG + " — needs date fields in the row shape")
c("activity-feed", 2, "liveS",
  "Recent ledger events (claims, stamps, closes) as a feed — the 'is this epic alive?' read the memory doctrine keeps asking for. Everything-is-a-task makes the event stream the heartbeat.",
  '{ "type": "activity-feed",\n  "query": {"source": "task-events", "filter": {"parent_id": "epic-x"}, "last": 20},\n  "kinds"?: ["claim", "stamp", "close"] }',
  flags=R_FLAG + " — no task-event source is exposed to blocks")
c("claim-monitor", 2, "liveS",
  "Live board of current claims: worker, lease age, pulse now-line per task. The ledger-liveness contract (pulse the now-line) has no reader surface today — this is it.",
  '{ "type": "claim-monitor",\n  "query": {"source": "tasks", "filter": {"status": "in_progress"}},\n  "show"?: ["worker", "now", "epoch", "age"] }',
  flags=R_FLAG + " — claim/now-line fields are not in the resolver row shape")
c("criteria-progress", 2, "liveS",
  "Acceptance-criteria met/total rolled up across a query (per task and aggregate). Resolver rows ALREADY carry criteria — this is a pure shaping + render job, the cheapest live candidate here.",
  '{ "type": "criteria-progress",\n  "query": {"source": "tasks", "filter": {"parent_id": "epic-x"}},\n  "detail"?: "rows" | "total" }')
c("epic-heartbeat", 2, "liveS",
  "One banner for an epic: its wave_status heartbeat line + child progress counts. The charter contract writes wave_status on every phase; no block renders it.",
  '{ "type": "epic-heartbeat",\n  "task": "pd-block-wishlist-epic",   // the epic task slug\n  "show"?: ["wave_status", "children", "updated"] }',
  flags=R_FLAG + " — wave_status passthrough missing from the row shape")
c("countdown", 2, "i1",
  "Deadline countdown to a datetime (launch, gate close). Client ticks; server paints the absolute date so the degrade is honest everywhere.",
  '{ "type": "countdown",\n  "to": "2026-08-01T12:00:00Z",\n  "label"?: "beta freeze", "done"?: "Shipped." }',
  email="degrade badge: absolute date (REAL text)")
c("deploy-status", 2, "liveS",
  "Live deploy slot card (blue/green, current rev, health) for an instance — runbooks that show the truth they describe. Plugin-domain data (cloud/instances).",
  '{ "type": "deploy-status",\n  "instance": "guerrilla",\n  "show"?: ["slot", "rev", "health", "last_deploy"] }',
  flags=S_FLAG)
c("sheet-chart", 2, "liveS",
  "Chart over a Sheets range — the spreadsheet plugin owns tabular data people already maintain; letting a paper chart a range closes the loop without copy-paste.",
  '{ "type": "sheet-chart",\n  "sheet": "q3-budget", "range": "A1:C12",\n  "mark"?: "line" | "bar" }',
  flags=S_FLAG)
c("paper-stats", 2, "liveS",
  "Live corpus stats (papers count, block-type census like the 294-paper table in this paper) — the census that grounded THIS wishlist was hand-run SQL; a block makes it reproducible.",
  '{ "type": "paper-stats",\n  "query": {"source": "papers", "groupBy": "block_type"},\n  "top"?: 12 }',
  flags=R_FLAG + " — content-source aggregate; the resolver is task-only by design")

# ── editorial & structure (12) ───────────────────────────────────────────────
c("footnote", 3, "ed",
  "Numbered footnotes with backlinks — the reference apparatus long-form papers fake with parenthetical asides today. Inline marker + notes list, wired both ways.",
  '{ "type": "footnote",\n  "notes": [{"id": "fn1", "content": [ ...inline spans... ]}] }\n// inline side: {"type": "footnote-ref", "ref": "fn1"} span')
c("sidenote", 3, "ed",
  "Margin note (Tufte-style): commentary beside the text column on wide screens, inline aside on narrow/email/TUI. The honest-degrade story is the whole design.",
  '{ "type": "sidenote",\n  "content": [ ...inline spans... ],\n  "align"?: "right" }')
c("glossary-term", 3, "i0",
  "Inline term with an expandable definition (native <details>/<abbr>). Barkpark's own papers are jargon-dense — E-grades, I-tiers, seams — and every reader meets them cold.",
  '{ "type": "glossary-term",\n  "term": "E3", "definition": "server-paint + JSON island",\n  "inline"?: true }')
c("steps", 3, "ed",
  "Numbered procedure with substeps and per-step blocks — the docs staple (GitBook/ReadMe both ship it). Runbooks here hand-number headings and lose the semantics.",
  '{ "type": "steps",\n  "steps": [{"title": "Claim the task", "blocks": [ ...child blocks... ]},\n            {"title": "Stamp evidence", "blocks": [...]}] }')
c("faq", 3, "i0",
  "Question/answer pairs as native details accordions. Support docs and launch pages want this shape; the tickets plugin gives it a real consumer.",
  '{ "type": "faq",\n  "items": [{"q": "Is my data portable?", "a": [ ...blocks... ], "open"?: false}] }')
c("definition-list", 3, "ed",
  "Semantic term/definition pairs (dl/dt/dd). table is overkill for glossaries and option references — 207 ledger tables include many two-column definition tables that want this.",
  '{ "type": "definition-list",\n  "items": [{"term": "widget", "definition": [ ...inline spans... ]}] }')
c("chronology", 3, "ed",
  "Editorial timeline of dated events (project history, incident postmortems) — vertical line + entries. Distinct from timeline-gantt: hand-authored narrative, not live task spans.",
  '{ "type": "chronology",\n  "events": [{"date": "2026-07-17", "title": "Charter ratified", "content"?: [ ...spans... ]}] }')
c("changelog", 3, "ed",
  "Release-note entries with version, date, and change-kind badges (added/fixed/breaking). Every SDK release note here is hand-formatted headings + lists.",
  '{ "type": "changelog",\n  "entries": [{"version": "1.4.0", "date": "2026-07-10",\n               "changes": [{"kind": "added", "text": "..."}]}] }')
c("citation-list", 3, "ed",
  "Bibliography with inline cite markers — the academic apparatus (Typst pull). Research papers in the corpus (perfect-plan verdicts) cite by bare URL today.",
  '{ "type": "citation-list",\n  "refs": [{"id": "c1", "title": "...", "url"?: "...", "authors"?: [...], "year"?: 2026}] }')
c("pros-cons", 3, "ed",
  "Two-column verdict block (pros / cons / verdict line) — review and decision docs hand-roll this with columns + callouts; one purposeful widget reads better on every surface.",
  '{ "type": "pros-cons",\n  "pros": [ ...inline spans per item... ], "cons": [...],\n  "verdict"?: [ ...inline spans... ] }')
c("hero", 3, "ed",
  "Cover hero: background image + title/kicker overlay + action. The content-first doctrine gives papers title+featured-image; launch and template pages need the composed front door. Slots-native: element ARRAYS, never flat strings (the silent-empty trap).",
  '{ "type": "hero",\n  "slots": {"media": [{"type": "image", "src": "..."}],\n            "title": [{"type": "heading", "level": 1, "text": "..."}],\n            "action"?: [{"type": "action", "label": "Start", "href": "..."}]} }')
c("page-break", 3, "ed",
  "Print/PDF pagination hint — an element like divider that browsers honor in print CSS. The paper-to-PDF path has no pagination control at all.",
  '{ "type": "page-break" }',
  tier=":element", cost="STATIC (one CSS rule + no-op ports)",
  tui="no-op (honest)", email="no-op", react="one-line port",
  edit="E2 — a labeled marker line in the canvas")

# ── interactive & disclosure (10) ────────────────────────────────────────────
c("tabs", 4, "i1",
  "Tabbed panels of child blocks — prior art is ALREADY in the repo: internal/pdrender/dashboard.go dashboardTabs renders {label, blocks} tab sets in the terminal. GitBook ships it; multi-audience docs (per-OS installs) need it.",
  '{ "type": "tabs",\n  "tabs": [{"label": "macOS", "blocks": [ ...child blocks... ]},\n           {"label": "Linux", "blocks": [...]}],\n  "active"?: 0 }',
  tier=":section (owns child layout, like columns)",
  tui="already proven — the dashboard.go {label,blocks} renderer generalizes",
  email="degrade badge: stacked sections with tab-name headings")
c("expandable", 4, "i0",
  "A generic collapsible container — D9 repriced: callout already ships native <details> (walk.ex:1415-1434); this is the same pattern minus the callout chrome. GitBook's 'expandable' by name.",
  '{ "type": "expandable",\n  "summary": "Show the full trace",\n  "blocks": [ ...child blocks... ], "open"?: false }')
c("toggle-list", 4, "i0",
  "Craft's toggle list: list items that expand into block bodies — per-item <details>. The outline-first writing pattern Notion/Craft users expect on day one.",
  '{ "type": "toggle-list",\n  "items": [{"summary": [ ...inline spans... ], "blocks": [ ...child blocks... ]}] }')
c("carousel", 4, "i1",
  "Slide sequence of child blocks with dots/arrows — product tours and screenshot walkthroughs. Email/TUI degrade to a stacked sequence, which stays honest.",
  '{ "type": "carousel",\n  "slides": [{"blocks": [ ...child blocks... ], "caption"?: "..."}],\n  "loop"?: false }',
  tier=":section (owns child layout)")
c("action-button", 4, "i2",
  "Coda's pull: a button that fires a declared mutation (close a task, trigger a webhook) with confirmation + result state. The first write-path block — its security surface IS the cost (D6 I2).",
  '{ "type": "action-button",\n  "label": "Close task",\n  "action": {"kind": "task.close", "task": "slug"} | {"kind": "webhook", "url": "..."},\n  "confirm"?: "Really close?" }')
c("template-button", 4, "i2",
  "Notion's template button: inserts a predefined block template into the doc (meeting notes row, decision record). Studio-edit-only by nature — readers never see it do anything.",
  '{ "type": "template-button",\n  "label": "+ Decision record",\n  "template": [ ...blocks to insert... ] }',
  cost="I2 + STUDIO-EDIT (the whole feature lives in the canvas)",
  email="hidden (edit-only block)", tui="hidden (edit-only block)")
c("reactive-input", 4, "i2",
  "Observable's core move: a slider/select whose value feeds sibling query/chart blocks — documents that answer what-ifs. The biggest unlock in this family and honestly the most expensive (client dataflow graph).",
  '{ "type": "reactive-input",\n  "name": "weeks", "kind": "range", "min": 1, "max": 12, "value": 8 }\n// sibling blocks reference {"$input": "weeks"} in query params')
c("poll", 4, "i2",
  "Reader vote + live tally (team decisions, talk feedback). Backend-write with dedup per principal; tally renders as the existing bar vocabulary.",
  '{ "type": "poll",\n  "question": "Which S-tier block first?",\n  "options": ["tabs", "map", "toc"], "multi"?: false }')
c("checklist", 4, "i2",
  "Persisted checkboxes (doc-state write) — onboarding and runbook progress that survives reload. Distinct from list's static checked marks: state belongs to the reader+doc pair.",
  '{ "type": "checklist",\n  "items": [[ ...inline spans... ], ...],\n  "scope"?: "reader" | "doc" }')
c("quiz-embed", 4, "i2",
  "Embed a Hyperquiz question or deck inline — the quiz engine is LIVE as Plugins.Quiz on this very instance; papers cannot host it because plugins cannot register block types.",
  '{ "type": "quiz-embed",\n  "quiz": "quiz-slug", "mode"?: "single" | "deck" }',
  flags=S_FLAG)

# ── media (8) ────────────────────────────────────────────────────────────────
c("video", 5, "media",
  "Plain <video> file block (poster, captions, controls). The census shows ZERO video in 294 papers — because no block exists, not because nobody wants product demos in docs.",
  '{ "type": "video",\n  "src": "https://.../demo.mp4", "poster"?: "...",\n  "captions"?: [{"lang": "en", "src": "..."}], "loop"?: false }')
c("audio", 5, "media",
  "Plain <audio> block with an optional transcript body — voice notes, podcast clips, pronunciation. Transcript doubles as the TUI/email degrade.",
  '{ "type": "audio",\n  "src": "https://.../clip.mp3",\n  "transcript"?: [ ...blocks... ] }')
c("gallery", 5, "media",
  "Notion's gallery: an image grid with captions and a lightbox. figure is one image; screenshot-heavy release notes stack figures vertically today. Grid is I0; the lightbox is the I1 part.",
  '{ "type": "gallery",\n  "images": [{"src": "...", "caption"?: "...", "alt": "..."}],\n  "columns"?: 3, "lightbox"?: true }',
  tier=":widget", cost="I0 grid; I1 with lightbox (D7 split)")
c("image-compare", 5, "i1",
  "Before/after slider over two images — design reviews and the view-edit-parity audits ship side-by-side screenshots that beg for this.",
  '{ "type": "image-compare",\n  "before": {"src": "...", "label"?: "before"},\n  "after":  {"src": "...", "label"?: "after"}, "start"?: 0.5 }',
  email="degrade badge: both images stacked (REAL)")
c("pdf-embed", 5, "media",
  "Inline PDF viewer (object/iframe with a download fallback card). Contracts, invoices, and specs live as PDFs; today they leave the paper.",
  '{ "type": "pdf-embed",\n  "src": "https://.../contract.pdf", "height"?: 640,\n  "title": "Q3 agreement" }')
c("file-attachment", 5, "media",
  "Download card: filename, size, type icon, checksum. The media plugin stores files; papers have no way to hand one to the reader.",
  '{ "type": "file-attachment",\n  "src": "...", "name": "dataset.csv", "size"?: 48123, "sha256"?: "..." }',
  email="REAL render (a link is a link)")
c("svg-inline", 5, "media",
  "Sanitized inline SVG — diagrams exported from design tools render crisp and theme-tintable. The sanitizer IS the feature; without it this block is an XSS hole (honest security cost).",
  '{ "type": "svg-inline",\n  "svg": "<svg ...>...</svg>",     // server-sanitized allowlist\n  "caption"?: "..." }',
  cost="STATIC + sanitizer (security-reviewed allowlist)")
c("icon", 5, "media",
  "Inline icon element from the shipped Lucide set (Studio already bundles it) — status glyphs and nav affordances without image round-trips.",
  '{ "type": "icon",\n  "name": "check-circle", "size"?: 20, "label"?: "done" }',
  email="degrade badge: unicode fallback", tui="unicode glyph")

# ── geo & map (5) ────────────────────────────────────────────────────────────
c("map", 6, "geo",
  "Marker map — the strongest dedup-by-demand case in the wishlist: the SAME dep-free Canvas2D map is duplicated in web/components/listings-map.tsx AND apps/hundesteder/components/places-map.tsx. One block retires two forks.",
  '{ "type": "map",\n  "center": [59.91, 10.75], "zoom": 12,\n  "markers": [{"at": [59.91, 10.75], "label": "Oslo", "href"?: "..."}] }')
c("map-route", 6, "geo",
  "Polyline route with waypoints (trail guides, delivery runs, race courses) — the hundesteder domain (dog places) is literally routes and places.",
  '{ "type": "map-route",\n  "path": [[59.91, 10.75], [59.93, 10.71]],\n  "waypoints"?: [{"at": [59.92, 10.73], "label": "rest"}] }')
c("choropleth", 6, "geo",
  "Region-shaded map from inline GeoJSON + values (sales by region, coverage by country). Honest cost: geometry payloads are big; the block must own simplification discipline.",
  '{ "type": "choropleth",\n  "regions": {"type": "FeatureCollection", ...},\n  "values": {"NO-03": 42, "NO-50": 17}, "ramp"?: "shade" }')
c("location-card", 6, "geo",
  "Single place card: mini-map + address + hours + link — the hundesteder place-page pattern as a reusable block for contact pages and event papers.",
  '{ "type": "location-card",\n  "at": [59.91, 10.75], "name": "HQ",\n  "address": "...", "hours"?: [...], "href"?: "..." }',
  email="degrade badge: address text (REAL enough)")
c("geojson-map", 6, "geo",
  "Arbitrary GeoJSON feature render — the power-user escape hatch when markers/routes/regions compose (survey plots, territory maps).",
  '{ "type": "geojson-map",\n  "features": {"type": "FeatureCollection", ...},\n  "fit"?: "bounds" }')

# ── dev & code (10) ──────────────────────────────────────────────────────────
c("api-endpoint", 7, "ed",
  "Endpoint doc card: method chip + path + params + response table — the docs staple. docs/api-v1.md hand-formats dozens of these; the block makes them consistent and greppable.",
  '{ "type": "api-endpoint",\n  "method": "POST", "path": "/v1/data/mutate",\n  "params": [{"name": "dataset", "in": "path", "type": "string", "required": true}],\n  "responses"?: [{"status": 200, "note": "..."}] }')
c("openapi-console", 7, "i2",
  "GitBook's try-it console driven by an OpenAPI operation — live request builder + real response. The repo already maintains docs/openapi.json; this block makes it executable.",
  '{ "type": "openapi-console",\n  "spec": "/docs/openapi.json", "operationId": "mutateData",\n  "auth"?: "token-prompt" }')
c("code-tabs", 7, "i1",
  "One snippet per language with a synced switcher (choose npm once, every code-tabs block follows). SDK docs across Go/JS/HTTP need it on nearly every page.",
  '{ "type": "code-tabs",\n  "tabs": [{"label": "JS", "language": "js", "value": "..."},\n           {"label": "Go", "language": "go", "value": "..."}],\n  "syncKey"?: "lang" }')
c("json-viewer", 7, "i0",
  "Collapsible JSON tree (native details per node) — API payload docs beyond code's flat text. The capabilities manifest and task docs in this repo are exactly this shape.",
  '{ "type": "json-viewer",\n  "value": { ...literal JSON... },\n  "open"?: 2                    // expand depth }')
c("csv-table", 7, "ed",
  "Paste CSV/TSV, render a table — removes the hand-conversion between spreadsheets and the 207 ledger tables. Element-simple, sheet-plugin-free.",
  '{ "type": "csv-table",\n  "csv": "name,count\\nparagraph,4969",\n  "header"?: true, "align"?: ["l", "r"] }',
  tier=":element")
c("commit-card", 7, "ed",
  "Git commit card (sha, message, stats, author) resolved via the github plugin (source EXACTLY \"github\") — postmortems and release notes cite commits as bare hashes today.",
  '{ "type": "commit-card",\n  "repo": "FRIKKern/barkpark", "sha": "42e2caffe" }',
  flags=S_FLAG)
c("pr-status", 7, "ed",
  "Live PR card: state, checks, review status — wave papers narrate PRs by number and go stale the moment a gate flips. The github plugin owns the data.",
  '{ "type": "pr-status",\n  "repo": "FRIKKern/barkpark", "pr": 4008,\n  "show"?: ["checks", "reviews", "mergeable"] }',
  flags=S_FLAG)
c("kbd", 7, "ed",
  "Keyboard-shortcut caps (kbd chips with plus separators) — TUI docs and the keybindings guide describe chords in prose; every docs platform renders them as caps.",
  '{ "type": "kbd",\n  "keys": ["cmd", "shift", "p"], "label"?: "command palette" }',
  tier=":element")
c("badge-row", 7, "ed",
  "Status badge row (build passing, version, license) — READMEs get shields.io; papers get nothing. Static chips with tone + optional link, no external image dependency.",
  '{ "type": "badge-row",\n  "badges": [{"label": "gate", "value": "green", "tone": "success", "href"?: "..."}] }',
  tier=":element")
c("package-install", 7, "i1",
  "Install snippet with a package-manager switcher (npm/pnpm/yarn/go get) — the first block of every SDK quickstart, synced with code-tabs' syncKey.",
  '{ "type": "package-install",\n  "package": "@barkpark/react",\n  "managers"?: ["npm", "pnpm", "yarn"] }')

# ── fields & schema (8) ──────────────────────────────────────────────────────
c("field-number", 8, "field",
  "The MISSING numeric field atom — string/slug/text/boolean/select/datetime/color/image/reference all exist; number does not. Every schema with a price, count, or weight hits this wall first.",
  '{ "type": "field-number",\n  "name": "price", "label"?: "Price",\n  "min"?: 0, "max"?: 10000, "step"?: 0.01, "unit"?: "NOK" }')
c("field-url", 8, "field",
  "URL field atom with validation and a link-preview affordance (pairs with the link-preview block and the shipped OG manifest).",
  '{ "type": "field-url",\n  "name": "website", "label"?: "Website",\n  "allow"?: ["https"] }')
c("field-file", 8, "field",
  "File/attachment field storing through the media plugin — schemas model downloads (spec PDFs, firmware) with a string URL hack today.",
  '{ "type": "field-file",\n  "name": "manual", "accept"?: [".pdf", ".zip"], "maxSize"?: 10485760 }')
c("field-geopoint", 8, "field",
  "Lat/lng picker atom — the schema-side twin of the map family; hundesteder's places store coordinates as two floats with no picker.",
  '{ "type": "field-geopoint",\n  "name": "location", "label"?: "Location",\n  "default"?: [59.91, 10.75] }')
c("field-json", 8, "field",
  "Raw JSON field atom with syntax validation — escape hatch for structured config values (webhook payload templates, feature flags).",
  '{ "type": "field-json",\n  "name": "config", "schema"?: { ...JSON-schema subset... } }')
c("field-rating", 8, "field",
  "Bounded rating atom (stars / 1-N scale) — reviews, quiz scoring, the Cody-style graded dimensions as schema data.",
  '{ "type": "field-rating",\n  "name": "score", "max": 5, "style"?: "stars" | "number" }')
c("field-tags", 8, "field",
  "Weighted-tag editor atom — Barkpark's OWN tag contract ({tag, strength, rationale}, distinct strengths) has no field control; every paper publish wall depends on hand-typed JSON.",
  '{ "type": "field-tags",\n  "name": "tags", "registry": "tag",   // registered tag docs\n  "distinctStrengths": true }')
c("schema-card", 8, "field",
  "Live render of a schema type's field table (name, type, required, description) — SDK and API docs re-type schemas by hand and drift from the source of truth.",
  '{ "type": "schema-card",\n  "schema": "post", "dataset"?: "production",\n  "show"?: ["types", "required"] }',
  prof_edit_keep=True, tier=":widget",
  cost="STATIC (server has the schema)", view="server-painted table",
  edit="E3 — reference + options island", tui="table port", react="port",
  email="REAL render (static table)", flags=R_FLAG + " — needs a schema-source resolver for blocks")

# ── navigation & meta (8) ────────────────────────────────────────────────────
c("toc", 9, "nav",
  "Heading-derived table of contents with anchor links — a confirmed Notion gap, a GitBook standard, and painfully absent from THIS 500-block paper. Server walks the blocks; zero client JS.",
  '{ "type": "toc",\n  "depth"?: 2, "numbered"?: false,\n  "sticky"?: true               // viewport affordance, View-only }')
c("breadcrumb", 9, "nav",
  "Ancestor trail (workspace / project / collection / paper) — the Notion gap; readers landing deep from search have no sense of place.",
  '{ "type": "breadcrumb",\n  "show"?: ["project", "collection"] }',
  flags=R_FLAG + " — needs the doc-graph ancestors exposed to blocks")
c("backlinks", 9, "nav",
  "Papers that reference THIS paper — the server capability already exists (reverse_referencers); no block surfaces it. The knowledge-graph payoff for free.",
  '{ "type": "backlinks",\n  "limit"?: 10, "kinds"?: ["paper", "task"] }',
  flags=R_FLAG + " — block-level plumbing to reverse_referencers")
c("related-papers", 9, "nav",
  "Related papers by shared weighted tags — the registered-tag system (strengths, rationale) is a similarity signal nothing reads yet.",
  '{ "type": "related-papers",\n  "by"?: "tags", "limit"?: 5 }',
  flags=R_FLAG + " — needs a content-query resolver")
c("synced-block", 9, "i2",
  "Notion's synced block: one fragment mirrored live across papers, edited anywhere. embed (![[note]]) covers whole-note transclusion; this is block-granular with write-back — honest: the consistency semantics are the hard 80%.",
  '{ "type": "synced-block",\n  "source": {"paper": "policies", "blockId": "sec-3"},\n  "editable"?: false }')
c("link-preview", 9, "nav",
  "Craft's card-link: a rich URL preview card — and the repo ALREADY ships the machinery: the OG preview manifest (preview-contract, no-oEmbed law). Fetch at save, render static, never iframe.",
  '{ "type": "link-preview",\n  "href": "https://...",\n  "fetched"?: {"title": "...", "description": "...", "image": "..."}  // snapshot at save }',
  cost="STATIC + save-time fetch (OG manifest precedent)")
c("paper-list", 9, "nav",
  "Query-driven list of papers (by tag/type/recency) — index pages and team homepages hand-curate link lists that go stale weekly.",
  '{ "type": "paper-list",\n  "filter": {"tags": ["portabledoc"]}, "sort"?: "-updatedAt",\n  "limit"?: 10, "show"?: ["description", "date"] }',
  flags=R_FLAG + " — needs a content-query resolver")
c("freshness-badge", 9, "nav",
  "Slite's verification badge: verified-by + last-verified + stale-after-N-days — docs rot silently; this block makes staleness a visible, gateable state (the distrust-vacuous-green culture, applied to prose).",
  '{ "type": "freshness-badge",\n  "verifiedBy": "pelle", "verifiedAt": "2026-07-17",\n  "staleAfterDays"?: 90 }')

assert len(C) == 100, f"need 100, got {len(C)}"

# ── build blocks ─────────────────────────────────────────────────────────────
blocks = []
A = blocks.append

A({"id": "bw-eyebrow", "type": "eyebrow", "text": "PD BLOCK WISHLIST · WAVE 1 · 2026-07-17"})
A({"id": "bw-ingress", "type": "ingress", "text":
   "One hundred NEW block candidates for PortableDoc — deduped against the 62 canonical types (plus the TUI dashboard and this wave's blockquote), graded honestly per surface, priced by cost tier, and wired to real demand evidence. The companion Review paper ranks them by usefulness; this paper is the raw material, and it is written IN the product it describes."})

A(callout("bw-method", "info", "Method",
  "Baseline: tiers.ex's 62 canonical types (25 element + 35 widget + 2 section, test-enforced) + TUI-only dashboard + blockquote (born this wave) — charter D1. Struck by the binding dedup verdicts (D9): linear gauge (stat max-bar + 1-row gauge-list cover it), toned callout (5 tones shipped), and generic \"mermaid support\" (the browser is a full pass-through). The chat-approval / chat-question / chat-plan rows once wished for are ALREADY first-class blocks — demand satisfied before this list was written."))

A({"id": "bw-keys", "type": "section", "layout": {"mode": "grid", "tracks": 2}, "blocks": [
    callout("bw-keys-a", "neutral", "How to read a candidate",
      "Each entry: anchor + kebab type name, one-line pitch with its demand evidence, an Attrs-contract data-shape sketch (the ratified pbp-tui-creative-slate style), then one grade line: family · tier · cost · View · Edit (E0-E4) · TUI · React · Email. Grades are per surface and never inferred from each other (D2 — the React/Edit missing-sets overlap on only 4 of 14 items)."),
    callout("bw-keys-b", "warning", "Honesty rules",
      "Data-viz Edit defaults to E3 — a JSON textarea is not WYSIWYG (D3). Email badges split REAL renders from degrades (D4). Cost tiers are calibrated on shipped datapoints (D6/D7): STATIC ~9-14 files; I1 dual hydration cost asciicast 30-40 files; I2 adds a route + security surface; in-canvas editability is a separate ~514-line STUDIO-EDIT surcharge. Blocks needing non-task data carry a resolver flag; plugin-domain blocks carry a seam flag (D10)."),
  ]})

A(table("bw-egrades", ["Edit grade", "Meaning"], [
  ["E0", "opaque carry — the canvas holds the block, no affordance"],
  ["E1", "read-only reference atom"],
  ["E2", "server-painted, no island"],
  ["E3", "server-paint + JSON/query island (data-viz default, D3)"],
  ["E4", "true in-canvas (a=control atom, b=WYSIWYG body, c=no-data leaf)"],
]))

A(table("bw-costs", ["Cost tier", "Calibration (D6/D7)"], [
  ["STATIC", "scaffy-startable, ~9-14 files/block when it reuses a rendering vocabulary"],
  ["I0", "zero-JS interactive (native <details>/CSS — collapsible-callout precedent)"],
  ["I1", "hydrated-stateless: dual implementations (client.ts + Phoenix hook) + real-browser test; asciicast cost 30-40 files"],
  ["I2", "backend-write: I1 + new API route + resolver + security surface"],
  ["STUDIO-EDIT", "in-canvas editability surcharge, ~514 lines / 8 files per block — separate from birth"],
]))

A(heading("bw-demand-h", 2, "The demand springs"))
A({"id": "bw-demand-cols", "type": "columns", "columns": [
    [para("bw-demand-p1",
      "Demand is measured, not vibed. The ledger census over 294 guerrilla papers shows what authors reach for when blocks exist (right). Beyond the ledger: the SAME dep-free Canvas2D map is duplicated in web/components/listings-map.tsx and apps/hundesteder/components/places-map.tsx (the geo family's origin story); the Projects Board shipped a bespoke Gantt (the timeline family's); and ~25 confirmed competitor gaps span Notion (synced block, ToC, breadcrumb, equation, template button, gallery), Coda (action buttons), Craft (card-link, toggle list), Observable (chart cell, data table, reactive inputs), GitBook (try-it console, expandable, tabs), Typst (vector diagram, tree, scientific plot, chemfig) and Slite (freshness badge)."),
     ],
    [table("bw-census", ["Block", "Uses"], [
      ["paragraph", "4969"], ["heading", "3232"], ["list", "759"], ["callout", "676"],
      ["table", "207"], ["code", "156"], ["terminal", "100"], ["diagram", "37"],
      ["chart", "25"], ["stats", "23"], ["heatmap / gauge-list / roadmap", "8 each"],
    ])],
  ]})

A(heading("bw-live-h", 2, "The ledger, live"))
A(para("bw-live-p",
  "These three data-viz blocks carry a query, not a snapshot — the task resolver runs them fresh on every page load against the real ledger (COUNT aggregates only, per D10; sum/avg stay k-anon-gated). What you see below is this workspace's task system, now."))
A({"id": "bw-live-stat", "type": "stat", "label": "tasks in this workspace (live count)",
   "query": {"source": "tasks", "agg": {"op": "count"},
             "over": {"bucket": "week", "on": "inserted_at", "last": 8}}})
A({"id": "bw-live-chart", "type": "chart", "kind": "line",
   "caption": "Tasks created per week, by lifecycle status — live COUNT aggregate.",
   "axes": {"min": 0},
   "query": {"source": "tasks", "groupBy": "status",
             "over": {"bucket": "week", "on": "inserted_at", "last": 8},
             "agg": {"op": "count"}}})
A({"id": "bw-live-heat", "type": "heatmap", "values": True,
   "query": {"source": "tasks", "groupBy": ["status", "priority"], "agg": {"op": "count"}}})

A(heading("bw-shape-h", 2, "The wishlist at a glance"))
n_res = sum(1 for x in C if x["ov"].get("flags", "").startswith("blocked"))
n_seam = sum(1 for x in C if x["ov"].get("flags", "") == S_FLAG)
def costof(x):
    return x["ov"].get("cost", P[x["prof"]][1])
n_static = sum(1 for x in C if costof(x).startswith("STATIC"))
n_i0 = sum(1 for x in C if costof(x).startswith("I0"))
n_i1 = sum(1 for x in C if costof(x).startswith("I1"))
n_i2 = sum(1 for x in C if costof(x).startswith("I2"))
A({"id": "bw-statgrid", "type": "stat-grid", "items": [
    {"label": "candidates", "value": "100"},
    {"label": "families", "value": "10"},
    {"label": "STATIC-cost", "value": str(n_static), "denom": "100"},
    {"label": "I0 zero-JS", "value": str(n_i0)},
    {"label": "I1 hydrated", "value": str(n_i1)},
    {"label": "I2 backend-write", "value": str(n_i2)},
    {"label": "resolver-flagged", "value": str(n_res)},
    {"label": "plugin-seam-flagged", "value": str(n_seam)},
  ]})

fam_counts = {}
for x in C: fam_counts[x["fam"]] = fam_counts.get(x["fam"], 0) + 1
mm = ['flowchart TD', '  W["Block Wishlist 100"]']
for i, (fname, _) in enumerate(FAMS):
    safe = fname.replace(" & ", " and ")
    mm.append(f'  W --> F{i}["{safe} ({fam_counts[i]})"]')
A({"id": "bw-taxonomy", "type": "diagram",
   "caption": "Ten families (charter D8) — family x code-tier matrix; nearly every candidate lands :widget.",
   "source": "\n".join(mm)})

A({"id": "bw-pull", "type": "pullquote",
   "text": "A wishlist is only honest if every wish carries its price tag and its proof of demand."})
A({"id": "bw-div-intro", "type": "divider"})

# family sections + candidates
FAM_INTROS = [
 "The largest family, because the wish named graphs first. chart (line), stat, stats, stat-grid, heatmap and gauge-list exist; everything here is a missing FORM, not a missing datum — plus two Observable-inspired query-native blocks at the end.",
 "The browser already renders every mermaid kind; the terminal renders only what has a hand-built renderer. Seven per-kind TUI renderers (D9's answer to 'mermaid support'), then the notation blocks Typst and Notion prove people need.",
 "Everything-is-a-task makes the ledger the liveliest data source in the product. Two candidates ride the existing count resolver nearly for free; the rest state exactly which plumbing they wait on (D10).",
 "Long-form structure: the apparatus of serious documents — footnotes, procedures, changelogs, verdicts. Cheap (STATIC), email-REAL, and heavily demanded by the corpus's own writing patterns.",
 "Disclosure and interaction, priced by I-tier (D7). The I0 entries reuse callout's shipping <details> pattern; the I2 entries are honest about buying a route + security surface.",
 "Media beyond image/figure/asciicast: the census shows zero video in 294 papers because no block exists. All degrade honestly (poster, link, transcript).",
 "Born from a real dedup: the same Canvas2D map shipped twice in this repo. One shared core, five compositions.",
 "Developer-doc staples: endpoint cards, code tabs, install snippets — plus two github-plugin cards that wait on the block-registration seam.",
 "Schema atoms: field-number is the loudest single gap in the family (no numeric field exists). Field atoms are E4a by nature — their canvas control IS the block.",
 "Blocks that make the corpus navigable: ToC, backlinks (the server capability already exists), link previews via the shipped OG manifest, and Slite's freshness badge as gate culture for prose.",
]

num = 0
for fi, (fname, _) in enumerate(FAMS):
    A(heading(f"bw-fam-{fi}", 2, f"{fname} ({fam_counts[fi]})"))
    A(para(f"bw-fam-{fi}-p", FAM_INTROS[fi]))
    for x in [x for x in C if x["fam"] == fi]:
        num += 1
        nid = f"{num:03d}"
        prof = P[x["prof"]]
        ov = x["ov"]
        tier = ov.get("tier", prof[0]); cost = ov.get("cost", prof[1])
        view = ov.get("view", prof[2]); edit = ov.get("edit", prof[3])
        tui = ov.get("tui", prof[4]); react = ov.get("react", prof[5])
        email = ov.get("email", prof[6]); flags = ov.get("flags", "none")
        A(heading(f"bw-{nid}", 3, f"B{nid} {x['name']}"))
        A(para(f"bw-{nid}-p", x["pitch"]))
        A(code(f"bw-{nid}-a", x["attrs"]))
        meta = (f"{fname} · {tier} · cost: {cost} · View: {view} · Edit: {edit} · "
                f"TUI: {tui} · React: {react} · Email: {email} · Flags: {flags}")
        A(para(f"bw-{nid}-m", meta))

A({"id": "bw-div-end", "type": "divider"})
A(callout("bw-next", "success", "What happens next",
  "The Review paper (round 2 of this wave) scores all 100 on the D5 rubric — demand 35%, frequency 25%, unlock 25%, reach 15%, cost as tiebreak only — and ranks them S/A/B/C. Every S-tier candidate gets filed as a bp task; the S tier IS the backlog for wave 2."))

assert num == 100
with open(OUT, "w") as f:
    json.dump(blocks, f, ensure_ascii=False)
print("blocks:", len(blocks), "candidates:", num,
      "| static", n_static, "i0", n_i0, "i1", n_i1, "i2", n_i2,
      "| resolver", n_res, "seam", n_seam,
      "| bytes", len(json.dumps(blocks)))
