# PDS wave 28 — mechanical floor, FULL PASS over all 213 reasons

Corpus: PDS closure from `task-2ac1f95237c4a8e5`, paged with explicit offsets
(same transport discipline as `scripts/pds-ledger-census.sh`), window
2026-07-31T11:00:59Z → 11:01:56Z. closure=357 live=190 corpus=4022.
Non-empty `disposition_reason` = **213** (172 live + 41 terminal).
live_adjudicated=172, live-with-disposition-but-no-reason=**0**,
live-with-no-disposition=**18** (was 19 at charter time).

## Re-derive the corpus

    # (run from an EMPTY directory — see pds-w27-bl-census-executes-stray-code-from-cwd)
    python3 dump.py rows.json      # script body inlined below

`dump.py` = `tooling/grip/ledger/pds-w25-rowdump.py` with `reason` emitted
verbatim instead of `reason_md5`.

## Typed extraction rules (these ARE the finding)

- mask `task-<hex>` and UUID-shaped tokens BEFORE scanning for hex → **0**
  phantom shas survived (the ~18 recovery-boilerplate phantoms are gone).
- `git cat-file -t` every surviving hex BEFORE judging it.
- rooted path = contains `/` + known extension, `exs` alternated BEFORE `ex`
  with a trailing `(?![\w])` boundary → **0** `config.exs`→`config.ex` phantoms.
- bare basename = PATHLESS-REF, never resolved.

## Verdicts

| class | tokens | verdict |
|---|---|---|
| hex | 73 | 64 COMMIT-ANCESTOR · 3 NON-COMMIT-BLOB · 6 MISSING-OBJECT · **0** NOT-ANCESTOR |
| rooted path | 134 | 118 PATH-OK · 16 PATH-GONE |
| path:line | 41 (34 rows) | **41/41 in range — 0 beyond EOF** |

All 6 MISSING-OBJECT are FALSE POSITIVES and none is a git ref: 4 × 32-hex
(one bp doc `_rev`, two md5 of `pg_get_functiondef`, one column digest) and
2 × 14-digit migration timestamps (`20260719030000`, `20260719030100`).
All 3 blobs are TRUE and `merge-base --is-ancestor` REDS them.

13 of 16 PATH-GONE resolve uniquely by suffix as **root-relative shorthand**
(`content/schema.ex` → `api/lib/barkpark/content/schema.ex`); `config/runtime.exs`
resolves 2 ways. 2 are HONEST NEGATIVES (the reason cites the path in order to
say it is gone). 1 is a real refutation.

    git ls-tree -r --name-only origin/main | grep -c '/content/schema\.ex$'   # 1

## CONFIRMED REFUTED — 3 rows of 213 (1.4%), all LIVE

1. **task-fff1116564723b60** — cites `api/test/barkpark/workspace_bundle_test.exs`
   and concludes `git grep -c webhook_deliveries -- <that path>` "returns nothing,
   so neither accident is pinned by a test." The pathspec matches nothing; the
   real file is `api/test/barkpark/tenancy/workspace_bundle_test.exs` and the
   token IS there. The conclusion is FALSE, drawn from an exit code alone.

       git grep -c webhook_deliveries origin/main -- api/test/barkpark/workspace_bundle_test.exs          # rc=1, no output
       git grep -c webhook_deliveries origin/main -- api/test/barkpark/tenancy/workspace_bundle_test.exs  # :1

2. **pds-bl-sobelow-baseline-line-shift-reconcile** — "On origin/main 9110a0ebe
   the baseline line is :118 and it now pins router.ex:2550". TRUE at the cited
   sha, REFUTED at HEAD.

       git show 9110a0ebe:api/.sobelow-skips | sed -n 118p        # Config.Headers: ... router.ex:2550,18ED697
       git show origin/main:api/.sobelow-skips | wc -l            # 58
       git show origin/main:api/.sobelow-skips | grep -c 'Config.Headers'   # 0
       git show origin/main:api/.sobelow-skips | grep -c 'router.ex:2550'   # 0

3. **pds-bl-sobelow-baseline-line-shift-tenancy** — carries the same
   `router.ex:2550` pin; same refutation.

## The sizing number slice 1 rests on

A naive typed floor (MISSING-OBJECT ∪ NOT-ANCESTOR ∪ PATH-GONE) REDS **14 rows**.
Exactly **1** is a real refutation → **precision 0.07**.
The other 2 real refutations are not in the fire set at all (`.sobelow-skips`
carries no extension, so the extractor never emitted it) → **recall 0.33**.
Both are worse than the 0.20 the survey measured and than the 0.67 at which
grip's prose scanner was already refuted (truth-grip D26).

Honest-negative-citation rows: **23** (regex-bounded, extractor-dependent).
Self-correcting rows (quote a stale pointer then correct it): **20** — e.g.
`pds-bl-sync-source-bypasses-publish-door`, correct at :309/:310 today while
quoting :277:

    git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n 309,311p

## Ruling this recipe supports

The floor must check the reason's OWN ASSERTED anchor (a stored
`disposition_rerun` field) and not scraped tokens. A scraper over this corpus
is a 0.07-precision / 0.33-recall instrument, and 23+20 = the most honest rows
in the ledger are exactly the ones it punishes.
