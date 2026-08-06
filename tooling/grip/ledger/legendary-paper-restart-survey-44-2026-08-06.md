<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-44 | budget: 1400tok -->
# Restart Survey 44 — PDS44 TUI80 live regression and frozen gates

Assignment `restart-survey-44` re-attested `pds-wave-44-2026-08-03::tui80` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **direct rendering is unchanged, but the actual 80×24 TUI could not open the assigned Paper; live reachability is regressed or blocked**.

Direct width-80 NoColor output passed `3/3`, byte-equal to Round 1: rc0, 111,922 bytes, 1,305 lines, maximum 80 cells, zero overflow, SHA `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`. Widths 60/50/40/30/20/16 also had zero overflow but expanded to 1,710/2,087/2,653/3,696/6,568/7,530 lines. Real pane-width controls 48/38/28/18/14 expanded to 2,152/2,839/4,153/6,870/9,417 lines.

Two actual 80×24 PTYs tested the installed `f59aaf717` binary and current-worktree `b6ebd4f76` via `go run`. Both connected, loaded 39 schemas, selected Papers, changed the prompt to “Select a document to edit,” and painted no Paper rows. Exact-slug search returned one unrelated task. Authenticated API controls returned Paper rows and 12 PDS44 revisions, so backend emptiness is not established.

Direct content is unchanged: 84/99 visible groups after 15 empty paragraphs compact away; ten lists/85 items and five table bodies remain; authored headers `0/12`; callout tone labels `0/4`; NoColor H2/H3 remain indistinguishable. Rendered slug/revision occurrences are zero and history is unavailable in the unopened reader. Missing Paper returns rc4; invalid width/perspective return rc2.

Global help, Escape, and quit worked. Exact Paper scroll/top/bottom/focus/search/mouse/AT were unvisited because PDS44 could not open. Direct output does not proxy-pass the actual reader. No state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-44","unit":"pds-wave-44-2026-08-03::tui80","verdict":"direct renderer unchanged; actual assigned-Paper reachability regression or blocker","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","blocks":99,"raw_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d"},"actual_tui":{"attempts":2,"paper_opened":0,"schemas":39,"api_papers_present":true,"classification":"regression_or_blocked"},"direct_w80":{"samples":"3/3","bytes":111922,"lines":1305,"max_cells":80,"overflow":0,"sha256":"cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076","round1_equal":true},"content":{"visible_groups":"84/99","headers":"0/12","tone_labels":"0/4","visible_identity":false},"history":{"api_revisions":12,"reader_available":false},"mutations":0}
```
