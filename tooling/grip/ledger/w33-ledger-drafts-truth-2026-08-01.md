# w33 ledger-drafts-truth — re-derivation recipes (2026-08-01)

Verifier `ledger-drafts-truth`, PDS wave 33. Every row re-derives one fact. Read-only
unless marked MUTATES.

## R1 — Arm A / Arm B are genuine unpublished drafts with 8 criteria each

    bp task get pds-w32-census-pin-simplify -o json | jq -c '.doc|{doc_id,status,cp:.criteria_progress,crit:(.content.acceptance_criteria|length)}'
    bp task get pds-w32-census-binds-the-basis -o json | jq -c '.doc|{doc_id,status,cp:.criteria_progress,crit:(.content.acceptance_criteria|length)}'

Expect `doc_id":"drafts.…","status":"draft"`, `{"met":0,"total":8}`, `crit:8`.

## R1b — the assignment's probe command is the WRONG address form

    bp doc get task drafts.pds-w32-census-pin-simplify -o json          # 404 not_found
    bp doc get task drafts.pds-w32-census-pin-simplify --perspective raw -o json   # 200

`bp doc get` without `--perspective raw` reads the PUBLISHED perspective and 404s a draft.
`bp task get <bare-id>` resolves the draft directly.

## R2 — the drafts ARE in the ready queue, just past the default page

    bp task ready -o json      | jq -r '.docs[].doc_id' | grep -c '^drafts\.'   # 0 (page of 50)
    bp task ready --all -o json | jq -r '.docs[].doc_id' | grep -c '^drafts\.'   # 45 of 1457

## R3 — WHY the two drafts were never published: one 19-char tag rationale

    bp doc get task drafts.pds-w32-census-pin-simplify --perspective raw -o json | jq -c '.tags'
    git show origin/main:api/lib/barkpark/content/label_spine.ex | sed -n '60p;263p'

`@min_rationale 20`; `String.length(String.trim(rationale)) >= @min_rationale`.
Both drafts carry the rationale `internal/cli census` = 19 characters. One char short.

## R4 — the publish wall IS passable today (MUTATES: creates + deletes one probe task)

    bp task create "W33 verifier publish-wall probe (delete me)" \
      --description "<a description well over 20 characters>" \
      --set 'tags:=[{"tag":"testing","strength":90,"rationale":"<>=20 chars>"},{"tag":"docs","strength":40,"rationale":"<>=20 chars>"}]' \
      --set doc_id=pds-w33-wall-probe-deleteme --publish --yes -o json
    bp doc delete task pds-w33-wall-probe-deleteme --yes -o json

Bisection held strengths constant at 90/40 and varied only `rationale`:
no rationale -> 422 `label_spine`; rationale >= 20 chars -> `"_draft":false`.
Float strengths (0.9/0.4) also red — the scale is integer 1..100, all distinct.

## R5 — the CLI cannot print the wall's per-field details

    git grep -c 'details' origin/main -- internal/cli/errors.go    # no match: 0

The 422 hint says "details lists each field, the rule it broke, and the fix";
the CLI envelope struct has no `details` member, so it prints none of it.

## R6 — which of D447's seven unfiled findings already have a ledger row

    bp task ready --all -o json | jq -r '.docs[]|[.doc_id,.title]|@tsv' > /tmp/ready.tsv
    grep -iE 'generic|indexexpr|instantiat' /tmp/ready.tsv          # none on-topic
    grep -iE 'paid:|whole-file|destroy'      /tmp/ready.tsv          # none on-topic
    grep -iE 'notreadable|remediation hint'  /tmp/ready.tsv          # none
    grep -iE 'firewall'                      /tmp/ready.tsv          # none
    grep -iE 'wave_log|wave-log'             /tmp/ready.tsv          # none
    grep -iE 'elixir|ok: true|http receipt'  /tmp/ready.tsv          # none on-topic
    grep -iE 'publish wall|label_spine|task-create' /tmp/ready.tsv   # SIX existing rows

## R7 — D447's "the wall rejected EVERY newly created task during this run" is refuted

    for id in cch-w15-bl-publish-wall-rationale-length-opaque \
              pds-bl-record-update-basis-overclaims \
              bp-bulldocs-patch-batch-ops-fail-on-nil; do
      bp task get "$id" -o json | jq -r '.doc|.doc_id+" "+.inserted_at+" "+.status'
    done

00:15, 01:29 and 01:37 on 2026-08-01 all show `published` type:task rows created
within the same window the drafts (00:40) were left unpublished.
