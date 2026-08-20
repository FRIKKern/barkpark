# PDS wave 40 — re-derivation recipes: the six merge-gated N-1 rows + the three w25 shards

Every row below is re-derivable from scratch. Run at `origin/main` 28f4cd4730c96667ad0f3bddd406e2ce754a1273.

## Binding: the PR carries the builder's own commit (not a text match)

    cd /Volumes/SATECHI/github/barkpark
    for n in 9112 9113 9114 9115 9116 9117; do gh pr view $n --json headRefName,commits -q '.headRefName+" "+([.commits[].oid]|join(","))'; done
    for n in 9112 9113 9114 9115 9116 9117; do sha=$(gh pr view $n --json mergeCommit -q .mergeCommit.oid); git merge-base --is-ancestor $sha origin/main && echo "$n IN-MAIN"; done

Head-commit OIDs equal the OIDs the builders stamped in `claim.now.text`
(5a0f29ee4 / fb408a4e8 / 633262f12 / 23e990875 / a94eeced2 / 03d27f02f), even though
every PR was opened on a `pds-w39-r-*` branch rather than the `loop-epic/*` branch the
stamp names. The commit identity is the binding; the branch name is not.

## Lead act per row

    # pds-w39-record-parity-shallow-guard c9 — mutant (b), off-HEAD-graft fixture must red
    D=$(mktemp -d); git archive origin/main | tar -x -C $D; cd $D
    bash scripts/pds-record-parity.test.sh                 # PASS 76 checks, 0 failures
    # plant: in walk_truncation(), replace `    true)  : ;;` with
    #   `    true)  WALK_STATE="truncated"; WALK_GRAFT="MUTANT-B"; return 0 ;;`
    bash scripts/pds-record-parity.test.sh                 # FAIL 76 checks, 5 failures

    # pds-w38-falsifier-promotion c10 — blinding mutation must exit 1
    sed -i '' -e 's/Content.get_document(/BLINDED_get_document(/g' \
              -e 's/Conflicts.list(/BLINDED_list(/g' \
       api/test/barkpark/plugins/github/inbound_events_test.exs
    elixir scripts/pds-elixir-receipt-census.exs; echo RC=$?   # RC=1, 3 refusal(s), FAIL BASIS-FALSIFIERS

    # pds-w38-verdict-freshness-arm c12 — one REFUTED-row correction, from source
    git show origin/main:api/lib/barkpark/scim.ex | sed -n '495,520p'
    git show origin/main:api/lib/barkpark_web/controllers/scim_groups_controller.ex | sed -n '160,180p'

    # pds-w34-owning-doc-amendment c12 — cap is measured, not carried forward
    git show origin/main:docs/decisions/success-claim-census.md | wc -c        # 18507
    git show origin/main:scripts/check-doc-budgets.sh | grep success-claim     # 19307 = 18507 + 800
    git log --oneline -3 -L69,69:scripts/check-doc-budgets.sh origin/main      # line ADDED by #9117

    # pds-w38-charter-ledger-disagreement-sweep c10 — one disagreement, live
    bp task get pds-w29-pay-lb -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'])"
    gh pr view 8644 --json state -q .state     # open 12/14  vs  MERGED

    # pds-bl-status-only-residue-payment c8 — one callee return, from source
    git show origin/main:api/lib/barkpark/content/schema.ex | sed -n '178,210p'
    git show origin/main:api/lib/barkpark_web/controllers/schema_controller.ex | sed -n '55,75p'
    gh pr checks 9114 | grep -E "^Elixir gate|^Test \("

## The three w25 shards — the manifest survives

    ls -la /tmp/w25-manifest.tsv /tmp/w25-count.py
    for c in parked open-normalise bare; do python3 /tmp/w25-count.py $c /tmp/w25-manifest.tsv; echo RC=$?; done
    # parked 27/27 RC=0 · open-normalise 103/103 RC=0 · bare 33/34 RC=1
    bp task get pds-bl-dedup-unavailable-error-code -o json   # content.disposition == "open", no owner
