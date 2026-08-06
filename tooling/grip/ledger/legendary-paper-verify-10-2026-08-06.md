<!-- doc-tier: cold | canonical-for: legendary-paper-verify-10-evidence | budget: 1700tok -->
# Verify 10 — direct Go renderer determinism and width safety

Verdict: `refuted` overall. Direct `pdrender` is perfectly deterministic and display-cell bounded, but it is not semantically or profile invariant for the pinned corpus: legacy headers disappear, Wave 29 nested lists render blank, unsupported tones collapse, and marked Wave 29 tables change layout between NoColor and ANSI.

| Paper/profile cohort | Deterministic renders | Overflow lines | ANSI stripped equals NoColor |
| --- | ---: | ---: | ---: |
| Cloud Console wave 28, all profiles | 20/20 | 0 | 20/20 |
| Cloud Console wave 29, NoColor | 5/5 | 0 | 5/5 |
| Cloud Console wave 29, ANSI16/256/TrueColor | 15/15 | 0 | 0/15 |
| PDS wave 45, all profiles | 20/20 | 0 | 20/20 |
| PDS wave 44, all profiles | 20/20 | 0 | 20/20 |
| Total | 80/80 | 0 | 65/80 |

- The matrix covers four Papers × widths 20/40/60/80/120 × NoColor/ANSI16/ANSI256/TrueColor, with two repeated renders each. Measurement used the production ANSI-aware `ansi.StringWidth` path, not bytes.
- `go test -count=1 ./internal/pdrender` passes. Width enforcement uses ANSI-aware soft/hard wrap and a final document boundary.
- Width-20 versus width-120 NoColor line growth is 7.21–8.59× and byte growth 1.53–1.97×: large but consistent with bounded wrapping. ANSI changes bytes, not visible cells.
- Wave 29 table blocks 22 and 81 differ after stripping every ANSI profile at every width. They contain 31 and 70 marked runs. Removing marks in an isolated control restores equality, proving styled strings passed into the wrapping table are the trigger.
- All 46 tables use legacy `header`; 35 contain 113 header labels and none use `head`. The renderer reads `head`, columns, or header-marked rows but not top-level `header`, so every canonical legacy label is omitted.
- Wave 29 blocks 172 and 179 contain eleven paragraph-shaped list items / 2,268 characters and render as eleven blank bullets. List item arrays pass through unchanged; inline fallback looks for `children`, not paragraph `content`.
- Wave 29 `note` and Wave 28 `warn` are byte-identical to info. Theme handling recognizes success/warning/danger/neutral and falls back otherwise.

Negative findings: the other three Papers have exact ANSI-strip parity; both stored mark encodings are otherwise recognized; no nondeterminism, overflow, crash, missing Paper, or revision drift occurred. The corpus has no wikilink or valueref nodes, and direct rendering correctly excludes the CLI-added Related appendix. Task/value/image/reference resolvers therefore cannot explain the failures.

Package tests and the full fresh corpus matrix were run at clean commit `d474c22c24`. No repository, task, or Paper mutation occurred. Remaining interactive-shell and task-chip behavior belongs to verify-11/12.
