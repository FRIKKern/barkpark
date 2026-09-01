---
'@barkpark/nextjs': patch
'@barkpark/core': patch
---

The path-segment rule has one implementation again.

`@barkpark/core` closed the `..`-retargets-the-fetch class in `util/guards.ts` with `assertSegment` — one guard backing eleven call sites, written that way so fixing four path builders would not leave the class open at the other seven. The symbol was never added to core's export surface, so when `@barkpark/nextjs` closed the same class on its server fetch path it wrote a second copy of the rule instead of calling the first. Its own comment said so: _"a local mirror of core's `assertSegment` … which is not on core's public export surface."_

A missing export produces a duplicate. This is the second time: `@barkpark/nextjs/client` had forked `detectEdgeRuntime` for exactly the same reason, and that fork had drifted into classifying every browser as an edge runtime before anyone noticed. The remedy is the same one — export the original, delete the copy.

`@barkpark/core` now additively exports `assertSegment`. `@barkpark/nextjs`'s `assertPathSegment` keeps its name and its `barkparkFetch:` message prefix (core's third parameter exists to carry a call-site message, and core's own `getSchema`/`deleteSchema` use it the same way) but holds no predicate of its own — it delegates. There is one place left to change the rule.

**No behaviour change.** The two copies had not drifted: the mirror's predicate was core's with `allowSep` at its default `false`, and both deliberately decline to reject percent-encoded `%2e%2e` (every call site wraps the value in `encodeURIComponent`, which escapes the `%` itself, so it can never decode back to `..` at the URL parser). Checked across 23 inputs — non-strings, empty and whitespace-only values, `.`, `..`, separator-bearing and percent-encoded forms, and legitimate ids — the thrown message, `field` and `code` are identical, and accept/reject agrees on every one. The existing `..` tests are unchanged and still assert the emitted URL rather than the guard's identity, so they hold whoever implements the rule.
