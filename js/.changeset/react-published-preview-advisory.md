---
'@barkpark/react': patch
---

README: state the published-preview blast radius honestly.

Both versions of this package on npm — `1.0.0-preview.0` and `1.0.0-preview.1` —
ship the reference-error collapse repaired by #9601, and no release contains the
repair yet. The README gains a `## Published preview advisory` section quoting
the collapse out of the published `dist/index.mjs` (obtained with `npm pack`, not
read from a sourcemap) and naming both affected versions, with the interim
workaround: pass an explicit `fetcher` prop.

The pending `react-reference-error-not-notfound` changeset asserted the opposite
— that the published tarball is free of the collapse — and would have carried
that into the published CHANGELOG. Corrected to the measurement. A new vitest
guard, `tests/published-preview-advisory.test.ts`, keeps both facts pinned.

No runtime code changes.
