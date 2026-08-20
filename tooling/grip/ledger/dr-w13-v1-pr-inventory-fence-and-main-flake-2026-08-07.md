# dr-w13 V1 — PR inventory, main's own red, and the CCH wave-45 fence

Measured 2026-08-07 10:28–10:41Z. `origin/main` = `b00d793c0e2065e98a03fed6c4356245d897ee3a` at both ends
of the window (it did not move). GitHub REST budget at start: `4945` remaining.

## 1. main's own Elixir Test HAS concluded — FAILURE — and it is a FLAKE, not a regression

    gh api "repos/:owner/:repo/commits/b00d793c0e2065e98a03fed6c4356245d897ee3a/check-runs?per_page=100" \
      -q '.check_runs[]|[.name,.status,.conclusion]|@tsv' | grep -vE 'success|skipped'

    Test (Elixir 1.18.1 / OTP 27.0)   completed  failure
    Elixir gate                       completed  failure     # fail-closed rollup of the above

One test of 13,561 (`27 doctests, 13561 tests, 1 failure, 48 excluded`, finished 703.0s):

    1) test POST — the Runner did not answer an unanswered trigger is its OWN 503 …
       (BarkparkWeb.SiteDeployControllerTest)
       test/barkpark_web/controllers/site_deploy_controller_test.exs:158
       ** (RuntimeError) expected response with status 503, got: 202

Flake proof (byte-identity across a green run and a red run):

    gh api repos/:owner/:repo/commits/$(gh pr view 10015 --json headRefOid -q .headRefOid)/check-runs \
      -q '.check_runs[]|select(.name|startswith("Test ("))|[.name,.conclusion]|@tsv'
    # => Test (Elixir 1.18.1 / OTP 27.0)   success

    git diff --stat d73c5b526 b00d793c0 -- \
      api/lib/barkpark/sites/deploy_runner.ex \
      api/lib/barkpark_web/controllers/site_deploy_controller.ex \
      api/test/barkpark_web/controllers/site_deploy_controller_test.exs
    # => EMPTY

The only api/ delta since #10015 landed is #10207's papers-reader dark mode
(`bulldocs.html.heex`, `.sobelow-skips`, one render test). The test sets
`trigger_call_timeout_ms: 1` and asserts the real Runner outruns a 1 ms budget — a race whose
green side is luck. This is a deploy-reliability-owned instrument that can report a pass it did
not earn AND a fail nobody caused.

## 2. Merge board (re-queried at 10:41Z per D127)

    for n in 10245 10246 9976 10069 10238 10014 10133 10155 10019 10129 10173; do \
      gh pr view $n --json state,mergeable,mergeStateStatus,headRefOid \
        -q '[.state,.mergeable,.mergeStateStatus,.headRefOid]|@tsv'; done

CLEAN, all four required contexts green, no reviewDecision, no auto-merge, nothing blocking —
**FIVE**, not four (#10238 was uncounted):

| PR | contents | why still open |
|---|---|---|
| 10245 | 1 file, webhook fan-out counter | opened 09:47Z; nobody merged |
| 10246 | 1 file, scripts escape floor | opened 09:47Z; nobody merged |
| 9976  | 6 files, `tooling/grip/ledger/**` ONLY | task-gate went green 08:07Z; nobody merged |
| 10069 | 7 files, `tooling/grip/ledger/**` ONLY | task-gate went green 08:07Z; nobody merged |
| 10238 | CCH w44 charter + 5 ledger rows | CLEAN; nobody merged |

BLOCKED, cause named per PR:

    # 10014 — Cloud path-escape ratchet, one line
    gh api repos/:owner/:repo/actions/jobs/92786582581/logs | grep -i UNCOVERED
    ##[error]cloud-path-escape-check: UNCOVERED repo-root read: deploy/site-deploy-node.sh
    Fix: add the path to CLOUD_PATHS at the top of this script
    # main's CLOUD_PATHS (git show origin/main:scripts/cloud-path-escape-check.sh, :114-122)
    # carries deploy/site-deploy.sh but NOT deploy/site-deploy-node.sh. One line. Confirms the digest.

    # 10133 — sticky pr-task-gate lease lapse (no code fault)
    ##[error]pr-task-gate: FAIL: task 'task-fb4fb869490b4213' is 'open': the claim by
    'epic-cycle-decide' had ALREADY lapsed 22s before this PR was opened
    # only a PUSH re-fires the verdict

    # 10155 — Cloud gate AND Console gate, both via path-escape ratchet
    Console gate:  R_ESCAPE: failure … FAIL  path-escape ratchet: failure

CONFLICTING (`git merge-tree --write-tree --name-only origin/main <head>`):

    10129 -> attention_order.json, cloud_status_cmd.go, cloud_status_cmd_test.go,
             attention_order_cases.json   (deploy_ledger.ex and router.ex AUTO-MERGE clean)
    10173 -> .claude/workflows/bp-deploy-reliability-charter.md   (only file; #10208 moved it)
    10019 -> cloud/lib/barkpark_cloud/notifications/render.ex     (only file)

## 3. Merge order

D127 governs: merge everything CLEAN, then re-query. Order that minimises re-conflict:

1. **9976, 10069** — ledger-only `.md`, zero code surface, cannot conflict with anything.
2. **10238** — CCH charter + ledger; touches no file any other open PR touches.
3. **10246** — `scripts/` only.
4. **10245** — 1 file, no other open PR touches it.
5. Then unblock, in this order, because each removes a blocker for the next:
   **10014** (add `deploy/site-deploy-node.sh` to `CLOUD_PATHS`; same one-line fix also clears
   **10155**) → **10133** (re-claim `task-fb4fb869490b4213`, push) → **10173** (rebase the charter
   onto #10208) → **10129** (rebase; its Elixir side already auto-merges, only the Go/JSON
   attention-order fixtures conflict) → **10019** (rebase over #10200's `render.ex`).

Re-run main's Elixir gate before treating main as red; see §1.

## 4. CCH wave-45 declared fence vs deploy-reliability wave 13

`bp paper view` returns 422 semantic_empty and `/v1/data/doc/production/<id>` returns 404, so the
Paper was read over the query door:

    curl -s -H "Authorization: Bearer $(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")" \
      'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=300' \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['result']['documents'];p=[x for x in d if x['_id']=='cloud-console-hardening-wave-45-2026-08-07'][0];print(json.dumps(p['body']))"

DECLARED fence (movement one = the instance-detail write cluster; movement two = the binding
census's derived arm):

- WRITE: `cloud/priv/static/app.js`, `cloud/priv/static/__binding_census.mjs`,
  `cloud/priv/static/__preview__/{scenarios,smoke,breakpoint-sweep*}.mjs`,
  `cloud/priv/static/__app.test.mjs`, `.claude/workflows/bp-cloud-console-hardening-charter.md`,
  `tooling/grip/ledger/cch-w45-*`
- READ ONLY: `cloud/lib/**` (`accounts.ex`, `accounts/authz.ex`, `web/router.ex`,
  `TeamMembership.outranks?` callers), `cloud/priv/static/index.html`

DISJOINT from `deploy/**`, `internal/agent`, `internal/cloudclient` and every
deploy-reliability ledger row — the declared fence contains none of them.

    git log origin/main --since='24 hours ago' --name-only --pretty=format:'%h|%s'
    # 24h: no CCH-authored commit touches deploy/, internal/agent or internal/cloudclient.

**BUT the declared fence understates CCH's observed reach.** In the same 24h, CCH-authored
commits wrote two files deploy-reliability wave 13 needs:

    git log origin/main --since='24 hours ago' --pretty=format:'%h %s' --name-only -- \
      cloud/lib/barkpark_cloud/web/router.ex cloud/lib/barkpark_cloud/notifications/

    6ddbda7c6 (#10200, CCH)  notifications.ex, notifications/event_email.ex, notifications/render.ex
    f85b944c4 (#10125, CCH)  web/router.ex
    8be3dedea (#10087, CCH)  web/router.ex
    7b5e54b5d (#9918,  CCH)  web/router.ex
    b664b0b6d (#10187, DR)   web/router.ex

Open PRs contending for the SAME two files right now: `web/router.ex` — #10154 (CCH), #9956
(CCH), #10019 (DR), #10129 (DR). `notifications/render.ex` — #10019 (DR), and it is #10019's
ONLY conflict, caused by CCH's #10200.

Ruling for the wave: a wave-13 slice on `web/router.ex` or on `cloud/lib/barkpark_cloud/
notifications/**` is fence-disjoint from CCH w45 **as declared** but sits on CCH's proven
traffic lane. Give any such slice a narrow, function-level anchor and land it before CCH w45's
builders re-enter `cloud/lib`, or it repeats #10019's conflict exactly.
