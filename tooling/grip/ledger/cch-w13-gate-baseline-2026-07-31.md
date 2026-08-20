# cch wave 13 — gate baseline at origin/main (re-derivation recipes)

origin/main measured: `0f28d541e2b8b1412c7f4ee373950443dca7f49c`
(`feat(tasks): a task is born adjudicated, and adoption cannot smuggle a bare row in (#8519)`)

## 0. Get an origin/main tree without touching the checkout

The primary checkout is NOT origin/main (see §4). Every gate below was run against
bytes extracted from origin/main, not against the working tree.

    D=/tmp/gm && rm -rf "$D" && mkdir -p "$D" && git archive origin/main | tar -x -C "$D"

A PARTIAL extract manufactures reds. `cloud/priv/static/__app.test.mjs` reads
`internal/taskboard/testdata/**`; `design/emit-fence.test.mjs` copies
`api/assets/**` and `api/lib/barkpark_web/layouts/root.html.heex`; the seal
predicate spawns emit-fence, so a cloud-only extract reds 2/49 seal tests for a
reason that has nothing to do with the seal. Extract the WHOLE tree.

## 1. Console gate — every step of console-harness.yml job `console-unit`

    cd $D
    node --check cloud/priv/static/app.js                                  # 0
    node --test cloud/priv/static/__app.test.mjs                           # 0  (741 pass / 0 fail)
    node cloud/priv/static/__preview__/smoke.mjs                           # 0  (99 scenarios)
    node --test cloud/priv/static/__preview__/seal-predicate.test.mjs      # 0  (49 pass / 0 fail)
    node cloud/priv/static/__css_check.mjs                                 # 0  (861 classes, 0 errors)

job `cssom-parity`:

    node cloud/priv/static/__preview__/cssom-parity.mjs                    # 0  (1236 heads, MISSES 0)

job `path-escape`:

    bash scripts/console-path-escape-check.sh --selftest                   # 0  (144 passed)
    bash scripts/console-path-escape-check.sh                              # 0  (10 reads dispatched)

## 2. Cloud gate — every step of cloud.yml jobs `compile`, `test`, `path-escape`

`cc` is shadowed by the Claude wrapper on this host; bcrypt_elixir's NIF build dies
with `error: unknown option '-g'` unless CC is pinned.

    ln -sfn /Volumes/SATECHI/github/barkpark/cloud/deps $D/cloud/deps
    cd $D/cloud
    CC=/usr/bin/clang mix compile --warnings-as-errors                     # 0
    mix format --check-formatted                                           # 0
    MIX_ENV=test MIX_TEST_PARTITION=_gb13 CC=/usr/bin/clang mix ecto.create # 0
    MIX_ENV=test MIX_TEST_PARTITION=_gb13 CC=/usr/bin/clang mix ecto.migrate # 0
    MIX_ENV=test MIX_TEST_PARTITION=_gb13 CC=/usr/bin/clang mix test        # 0  (2593 tests, 0 failures)

`config/test.exs:17` hardcodes `barkpark_cloud_test#{MIX_TEST_PARTITION}` and IGNORES
`DATABASE_URL` — set MIX_TEST_PARTITION or you silently run against the stale local
checkout's test DB.

    cd $D
    bash scripts/cloud-path-escape-check.sh --selftest                     # 0  (121 passed)
    bash scripts/cloud-path-escape-check.sh                                # 0  (4 reads dispatched)

## 3. The two pre-existing advisory reds — NOT a wave-13 builder's

    gh api repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/check-runs \
      --paginate -q '.check_runs[] | select(.conclusion=="failure") | .name'

  * `Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)`
    — `security.yml:220 continue-on-error: true`, `working-directory: api`. Every
    finding is in `api/lib/barkpark/tenancy/workspace_bundle/janitor.ex` (lines 179,
    188, 275, 276, 286) plus `lib/barkpark_web/controllers/error_html.ex`. It never
    scans `cloud/**`. Owned by a DIFFERENT epic: `pds-bl-sobelow-baseline-line-shift-reconcile`.
  * `Required-check spec drift (advisory)` — `required-checks-drift.yml:116
    continue-on-error: true`. `required-checks: 114 passed, 1 failed`; the one failure
    is `FAIL full mode reds on the committed spec — hgw2-s7's slice gate cannot pass`.
    That IS the unmade PUT (see §5). Not touchable this wave by the wish.

## 4. The checkout is not origin/main

    git rev-parse HEAD          # a31faa52dc7586168cecc7dc2d2324b3732943f6
    git rev-parse origin/main   # 0f28d541e2b8b1412c7f4ee373950443dca7f49c
    git rev-list --count HEAD..origin/main   # 201
    git rev-list --count origin/main..HEAD   # 48
    git merge-base --is-ancestor HEAD origin/main; echo $?   # 1 — DIVERGED, not merely behind

Local `main` is 201 behind AND 48 ahead. Any gate run in the primary checkout, or in
a worktree branched from local `main`, measures a tree that does not exist on the
server. Builders must branch from `origin/main` explicitly.

## 5. Cloud gate and Console gate are COMMITTED but NOT LIVE

    node -e "console.log(require('./.github/required-checks.json').protection.required_status_checks.checks.map(c=>c.context))"
      # [ 'Cloud gate', 'Console gate', 'Elixir gate', 'PR references an active task' ]
    gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.checks[].context'
      # Elixir gate
      # PR references an active task

Consequence for a wave-13 builder: a RED `Cloud gate` or `Console gate` does not block
the merge button today. The gate is honest; it is simply not wired to the door. Run it
yourself; do not infer safety from a green merge.

## 6. Nothing local runs the cloud format check

    grep -n '^format' Makefile          # both targets are `cd api && mix format …`
    grep -c cloud .githooks/pre-commit  # 0

Wave 12's cloud red (task-107a3b8292cbf8eb, one unformatted file from #8499) can
recur identically. `cd cloud && mix format` is a manual step with no local guard.

## 7. Two console instruments are gated by NOTHING

    grep -rn 'overflow-guard\|modal-oracle' --include='*.yml' --include=Makefile --include='*.sh' .

Only hits are historical ledger/fixture text. `cloud/priv/static/__preview__/overflow-guard.mjs`
and `modal-oracle.mjs` are run by no workflow, no make target and no script on
origin/main. A wave-13 band slice that extends overflow-guard is extending an
UNGATED instrument unless it also wires it into `console-unit`.
