<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-43 | budget: 1400tok -->
# Restart Survey 43 — PDS44 TUI80 provenance/current pin

Assignment `restart-survey-43` re-attested `pds-wave-44-2026-08-03::tui80` at Paper revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **current source-to-terminal projection is exact and deterministic; visible immutable revision identity is absent; live interactive PDS44 selection remains partial**.

Three raw Paper reads were byte-identical: 328,256 bytes, SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`, 99/99 unique blocks from `b1` to `dbf34`. `jq -c '.blocks'` including terminal LF is 76,025 bytes/SHA `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`. Direct draft lookup returned 404; published/drafts renders were identical.

Three NoColor captures per width were deterministic and bounded:

- width 80: 1,305 lines, SHA `cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076`, max 80 cells;
- width 48: 2,152 lines, SHA `e13d3879e3815f5d8b1b2eef5794b2ea725b32f924cf6e0884277cc5e44d2ad2`, max 48;
- width 28: 4,153 lines, SHA `e9d85dea55d96edc9d57d26084b37151dcba577b726410049ae0e986f3e9b590`, max 28.

A real 80×24 PTY `bp paper view` ANSI capture matched explicit ANSI output after removing only 16 capability-negotiation bytes and normalizing CRLF. A fresh interactive `bp` connected, loaded 39 schemas, and allocated a 28-column Structure pane plus 48-column editor—the real width-80 Paper allocation. Exact PDS44 did not become selectable during the timebox, so no live PDS44 keypress pass is claimed.

One-shot and TUI paths share the decoder/renderer. Focused Paper mode is read-only and source maps scroll/page/top/bottom/help/back keys, but the visible output contains no `_rev`. Known loss remains: top-level `header` is not read, so 12 table headers disappear; 15 empty paragraphs compact away. Tests were not claimed in this lens. Temporary artifacts were trashed; no state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-43","unit":"pds-wave-44-2026-08-03::tui80","verdict":"exact deterministic terminal projection; visible immutable revision absent; interactive selection partial","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","raw_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","blocks":99,"blocks_jqc_lf_sha256":"1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce","draft_twin":false},"renders":{"w80":{"lines":1305,"sha256":"cdc224a9741b010f35d20ea98bf2fdab17e80a4b8153001c1723c503d8f8b076","max_cells":80},"w48":{"lines":2152,"sha256":"e13d3879e3815f5d8b1b2eef5794b2ea725b32f924cf6e0884277cc5e44d2ad2","max_cells":48},"w28":{"lines":4153,"sha256":"e9d85dea55d96edc9d57d26084b37151dcba577b726410049ae0e986f3e9b590","max_cells":28}},"pty80_matches_explicit":true,"visible_revision":false,"header_cells_lost":12,"mutations":0}
```
