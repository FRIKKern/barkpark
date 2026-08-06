<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-58 | budget: 1400tok -->
# Restart Survey 58 — PDS45 TUI80 provenance

Assignment `restart-survey-58` re-attested `pds-wave-45-2026-08-03::tui80` at revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **renderer provenance passes; real TUI discovery/open fails; terminal revision identity is absent**.

Three machine/source reads were stable at 227 blocks; newest history revision `4afe0099-26af-40eb-8943-f6935c16c29d` matches current content. Direct width-80 profile-none rendering was 3/3 identical: SHA `1c9c67b7…0746`, 1,537 lines, maximum exactly 80 cells. A real 80×24 PTY one-shot normalizes byte-identically to explicit ANSI output. Title and content order survive, but slug, `_rev`, and block IDs do not appear.

The live Paper query returns 100 Papers including PDS45, yet the installed no-argument TUI cannot reach them. Server desk emits Papers directly as a `document_type_list` without `child`; TUI traversal only follows `item.Child`, so Enter records a path without building the Paper list. Exact-slug search returns one unrelated task. Installed binary build commit is `f59aaf717`; relevant traversal/render files do not differ from worktree HEAD.

Thus direct renderer truth cannot proxy interactive selection, open, scrolling, click/wheel, or focus. Generic search is not a reliable identity fallback. Connected Studio, mutation controls, other widths, and server search ranking internals remain unvisited. Temporary captures were trashed. No test or mutation ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-58","unit":"pds-wave-45-2026-08-03::tui80","verdict":"partial","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","source_stable":true,"renderer_deterministic":true,"pty_matches_renderer":true,"render_lines":1537,"max_cells":80,"tui_exact_target_reachable":false,"revision_identity_visible":false,"primary_risk":"server desk emits direct document_type_list while TUI traversal requires item.Child","mutations":0,"tests_run":0}
```
