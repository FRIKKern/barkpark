# v9 twin-preflight — re-derivation recipes (2026-08-12)

Verifier v9 (paper-excellence wave). Each row re-derives one ruling input from scratch.

| # | Claim | Re-derive |
|---|---|---|
| 1 | `container` is NOT a paper block type — reader emits `Unsupported block: container` and DROPS its children | `curl -s https://guerrilla.barkpark.cloud/papers/probe-container-wide-2026-08-12 \| grep -o 'Unsupported block: container'` and `grep -c 'CONTAINER CHILD PARAGRAPH'` (0) |
| 2 | compose.ex has no container clause; unknown types hit the 1719 catch-all | `sed -n 1719,1721p api/lib/barkpark/portable_doc/render/compose.ex` |
| 3 | Article shell = 720px incl. 40px side padding → 640px content box; NOTHING renders wider (measured: shell 720, control ¶ 640, bare table 640) | CDP at 1440: `document.querySelector('.bp-paper-shell').getBoundingClientRect().width` on the probe page; shell rule `sed -n 694,698p api/lib/barkpark_web/layouts/bulldocs.html.heex` |
| 4 | walk.ex PdContainer clamps `min(maxWidth, width)` with article palette width 680 — even the export path cannot exceed the budget | `sed -n 184,191p api/lib/barkpark/portable_doc/render/walk.ex`; `grep -n 'width: 680' api/lib/barkpark/portable_doc/render/palettes.ex` |
| 5 | Nesting WORKS on the live reader: section stack, section grid (2×307px cells side-by-side), columns (2×307px), terminal chrome, expandable | `curl -s https://guerrilla.barkpark.cloud/papers/probe-nesting-section-columns-2026-08-12 \| grep -c SENT-GRID-A` (≥1); CDP gridTemplateColumns `307.203px 307.203px` |
| 6 | Grid span/order live TOP-LEVEL on the child (`"span": 2`), NOT under `layout` — `layout:{span:2}` is silently dropped | `sed -n '/defp cell_layout_attr/,+10p' api/lib/barkpark/portable_doc/render/compose.ex` (reads `Map.get(child, "span")`) |
| 7 | Code block content key is `value` ONLY — a `code` key renders an EMPTY `<pre>` silently (probe's terminal child) | `grep -n 'Map.get(b, "value", "")' api/lib/barkpark/portable_doc/render/compose.ex` (code clause :511); live: probe-nesting pre is empty |
| 8 | Table cells must be `{"text":…}` / `{"content":[…]}` / inline list — plain strings 422 at the wall ("no renderable inline content") | republish probe-container payload with string cells; wall error names `blocks[i].rows[j].cells[k]`; code `sed -n 1596,1613p api/lib/barkpark/content/papers/block_ops.ex` |
| 9 | spacing_norm advisory FALSE-POSITIVES on `text`-keyed paragraphs: it checks only `content==[]` while EpicQuality honors `text` | `sed -n 295,312p api/lib/barkpark/content/authoring_wall.ex` vs `sed -n 195,199p api/lib/barkpark/content/papers/epic_quality.ex`; live: probe publish printed `warning[spacing_norm] … 1 empty paragraph` for a text-keyed, visibly-rendering ¶ |
| 10 | EpicQuality caps bind ONLY the exact tag `epic-cycle-wave-paper`; twin fits them anyway (erasure: 11 headings, ~1.9k words, ≲60 blocks) | `grep -n '@canonical_tag\|@max_top' api/lib/barkpark/content/papers/epic_quality.ex`; `python3 -c` tag-count over tooling/paper-excellence/evidence/erasure.html |
| 11 | Registered tags = 191 published `type:tag` docs on guerrilla; `authoring-excellence`, `bulldocs`, `design-language`, `render`, `benchmark` all registered | `curl -s -H "Authorization: Bearer $BP_TOKEN" 'https://guerrilla.barkpark.cloud/v1/data/query/production/tag?limit=300'` |
| 12 | asciicast src must be http/https (data: refused) → inline cast data needs a hosted .cast file | `grep -n '@allowed_scheme' api/lib/barkpark/portable_doc/render/util.ex`; `sed -n 130,146p api/lib/barkpark/portable_doc/render/figures.ex` |
| 13 | Live article body ¶ = 16px at 1440 (corroborates v1's 16px reading) | CDP on probe page: `getComputedStyle(controlP).fontSize` → `"16px"` |

Probes left PUBLISHED on guerrilla for Decide/builders: `probe-container-wide-2026-08-12`, `probe-nesting-section-columns-2026-08-12`. Screenshots: scratchpad `v9/probe-container-1440.png`, `v9/probe-nesting-1440.png`.
