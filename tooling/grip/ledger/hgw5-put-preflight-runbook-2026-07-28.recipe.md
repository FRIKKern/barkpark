# PUT pre-flight runbook — honest-gates wave 5, the flip

Every line below was RUN against `origin/main @ ab396959c` on 2026-07-28 and the
real output pasted. Charter D73 makes every settings read L3: re-derive steps
0, 4, 5 and 6 at PUT time. Never quote this file's numbers as current.

## Which two shas, and why

The generator's S1 selection keeps only names present on EVERY sampled path
shape. One sha therefore has to exercise the Elixir matrix and one has to skip
it, or a matrix name that is really path-conditional gets promoted.

| sha | PR | path shape | dispatcher | matrix jobs |
|---|---|---|---|---|
| `2053319d3e4bd5618dfc79d0bc6f013d9755a408` | #6551 | CODE (`api/lib/**`, `api/test/**`, `docs/**`) | `Dispatch (changed-path sets)` = success | RAN — `Test (Elixir 1.18.1 / OTP 27.0)` rendered |
| `cc38bd37bafa3c562ecf50af3a0a34d55ff3fda1` | #6414 | DOCS/CI (`.github/workflows/**`, `scripts/**`, `.claude/**`) | `Dispatch (changed-path sets)` = success | SKIPPED — templates visible: `Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})` |

Both post-shim (both render `Elixir gate`). The #6414 head is the important one:
it is the poisoned shape R1/R2 exist for, and sampling only code heads would let
a template name through.

Re-derive the two shas rather than copying them:

    gh pr list --state open --limit 30 --json number,headRefOid,files --jq \
      '.[] | {n:.number, s:.headRefOid, code:([.files[].path]|map(startswith("api/"))|any)}'

Pick one `code:true` and one `code:false`, then confirm each:

    gh api repos/FRIKKern/barkpark/commits/<sha>/check-runs?per_page=100 \
      --jq '.check_runs[]|"\(.conclusion)\t\(.app.id)\t\(.name)"' | sort

Accept only if `Dispatch (changed-path sets)` is `success` and `Elixir gate` is
present. Reject any head where `Dispatch` is missing — the aggregator job did
not exist at that sha and no re-run can rescue it.

## Step 0 — pin the tree and read the world

    git fetch origin main -q && git rev-parse origin/main
    gh api repos/FRIKKern/barkpark/branches/main/protection || true
    gh api repos/FRIKKern/barkpark --jq '{auto:.allow_auto_merge,admin:.permissions.admin}'
    gh api repos/FRIKKern/barkpark/rulesets --jq 'length'

Observed 2026-07-28:

    ab396959c77b01f87800e7399d5616ed8fd99a7b
    {"message":"Branch not protected", ... "status":"404"}
    {"admin":true,"auto":false}
    0

`auto:false` is a REQUIRED pre-condition, not an observation: auto-merge stays
off (D53). If it reads true, stop and turn it off before the PUT.

## Step 1 — regenerate

    ./scripts/required-checks-generate.sh \
      --sha 2053319d3e4bd5618dfc79d0bc6f013d9755a408 \
      --sha cc38bd37bafa3c562ecf50af3a0a34d55ff3fda1 \
      --out /tmp/put.json
    # wrote /tmp/put.json (2 required context(s))

## Step 2 — the floor, and it must be SUPERSET, not `>= 2`

Nothing in the toolchain enforces a floor. `required-checks-verify.sh:74` asserts
only `checks | length > 0`, and a one-name spec is green END TO END — measured:

    jq '.protection.required_status_checks.checks |= [.[0]]' /tmp/put.json > /tmp/one.json
    bash scripts/required-checks-verify.sh --ci --spec /tmp/one.json ; echo $?   # → 0

An empty spec is the only thing that reds (`FAIL: … lists zero required
contexts — a spec that requires nothing cannot fail`, exit 1). So the runbook
supplies the floor itself, as a superset assertion against the COMMITTED spec:

    jq -e --slurpfile new /tmp/put.json '
      [.protection.required_status_checks.checks[] | .context] as $old
      | [$new[0].protection.required_status_checks.checks[] | .context] as $now
      | ($old - $now) | length == 0
    ' .github/required-checks.json >/dev/null \
      && echo FLOOR_OK || { echo "FLOOR FAIL: regen DROPPED a committed context"; exit 1; }

A bare `>= 2` would pass a spec that swapped both names for two junk ones.

## Step 3 — diff `.protection` ONLY

    diff <(jq '.protection' .github/required-checks.json) <(jq '.protection' /tmp/put.json) \
      && echo PROTECTION_IDENTICAL

Observed: `PROTECTION_IDENTICAL`. `.generated_from_shas` differs by design —
diffing whole files makes a clean regen look like drift.

## Step 4 — prove the deadlock detector CAN FAIL, before the PUT

Not a selftest: point it at a real frozen head.

    bash scripts/required-checks-verify.sh --deadlock --sha 4f80c43303ee16e390ef9b2ad8122f88d92c4fe9 ; echo $?

Observed exit 3, `DEADLOCK: … missing: Elixir gate`. Then a good head:

    bash scripts/required-checks-verify.sh --deadlock --sha 2053319d3e4bd5618dfc79d0bc6f013d9755a408 ; echo $?
    #   ok  every required context appears in the 17 name(s) rendered on 2053319d…  → 0

Both directions, or the detector is decoration.

## Step 5 — the rendered-name census (re-derive; do not quote)

    gh pr list --state open --limit 30 --json number,headRefOid,mergeable \
      --jq '.[]|"\(.number) \(.headRefOid) \(.mergeable)"' | while read -r n s m; do
      rc=0; bash scripts/required-checks-verify.sh --deadlock --sha "$s" >/dev/null 2>&1 || rc=$?
      printf '%-6s %-42s %-12s %s\n' "$n" "$s" "$m" "$rc"
    done

Observed 2026-07-28: 14 open, **10 at rc=3** (6086 6057 6055 6053 6028 5951 5922
5901 2907 — plus none others; 6551 6498 6414 5754 at rc=0). Three of the ten
(#6055 #6053 #6028) are MERGEABLE — they freeze on day one with no conflict to
blame. This census is the blast radius the flip announces; it belongs in the
slice's evidence, not in a survey.

## Step 6 — stamp the reversal BEFORE the call

Paste this exact string onto the task before the PUT:

    bash scripts/required-checks-apply.sh --disable --confirm

It is a `DELETE …/branches/main/protection`, prints the acting login and a UTC
timestamp, leaves the committed spec at `enforced:true` so the CI guard goes RED
until protection is restored. It does NOT route through `scripts/breakglass.sh`
— there is no committed record on this path (wave-5 S4's gap).

Restore is the same apply, forward:

    bash scripts/required-checks-apply.sh --spec .github/required-checks.json --confirm

## Step 7 — the PUT

`apply` refuses while the spec says `enforced:false` — measured, exit 1:

    FAIL: /tmp/put.json says enforced=false — regenerate and flip it in the PR
    that intends the protection, then apply

So the flip PR must land `enforced:true` in `.github/required-checks.json`
FIRST; the PUT then reads the committed spec, never `/tmp/put.json`:

    bash scripts/required-checks-apply.sh --spec .github/required-checks.json --confirm

Payload it will send (verify with `--payload` first — read-only):

    {"checks":[{"context":"Elixir gate","app_id":15368},
               {"context":"PR references an active task","app_id":15368}],
     "ea":true,"afp":false}

`apply` verifies its own read-back. Then, independently:

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{ea:.enforce_admins.enabled, checks:[.required_status_checks.checks[].context]}'
    bash scripts/required-checks-verify.sh --ci ; echo $?

## Prose sites — measured, and narrower than the charter says

`git grep -n -- '--admin'` on tracked files. Only ONE site TEACHES the verb:

- `.claude/workflows/bp-loop-ledger.md:43` — imperative fleet instruction. FIX.
- `docs/ops/merge-gates.md:326-327` — asserts "every merge in this repo is
  `gh pr merge --squash --admin`". Stale after the flip. FIX as an assertion.
- `.github/workflows/elixir.yml:27` — descriptive, becomes MORE true. LEAVE.
- `scripts/required-checks-verify.sh:117` and `scripts/required-checks.test.sh:337`
  carry the same sentence inside the flip's OWN verifier. A naive prose ratchet
  reds on main here. Scope any ratchet to `*.md` minus `tooling/grip/ledger/**`.
- `scripts/bp-merge.test.sh:118` — the ratchet that already exists, over
  EXECUTABLE lines of `bp-merge.sh`. Do not duplicate it.

Nothing outside the charter and `shell-harnesses.yml` references
`scripts/bp-merge.sh` — confirmed by `git grep -n bp-merge`.
