# dr-w35 alarm-fix preflight — re-derivation recipes (2026-08-17)

Every row below re-derives one fact from scratch. No state is written by any of them.

| Fact | Command |
|---|---|
| Only TWO open `ci-failure` issues exist; both carry `assignees=[]` | `gh issue list --label ci-failure --state open --json number,title,assignees` |
| Only THREE `ci-failure` issues have EVER existed (#4966 closed proof issue) | `gh issue list --label ci-failure --state all --json number,title,state,createdAt,closedAt` |
| Six alarm keys exist in the tree; only two of them have an open issue | `git grep -n 'CI_FAILURE_KEY' origin/main -- .github/workflows` |
| The comment branch posts `{body:"Still failing."+context}` and `exit 0`s — no assignee, no mention | `git show origin/main:scripts/file-ci-failure-issue.sh \| sed -n '138,155p'` |
| The assignee source is the owner half of `GITHUB_REPOSITORY` unless `CI_FAILURE_ASSIGNEE` is set | `git show origin/main:scripts/file-ci-failure-issue.sh \| grep -n 'assignee=' ` |
| `paper-readers.yml` sets only KEY + DETAIL, so the assignee falls back to `FRIKKern` | `git show origin/main:.github/workflows/paper-readers.yml \| sed -n '64,79p'` |
| `FRIKKern` IS assignable in this repo (HTTP 204) | `gh api repos/FRIKKern/barkpark/assignees/FRIKKern -i \| head -1` |
| The owner is still UNSUBSCRIBED from the repo | `gh repo view --json nameWithOwner,viewerSubscription` |
| The list response the script already parses carries `assignees` (no extra API call needed for mention-on-demand) | `gh api '/repos/FRIKKern/barkpark/issues?state=open&labels=ci-failure&per_page=100' --jq '.[]\|{number,assignees:[.assignees[].login]}'` |
| The widened cancelled-guard HAS fired 8 times since #11481 merged — every firing an unrouted bot comment | `gh issue view 5658 --json comments --jq '.comments[]\|"\(.createdAt) \(.author.login)"' \| tail -10` |
| Every scheduled `paper-readers` run since 2026-08-04 is `cancelled` at ~30 m | `gh run list --workflow=paper-readers.yml --limit 40 --json databaseId,conclusion,createdAt,updatedAt` |
| The hanging step is step 5 `Audit every published Paper`, 29 m 42 s of a 30 m cap | `gh api repos/FRIKKern/barkpark/actions/runs/31999265701/jobs --jq '.jobs[].steps[]\|"\(.name) \(.conclusion) \(.started_at) \(.completed_at)"'` |
| Audit step duration grows monotonically: 17 m 25 s (07-21) → 27 m 07 s (08-03) → cap | `for r in 29811452510 30798381145 31362916087; do gh api repos/FRIKKern/barkpark/actions/runs/$r/jobs --jq '.jobs[].steps[]\|select(.name=="Audit every published Paper")\|"\(.conclusion) \(.started_at) \(.completed_at)"'; done` |
| The corpus was 651 papers on 08-03 (all audited) and is 774 today | `gh run download 30798381145 -R FRIKKern/barkpark -D /tmp/a && jq '{inventory,audited,passed,failed}' /tmp/a/paper-reader-audit-30798381145/paper-reader-audit.json` |
| Today's published-paper count is 774 | `bp -s https://guerrilla.barkpark.cloud -d production search query '*' --type paper --perspective published --all -o json \| jq '.documents\|length'` |
| The inventory query is NOT the bottleneck (3 s, 774 docs) | `time bp -s https://guerrilla.barkpark.cloud -d production search query '*' --type paper --perspective published --all -o json >/dev/null` |
| deploy-reliability wave 32/33/34 Papers 422 `semantic_empty` on ALL THREE reader edges | `for s in deploy-reliability-wave-32-2026-08-09 deploy-reliability-wave-33-2026-08-09 deploy-reliability-wave-34-2026-08-10; do for e in "" /email /source; do curl -sS -o /dev/null -w "$s$e %{http_code}\n" "https://guerrilla.barkpark.cloud/papers/$s$e"; done; done` |
| ~7.7 % of the corpus (6 of a 78-paper systematic sample) is 422 `semantic_empty` | `bp -s https://guerrilla.barkpark.cloud -d production search query '*' --type paper --perspective published --all -o json \| jq -r '.documents[]\|(._id//.id//.slug)' \| sort \| awk 'NR%10==3' \| xargs -P8 -I{} sh -c 'printf "%s {}\n" "$(curl -sS -o /dev/null -w %{http_code} https://guerrilla.barkpark.cloud/papers/{}/source)"' \| awk '{print $1}' \| sort \| uniq -c` |
| The charter rules FILED, never PAGED (D563) — and D590 corrects the wave-33 slice title | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| sed -n '11388,11400p;11904,11916p'` |
| Both fix options are already filed as bp rows | `bp task get dr-w34-bl-alarm-comment-path-reaches-nobody -o json`; `bp task get dr-w33-followup-comment-path-routing -o json` |
