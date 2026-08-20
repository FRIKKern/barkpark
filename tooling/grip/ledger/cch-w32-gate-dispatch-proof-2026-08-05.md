# cch-w32 — gate dispatch proof (re-derivation recipes)

Verifier: gate-dispatch-proof. All commands assume a checkout of `origin/main`.
The primary checkout was **447 commits behind** when this ran, and two of the
three mandated scripts did not exist in it — every command below therefore
materializes `origin/main` first.

## 0. Materialize origin/main (REQUIRED — the worktree is stale)

    git rev-list --count HEAD..origin/main          # 447 at time of writing
    D=$(mktemp -d); git archive origin/main | tar -x -C $D; cd $D

## 1. Selftests (all three ratchets)

    bash scripts/console-path-escape-check.sh --selftest   # 172 passed, 0 failed
    bash scripts/cloud-path-escape-check.sh   --selftest   # 122 passed, 0 failed
    bash scripts/elixir-path-escape-check.sh  --selftest   # 113 passed, 0 failed

Selftests MUST run from a real repo root: cases 8/9 read
`.github/workflows/*.yml` relative to the script's own `..`, and fail with
`FAIL — <wf>.yml not found` plus a Python traceback when run from a bare
scripts/ dir. That traceback is an environment fault, not a gate defect.

## 2. Dispatch matrix (Q1/Q2/Q3)

    printf 'cloud/lib/barkpark_cloud/notifications.ex\n' \
      | bash scripts/elixir-path-escape-check.sh  --match compile   # false
    printf 'cloud/lib/barkpark_cloud/notifications.ex\n' \
      | bash scripts/elixir-path-escape-check.sh  --match test      # false
    printf 'cloud/lib/barkpark_cloud/notifications.ex\n' \
      | bash scripts/console-path-escape-check.sh --match console   # true
    printf 'cloud/lib/barkpark_cloud/notifications.ex\n' \
      | bash scripts/cloud-path-escape-check.sh   --match cloud     # true

    printf 'cloud/priv/static/app.js\n' \
      | bash scripts/elixir-path-escape-check.sh  --match compile   # false
    printf 'api/lib/barkpark/documents.ex\n' \
      | bash scripts/console-path-escape-check.sh --match console   # false (control)

Declared sets:

    bash scripts/console-path-escape-check.sh --print-set console   # includes cloud/lib/**
    bash scripts/elixir-path-escape-check.sh  --print-set compile   # api/** design/** only

## 3. The vacuous-green mechanism

`.github/workflows/elixir.yml:644-646` — `Elixir gate` is `if: always()`, so it
renders on every PR. Its `decide()` (`:670-700`) accepts `skipped` whenever the
dispatcher output is exactly `false`. On a `cloud/**`-only PR both outputs are
`false`, so the REQUIRED context concludes **success having compiled and tested
nothing**. Honest in its log, silent in its conclusion.

## 4. Cloud gate vs cloud/priv/static

    grep -rn 'File.read\|Path.join.*static' cloud/test/ | grep -iE 'app\.js|app\.css'
    # -> ZERO hits. No Elixir test parses console bytes.
    grep -c 'test(' cloud/priv/static/__app.test.mjs        # 919

`cloud/test/web/static_allowlist_test.exs:26-30` asserts only that `/app.js`,
`/app.css` and `/fonts/Inter-var.woff2` return 200. All 919 content assertions
run under `console-harness.yml` (Console gate), never `cloud.yml`.

## 5. Required set — LIVE, not committed

    gh api repos/:owner/:repo/branches/main/protection/required_status_checks
    bash scripts/required-checks-verify.sh          # exit 0, "all agree"

Live = FOUR: Elixir gate, PR references an active task, Cloud gate, Console gate.
Therefore `console-harness.yml:351,481,548` ("`Console gate` … is ADVISORY today
— the live required set is `Elixir gate` and `PR references an active task`") is
**stale in three places**, and tasks
`cchi-w25-bl-live-protection-requires-two-while-the-spec-declares-four` and
`task-fbdf8011a1721236` are FALSE-OPEN (both `status=published`, `closed_at=None`).

## 6. Font pin

    git ls-tree -r --name-only origin/main | grep -i 'woff2$'
    # cloud/priv/static/fonts/ -> FOUR   (Inter-var + 3x IBMPlexMono)
    # api/priv/static/fonts/   -> SIX    (adds 2x SourceSerif4Variable)

The "six" belongs to `api/`, not the console.

## 7. rc 1 vs rc 2 conclusion identity

`console-harness.yml:424-449` — the CSSOM parity wrapper maps rc 2 -> `exit 1`
and rc 1 -> `exit 1`. **Identical check conclusion**; only the annotation
differs (`::error title=CSSOM parity REFUSED` vs `…DEFECT`, plus
`…UNINTERPRETABLE` for anything outside 0/1/2). Proven by selftest case 11.

## 8. Mutation proof — the console ratchet can lose

    # inside the materialized tree
    python3 - <<'EOF'
    p='cloud/priv/static/__app.test.mjs'; s=open(p).read()
    open(p,'w').write('const __probe = join(REPO_ROOT, "api/mix.exs");\n' + s)
    EOF
    bash scripts/console-path-escape-check.sh; echo $?     # 1
    # ::error::console-path-escape-check: UNCOVERED repo-root read: api/mix.exs
    git checkout cloud/priv/static/__app.test.mjs
    bash scripts/console-path-escape-check.sh; echo $?     # 0

GOTCHA that cost two attempts: the ratchet only flags reads of files that
**exist**, and it scans reads made FROM `cloud/priv/static/**.{mjs,js}` — not
paths appearing in workflow `run:` steps. A probe naming a non-existent path,
or a mutation planted in `console-harness.yml`, both pass at rc 0 and look like
a guard that cannot lose. Mutate with a real, undeclared path.
