<!-- doc-tier: cold | canonical-for: cloud-build-doneset-floor1-ancestry-rederivation | budget: 1200tok -->

# Cloud-Build done-set — Floor 1 (SHA-ancestry) re-derivation recipe

Audit wave `bp-cloud-build-doneset-audit-2026-08-18`, assignment `ancestry-100pct-run`.
Snapshot HEAD `H=a28e5ba53696ae4970996e76cd5735910ae22aeb` (origin/main, 2026-08-18).

## Re-derive the live done denominator (L1, NOT child_count)

    bp task get bp-cloud-build-epic -o json \
      | python3 -c "import json,sys; d=json.load(sys.stdin); \
        print(sum(1 for c in d['children'] if c['lifecycle_status']=='done'))"
    # => 36 done  (48 children: 36 done / 10 open / 2 considering)

## Resolve each cited PR to its squash mergeCommit + ancestry

Never local git (this shared checkout PRUNES objects mid-run — a bulk
NOT-ANCESTOR is a prune artifact). Use the GitHub compare API; ancestor iff
`behind_by==0` (the corrected oracle — the status word is order-fragile).

    H=a28e5ba53696ae4970996e76cd5735910ae22aeb
    for n in 2790 2886 3011 3012 3013 3014 3027 3036 3037 3038 3061 3065 \
             3066 3071 3167 3168 3169 3393 3394 3423 3424 3425 3426 3427 \
             3428 5730 12221 12223; do
      sha=$(gh api repos/FRIKKern/barkpark/pulls/$n --jq '.merge_commit_sha')
      merged=$(gh api repos/FRIKKern/barkpark/pulls/$n --jq '.merged')
      b=$(gh api repos/FRIKKern/barkpark/compare/$sha...$H --jq '.behind_by')
      echo "$n merged=$merged $sha behind=$b"
    done

## Verdict (100% coverage, 36/36 done rows)

- 35/36 rows map to >=1 MERGED squash that ancestors H (behind_by==0).
- 25 cited PRs merged & ancestor; every code/doc row has an ancestor.
- `#3065` merged=False behind=2 (superseded) and `#3061` (never existed) are
  each cited only ALONGSIDE a merged ancestor: shared-slug-dek via #3036/#3169,
  datakeys-write-path via #3169, search-config-workspace via #3071/#3168,
  task-51eb1151 via #3169. The Connectors 5-row trap — defused.
- Dangling-orphan trap: `bpb-search-config-workspace-attribution` claim.now
  cites orphan `b3824174a` but its criteria cite real merge #3168
  (`fe24a6ae7...`) which IS an ancestor. Mechanical would false-flag; resolved true.
- SOLE NOT-ANCESTOR: `bp-cloud-build-wave-2b-log` — cites only PR #12223,
  currently OPEN + mergeable_state=dirty (conflicted), never merged. A
  paperwork/log row (acceptance_criteria=null) closed 2026-08-18T07:50:19Z
  while its charter PR is still open. Claim.now honestly reads "charter PR
  #12223 open, reporting checks" (no over-claim). Two-lane: log-existence row,
  not strict ancestry — routed to the judgment layer as a premature-close
  candidate, NOT reopened here (its own claim is honest).
