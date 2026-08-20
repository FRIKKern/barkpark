# pe-w3 inline-corpus-shapes — live BPML refusal shapes + honest +79 bound

Verifier lane `inline-corpus-shapes`, Paper Excellence wave 3. All measured live against
`https://guerrilla.barkpark.cloud` on 2026-08-17 (corpus = 781 `type:paper`).

## Corpus BPML source buckets (781 papers)

| bucket | count | meaning |
|---|---|---|
| 200 ok | 285 | already round-trips |
| 422 kind:block | 222 | first refusal is a non-kernel block (divider/notes/cards/…) |
| 422 kind:inline | 177 | first refusal is a node-spelled inline node |
| 422 kind:mark | 16 | unhandled mark (e.g. `{"type":"bold"}` map-mark) |
| 422 kind:head_cell | 3 | bare-string / map-notext table head cell |
| 422 opaque body_html | 22 | ingested HTML, no block source (never printable) |
| 500 | 2 | the two wave-3 papers being authored live (transient) |

Rerun: `bp doc query paper --limit 1000 --fields _id -o json` → per slug
`curl -s https://guerrilla.barkpark.cloud/papers/<slug>/source?format=bpml`, bucket on
`error.message` regex `kind: (\w+)`.

## kind:inline first-refusal node-type census (177 papers)

strong 86 · code 31 · paragraph 15 · valueref 12 · em 5 · bare-string/nil 28.
(First-refusal only — a paper counts once, at the FIRST unspellable node in DFS order.)

## Exact node text-field shapes (verbatim, live JSON) — the extraction contract

THE FIELD DIFFERS BY NODE. A one-field-fits-all guess corrupts half the marks.

- `code`  → `{"type":"code","value":"bp task stamp"}` — text in **`value`** (scalar binary),
  same as the `text` node. Spell `<code>#{esc(value)}</code>`. NO children.
- `strong`→ `{"type":"strong","children":[{"type":"text","value":"STATUS: SURVEYING. "}]}` —
  text in **`children`** (an inline-node LIST). Spell `<b>#{inline(children)}</b>` — RECURSE,
  there is no `value`.
- `em`    → `{"type":"em","children":[{"type":"text","value":"Log: 2026-07-11 …"}]}` —
  **`children`**, recurse. Spell `<i>#{inline(children)}</i>`.

These three are the standalone-node twins of the existing `mark_tag` (strong→b, em→i,
code→code, printer.ex origin/main). Insertion point: above the `inline_node(%{"type" => type})`
catchall at printer.ex:176 (origin/main), same region as #11758's fail-honest clauses.

Stay-refused shapes (NOT covered by code/strong/em):
- `valueref` → `{"type":"valueref","as":"duration","field":"launch_delay","target":"lvd-…",
  "label":"launch delay","fallback":"6 weeks","children":[{"type":"text","value":"6 weeks"}]}`
  — rich data-binding node; `children` hold display text but `target`/`field`/`as` have no
  kernel spelling. Lossless refusal is correct; flatten-to-children would drop the binding.
- `paragraph` (as inline) → `{"type":"paragraph","content":[…],"id":"g2"}` — a BLOCK shape in an
  inline-node list (`content`, not children). Stays refused; would need flattening.

## +79 headline — REFUTED. Realized lossless round-trip unlock = 35 papers.

Measured two independent ways, both agree:
1. Per-location blocker walk (traverse every inline-bearing kernel slot; a paper unlocks iff its
   entire unspellable set ⊆ {inline code,strong,em}).
2. Conservative whole-tree type scan (flag ANY dict-type not in kernel∪{text,link,code,strong,em},
   any mark ∉ {strong,em,code,underline,strike}, any bare string in content/children).

Both → **35 papers** move 422→200 losslessly. All 35 are currently live-422 kind:inline
(spot-checked authoring-excellence-wave-2026-07-10, chat-plan-1caa96602607,
bp-mcp-serve-epic-wave-2026-07-11 — all HTTP 422 kind:inline now).

- +79 is an ~2.3× overcount for round-trip. The census `code 87/strong 84/em 34` (printer.ex
  comment) counts papers CONTAINING the node, not papers whose ONLY blocker is that node.
- If valueref-only (12) + paragraph-only (13) are additionally FLATTENED (lossy), ceiling rises
  to 60 — still < 79.
- Residual-blocker histogram over the 180 fetched refusers (count of blockers beyond code/strong/em):
  `{0:35, 1:93, 2:25, 3:10, 4:4, 5:5, 6:1, 7:4, 8:1, 11:1, 40:1}`. The 93 one-away papers are
  dominated by **`divider` (82 papers)** — divider, not inline vocab, is the single biggest
  next round-trip lever. notes 18, cards 21, terminal 13, head_cell-string 18 follow.

## 422 body carries (kind: X) — proven

`curl .../heggemsnes-act/source?format=bpml` →
`…block type "notes" is outside the BPML kernel vocabulary (kind: block)` HTTP 422.
`…authoring-excellence-wave-2026-07-10…` →
`…inline node type "code" is outside the BPML kernel vocabulary (kind: inline)` HTTP 422.
head_cell bucket = 3 papers (message `…(kind: head_cell)`).

Rerun everything: scratchpad scripts probe.sh / probe2.sh / strict.py + the whole-tree scan,
against the 781-slug list from the query above.
