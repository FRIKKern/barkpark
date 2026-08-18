<!-- doc-tier: cold | canonical-for: stw12-stale-open-close-batch-rederivation | budget: 1500tok -->

# Search-template W12 — stale-open close-batch re-derivation (verifier v4)

Re-run to reproduce the per-row / per-criterion verdicts. `now = 2026-08-18`; all claims lapsed 2026-07-26 (worker=None) → re-claimable; Decide must read CURRENT holder+epoch immediately before each close.

## PR merge SHAs (ALL confirmed ancestors of origin/main)

    for sha in 018045261c e2b329a185 123aaa9f45 45fa86ebdd 0511125689 4028efbef9 07e85d917c 608ca1cb79; do \
      printf "%s: " $sha; git merge-base --is-ancestor $sha origin/main && echo ANCESTOR || echo NOT; done

| Row | PR | merge SHA (ancestor) | verdict |
|---|---|---|---|
| stw11-vendor-freshness-gate | #6939 | 018045261c | STALE-OPEN; crit0-5 delivered, crit6=merge itself |
| stw11-readme-command-gate | #6941 | e2b329a185 | STALE-OPEN; crit1 & crit5 SUPERSEDED (see below) |
| stw9-backlog-provision-indx | #6275 | 123aaa9f45 | STALE-OPEN; crit0-3 already met+stamped, crit4 live→lead |
| stw9-backlog-graph-server-honesty | #6274 | 4028efbef9 | STALE-OPEN; crit2 edge-filter delivered, crit6 live→lead |
| stw9-backlog-doctype-readback | #6276 | 07e85d917c | STALE-OPEN; crit3 console rail delivered, crit5 live→lead |
| stw9-backlog-bpgraph-identity-tripwire | #6277 | 608ca1cb79 | STALE-OPEN; crit0-6 met, crit7 merge-gated→lead |
| task-bbe4686 (PublicRead ==) | #7870 + #6271 | 0511125689 + 45fa86ebdd | STALE-OPEN; TWO SHAs (see below) |
| task-03a92ad1 (SR-2 review) | #6271 | 45fa86ebdd | 0 criteria; concern addressed (7 Indx gate tests) — judgment close |
| stw10-template-copy-unknown-dataset | — | NONE | GENUINELY-UNBUILT — no fix SHA exists |

## Per-criterion adjudications that break a blanket single-SHA close (console-w76 lesson)

**stw11-readme-command-gate #6941** — crit1 ("checker REDs exactly 3 defects at README:41/DEPLOYING:12/DEPLOYING:38, exits non-zero") and crit5 ("no template markdown modified — those fixes belong to stw11-claim-ledger") are SUPERSEDED: the merged PR *fixed* those 3 md defects inline (stat shows DEPLOYING.md +17, README.md +14), so the checker now GREENs 24/24, not REDs 3. Close crit1/crit5 as "delivered-differently / superseded by review," NOT literal-met.

    git show e2b329a185 --stat | grep -E "DEPLOYING|README"   # both template md modified

**task-bbe4686 needs TWO SHAs, not one.** crit0-2 (PublicRead membership `"public-read" in perms`, mutation test, fail-broken singleton) = #7870 / 0511125689 (`api/lib/barkpark_web/plugs/public_read.ex:39,116`). crit3 (indx allowlist-not-denylist, nil/absent-visibility row) = #6271 / 45fa86ebdd (`api/test/barkpark/search/documents_retriever_visibility_test.exs`, `indexer_upsert_visibility_test.exs:93`). #7870 alone does NOT satisfy crit3 — its diff never touches the retriever/indx path.

## stw10-template-copy-unknown-dataset — the "pin the fix SHA" premise is WRONG

No fix commit exists. Current copy still describes the JOIN, not the refusal:

    grep -rn "unknown_dataset" templates/ | grep -v node_modules   # ZERO hits
    templates/search-starter/README.md:116  "the browser falls back to the docs default: it joins"
    templates/search-starter/DEPLOYING.md:95 "inlines the URL and token but not the dataset joins"

#6273 (26e7b53824) is server-side WS dataset validation (stw9-backlog-ws-dataset-validation), NOT template copy. → GENUINELY-UNBUILT residue; offline grep-provable copy edit for the build tail, not a stale-open close.
