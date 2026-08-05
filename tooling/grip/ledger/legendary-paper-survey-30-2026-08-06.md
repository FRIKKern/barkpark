<!-- doc-tier: cold | canonical-for: legendary-paper-survey-30-evidence | budget: 1200tok -->
# Survey 30 — PDS wave 45 / CLI semantic parity

Verdict: `partial`. Terminal output preserves body text and authored block order, but drops nine canonical table-header cells and weakens hierarchy/emphasis in no-color output.

- Authority: `pds-wave-45-2026-08-03@b992fd8aaa028b0dab30a8da76f077fd`; 227 blocks—33 headings, seven lists, 12 tables, nine callouts, and 166 paragraphs.
- Width 120 renders 1,040 lines. Sequential rendering preserves visible top-level source order, all 33 heading texts, seven lists, nine callouts, and 21 literal task-like IDs.
- Three tables carry canonical top-level `header` arrays containing nine cells. The terminal renderer recognizes `head`, `columns`, or a header-marked first row, but not `header`; distinctive header strings are absent while body rows remain. This is confirmed semantic loss.
- Exact mark accounting is eight strong-marked text nodes, eight mark records, and 161 marked characters. An earlier count of 16 double-counted byte-equivalent `.blocks` and `.body.blocks` copies. ANSI profiles render all eight bold; profile `none` retains the words but removes emphasis.
- H1 is uppercased and underlined. H2/H3 rely on ANSI styling and become textually indistinguishable in no-color output.
- Human output omits revision and other provenance fields, and direct `slug@rev` selection returns 404. Immutable reads require the full release-pin flag set.
- A live `Related` appendix follows canonical content. It does not reorder authored blocks but means output is not an exact source-only projection.
- `bp graph tasks` returns zero edges. Task IDs are frozen prose, so current status, criteria, movement to later waves, and authority drift are not surfaced.

Required Verify work: add a focused renderer fixture for the canonical `header` vocabulary and count its production-corpus blast radius. Monochrome hierarchy/emphasis accessibility, revision-pinned human reading, and live task-link projection remain partial risks. No state mutation occurred.
