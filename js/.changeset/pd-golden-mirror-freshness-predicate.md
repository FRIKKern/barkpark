---
---

Empty changeset: test-only. `@barkpark/react` gains a mirror-freshness predicate
(`tests/pd-golden-mirror-parity.test.ts` + `tests/support/pd-golden-mirrors.ts`) that
asserts the JS pd-golden mirror is set- and byte-identical to the canonical Elixir mint
at `api/test/support/fixtures/pd-parity/`, and `PortableDoc.parity.test.tsx`'s coverage
floor stops being the pinned literal `>= 46` (65 fixtures were on disk) and derives from
that mint instead. Nothing under `src/**` changes, so no published bytes move and there
is no version bump — `pnpm size-limit` is byte-identical before and after.
