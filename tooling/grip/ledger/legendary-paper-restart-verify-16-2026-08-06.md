<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-16 | budget: 2100tok -->
# Restart Verify 16 — terminal table fidelity at narrow widths

Assignment `restart-verify-16` tested all 46 live tables at widths 72, 50, and 28, plus complete renders of four frozen Papers at all three widths. Verdict: **refuted; bounding masks header and body-content loss**.

The frozen source contains 46 tables, 113 authored legacy top-level `header` cells, 423 rows, and 1,374 body cells. Every live table has `header` and no `head`; the production Go table renderer reads `head` and never the legacy field. Consequently 0/113 unique headers are emitted at every width, or 0/339 table-width header observations. A disposable key-normalization control immediately renders the missing header band, proving the field mismatch, but width 28 still clips normalized labels, so a key fallback alone cannot satisfy narrow fidelity.

| Measure | Width 72 | Width 50 | Width 28 | Total |
|---|---:|---:|---:|---:|
| Exact displayed token multiset | 3/46 | 1/46 | 0/46 | 4/138 |
| Exact nonspace-character multiset | 43/46 | 42/46 | 27/46 | 112/138 |
| Header observations emitted | 0/113 | 0/113 | 0/113 | 0/339 |

Twenty-six table-width cells delete 224 authored non-whitespace characters rather than merely wrapping them. In decisive CCH28 table `w28b021` at width 28, source text ends `orphans=57`; the rendered row ends at `orphans=`, losing `57` before the next row begins.

Geometry passes independently: 138/138 isolated table frames and 12/12 full-Paper frames are bounded with zero overflow. The twelve full frames are byte-deterministic across two runs. That positive result cannot pass the conjunction because bounded output is achieved partly through clipping authored content.

All targeted `TestPdTable*` repository tests pass. They do not bind live top-level `header` input or assert exact content at 72/50/28, so the green suite exposes a coverage gap rather than contradicting the live-fixture result.

Evidence root is `/private/tmp/bp-restart-verify-16.7me3z8`. Its 397-file manifest SHA-256 is `7a87e3177494602ea6331b4bd444bae76670e3310921b042156f15b917b365d6`; it includes exact source documents, 138 table ANSI/plain frames, 24 two-run Paper frames, token/character diffs, fixtures, commands, and boundary records. Repository status and staged/unstaged diffs were empty; Task, Paper, Cycle, production, and credential mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-16","assignment_uuid":"9c44a504-f3c3-4815-9621-e2cfa7839e58","verdict":"refuted","papers":4,"tables":46,"headers":{"authored":113,"preserved_unique":0,"observations":"0/339"},"body_cells":1374,"token_exact":{"w72":"3/46","w50":"1/46","w28":"0/46","all":"4/138"},"character_exact":{"w72":"43/46","w50":"42/46","w28":"27/46","all":"112/138","loss_cells":26,"missing_nonspace_chars":224},"bounded":{"paper_width":"12/12","table_width":"138/138","overflow":0},"deterministic":"12/12","render_errors":0,"mutations":0,"manifest_sha256":"7a87e3177494602ea6331b4bd444bae76670e3310921b042156f15b917b365d6"}
```
