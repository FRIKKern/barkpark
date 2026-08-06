<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-60 | budget: 1400tok -->
# Restart Survey 60 — PDS45 TUI80 negative capability

Assignment `restart-survey-60` challenged `pds-wave-45-2026-08-03::tui80`. Verdict: **blocked, with proven renderer defects**.

Installed TUI at 80×24 loads 39 schemas/live desk, but exact Paper open was not achieved, so live key, scroll, focus, mouse, AT, history, and reconnect claims remain blocked. Worktree-built TUI fails schema loading with `unknown error` while installed succeeds, proving runtime/source drift without explaining its cause.

Current renderer stays within requested widths 120→1 and preserves non-table text, but tables progressively lose content: body alphanumerics are 22,054/22,054 at width80, 22,033 at50, 22,026 at48, 20,363 at20, 18,421 at16, 1,158 at8, and zero at1. All nine legacy header cells disappear because rendering reads `head`, not `header`. At an inferred 50-column Paper pane the 2,504-line result spans roughly 126 screens.

Paper keys cover line/half/page/top/bottom/back, but their early branch intercepts `H`, making generic history inaccessible. Revision exists in `Doc.Extra` but is not displayed. Main TUI enables alt-screen only and has no mouse path. Malformed controls reveal silent empty success for empty/null/scalar items, visible unknown-block fallback, distorted tables, and safe control-byte stripping. Missing Paper JSON nests/clips typed server context. Fresh Go tests for pdrender, command, and apiclient passed, but exact selection/key/history/table-completeness coverage is absent. No mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-60","unit":"pds-wave-45-2026-08-03::tui80","rev":"b992fd8aaa028b0dab30a8da76f077fd","verdict":"blocked","fresh":{"blocks":227,"terminal":"80x24","implied_paper_width":50,"render_lines_w50":2504,"screens_w50_h20":126,"header_cells_lost":9,"table_body_preserved_w50":"22033/22054","table_body_preserved_w8":"1158/22054","table_body_preserved_w1":"0/22054","overflow":false},"negative":["legacy header loss","narrow table content loss","Paper history key unreachable","revision not displayed","no main-TUI mouse path","silent empty malformed items","nested/clipped JSON error"],"blocked":["exact live open","live keys/scroll/focus","mouse/AT","history content","reconnect"],"tests_run":3,"tests_passed":3,"mutations":0}
```
