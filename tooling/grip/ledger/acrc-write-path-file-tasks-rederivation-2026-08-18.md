<!-- doc-tier: cold | canonical-for: acrc-write-path-file-tasks-rederivation | budget: 800tok -->
# ACRC write-path FILE-task re-derivation (2026-08-18)

Verifier lane [write-path-file-tasks]. Confirms both write-path findings are PUBLISHED
tasks with concrete failing scenarios and that every cited fix site still exists on
origin/main (tip at check time reachable via `git show origin/main:...`).

## Task publication state (both open == published, parented to epic)

    bp task get acrc-publish-atomicity-txn-boundary -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"], len(str(d.get("content"))))'
    # -> open 8085   (6 acceptance_criteria, parent api-content-render-correctness-audit)

    bp task get acrc-dedup-toctou-serialize -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"])'
    # -> open        (5 acceptance_criteria, parent api-content-render-correctness-audit)

## Cited fix sites on origin/main (all present)

    git show origin/main:api/lib/barkpark/content/lifecycle.ex | grep -nE 'AuthoringWall.enforce|Repo.transaction|tap_broadcast'
    # 145: AuthoringWall.enforce   (dedup gate, BEFORE txn)
    # 173: Repo.transaction        (publish txn: upsert + fenced_delete)
    # 202: tap_broadcast           (save_revision/save_event, AFTER txn close == post-commit)

    git show origin/main:api/lib/barkpark/content/broadcast.ex | grep -nE 'def save_event|def save_revision|def tap_broadcast'
    # 113: tap_broadcast   310: save_event   337: save_revision

    git show origin/main:api/lib/barkpark/content/dedup_wall.ex | grep -nE 'def check|Repo.transaction'
    # 155: check   398: own Repo.transaction (dedup read-only txn, separate from publish txn)

## Verdict

Both findings FILED-and-concrete, not merely drafted. No citation drift. Neither task
carries an offline-deterministic fail-closed slice small enough to BUILD in this wave —
correctly left as FILE (design changes the wish scopes OUT). Count contribution: 2 filed.
