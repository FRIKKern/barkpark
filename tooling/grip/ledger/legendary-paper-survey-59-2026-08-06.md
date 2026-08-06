<!-- doc-tier: cold | canonical-for: legendary-paper-survey-59-evidence | budget: 1200tok -->
# Survey 59 — PDS wave 44 / CLI-API reader

Verdict: `partial`. The reader is lossless and strictly width-safe, but a 99-block Paper remains a long linear stream with no native navigation; two concrete CLI correctness defects also remain.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; raw JSON is 328,256 bytes and preserves all document identity and fields.
- NoColor renders obey every requested width: width 100 is 1,062 lines, 80 is 1,305, 60 is 1,710, 40 is 2,653, and 20 is 6,568; measured maximum line width equals the request and overflow is zero throughout.
- Width correctness is not usability. `paper view` has no pager, outline, within-Paper search, heading jump, or progress indicator. Source comments mention piping to `less`, but user help does not.
- `--width 0` is accepted and silently resolves to auto/default; redirected output becomes 80 columns. Invalid nonnumeric width and perspective correctly exit 2.
- Confirmed fidelity defect: the five tables store 12 cells in top-level `header`, while `pdrender` reads `head`, `columns`, or a header-marked first row. Unique labels such as “why now” and “Gate re-run on the final state” disappear from the human render.
- Confirmed query defect: `doc history --limit 5` returns all 12 revisions and `doc related --limit 1` returns all ten matches. Global parsing consumes `limit`, but request construction forwards it only when the manifest marks the command paginated; both commands declare the flag while `paginated:false`. The server correctly supports history limits.
- Projection works: `doc get --fields title,slug,style` reduces 328,256 bytes to 403 while retaining identity. Standard `doc ls --limit 1 --count` returns one row and total 666.
- History lists 12 newest-first revisions; fetching `344fe5ee-c8a0-4bb9-8b5e-17a3562992d5` returns a 99-block immutable snapshot. `paper view --revision-id` instead means a Cycle/Wave release pin and cannot render document-history snapshots.
- Human output appends five of ten related records; backlinks are zero. Related is fail-open, so absence cannot distinguish no matches from transport failure. This fixture contains no task/link nodes, so task-chip rendering remains untested.
- Rendered output does not expose `_rev`. Bad revision errors are clean and structured; bad Paper JSON wraps/clips the upstream error. Live capabilities acquisition was unstable.

Checked Paper/CLI renderer, width resolution, table decoding, link chips, history UI, global/query forwarding, API client, server history limits and tests, manifest fixtures, and the pinned Paper. No mutation occurred. Verify must add `header` compatibility, repair declared-limit forwarding, define long-reader navigation/pager behavior, clarify revision terminology/history rendering, disclose fail-open Related in debug mode, and exercise real task-link fixtures.
