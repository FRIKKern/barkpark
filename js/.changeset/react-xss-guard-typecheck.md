---
'@barkpark/react': patch
---

Fix a TS2379 in the XSS output-encoding regression guard that left the package's
Typecheck job red on `main`.

`tests/xss-output-encoding-guard.test.ts` destructured the optional `allowImgSvg`
field out of a test-case row (type `boolean | undefined`) and passed it into an
object literal for a parameter typed `{ allowImgSvg?: boolean }`. Under
`exactOptionalPropertyTypes` an optional property must be absent rather than
present-and-undefined, so the key is now omitted when it was not set. Behaviour is
unchanged — the only read is `if (!opts.allowImgSvg)`, so absent, `false` and
`undefined` were already equivalent at the use site.

No shipped code changed: the fix is confined to a test file, which is not part of
the published artifact, so this release is a no-op for consumers. It carries a
patch bump only because the repo requires a changeset for any PR touching
`packages/**` (js/CLAUDE.md), and `changeset status --since` does not accept an
empty changeset as satisfying that rule.
