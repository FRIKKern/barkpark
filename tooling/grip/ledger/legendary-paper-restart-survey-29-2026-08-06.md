<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-29 | budget: 1400tok -->
# Restart Survey 29 — CCH29 TUI80 live regression and frozen gates

Assignment `restart-survey-29` re-attested `cloud-console-hardening-wave-29-2026-08-03::tui80` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged failure: deterministic width-80 containment, transient live 500s, and only partial interactive proof**.

## Direct answer

The exact source remained `_rev=18768b0a14c2eead927181c4a0e37c18`, 431,200 bytes and 252 blocks. Five installed `bp paper view` width-80 runs were byte-identical to the frozen baseline: 126,556 bytes, 1,440 lines, maximum 80 cells, zero overflow, SHA-256 `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`. Current worktree core rendering was 125,535 bytes and 1,421 lines with the same 80-cell containment.

Containment passed at widths 20/40/60/80/120, but readability did not: core heights were 8,365/3,146/1,928/1,421/974 lines. Width 10 paradoxically produced 6,790 lines, fewer than width 20. Core rendering stayed bounded at widths 1 and 2, while the installed command overflowed one line to seven cells because the secondary `Related` heading sits outside the renderer. Explicit width zero silently became width 80.

Reliability was not clean. The first two ANSI16 attempts returned source-endpoint HTTP 500; five immediate retries succeeded identically. Across 26 valid Paper commands, 24 succeeded, two returned 500, and none stalled.

## Frozen-gate ruling

- Identity failed: stdout contains neither slug nor revision.
- Nested-list parity failed: canonical words survive `0/406` in blocks `w29D015` and `w29D022`.
- Table semantics failed: renderer reads `head`, source uses `header`, so `0/35` authored header cells are structurally rendered.
- Mark semantics failed: source has 313 marks; NoColor removes distinctions and 35 marked header cells disappear.
- Callout bodies pass `4/4`, but tone labels pass `0/4`; unknown source tone `note` falls through to info.
- Spacer migration failed: 139 exact empty paragraphs remain.
- Outline and in-reader history failed. The API returned 14 revisions, but Paper mode consumes `H` before generic history handling.
- Paging is partial: `j/k`, half-page, Space, and top/bottom exist, while the footer omits Space/PageUp/PageDown.
- Task reachability failed: 5,269 live tasks were checked; 23 reference the Paper only through `wave_paper`, while hydration reads only `design_doc` and `papers[]`. None is navigable from this reader path.

Current code and targeted reducer tests retain the one-third details default, drag persistence, click/Enter parity, focus-local wheel scrolling, and debounced hover routing. A fresh real PTY, mouse, terminal screen reader, and alternate emulator were not exercised, so those are partial static/test-backed claims rather than live-reader passes. Targeted tests passed for `internal/pdrender`, `internal/taskboard`, and Paper/history cases in `cmd/barkpark`; no full-suite pass is claimed.

## Cycle payload

```json
{"assignment_id":"restart-survey-29","unit":"cloud-console-hardening-wave-29-2026-08-03::tui80","verdict":"unchanged failure with deterministic tui80, transient 500s, and interactive partial","paper_revision":"18768b0a14c2eead927181c4a0e37c18","source":{"runs":"3/3 identical","blocks":252,"bytes":431200,"sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15"},"width80":{"runs":"5/5 identical","bytes":126556,"lines":1440,"max_cells":80,"overflow":0,"sha256":"e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83"},"content":{"nested_words":"0/406","table_headers":"0/35","marks":313,"callout_bodies":"4/4","callout_tones":"0/4","empty_spacers":139},"identity":{"slug":false,"revision":false,"history_api":14,"history_in_reader":false},"task_reachability":{"rows":5269,"wave_paper_refs":23,"navigable":false},"reliability":{"commands":26,"success":24,"http_500":2,"stalls":0,"retry_success":"5/5"},"interactive_pty":"unvisited","real_at":"blocked"}
```
