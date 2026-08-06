<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-45 | budget: 1400tok -->
# Restart Survey 45 — PDS44 TUI80 negative capability

Assignment `restart-survey-45` challenged `pds-wave-44-2026-08-03::tui80` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial**. Real TUI startup, representative Paper scrolling, headless behavior, network failure, and shared rendering are proven; exact PDS44 interactive selection, live resize, full keyboard coverage, refresh retention, malformed-runtime behavior, and terminal accessibility remain unvisited or contradicted.

A fresh 80×24 PTY opened the no-arg TUI, loaded 39 schemas, and opened a representative Paper through global search. Paper help was read-only; `j` scrolled one row, `G` reached bottom, and Ctrl-C restored the terminal. Exact PDS44 search remained task-heavy and non-unique, so this representative control is not an exact-document pass.

Headless `bp </dev/null` exited 0 with scope, 5,748-document/39-schema status, and command guidance. An unreachable server exited 1 with schema-fetch URL and connection refusal. PDS44 renders at widths 1/20/80/100/200 completed in 103,906/6,568/1,305/1,062/592 lines; these prove the shared renderer, not interactive viewport/resize.

Paper mode intercepts input before generic edit/save/history handlers. Read-only posture is proven; generic `H` history and Ctrl-S are unreachable. No mouse handler or mouse program option exists, so mouse scrolling/navigation is contradicted. Keyboard scrolling is partially proven; live resize is static inference only. Legacy table headers remain lost. Decode failure silently falls back to the ordinary field form, contradicting visible malformed-Paper recovery.

Fresh `CGO_ENABLED=0 go test ./cmd/barkpark ./internal/pdrender` passed, but no exact PDS44 TUI fixture exists. Real AT, every key, SSE refresh/scroll retention, and exact malformed runtime remain unvisited. Source hash stayed `4923e1…f96d`; no state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-45","unit":"pds-wave-44-2026-08-03::tui80","verdict":"partial","claims":{"real_tui_startup":"proven","representative_paper_path":"partial","exact_pds44_selection":"blocked","headless":"proven","network_error":"proven","read_only":"proven","revision_history":"contradicted","mouse":"contradicted","keyboard_scroll":"partial","live_resize":"unvisited","table_headers":"contradicted","malformed_visible_error":"contradicted"},"renderer":{"width1_lines":103906,"width20_lines":6568,"width80_lines":1305,"width100_lines":1062,"width200_lines":592},"tests":{"packages":["./cmd/barkpark","./internal/pdrender"],"passed":true,"exact_fixture":false},"paper_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","mutations":0}
```
