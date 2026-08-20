# fanout-site — runner-side vs box-side: re-derivation recipes (2026-08-08)

Wave 24, deploy-reliability. Every number below re-derives from these commands.

## R1 — successful deploy runs, with per-target job outcome

    gh run list --workflow=deploy.yml --branch=main --status=success --limit=40 \
      --json databaseId --jq '.[].databaseId' |
    while read id; do
      gh run view $id --json headSha,createdAt,jobs --jq \
        '.headSha[0:8]+" "+.createdAt+" cp="+((.jobs[]|select(.name=="control-plane")|.conclusion)//"absent")+" inst="+((.jobs[]|select(.name=="instance")|.conclusion)//"absent")'
    done

Observed 2026-08-08: cp=skipped 4/40, inst=skipped 23/40. A skipped target still
makes the RUN succeed, so the `changes` job's base (`gh run list --status=success
--limit=1`) advances past commits that target never received.

## R2 — runner-derived range vs box-true range, per target

    git fetch origin main
    # runner range for run N = (headSha of previous SUCCESSFUL run) .. (headSha of run N)
    # box-true range for target T = (headSha of previous run where T ran) .. (headSha of run N)
    git rev-list --count 2f7e00d3..8af8c2ad      # runner  -> 3
    git rev-list --count 31bbb79b..8af8c2ad      # box     -> 4
    git rev-list --count 31bbb79b..2e38228b      # inst box-> 11  (runner said 3)
    git rev-list --count 8251f3a5..31bbb79b      # inst box-> 16  (runner said 2)

## R3 — the box HEAD is not the run headSha (the fabrication proof)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'cd /opt/barkpark && git reflog show HEAD -n 6 --format="%H %gd %gs"'
    ssh -i ~/.ssh/barkpark_indx root@guerrilla.barkpark.cloud \
      'cd /opt/barkpark && git reflog show HEAD -n 5 --format="%H %gd %gs"'

CP reflog HEAD@{1} = 5b68852f ("charter: hobby-scale hardening program (#10733)"),
a sha that is NOT any deploy run's headSha — deploy.yml is not even triggered by
a charter-only merge. `git pull --ff-only origin main` takes origin/main AT PULL
TIME, so run 8af8c2ad's control-plane leg delivered 31bbb79b..5b68852f = 7
commits and left the box serving 5b68852f. A runner-anchored recorder would have
written serving_sha=8af8c2ad over a 3-commit range: wrong sha, 4 commits missing.

    git merge-base --is-ancestor 8af8c2ad 5b68852f && echo YES   # YES
    git merge-base --is-ancestor b7f4f2ad 5b68852f || echo NO    # NO
    git rev-list --count 31bbb79b..5b68852f                      # 7

## R4 — the no-op is visible on the box, invisible to the runner

guerrilla reflog HEAD@{3} == HEAD@{4} == 2673eb00: a deploy that moved nothing
still writes a reflog entry, so a box-anchored range is legitimately empty. A
run-anchored base instead ADVANCES on a delivery of nothing.

## R5 — fence and credential facts

    git show origin/main:.github/workflows/deploy.yml | sed -n '95,120p'   # DEPLOY_SSH_KEY + CP_HOST
    git show origin/main:.github/workflows/deploy.yml | sed -n '144,175p'  # DEPLOY_SSH_KEY + GUERRILLA_HOST
    grep -n 'D716' -A12 .claude/workflows/bp-pds-charter.md | grep -i 'github\|deploy/'

`.github/workflows/**` is OUT of the PDS fence; `deploy/cp-deploy.sh` and
`deploy/instance-deploy.sh` are IN-fence. Box-side fan-out is illegal this wave.

## R6 — the reader cannot anchor itself

    git show origin/main:cloud/lib/barkpark_cloud/platform_delivery.ex | sed -n '/def list/,/^  end/p'

`list/1` filters on `sha` and `limit` only — no `target`, no "latest". A
self-anchoring recorder cannot ask GET /v1/deliveries "what did I last deliver to
cp?" today. And `@conflict_target [:sha, :delivering_run_id, :first_seen_at]`
omits `target`, so posting both legs with one run-scoped timestamp drops the
second row under `on_conflict: :nothing`.
