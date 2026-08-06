<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-32 | budget: 1400tok -->
# Restart Survey 32 — PDS44 CLI/API live regression and frozen gates

Assignment `restart-survey-32` re-attested `pds-wave-44-2026-08-03::cli_api` at revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **unchanged partial: frozen output is stable, while known CLI contract failures remain**.

## Direct answer

No content/hash regression occurred. Ten machine reads all succeeded and were byte-identical: 328,256 bytes, SHA-256 `4923e1b72da37c384eb5c7b80ba15a08c9998fde560db0095d349a27457f96d`; published/drafts/raw matched. Eleven human reads succeeded. Five NoColor width-80 runs were identical at 111,922 bytes, 1,305 lines, SHA-256 `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`. ANSI16/256/truecolor each passed `2/2` and stripped byte-identically to NoColor.

The 99 unique blocks contain 32 headings (1/24/7), 48 paragraphs including 15 exact-empty scaffolds, ten lists/85 items, five tables/54 rows/203 body cells, three header-bearing tables/12 header cells, and four untoned callouts.

## Frozen failures

- Human table headers remain absent. Source uses `header`; renderer reads `head`. Five unique-label probes returned zero occurrences and all 12 authored header cells remain machine-only.
- Human provenance remains absent: rendered output contains neither slug nor exact `_rev`.
- Five Related entries occupy lines 1,287–1,305. They come from a mutable fail-open secondary request; stable sampling does not make them revision-bound.
- History returned 12 entries and latest content matched current 99 blocks. Limits 1/5/10/50 all returned 12 because the CLI forwards global limit only for `paginated` commands while `doc.history` declares false.
- Missing Paper returns rc4, invalid arguments rc2, and width zero falls back to 80. Refused transport incorrectly returns `not_found`/rc4 through the unconditional Paper error mapping.

A 5,269-task live snapshot contained 11 direct `wave_paper` matches: four done, six open, one cancelled. Two done tasks have incomplete criteria denominators; their close evidence was not re-proven. Cycle Survey assignments intentionally carry empty `unit_ids` because Survey observes reader units rather than Build ownership; the unit therefore remains unassigned for later Build reconciliation.

Fresh `CC=/usr/bin/clang go test -count=1 ./internal/pdrender ./internal/apiclient ./internal/cli` passed. Installed `bp` and repository HEAD differ, so tests prove current source while live hashes prove the installed binary. Immutable release-candidate reads, forced Related failure, interactive TTY, screen reader, proxy 5xx/throttling, race, full suite, and linked-task close evidence remain unvisited. No state mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-32","unit":"pds-wave-44-2026-08-03::cli_api","verdict":"unchanged_partial","machine":{"samples":"10/10","bytes":328256,"sha256":"4923e1b72da37c384eb5c7b80ba15a08c9998fde560db0095d349a27457f96d"},"human":{"samples":"11/11","lines":1305,"bytes":111922,"sha256":"cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076","profile_strip_parity":true},"structure":{"blocks":99,"empty_paragraphs":15,"lists":10,"items":85,"tables":5,"rows":54,"header_cells":12},"failures":{"human_headers":"0/12","human_identity":false,"transport_taxonomy":"not_found_rc4","history_limit":"ignored","related_immutable":false},"history":{"revisions":12,"latest_blocks_equal":true},"tests":"3/3 packages pass","tasks":{"matches":11,"done":4,"open":6,"cancelled":1,"done_incomplete":2}}
```
