---
---

Empty changeset: dev-only tooling under `js/packages/react/scripts/`, no
published package change — `src/**`, `dist/**` and `.size-limit.json` are
untouched, and the three over-limit entries still read 250/282/276 B over,
byte-identical to the merge base.

`scripts/bundle-census.mjs` gains `--gz`: a MEASURED gzipped column. Its
existing per-file column is raw minified bytes while the budget is gzipped, and
gzip is not additive over a partition of its input — so the only way to price a
row against the budget was to scale it by the header's ratio, which is a guess.
This red has already spent three output-identical rewrites that all measured
WORSE than the code they replaced, which is the failure a ratio invites.

`attributeViaSourcemap` now records each source's `[start, end)` spans alongside
its byte total — one partition, built once, so the raw and gzipped columns
cannot describe two different splits of the stream. Per row the tool excises
exactly those spans, re-gzips the remainder, and prints
`gzip(full) - gzip(excised)`. The header states what that does and does not
license: the gzipped cost of those minified bytes IN THIS STREAM, not a
prediction of what deleting the source would save.

The distinction is made mechanical, not asserted. A ratio-derived column sums to
the gzipped total by construction; a measured one cannot, because excising one
file leaves the rest able to back-reference the literals it supplied. The tool
prints that sum beside the total and calls a sum at or above it BROKEN. Measured
on main's three over entries: 1,434 / 1,349 / 1,261 B of cross-file gzip overlap
belongs to no single row.
