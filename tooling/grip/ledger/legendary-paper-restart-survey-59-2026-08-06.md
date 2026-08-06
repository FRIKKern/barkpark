<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-59 | budget: 1400tok -->
# Restart Survey 59 — PDS45 TUI80 frozen gates

Assignment `restart-survey-59` re-attested `pds-wave-45-2026-08-03::tui80`. Verdict: **mixed/unchanged**. The 80×24 taskboard supports keyboard epic navigation, but this Paper remains undiscoverable; direct rendering passes bounds while identity, headers, navigation, progress, and history replay fail.

`bp tasks` started at 80×24, keyboard navigation reached the PDS epic, and Enter opened it. Footer advertised keyboard and mouse controls. Live census found 5,269 tasks with seven exact `wave_paper` references, but zero `papers[]` or `design_doc` references; hydration consumes only the latter, so Paper discovery/open and actual Paper-frame scroll/click/wheel remain blocked. One transient server status recovered.

Three direct width-80 renders were identical: 136,500 bytes, 1,537 lines, max width 80, zero overflow/ESC, SHA `1c9c67b7f7fba9459a81c60ac12ba432ef110126323d5293c4d4c3fa99940746`. All 33 headings occur. Nine legacy header cells remain absent; slug/revision are invisible. ANSI-stripped output equals NoColor, though ANSI contains 11,836 SGR sequences. Pager, outline, search, and section flags are unknown; progress and reader history replay are absent despite ten history entries.

Adding `wave_paper` hydration needs focused deduplication tests. Actual Paper-frame keys/mouse/focus and operational stability remain unknown. No test or mutation ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-59","unit":"pds-wave-45-2026-08-03::tui80","revision":"b992fd8aaa028b0dab30a8da76f077fd","verdict":"mixed_unchanged","actual_tui":{"viewport":"80x24","startup":"pass","epic_discovery":"pass","enter_open_epic":"pass","paper_discovery":"fail","paper_interaction":"blocked","mouse_mode_seen":true,"mouse_paper_tested":false,"transient_server_error":1},"census":{"tasks":5269,"wave_paper_refs":7,"papers_refs":0,"design_doc_refs":0},"render":{"runs":3,"success":3,"bytes":136500,"lines":1537,"max_cells":80,"overflow_lines":0,"sha256":"1c9c67b7f7fba9459a81c60ac12ba432ef110126323d5293c4d4c3fa99940746"},"failures":{"legacy_header_cells_ignored":9,"slug_visible":false,"revision_visible":false,"pager":false,"outline":false,"search":false,"section":false,"progress":false,"history_replay":false},"tests_run":0,"mutations":0}
```
