# PDS wave 33 — re-derivation recipes for the w26-false-paid ruling (2026-08-01)

Verdict re-derived by these commands. Each is standalone; none mutates.

## R1 — pds-w26-stamp-readback is DONE and every closed criterion is VERB-scoped (CLI), not server-scoped

    bp task get pds-w26-stamp-readback -o json \
      | jq -r '.doc.content.lifecycle_status, (.doc.content.acceptance_criteria[]? | "[\(.met)] \(.criterion) :: \(.evidence // "NO EVIDENCE")")'

Expect: `done`, 7 criteria all `[true]`. Every evidence anchor lands in
`internal/cli/`, `internal/taskboard/`, `internal/apiclient/` — zero `api/lib/` anchors.

## R2 — the server arm the row never claimed to fix, still reconstructing on main

    git show origin/main:api/lib/barkpark/tasks/stamp.ex | sed -n '225,240p'

Expect `Repo.update_all` at :230 (a ROW COUNT) then `1 -> {:ok, %{doc | content: new_content, rev: new_rev}}` at :235.

## R3 — the layer ruling is CHARTER-level, not an accident of the slice

    git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '5910,5915p'

Expect PDS-D361 "THE HONESTY GOES CLIENT-SIDE … The spine ships in `bp`. Every server-side idea is additive."

## R4 — D361's STATED BASIS has expired (the deploy gate it cited is open)

    curl -s https://guerrilla.barkpark.cloud/status.json | jq -r .commit
    git fetch origin -q && git rev-list --count $(curl -s https://guerrilla.barkpark.cloud/status.json | jq -r .commit)..origin/main

Measured 2026-08-01: deployed `6b1fe3738`, **1** commit behind `origin/main`.
D361 justified client-side-only on "that deploy is the same human gate already holding
pds-w25-round-terminal". That premise is no longer true; an API-side receipt fix is now
deploy-reachable and the constraint must be re-derived, not inherited.

## R5 — the CLI-layer choice's own known hole is already filed and OPEN

    bp task get pds-w26-mcp-stamp-bypasses-readback -o json | jq -r '.doc.content.lifecycle_status'
    git show origin/main:internal/cli/mcp_tasks.go | grep -n 'execManifestCommand'

Expect `open`. MCP dispatch never enters `runTaskStamp`, so the read-back does not cover it.

## R6 — `bp task close` has no CLI read-back seam at all (asymmetry with stamp)

    git ls-tree -r --name-only origin/main internal/cli/ | grep -i task   # no tasks_close_cmd.go
    git show origin/main:internal/apiclient/client.go | sed -n '1211,1258p'

Expect `TaskClose`/`TaskCloseN`/`TaskCloseRevN` return only `error` / `notices` / `help` —
no second GET anywhere.
