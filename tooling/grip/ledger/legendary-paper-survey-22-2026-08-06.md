<!-- doc-tier: cold | canonical-for: legendary-paper-survey-22-evidence | budget: 1200tok -->
# Survey 22 — PDS wave 45 / TUI80 structure

Verdict: `found`. TUI80 exposes every substantive block in source order; the only zero-output blocks are 124 empty paragraph spacers.

- Authority: revision `b992fd8aaa028b0dab30a8da76f077fd`; 227 present/unique IDs; canonical blocks SHA-256 `5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673`.
- Inventory: 166 paragraphs, 33 headings, 12 tables, nine callouts, seven lists. Structure audit finds 124 safe empty-paragraph violations and zero quarantined or other malformed shapes; digest `f08092328594c4dd1038c7b1366adb491f83184fe2c36a07b7bae4a134ef2d59`.
- Per-block production renderer execution emits visible output for all 103 substantive blocks and zero output for exactly the 124 empty paragraphs; no non-empty omission or reorder exists.
- Explicit width-80 no-color `bp paper view` exits 0 at 1,537 lines / 136,500 bytes, maximum width 80, SHA-256 `1c9c67b7f7fba9459a81c60ac12ba432ef110126323d5293c4d4c3fa99940746`.
- Excluding the CLI-only Related section, the body is 1,523 lines / 135,693 bytes and byte-identical to the standalone production renderer dump.
- CLI and interactive TUI share the same decoder/registry; pane width 80 resolves to an exact 80-cell paper measure with no centering pad.
- Fresh targeted Go tests for decode, Paper command, RenderDoc, and overflow passed in both renderer and CLI packages.

The interactive Bubble Tea viewport itself was not driven, so focus, scrolling, and viewport lifecycle remain an interaction-level gap. Empty spacers remain source debt even though terminal rendering suppresses them. No state mutation occurred.
