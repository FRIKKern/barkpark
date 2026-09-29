<!-- doc-tier: cold | canonical-for: spd-b22-text-xs-density-sweep | budget: 6000tok -->
# spd-b22 — `.text-xs` 11→12px density blast-radius sweep (2026-09-10)

> HISTORICAL RECORD (2026-09-10) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Task: `spd-b22-text-xs-density-blast-radius`. Sweeps the call sites of the `.text-xs`
utility after spd-s5 (#4566) made it resolve `var(--text-xs)` = 12px instead of a
hardcoded 11px.

## Census — the filing said 98, it is 106

    $ git grep -c 'text-xs' origin/main -- api/lib | grep -v root.html.heex
    api/lib/barkpark/plugins/tickets/inbox_live.ex:1
    api/lib/barkpark/portable_doc/render/components.ex:10
    api/lib/barkpark_web/components/studio_components/modals.ex:1
    api/lib/barkpark_web/live/studio/api_tester_live.ex:11
    api/lib/barkpark_web/live/studio/api_tester_live/components.ex:1
    api/lib/barkpark_web/live/studio/chat_hosts_live.ex:3
    api/lib/barkpark_web/live/studio/chat_live.ex:73
    api/lib/barkpark_web/live/studio/chat_tool_renderer.ex:4
    api/lib/barkpark_web/live/studio/tmux_live.ex:2
    → 106 occurrences in 9 files

`git grep -o -n` returns 106 as well (one occurrence per line), and none of the 106 is a
`--text-xs` token reference — all are `class="text-xs …"`. The same census on the commit
the box was serving (`99d5c763b`) is also 106.

The filing's "98 across LiveViews (badges, meta rows, table cells, chips)" understates the
count by 8 and mis-describes the shape: **73 of 106 (69%) sit in one file, `chat_live.ex`**,
and 10 more are HTML-string emitters in `portable_doc/render/components.ex`. There is no
broad spray across "the other Studio LiveViews" — there are two heavy files and seven light
ones.

## Method

Deployed build, authenticated admin browser (login-ticket handoff), Chrome DevTools.
`.text-xs` resolved to **12px** on the live page (`--text-xs: 12px`, computed 12px).
The box redeployed mid-sweep: early surfaces on `99d5c763b`, later ones on `e4dc0f3e8`.
Both carry `.text-xs { font-size: var(--text-xs); }` at root.html.heex:679.

Per surface, at 1440 and 900, for every `.text-xs` element with client rects:
computed font-size; horizontal overflow (`scrollWidth - clientWidth > 1`) split into
*scrollable* (`overflow-x: auto|scroll` — by design), *clipped* (`hidden|clip`) and
*plain overflow*; row-container overflow; document-level overflow.

**Control (this is what makes the sweep an attribution and not a census):** every
measurement is taken twice — once as shipped, once with `.text-xs{font-size:11px!important}`
injected. A defect belongs to spd-s5 only if the count is **higher at 12px than at 11px**.

## Sweep table

| surface | URL | width | #text-xs | overflow | clipped | rowOvf | docOvf | attributable (12−11) |
|---|---|---|---|---|---|---|---|---|
| API tester (default panel) | `/w/default/p/default/d/production/studio/api-tester` | 1440 | 7 | 0 | 0 | 0 | no | 0 |
| API tester (default panel) | same | 900 | 7 | 0 | 0 | 0 | no | 0 |
| API tester — Schema reference (40 cards, 40 tables) | same → "Schema reference" | 1440 | 462 | 0 | 0 | 0 | no | 0 |
| API tester — Schema reference | same | 900 | 462 | 0 | 0 | 9 | no | **+1 row** |
| API tester — response state | same → "List schemas" → Run | 900 | 2 | 0 | 0 | 0 | no | 0 |
| Chat desk (session list) | `/studio/chat` | 1440 | 89 | 0 | 34* | 0 | no | 0 |
| Chat desk (session list) | `/studio/chat` | 900 | 89 | 0 | 34* | 0 | no | 0 |
| Chat transcript (prose) | `/studio/chat/fcb4632f-…` | 1440 | 144 | 0 | 34* | 0 | no | 0 |
| Chat transcript (tools + 22 diffs + 113 thinking) | `/studio/chat/bf209919-…` | 1440 | 533 | 0 | 34* | 0 | no | 0 |
| Chat transcript (tools + diffs) | `/studio/chat/bf209919-…` | 900 | 534 | 0 | 34* | 0 | no | 0 |
| Chat hosts | `/w/default/p/default/studio/chat-hosts` | 900 | 0 (empty state) | – | – | – | no | n/a |
| Paper — `bp-diff` + `bp-filetree` | `/w/…/studio/paper/portabledoc-showcase` | 1440 | 2 | 0 | 0 | 0 | no | 0 |
| Paper — same | same | 900 | 2 | 0 | 0 | 0 | no | 0 |
| Profile modal | `/w/…/studio` → avatar | 1440 | 1 | 0 | 0 | 0 | no | 0 |
| Profile modal | same | 900 | 1 | 0 | 0 | 0 | no | 0 |
| tmux console | `/studio/tmux` | 1440 | 2 | 0 | 0 | 0 | no | 0 |
| tmux console | `/studio/tmux` | 900 | 2 | 0 | 0 | 0 | no | 0 |

\* the 34 "clipped" are the chat sidebar's session-preview lines, ellipsized by design.
The count is **identical at 11px and 12px**, so none of it is attributable.

Screenshots (not committed — captured under the sweep worker's scratch dir
`$ORCH/tmp/lead-studio/studio-w22/shots/`, listed here so the record names its evidence): `api-tester__1440.png`, `api-tester__900.png`,
`api-schema-ref__1440.png`, `api-schema-card-overflow__900.png`, `chat__1440.png`,
`chat__900.png`, `chat-session__1440.png`, `chat-tools__1440.png`, `chat-tools__900.png`,
`chat-hosts__900.png`, `paper-diff-filetree__1440.png`, `paper-diff-filetree__900.png`,
`profile-modal__900.png`, `tmux__1440.png`.

## Focus visibility

Real keyboard `Tab` (not a programmatic `.focus()`) onto an interactive `.text-xs`:
`SUMMARY.text-xs.text-muted` ("JSON", api_tester_live.ex:887) — computed font-size 12px,
`matches(':focus-visible')` **true**, outline `1px auto rgb(153, 200, 255)`, offset 0px.
On the chat desk, `A.btn.btn-primary.text-xs` ("New") — `:focus-visible` true,
outline `3px solid`. No repairs were made, so nothing about focus changed.

## The single attributable delta, run to ground

`.api-schema-summary` (root.html.heex:4691) is
`display: flex; gap: 12px; align-items: center` — **no `flex-wrap`, no `min-width: 0`**.
At 900px the schema-reference column is 255px and the row holds
name (14px) · title (14px, muted) · `.badge` (11px) · `.text-dim.text-xs` "N fields" (12px).

Per-card `scrollWidth − clientWidth` at 900px:

| card | 12px | 11px |
|---|---|---|
| cameraPreset | 18 | 16 |
| coordinatorLoop | 70 | 68 |
| form_response | 43 | 41 |
| **hudElement** | **3** | **(does not overflow)** |
| mediaCollection | 58 | 55 |
| projectileType | 45 | 42 |
| scalingCurve | 15 | 12 |
| upgradeCard | 16 | 13 |
| waveTemplate | 28 | 25 |
| **cards overflowing / 40** | **9** | **8** |

**Verdict: this site genuinely crowds at 900px — and it crowded at 11px too.**
8 of the 9 overflow by 12–68px before the token change; 12px adds 2–3px, the width the
"N fields" chip gains. One card (`hudElement`) crosses the >1px threshold only at 12px,
at a 3px delta. Reverting `.text-xs` to 11px fixes none of the 8.
Visually confirmed in `shots/api-schema-card-overflow__900.png`: `form_response`'s
"4 fields" is cut at the card border and `coordinatorLoop`'s chip is pushed outside it.

Disposition: **not a spd-b22 repair and not spd-b11 material** — sub-12px does not fix it.
It is a pre-existing narrow-width flex defect whose one-line fix (`flex-wrap: wrap` and/or
`min-width: 0` on the name) lives at **root.html.heex:4691, inside `<head>`** (head closes
at 4695), which this worker is forbidden to edit. Reported, not edited.

## A second finding: two of the ten portable_doc sites were never governed by `.text-xs`

`.bp-paper-surface .bp-diff, .bp-paper-surface .bp-filetree { font-size: 0.82rem }`
(= 13.12px) outranks `.text-xs` on specificity. On the Paper surface those two sites
(`components.ex:920`, `:950`) render at 13.12px and **spd-s5 did not change them at all**.
In chat — no `.bp-paper-surface` ancestor — `.text-xs` wins and the sibling
`bp-chat-tool-diff` (`:852`) renders at 12px; 22 live instances measured, 0 overflow at
both widths. All three containers carry inline `overflow-x: auto`, so a font-size increase
is absorbed by their own scroll box by construction.

## Coverage: 96 of 106 sites reached, 10 not

| file | sites | reached | note |
|---|---|---|---|
| `chat_live.ex` | 73 | yes (surface) | desk + 2 transcripts, 89/144/533 live instances; individual conditional branches (spawn chip :2334, missing-image placeholder :2253) not each proven |
| `api_tester_live.ex` | 11 | 11 | :501 ✓ :722–728 ✓ (7) :874 ✓ :882 ✓ :887 ✓ |
| `api_tester_live/components.ex` | 1 | aggregate | same `td.text-dim.text-xs` construction as :882, measured inside the 462 |
| `portable_doc/render/components.ex` | 10 | 4 | :852 ✓ (22 instances) :920 ✓ :950 ✓ :1088 ✓ (113). **NOT reached: :1061, :1066, :1106, :1130, :1148, :1441** — the todo, approval, question, plan and agent-list block types did not appear in any archived session opened |
| `tmux_live.ex` | 2 | 2 | `/studio/tmux` is live on guerrilla (the router's "dev-only" comment is stale) |
| `modals.ex` | 1 | 1 | profile modal, 12px, 151/151 |
| `chat_tool_renderer.ex` | 4 | 0 | no `li.text-xs` / todo card in any session opened |
| `chat_hosts_live.ex` | 3 | 0 | inside `:for={host <- @hosts}`; guerrilla has no registered hosts (0 `.text-xs` on the page) |
| `tickets/inbox_live.ex` | 1 | 0 | inside the `@mint_result` handoff card — rendered only after a `mint_key` submit, which is a WRITE; browsing was read-only |

## Conclusion

Across every surface reached, at 1440 and at 900, the 11→12px correction produced
**zero new plain overflow, zero new clipping, zero new document-level horizontal overflow**,
and exactly **one extra row-container overflow** — a card that was already 3px from a
defect 8 of its siblings already had at 11px. `.text-xs` stays at 12px.
