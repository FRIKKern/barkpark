<!-- doc-tier: cold | canonical-for: legendary-paper-survey-14-evidence | budget: 1200tok -->
# Survey 14 — wave 29 / CLI and API ergonomics

Verdict: `partial`. CLI/API reads are complete and width-safe, but the 252-block Paper is not navigable as one terminal stream and several command contracts are defective.

- Authority: revision `18768b0a14c2eead927181c4a0e37c18`; all tested machine readers returned 252 blocks.
- Render matrix: width 20 = 8,490 lines; 40 = 3,182; 60 = 1,951; 80 = 1,440; 120 = 986. No line exceeded its requested width.
- Width 80 emits 126,556 bytes, including 682 table-border lines. The viewer has no pager, outline, section selector, block jump, or progress affordance.
- Machine projection is useful: title plus description is 587 bytes, while the full JSON is 431,200 bytes. The canonical source response is 109,924 bytes and carries the exact revision.
- Bare slug, `/papers/<slug>`, and full URLs with query/fragment render byte-identically, but help documents only the slug form.
- `bp doc history ... --limit 3` returns all 14 rows and `bp doc related ... --limit 5` returns ten. Global limit forwarding is gated on `Paginated`, while these commands advertise limit but are non-paginated.
- `--width 0` exits successfully and silently falls back to width 80 instead of rejecting the value.
- Machine Paper errors clip and nest the server error, losing the typed hint and request ID; direct source misses return bare `not found`.
- `bp graph tasks <Paper>` returns zero even though the Paper names many tasks; sampled tasks also have empty `papers` arrays. Related discovery is affinity, not ownership.

TTY pager behavior, ANSI hierarchy, release-gated historical selection, authentication variants, malformed blocks, and performance beyond single measurements remain unvisited. No state mutation occurred.
