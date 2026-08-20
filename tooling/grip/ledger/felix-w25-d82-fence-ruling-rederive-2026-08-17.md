# felix w25 — D82 tenancy/workspace_bundle fence ruling: re-derivation recipe (2026-08-17)

Verdict re-derived here: **both stated grounds of the D82 fence are dead; amend D82 by name (D153 precedent) before any builder touches `api/lib/barkpark/tenancy/workspace_bundle*`; the guard is P3 defence-in-depth per D149, never a P0 spine.**

Each row: claim → the one command that re-derives it.

| # | Claim | Rerun |
|---|---|---|
| 1 | D82 fences Felix OFF `tenancy/workspace_bundle`, reason "(PDS crown)" | `git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \| sed -n '910,925p'` |
| 2 | D137 restates the fence as TWO grounds: PDS crown + PR #6551 OPEN rewriting the files | `git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \| sed -n '1946,1965p'` |
| 3 | Ground 2 dead: #6551 CLOSED unmerged 2026-07-30T16:53:36Z | `gh pr view 6551 --json state,mergedAt,closedAt` |
| 4 | #6551's content landed via #8130, MERGED 2026-07-30T16:52:47Z | `gh pr view 8130 --json state,mergedAt,title` |
| 5 | Ground 1 dead in substance: PDS crown = hardware-blocked export climb, rows cancelled/considering, no code work in these files | `bp task get pds-w8-crown-reclimb -o json; bp task get pds-bl-source-box-too-small-for-full-export -o json; bp task get pds-w10-climb-in-the-post-deploy-window -o json` |
| 6 | Zero live claims on any PDS bundle-adjacent row (worker null on all of savepoint-honesty / clean-import-500 / 409-http-test / w3-shares-fidelity / ddl-deadlock-flake) | `for id in pds-backlog-import-savepoint-honesty pds-bl-clean-import-ungated-500 pds-bl-import-409-http-test pds-w3-shares-fidelity pds-bl-import-ddl-deadlock-flake; do bp task get $id -o json \| python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d.get("claim"))'; done` |
| 7 | Zero open PRs touch ANY tenancy path (full file-level sweep of all open PRs) | `gh pr list --state open --limit 100 --json number --jq '.[].number' \| while read pr; do gh pr view $pr --json files --jq '.files[].path' \| grep -q tenancy && echo "PR $pr"; done` |
| 8 | The fence was ALREADY crossed with semantic (non-comment) changes by a merged third-party PR: #9411 (codex branch, merged 2026-08-03) rewrote `scalar!`→`Repo.query!` in workspace_bundle.ex | `gh pr view 9411 --json headRefName,mergedAt && git show 92f91f0433 -- api/lib/barkpark/tenancy/workspace_bundle.ex \| grep -E '^[+-][^+-]' \| head` |
| 9 | workspace_bundle files quiet on main since 2026-08-03 | `git log origin/main -3 --format='%h %ad %s' --date=short -- api/lib/barkpark/tenancy/workspace_bundle api/lib/barkpark/tenancy/workspace_bundle.ex` |
| 10 | The backlog row's own criterion 4 names the unlock: re-parent to PDS OR amend D82 by name; sequencing "after PR 6551 merges" is unsatisfiable (closed, never merges) | `bp task get felix-w23-bl-bundle-member-guard -o json \| python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"][3])'` |
| 11 | The guard is priority 3, repriced by D149 (admin-only reachability execution-proven); ships as scar-class defence-in-depth or not at all | `bp task get felix-w23-bl-bundle-member-guard -o json \| python3 -c 'import json,sys;c=json.load(sys.stdin)["doc"]["content"];print(c["priority"],c["reprice_note"])'` |
| 12 | import_member/3 still has NO membership guard on main (defect live-in-code; :1089/:1094) | `grep -n 'import_member' api/lib/barkpark/tenancy/workspace_bundle.ex` |
| 13 | D153 precedent: D82 amendable by name; its existing carve-out covers ONLY zero-semantic `# sobelow_skip` comment lines — NOT arbitrary doc comments, so the catalog.ex escaper-doc half needs the new amendment too | `git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \| sed -n '2184,2200p'` |
| 14 | Dataset changeset half is OUTSIDE the fence: `tenancy/dataset.ex` is not under `tenancy/workspace_bundle` | `ls api/lib/barkpark/tenancy/` |

Expiry: re-derive rows 3-9 if a PDS wave >27 opens or any open PR shows a tenancy file.
