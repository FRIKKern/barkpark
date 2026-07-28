# Re-derivation recipe — Felix wave 23, live Sobelow finding set + class bucketing (2026-07-28)

Subject: the CURRENT failing Sobelow finding set on main, bucketed against the
baseline that is supposed to cover it. All numbers below are re-derivable.

## 1. The newest main security run, and the job (not workflow) verdict

    gh run list --workflow=security.yml --branch=main --limit 5 \
      --json databaseId,headSha,createdAt,conclusion
    gh run view 30342320311 --json jobs -q '.jobs[] | "\(.name)\t\(.conclusion)"'

Workflow conclusion = `success`; the Sobelow JOB conclusion = `failure`
(continue-on-error masks it at workflow level).

## 2. Exact finding set (51 rows, 11 files)

    gh run view 30342320311 --log-failed > sobelow.log
    grep -oE 'File: [^ ]+' sobelow.log | sort | uniq -c | sort -rn

Structured (detector/file/line/function/variable) — strip the runner prefix and
pair each `<Detector>: <msg> - <Confidence>` header with the File/Line/Function/
Variable lines that follow, flushing on the `-----` separator.

## 3. Baseline, human-readable (108 entries, `detector,file:line,fingerprint`)

    git show origin/main:api/.sobelow-skips | wc -l
    git show origin/main:api/.sobelow-skips | grep -n 'workspace_bundle\|tenancy.ex'

## 4. Last reconcile of the baseline

    git log --oneline origin/main -- api/.sobelow-skips
    git show 238fb58e7 -- api/.sobelow-skips | grep -E '^[+-][^+-].*workspace_bundle\.ex'

238fb58e7 (2026-07-19T06:46 +02:00) is the last reconcile that touched the
tenancy pins.

## 5. The arithmetic that settles drift-vs-new (the decisive test)

    git show 238fb58e7:api/lib/barkpark/tenancy/workspace_bundle.ex > /tmp/wb_old.ex
    wc -l /tmp/wb_old.ex          # 368 lines total

Uniform offset test — subtract 711 from each current workspace_bundle line and
look the preimage up in the 238fb58e7 baseline set {299,328,340,345,348,354,358}:

    1039 S -> 328 S | 1051 Q -> 340 Q | 1056 S -> 345 S
    1059 Q -> 348 Q | 1065 Q -> 354 Q            (5 rows: pure drift)
    1082/1087/1102/1108/1122 -> 371/376/391/397/411  (past EOF: NEW code)

tenancy.ex: uniform +213 with byte-identical surrounding context:

    git show 238fb58e7:api/lib/barkpark/tenancy.ex > /tmp/t_old.ex
    git show origin/main:api/lib/barkpark/tenancy.ex > /tmp/t_new.ex
    for l in 1154 1167 1178; do sed -n "$((l-2)),${l}p" /tmp/t_old.ex; done
    for l in 1367 1380 1391; do sed -n "$((l-2)),${l}p" /tmp/t_new.ex; done

## 6. Provenance of the genuinely-new code

    git log --oneline -S'defp merge_upsert' origin/main \
      -- api/lib/barkpark/tenancy/workspace_bundle.ex     # 9b4b50784, 2026-07-19T18:21
    git log --oneline --diff-filter=A \
      -- api/lib/barkpark/tenancy/workspace_bundle/janitor.ex   # bc64d869a, 2026-07-21
    git log --oneline --diff-filter=A \
      -- api/lib/barkpark/media/blobstore/local.ex api/lib/barkpark/media/blobstore/s3.ex
                                                            # 1e0b43e67, 2026-07-26

## 7. Dead baseline anchors (7 provable)

    sed -n '299p;358p' <(git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex)
    git show origin/main:api/lib/barkpark/media.ex | sed -n '61p;62p;98p;115p;408p'

None of those seven anchors is the construct the baseline row names.

## 8. Prior art

    bp search query "sobelow baseline drift D29 three classes"
    bp task get pds-bl-sobelow-baseline-line-shift-tenancy

PDS wave 11 (2026-07-20) measured 27 unbaselined findings; today 51.
