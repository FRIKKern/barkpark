<!-- doc-tier: cold | canonical-for: legendary-paper-survey-01-2026-08-05 | budget: 1800tok -->
# Survey 01 — Cloud Console Hardening wave 29 / public / structure

## Verdict

`found` — the exact published Paper at revision `18768b0a14c2eead927181c4a0e37c18` is anonymously reachable, complete, and structurally parseable, but it fails the current quality contract. The dominant source defect is 139 empty paragraph spacers. The source is also far beyond the current first-pass composition limits: 252 top-level blocks, 37 top-level headings, and 10,365 primary-visible words. One required opening block is missing: no `ingress` occurs in the first eight meaningful blocks.

The reported `table_missing_header` failure needs targeted proof before repair: all 11 tables lack the canonical `head` field but contain a non-empty legacy `header`; the live public renderer deliberately accepts that fallback and emits 11 `<thead>` elements. This is source-contract drift, not a presently invisible public table header.

## Exact sample and facts

- Sample: 1/1 assigned Paper, 1/1 assigned reader, exact current/pinned revision. Public `bp paper view ... -o json` returned `_rev=18768b0a14c2eead927181c4a0e37c18`; `GET /papers/...` returned HTTP 200.
- Source topology: 252 top-level blocks. Counts are 187 `paragraph`, 37 `heading`, 13 `list`, 11 `table`, 4 `callout`. `body.blocks` is byte-structurally equal to top-level `blocks` and also contains 252 blocks.
- Identity/schema sanity: 0 non-object top-level blocks; 0 missing/invalid `type`; 0 missing/invalid `id`; 0 duplicate ids; 0 malformed text-node values. All 37 headings have valid levels: H1=1, H2=27, H3=9; H1 is first; no downward level jump skips a level.
- Empty structure: 139/187 top-level paragraphs are exact empty scaffolds, arranged in 108 runs (77 singletons, 31 pairs; maximum run 2). There are no leading or trailing empty blocks. `paper_structure.py` classifies all 139 as safe repair and reports 0 quarantined violations; findings digest `d5d13bff70fd7d5598d0b56e5873fdcee2ec4ed815a8cde9cab91ff19ae22c20`.
- Public visibility: the HTML DOM preserves all 252 source block ids in source order and with no duplicates. Empty paragraphs compose to empty block wrappers, not visible `<p>` elements; CSS explicitly suppresses legacy empty paragraphs at `api/assets/paper-surface/paper-surface.css:158-165`. Thus 113 meaningful top-level blocks paint content, while 139 empty wrappers remain in the DOM.
- Tables: 11 tables, 35 header cells, 98 body rows, 0 row-width mismatches, 1 blank legacy header cell (`w29d024`, header cell 0). All 11 lack `head`; all 11 have non-empty `header`; live HTML has 11 `<table>`, 11 `<thead>`, 35 `<th>`, 109 `<tr>`.
- Lists/callouts: 13 non-empty lists with 67 items and 4 non-empty callouts. No unsupported-block marker was found in rendered document content.
- Quality result: 0/1 pass, score 0. Hard failures: `empty_paragraph_spacer`, `opening_missing_ingress`, `primary_reading_load_exceeded`, `table_missing_header`, `top_level_block_overload`, `top_level_heading_overload`. Current thresholds are 5,000 primary words, 80 top-level blocks, and 16 top-level headings (`scripts/paper_quality.py:15-25`). Measured values are 10,365, 252, and 37.
- Density warnings: longest primary paragraph 149 words, longest primary table cell 67 words, longest list item 102 words, largest table 16 rows.

## Gate/renderer discrepancy

Fact: the quality gate reads only `block["head"]` and declares any row-bearing table without it headerless (`scripts/paper_quality.py:286-294`). Fact: the public renderer falls back from missing/empty `head` to `header` (`api/lib/barkpark/portable_doc/render/compose.ex:641-648`). Fact: the public result contains a `<thead>` for every table.

Inference: builders should normalize legacy `header` to canonical `head`, or make the gate recognize the supported legacy field, only after Decide establishes the intended canonical write shape. Removing header material would be a regression.

## Coverage ledger

| Surface | Checked for | Result |
|---|---|---|
| Paper `cloud-console-hardening-wave-29-2026-08-03` rev `18768b...` | Exact revision, top/body structure, ids, types, empty/missing/malformed blocks, tables, outline | `found` |
| Public reader `/papers/cloud-console-hardening-wave-29-2026-08-03` | Anonymous reachability, block-id projection, empty visibility, table headers, unsupported output | `found` |
| Barkpark task `task-a768c69e659add58` | Assignment scope, immutable resources, acceptance criterion 1, current Survey status | `found` |
| `scripts/paper_quality.py` | Contract thresholds and exact failure metrics | `found` |
| `scripts/paper_structure.py` | Safe/quarantined empty-structure classification | `found` |
| `api/lib/barkpark/portable_doc/render/compose.ex` | Public table header fallback | `found` |
| `api/assets/paper-surface/paper-surface.css` | Public empty-paragraph visibility law | `found` |
| Studio, TUI80, email, CLI visual render | Out of this assignment's public/structure lens | `not_found` / unvisited |
| Historical Paper revisions | History listed (14 revisions); their content was not audited | `partial` |

## Reproduction

```sh
bp paper view cloud-console-hardening-wave-29-2026-08-03 -o json > /private/tmp/survey01-public.json
jq '{_id,_rev,block_count:(.blocks|length),top_body_equal:(.blocks==.body.blocks)}' /private/tmp/survey01-public.json
python3 scripts/paper_quality.py --input /private/tmp/survey01-public.json
python3 scripts/paper_structure.py --input /private/tmp/survey01-public.json
curl -sS -L -D /private/tmp/survey01-public.headers -o /private/tmp/survey01-public.html https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-29-2026-08-03
rg -o 'data-block-id=' /private/tmp/survey01-public.html | wc -l
rg -o '<thead' /private/tmp/survey01-public.html | wc -l
```

Captured artifact hashes: public JSON `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`; public HTML `930a6e8d246382c1d66a14eb5ef0d52abb1449cc39aeedfdbd740778d80be256`; quality JSON `65524ce21db60379707f3dd9b5db4fae59f3cecf9dbc48544b7635d477c0570f`; structure JSON `7634f6117107ea6757b965df3b3c5968de9b4fb103b59be512a24c9e485808e8`.

## Risks and targeted proof owed

- A bulk spacer deletion is mechanically safe per the structure audit, but revision-fenced mutation and all-reader semantic parity remain unproved here.
- The canonical `head` versus supported legacy `header` discrepancy can cause a false-positive quality failure or an unsafe repair if treated as missing visible content.
- The 10,365-word first pass is more than twice the 5,000-word contract. Reducing it requires editorial decomposition, not blind deletion; this assignment did not judge which evidence belongs in appendices.
- No claims are made for Studio, TUI80, email, CLI/API semantic parity, responsive layout, or prior revisions.
