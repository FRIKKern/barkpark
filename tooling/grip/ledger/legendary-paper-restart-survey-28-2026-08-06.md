<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-28 | budget: 1400tok -->
# Restart Survey 28 — CCH29 TUI80 provenance and current pin

Assignment `restart-survey-28` re-attested `cloud-console-hardening-wave-29-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current render reproducible; immutable binding partial; full semantic survival contradicted**.

## Direct answer

The current Paper is exactly `_rev=18768b0a14c2eead927181c4a0e37c18`. Three source reads were byte-identical. Four fresh 80-column CLI renders—three installed-binary runs and one current-worktree run—were also byte-identical, exited zero, and stayed within 80 display cells.

This is strong after-the-fact correlation, not intrinsic immutable identity. Ordinary `bp paper view <slug>` reads the mutable current slug and stdout contains neither slug nor `_rev`. A genuinely immutable read needs the complete release-gate, wave-revision, and candidate tuple; that tuple was unavailable here.

Full semantic survival is false. The renderer traverses decoded top-level blocks in order, but drops 139 empty paragraphs. The Paper has 11 tables and 35 canonical header cells under `header`; decode retains that key, while the table renderer reads only `head`. All 11 rendered tables therefore omit their authored header bands. Remaining inline semantics were not exhaustively proven lossless.

## Exact evidence

- Source: 3/3 stable; 252 unique blocks; response SHA-256 `d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9`; canonical blocks SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`; ordered-ID SHA-256 `7c35fa8cbde3896cf72886a09776d1f384af0f4887e7cff8ba5ee68285316d07`.
- Source types: 187 paragraphs, 37 headings, 13 lists, 11 tables, and 4 callouts; 139 empty paragraphs, 67 list items, 98 table rows, and 35 table-header cells.
- CLI80: 4/4 byte-identical; 1,440 lines; 126,556 bytes; max width 80; zero overflow; SHA-256 `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`; zero slug or revision occurrences.
- Direct renderer body: 1,421 lines; 125,535 bytes; max width 80; zero overflow; SHA-256 `043582d797e8547fd3abcf83483ae0e65649913cb3df0eb12fdf782816d8a5c2`; exactly the CLI prefix. The remaining 19 lines are the mutable Related appendix outside Paper revision authority.
- Fresh targeted Go tests passed for `internal/pdrender`, `internal/apiclient`, and `internal/taskboard`.

Standalone TUI statically shares the renderer and uses an 80-cell measure at pane width 80, but no fresh fullscreen capture was made. The `bp tasks` Paper frame is different: an 80-cell frame reserves chrome and renders the body at 72 cells while carrying revision-keyed cache identity. Interactive fullscreen behavior, alternate terminals/themes, and complete inline parity remain unvisited. Temporary captures were moved to Trash; no repository, Task, Paper, Cycle, or production mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-28","unit":"cloud-console-hardening-wave-29-2026-08-03::tui80","verdict":"current render reproducible; immutable binding partial; full semantic survival contradicted","source":{"revision":"18768b0a14c2eead927181c4a0e37c18","samples":"3/3 stable","response_sha256":"d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9","blocks":252,"blocks_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21","ordered_ids_sha256":"7c35fa8cbde3896cf72886a09776d1f384af0f4887e7cff8ba5ee68285316d07"},"cli80":{"samples":"4/4 identical","lines":1440,"bytes":126556,"max_width":80,"overflow":0,"sha256":"e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83","visible_slug":false,"visible_revision":false},"renderer_body":{"lines":1421,"bytes":125535,"sha256":"043582d797e8547fd3abcf83483ae0e65649913cb3df0eb12fdf782816d8a5c2","equals_cli_prefix":true},"semantic_survival":{"empty_paragraphs_dropped":139,"tables":11,"header_cells":35,"header_bands":"all omitted","remaining_inline":"partial"},"immutable_binding":"partial after-the-fact hash correlation"}
```
