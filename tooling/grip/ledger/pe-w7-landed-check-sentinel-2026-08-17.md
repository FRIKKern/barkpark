# pe-w7 landed-check sentinel — re-derivation recipe (2026-08-17)

Verifier: landed-check-sentinel (Paper Excellence wave 7).
Purpose: pin the create-on-push (#11934) deploy sentinel so the run's readiness
gate cannot mistake "merged" for "serving" on guerrilla (documented ~69%
deploy-failure history).

## Baseline (deployed nil-arm — TODAY, pre-#11934)

A fresh slug POSTed to sync returns **404 code=not_found**, hint
"sync edits an existing paper — publish it first, then pull".

    TOK=bp_admin_[REDACTED — this credential was rotated and revoked 2026-09-01; see task-63c03c39bb2eee4c]
    S=w7-sentinel-probe-x-$(date +%s)
    curl -s -X POST "https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers/$S/sync" \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      -d "{\"bpml\":\"<paper slug=\\\"$S\\\" title=\\\"Sentinel\\\"><p>x</p></paper>\",\"baseRev\":\"1\"}"
    # => 404 {"error":{"code":"not_found", ... "hint":"sync edits an existing paper ..."}}

Note: bpml MUST be a valid BPML `<paper>` document (XML-ish, NOT markdown).
Markdown input (e.g. "# Title") triggers a parser FunctionClauseError → raw 500.
not_found is decided in sync_apply AFTER parse, so a valid BPML doc is required
to reach the sentinel arm.

## The flip (post-#11934 landed)

#11934 (commit 8859c88a64, NOT on origin/main at survey time) replaces the nil
arm: sync_apply nil -> sync_create. baseRev is NOT consulted on the create arm.
A fresh slug then returns EITHER 200 {"created":true,...} (clears the wall) OR
422 {"code":"create_wall",...} (wall refusal) — never code=not_found.

## Readiness-gate one-liner (the landed-check)

    S=w7-landcheck-$(date +%s); curl -s -X POST \
      "https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers/$S/sync" \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      -d "{\"bpml\":\"<paper slug=\\\"$S\\\" title=\\\"Land Check\\\"><p>probe</p></paper>\",\"baseRev\":\"1\"}" \
      | grep -q '"code":"not_found"' \
      && echo "NOT-LANDED: nil-arm 404 baseline still serving" \
      || echo "LANDED: #11934 sync_create arm engaged"

not_found present -> NOT landed. Absent -> landed (create arm serving).

## Pipeline-alive proof (auto-deploy IS firing)

#11929 (c37a292447, on origin/main) added notes to the BPML kernel. Live probe:
a `<notes>`/`<note>` block POSTed to a fresh slug parses cleanly (404 not_found,
NOT 422 unknown-tag), and the deployed parser's own unknown-tag error lists
"notes, note" among known block tags. Auto-deploy for c37a292447 FIRED — guerrilla
is serving merged api/** code now. Negative control: `<bogustag>` -> 422 unknown-tag.
