<!-- doc-tier: cold | canonical-for: legendary-paper-survey-09-evidence | budget: 1100tok -->
# Survey 09 — wave 29 / TUI80 semantic parity

Verdict: `found`; heading order and most prose survive, but lists and table headers suffer critical semantic loss.

- Authority: `cloud-console-hardening-wave-29-2026-08-03@18768b0a14c2eead927181c4a0e37c18`; sample is all 252 blocks in one TUI80 reader.
- `w29D015`: five blank bullets; 1,431 characters / 256 tokens lost.
- `w29D022`: six blank bullets; 837 characters / 150 tokens lost.
- Root cause: `itemNodes` leaves paragraph-wrapped arrays unchanged, then inline rendering drops the unknown `paragraph` nodes (`internal/pdrender/blocks.go:158`, `internal/pdrender/inline.go:125`).
- All 11 tables use legacy `header`. TUI reads only `head`, columns, or a specially marked first row, so all 35 header cells disappear—34 non-empty labels, 328 characters / 62 tokens, and 35 strong marks (`internal/pdrender/richblocks.go:37`). Table bodies remain: 98 rows / 316 cells.
- Every table wraps heavily at 80 columns; terminal output has no relational table semantics and copied/screen-reader text interleaves adjacent cell fragments.
- `not_found`: heading-order loss. All 37 headings match source order: one H1, 27 H2, nine H3.
- Non-table parity: 145/156 meaningful heading/prose/list/callout parts match in order; the only misses are the 11 list items.
- Source marks include 200 code and 113 strong nodes. ANSI256 supports string marks, but 35 strong marks vanish with omitted headers.
- All four callouts render, but source tone `note` silently maps to `info` because the TUI palette defaults unknown tones.
- Output is 1,440 lines, maximum width 80, with zero replacement characters or unknown-block boxes.

Capture hashes: source `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`; no-color output `e20c839b7be4443eed91bbe148a1f95f1bace8c24eed247fbab0d1c9236fbf83`; ANSI256 `fc8a5ca6c35cffe62d65e82bb01e4764fb893163077874c3693dbdffe35d5266`. Interactive Bubble Tea scrolling, terminal screen readers, alternate emulators, and other readers were unvisited. No state was mutated.
