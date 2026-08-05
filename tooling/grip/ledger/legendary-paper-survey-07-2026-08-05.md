<!-- doc-tier: cold | canonical-for: legendary-paper-survey-07-evidence | budget: 1000tok -->
# Survey 07 — wave 29 / TUI80 structure

Verdict: `partial`; the structure gate fails despite bounded rendering.

- Authority: `cloud-console-hardening-wave-29-2026-08-03@18768b0a14c2eead927181c4a0e37c18`.
- Sample: all 252 source blocks and the actual 80-column pdrender output.
- Source: 113 meaningful blocks plus 139 empty paragraph spacers. The renderer safely collapses the spacers into 112 single separators; no blank run exceeds one line.
- Output: 1,421 lines, maximum display width 80, zero overflow, missing ids, duplicate ids, unknown blocks, decoder errors, inconsistent table row widths, or empty table cells.
- `found`: list blocks `w29D015` and `w29D022` contain 11 paragraph-wrapped items that render as 11 bare bullets, losing all authored text. The renderer passes array items directly to inline rendering without normalizing paragraph nodes (`internal/pdrender/blocks.go:89`; documented at `internal/pdrender/pdrender.go:337`). Existing task `task-993d136b0fbf2fd1` tracks this exact defect.
- `found`: 11 tables render populated bodies (98 rows, 316 cells) but have legacy `header`, not `head`, and therefore no explicit header semantics.
- `not_found`: outline defects. The output preserves one H1, 27 H2, 9 H3, with zero level jumps or empty headings.
- Quality remains 0/1 with six hard classes; structure audit reports 139 safe and zero quarantined findings, digest `d5d13bff70fd7d5598d0b56e5873fdcee2ec4ed815a8cde9cab91ff19ae22c20`.

Both installed `bp` and the current-worktree renderer reproduce the blank bullets. Interactive viewport scrolling, ANSI color, other readers, and other Papers were unvisited. No state was mutated.
