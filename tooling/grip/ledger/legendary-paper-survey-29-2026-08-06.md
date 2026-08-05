<!-- doc-tier: cold | canonical-for: legendary-paper-survey-29-evidence | budget: 1200tok -->
# Survey 29 — PDS wave 45 / CLI reader ergonomics

Verdict: `partial`. Terminal and JSON readers are content-complete and width-correct, but a 227-block Paper remains a long linear stream without document navigation, and task relationships remain prose rather than live structured links.

- Authority: `pds-wave-45-2026-08-03@b992fd8aaa028b0dab30a8da76f077fd`; 227/227 blocks have unique IDs.
- Correct display-width measurements found zero overflowing lines: width 20 = 7,952 lines, 40 = 3,272, 60 = 2,066, 80 = 1,537, 120 = 1,040. Maximum display cells equal each requested width. An earlier apparent 3× overflow measured UTF-8 bytes for box-drawing glyphs and is withdrawn.
- Width 20 is technically correct but operationally arduous at 7,952 scroll lines. Existing golden tests cover 40/60/80/120, not 20.
- Root and noun help expose Paper reading, themes, widths, profiles, perspective, JSON, server, and release pins. The reader has no TOC, section index, jump-to-heading/block, pager, search, or progress indicator.
- Human rendering reads canonical narrow source and appends five fail-open Related results. JSON deliberately returns the raw compatibility document and omits Related, backlinks, history, and any heading-derived navigation index.
- History lists ten records, but document `_rev` and history UUID are distinct. Latest revision replay was not captured before the deadline.
- The Paper contains 23 unique task-like prose tokens, but no live task-wikilink projection. Across 5,207 task rows, no top-level `papers` or `wave_paper` field linked to this Paper.
- Missing Paper JSON errors are structured, while argument-parse failures such as invalid perspective remain human text even with `-o json`, because parsing precedes output-mode resolution.
- Related results and backlinks are separately discoverable through manifest commands; the human appendix being fail-open means absence cannot distinguish zero matches from a secondary-read failure.

Targeted Verify work: replay the newest history revision; add a width-20 corpus fixture; test structured parse-error parity; decide on opt-in machine navigation/Related projection; and determine which prose task IDs should become durable links. No state mutation occurred.
