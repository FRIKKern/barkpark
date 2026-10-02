---
'@barkpark/react': patch
---

The status-role vocabulary in `inline.tsx` is now GENERATED from `design/status-manifest.json` rather than hand-typed. `STATUS_ROLES` is built at runtime from the emitted `MANIFEST_STATUS_ROLES` (new, generated `src/status-vocab.gen.ts`) plus the single `UNKNOWN_STATUS_ROLE` fallback, so the package can no longer drift from the manifest every other surface reads.

No runtime behaviour changes: the derived set is the same vocabulary, in the same order, that the deleted literal spelled out. What changes is that it can no longer go stale silently — the same manifest now feeds this package, the web projections, the Go renderer and the Elixir surfaces, and `design/emit.mjs --check` byte-compares the committed artifact against a fresh emit.

The lock is real rather than a comment: the freshness check derives its expected value from the emitter itself, so a renamed or added status is picked up without editing the checker, and a one-character edit to the generated file reds it. Order is pinned as well as membership — swapping two keys in the manifest re-emits the artifact with the keys swapped, so a copy whose arm ORDER differed would red, not only one whose values differed.

`status-vocab.gen.ts` carries the standard generated-file banner and must not be hand-edited; regenerate with `node design/emit.mjs --write`.
