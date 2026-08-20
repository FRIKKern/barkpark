# Generates the block payload for Paper block-wishlist-100-review.
import json
from collections import Counter, OrderedDict
from score_data import S, FAM, score, tier

def T(v): return {"type": "text", "value": v}
def cell(v): return [T(str(v))]
def para(pid, txt): return {"id": pid, "type": "paragraph", "content": [T(txt)]}
def head(pid, lvl, txt): return {"id": pid, "type": "heading", "level": lvl, "text": txt}
def table(pid, headr, rows):
    return {"id": pid, "type": "table",
            "head": [cell(h) for h in headr],
            "rows": [[cell(c) for c in r] for r in rows]}

tiers = {b: tier(b, v) for b, v in S.items()}
scores = {b: score(v) for b, v in S.items()}
FLAG_LABEL = {"RESOLVER": "resolver (D10)", "SEAM": "plugin seam (D10)", "D22": "D22 parity"}

blocks = []
A = blocks.append

A({"id": "rv-eyebrow", "type": "eyebrow", "text": "PD BLOCK WISHLIST · THE USEFULNESS REVIEW · WAVE 1 · 2026-07-18"})
A({"id": "rv-title", "type": "heading", "level": 1, "text": "Block Wishlist 100 — the Usefulness Review, ranked in tiers S/A/B/C"})
A({"id": "rv-ingress", "type": "ingress", "text":
   "All 100 wishlist candidates (B001-B100) from block-wishlist-100, scored on the charter D5 rubric and ranked "
   "S/A/B/C with usefulness as the primary criterion. The scoring is demand-grounded and feasibility-honest: every "
   "prerequisite flag is visible, every dedup ruling applied, and build cost never enters the score - only the tiebreak. "
   "The S tier is the ready-to-build backlog for wave 2, filed as pbw-stier-* tasks under pd-block-wishlist-epic."})
A({"id": "rv-method-callout", "type": "callout", "tone": "info", "title": "The rubric (charter D5)",
   "content": [T("Each candidate scores 1-5 on four axes: demand evidence (weight 35%), frequency-of-use plausibility "
                 "(25%), unlock-power (25%), cross-surface reach (15%, honest per D2-D4). Usefulness = the weighted sum. "
                 "Build cost is a TIEBREAK only, read via the D6/D7 cost tier. Tier rule: S requires score >= 4.0 AND no "
                 "unmet prerequisite flag; a prerequisite-flagged candidate caps at A regardless of score; charter D22 "
                 "dedup rulings cap at C. Bands: A >= 3.4, B >= 2.7, C below.")]})

# ── verdict at a glance ──
A(head("rv-h-verdict", 2, "The verdict at a glance"))
tc = Counter(tiers.values())
flagged_resolver = sum(1 for v in S.values() if "RESOLVER" in v[8])
flagged_seam = sum(1 for v in S.values() if v[8] == "SEAM")
A({"id": "rv-statgrid", "type": "stat-grid", "items": [
    {"label": "S - build now", "value": str(tc["S"]), "denom": "100"},
    {"label": "A - next in line", "value": str(tc["A"]), "denom": "100"},
    {"label": "B - worthy, not yet", "value": str(tc["B"]), "denom": "100"},
    {"label": "C - low / capped", "value": str(tc["C"]), "denom": "100"},
    {"label": "resolver-blocked (capped A)", "value": str(flagged_resolver)},
    {"label": "plugin-seam-blocked", "value": str(flagged_seam)},
    {"label": "D22 parity entries", "value": "7"},
    {"label": "top score", "value": "4.75"},
]})
A({"id": "rv-tier-chart", "type": "chart", "kind": "bars",
   "caption": "Candidates per tier - COUNT of the 100 reviewed (one series, D21-safe).",
   "axes": {"min": 0, "xLabels": ["S", "A", "B", "C"]},
   "series": [{"label": "candidates", "points": [tc["S"], tc["A"], tc["B"], tc["C"]]}]})

fams = ["dv", "dg", "ld", "ed", "ix", "me", "geo", "dev", "fs", "nav"]
cells = []
for fk in fams:
    row = []
    for t in ["S", "A", "B", "C"]:
        row.append(sum(1 for b, v in S.items() if v[1] == fk and tiers[b] == t))
    cells.append(row)
A({"id": "rv-fam-heat", "type": "heatmap", "values": True,
   "rowLabels": [FAM[f] for f in fams], "colLabels": ["S", "A", "B", "C"],
   "cells": cells})
A(para("rv-verdict-note",
       "The D8 family-by-tier matrix above is exhaustive: the ten families times four tiers account for all 100 candidates. "
       "Editorial & structure, dev & code, and interactive & disclosure carry the densest S/A mass - they are cheap "
       "(mostly STATIC/I0 compose.ex emitters with REAL email renders) and sit on the most-cited demand. Data-viz is wide "
       "but mid-band: the vocabulary reuses one emitter family, so its strongest members (bar-chart) carry the rest. "
       "Diagrams & technical is barbell-shaped: equation is a top-4 candidate while seven D22 parity entries anchor the C tier."))
A({"id": "rv-div-1", "type": "divider"})

# ── demand evidence ──
A(head("rv-h-evidence", 2, "Demand evidence - what the scores cite"))
A(para("rv-ev-1",
       "Ledger evidence (the strongest signal class): the 294-paper census behind the wishlist counts 23 stat uses, 207 "
       "hand-typed tables, and ZERO video blocks - absence-by-missing-block, not absence of appetite. The broken-block "
       "drift is cited per charter D14 in its only citable form: the storage-path COALESCE census - "
       "coalesce(content->'blocks', content->'body'->'blocks') over published papers -> 77 placeholders "
       "(bulleted-list 27, bullet_list 22, bulleted_list 15, quote 8, numbered_list 3, bulletList 2), triple-confirmed; "
       "a naive single-path query undercounts to 51 and is not citable. The drift proves authors reach for block names "
       "that do not exist - the wishlist's core demand thesis."))
A(para("rv-ev-2",
       "Code duplication evidence: the SAME dep-free Canvas2D map is maintained twice (web/components/listings-map.tsx and "
       "apps/hundesteder/components/places-map.tsx) - B070's demand score is 5 because a block retires two live forks. "
       "Repo prior art: internal/pdrender/dashboard.go already renders {label, blocks} tab sets (B052), and the OG preview "
       "manifest (no-oEmbed law) already does link-preview's fetch-at-save work (B098). Competitor pull: confirmed gaps in "
       "Notion (toc, equation, breadcrumb), Typst (equation, scientific-plot, vector/tree diagrams, citations), GitBook "
       "(steps, tabs, expandable, openapi-console), Craft (toggle-list, card links), Observable (chart-cell, data-grid, "
       "reactive-input), Coda (action-button), Slite (freshness-badge)."))

# ── dedup guard ──
A(head("rv-h-dedup", 2, "Dedup guard (charter D22, binding)"))
A(para("rv-dedup-1",
       "Checked all 100 candidates against the binding rulings. (1) chat-approval, chat-question and chat-plan are EXISTING "
       "shipped block types (tiers.ex, #3514/#3742) - NO wishlist entry re-proposes them; the pool is clean of that dedup "
       "failure. (2) Per-kind TUI mermaid renderers are parity work under the ONE existing diagram block, never new-block "
       "candidates: B018-B024 are therefore capped at tier C with an explicit D22 flag - the terminal parity work itself "
       "stays legitimate but routes through the terminal-mermaid wave backlog, not a block build. (3) horizontal-bars is "
       "legitimate only as a distinct labeled ranking/leaderboard form: B003 bar-chart PASSES this test - it is the labeled "
       "categorical-bars block (gauge-list TUI vocabulary as prior art), not 'chart but sideways', and chart itself draws "
       "line series only."))
A({"id": "rv-div-2", "type": "divider"})

# ── S tier ──
A(head("rv-h-stier", 2, "S tier - the ready-to-build backlog (12)"))
S_ORDER = ["B093", "B043", "B003", "B025", "B075", "B077", "B052", "B062", "B085", "B053", "B040", "B034"]
task_slug = {"B093": "toc", "B043": "steps", "B003": "bar-chart", "B025": "equation",
             "B075": "api-endpoint", "B077": "code-tabs", "B052": "tabs", "B062": "video",
             "B085": "field-number", "B053": "expandable", "B040": "footnote", "B034": "criteria-progress"}
rows = []
for rank, b in enumerate(S_ORDER, 1):
    v = S[b]
    rows.append([rank, b, v[0], FAM[v[1]], f"{scores[b]:.2f}", v[3], "pbw-stier-" + task_slug[b]])
A(table("rv-stier-table",
        ["#", "ID", "block", "family", "usefulness", "cost tier", "bp task"],
        rows))
A(para("rv-stier-note",
       "Ordering within equal scores is the D5 cost tiebreak: toc and steps tie at 4.75 (both STATIC); bar-chart and "
       "equation tie at 4.60 (both STATIC); video (STATIC) edges field-number (STATIC + STUDIO-EDIT surcharge) at 4.20; "
       "expandable (I0, reusing callout's shipped native-details pattern) edges footnote (STATIC with two-way wiring) at "
       "4.15. criteria-progress is the one live-data entry that is genuinely unblocked: resolver rows already carry "
       "acceptance criteria, so it rides the existing task resolver with no new plumbing. Eight of twelve are STATIC - "
       "scaffy add-block-type is the suggested build path for those (charter D18: read the LIVE count pins - React/parity "
       "toHaveLength and EXPECTED_COUNT at their current values - never the stale scaffy corpus EXAMPLES). code-tabs and "
       "tabs are I1 (dual hydration + real-browser test, asciicast cost precedent 30-40 files)."))
A(para("rv-stier-tasks",
       "Every S-tier candidate above is filed as a PUBLISHED bp task (id in the last column), parented under "
       "pd-block-wishlist-epic with wave_paper=block-wishlist-wave-2026-07-18, priority 2, each carrying the pitch, "
       "data shape, per-surface notes, cost tier, prerequisites and a merge-gated 'PR merged' criterion."))
A({"id": "rv-div-3", "type": "divider"})

# ── full ranking per family ──
A(head("rv-h-full", 2, "The full ranking - all 100, by family"))
A(para("rv-full-key",
       "One row per candidate - this is each candidate's single scored appearance. Columns D/F/U/R are the four D5 axes "
       "(demand, frequency, unlock, reach, each 1-5); usefulness is the weighted sum; flags mark unmet prerequisites "
       "(which cap the tier at A) and D22 rulings (which cap at C)."))

FAM_BLURB = {
 "dv": "One shared Render.DataViz emitter vocabulary carries the whole family; bar-chart is the S-tier spearhead and the "
       "rest ladder behind it. chart-cell and data-grid score A on Observable-grade unlock but wait on the resolver seam.",
 "dg": "equation is the family's S-tier headline - a confirmed gap in both Notion and Typst with a zero-JS MathML path. "
       "B018-B024 are D22-capped parity entries; chemfig is the honest tail.",
 "ld": "The liveliest demand (everything-is-a-task doctrine) but the most prerequisite-bound family: five of eleven wait "
       "on resolver plumbing (tr-agg-resolver-wave), two on the plugin seam. criteria-progress is the unblocked S-tier pick; "
       "burndown-chart is the next-cheapest live read.",
 "ed": "The highest tier-mass family: cheap compose.ex emitters, REAL email renders, and docs-platform-staple demand. "
       "steps and footnote make S; faq, definition-list, changelog, glossary-term, pros-cons and hero all sit high in A.",
 "ix": "tabs (repo prior art in dashboard.go) and expandable (shipped details pattern, repriced by D9) make S cheaply. "
       "The I2 write-path members (action-button, checklist, reactive-input) score high on unlock but carry the security "
       "surface as their honest cost.",
 "me": "video is the family S pick on census-proven absence. file-attachment and gallery lead A; svg-inline carries an "
       "explicit sanitizer security cost.",
 "geo": "map is the top A candidate in the whole review (3.95) on fork-retiring demand; the rest of the family composes "
       "on its Canvas2D core once it exists.",
 "dev": "api-endpoint and code-tabs make S on docs-staple demand cited from this very repo. json-viewer, csv-table, kbd "
       "and package-install stack the A band; the github-plugin cards wait on the seam.",
 "fs": "field-number is the S-tier pick - the missing atom every schema hits first. field-tags (Barkpark's own contract "
       "with no control) leads the rest; schema-card waits on a schema-source resolver.",
 "nav": "toc is the review's top score (4.75). link-preview rides shipped OG machinery into A; paper-list scores 4.00 but "
       "caps at A on the content-query resolver; backlinks surfaces an existing server capability once block plumbing lands.",
}

for fk in fams:
    members = [b for b in sorted(S) if S[b][1] == fk]
    members.sort(key=lambda b: (-scores[b], b))
    A(head("rv-h-fam-" + fk, 3, FAM[fk] + f" ({len(members)})"))
    A(para("rv-fam-blurb-" + fk, FAM_BLURB[fk]))
    rows = []
    for b in members:
        name, fam, ct, cost, d, f, u, r, flags, ev = S[b]
        flag_txt = FLAG_LABEL.get(flags, flags) if flags else "-"
        rows.append([b, name, ct, cost, d, f, u, r, f"{scores[b]:.2f}", tiers[b], flag_txt])
    A(table("rv-fam-table-" + fk,
            ["ID", "block", "code tier", "cost", "D", "F", "U", "R", "usefulness", "tier", "flags"],
            rows))

A({"id": "rv-div-4", "type": "divider"})

# ── tier narratives ──
A(head("rv-h-atier", 2, "A tier (32) - next in line"))
A(para("rv-atier",
       "Unblocked A leaders, in score order: map 3.95 (the fork-retiring Canvas2D consolidation - first promotion candidate "
       "once an S slot frees), then a dense 3.90 band of cheap REAL-email blocks: faq, definition-list, changelog, "
       "toggle-list, file-attachment, json-viewer, csv-table, link-preview. checklist and action-button (3.85) lead the "
       "I2 write-path wave that should ship together behind one security review. Capped-at-A by prerequisite: paper-list "
       "(4.00 - the one candidate whose raw score is S-grade), data-grid 3.85, backlinks 3.75, schema-card 3.75, "
       "epic-heartbeat / activity-feed / timeline-gantt 3.60, chart-cell 3.50 - all resolver-gated (tr-agg-resolver-wave "
       "is the unlock); pr-status 3.75 and quiz-embed 3.60 wait on the plugin block-registration seam."))
A(head("rv-h-btier", 2, "B tier (43) - worthy, not yet"))
A(para("rv-btier",
       "The B band is real but outranked: the data-viz long tail (radial-dial, histogram, area-chart, scatter-plot, "
       "calendar-heatmap and scientific-plot lead it at 3.15; radar, funnel, waterfall, treemap and sankey sit behind), "
       "the live-data middle (burndown-chart and claim-monitor at 3.25, then sheet-chart, task-calendar, deploy-status, "
       "paper-stats - all but burndown prerequisite-flagged), the field-atom siblings (url, file, json, rating, geopoint), "
       "the remaining media embeds (audio, pdf-embed, svg-inline, image-compare, icon), geo composition members (map-route, "
       "location-card), editorial support (sidenote, chronology, citation-list), and the heavier interactive pieces "
       "(carousel, poll, template-button, openapi-console, synced-block). "
       "Wave 2+ should re-score B after the S wave ships - the data-viz tail gets cheaper "
       "once bar-chart births the DataViz emitter family."))
A(head("rv-h-ctier", 2, "C tier (13) - low or capped"))
A(para("rv-ctier",
       "Seven D22-capped parity entries (B018-B024) - legitimate terminal-mermaid work, wrong ledger for it. Six genuinely "
       "low scores: box-plot 2.55, choropleth 2.40, geojson-map 2.40, countdown 2.40, page-break 2.00 and chemfig 1.55 - "
       "the wishlist itself predicted chemfig's rank; honesty kept it there."))

A({"id": "rv-next-callout", "type": "callout", "tone": "success", "title": "What happens next",
   "content": [T("Wave 2 builds the S tier: eight STATIC candidates ride scaffy add-block-type (live count pins per D18), "
                 "tabs/code-tabs ride the I1 hydration pattern, field-number lands with its Studio control, and "
                 "criteria-progress rides the existing task resolver. tr-agg-resolver-wave unblocks the eight resolver-capped "
                 "A candidates; the plugin block-registration seam (pbw-backlog-plugin-block-seam) unblocks the five "
                 "seam-flagged candidates (two of them A-tier). Each pbw-stier-* task carries its full brief.")]})
A({"id": "rv-div-end", "type": "divider"})
A(para("rv-colophon",
       "Written in the product it reviews. Input: Paper block-wishlist-100 (100 candidates, live-verified). Rubric: charter "
       "D5; cost tiers D6/D7; families D8; dedup rulings D9/D22; dataviz constraints D21. Review slice: "
       "pbw-w1-usefulness-review-paper, wave Paper block-wishlist-wave-2026-07-18."))

# sanity: every candidate appears exactly once in family tables
ids_in_tables = []
for blk in blocks:
    if blk["type"] == "table" and blk["id"].startswith("rv-fam-table-"):
        for r in blk["rows"]:
            ids_in_tables.append(r[0][0]["value"])
assert sorted(ids_in_tables) == ["B%03d" % i for i in range(1, 101)], "family tables must cover all 100 exactly once"
assert len(ids_in_tables) == len(set(ids_in_tables))

json.dump(blocks, open("review_blocks.json", "w"), indent=1)
print("blocks:", len(blocks), "| bytes:", len(json.dumps(blocks)))
print("tier counts:", Counter(tiers.values()))
