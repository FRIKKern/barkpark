# felix-w30 V6 — prebuilt_artifact caps are LIVE (executed census row)

**Claim.** The 8 typed resource caps in `api/lib/barkpark/sites/prebuilt_artifact.ex`
(entries / total-bytes / entry-bytes / ratio / name-bytes / segments / pax-block +
extension-records + record-bytes) are ENFORCED at runtime, not merely declared in
moduledoc. Verdict: **already-good, upgraded L3(read) → L1(running system)**.

**Authority.** Both files byte-identical to origin/main (empty `git diff --stat`),
so the green run is authoritative for main — not just this worktree.

## Re-derivation

```
# 1. Prove files match main (empty output = identical):
git fetch origin -q
git diff --stat origin/main -- \
  api/lib/barkpark/sites/prebuilt_artifact.ex \
  api/test/barkpark/sites/prebuilt_artifact_test.exs

# 2. Run the suite (decisive):
cd api && MIX_ENV=test mix test test/barkpark/sites/prebuilt_artifact_test.exs
#   => "50 tests, 0 failures"  (7.2s)
```

## Why the pass is not vacuous

The 50 tests assert enforcement by ERROR CODE, not by reading the moduledoc:
`E_COMPRESSION_RATIO` (>200:1 past ratio floor, test:359), `E_TOO_MANY_ENTRIES`
(>20 000 entries, test:370; counter still live under an override cap, test:920/930),
`E_ENTRY_TOO_LARGE` (per-entry cap incl. a pax SIZE record re-measured, test:752/774),
pax-block budget refusals on size-field / record-count / per-record (test:812/821/829),
plus `caps/0` pinned equal to the charter numbers (test:957-970 — a silent cap edit reds).
The suite EXERCISES each cap through `stage/4`; it does not trust the doc.

Test file: 974 lines. HEAD at run: a6535504204df39850cb1d08316b5ffb25eb983b.
