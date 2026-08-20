# Re-derivation recipe — Console gate on origin/main (wave 37 verify)

Claim under test: "a surveyor extracted origin/main cleanly and got 7 pass / 68 FAIL from
`__preview__/seal-predicate.test.mjs`" — is the required Console gate RED on main?

Verdict: **NO. The gate is GREEN on main; the 68 failures are an EXTRACTION ARTEFACT.**

## 1. Reproduce the artefact (partial archive — no `.github/`, no `.git`)

```sh
T=$(mktemp -d); git archive origin/main cloud internal deploy | tar -x -C $T
cd $T && node --test cloud/priv/static/__preview__/seal-predicate.test.mjs 2>&1 | tail -8
# -> # pass 7 / # fail 68
```

Cause, quoted from the predicate's own refusal (exit 2, INFRA FAULT — not a verdict):

```sh
cd $T && node cloud/priv/static/__preview__/seal-predicate.mjs \
  --ledger cloud/priv/static/__preview__/fixtures/seal-predicate/sealable.json \
  --repo . --guard-cmd true 2>&1 | tail -4
# VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT ... code=UNREADABLE-REPO-ROOT repo=.
```

`seal-predicate.test.mjs` sets `REPO = resolve(HERE, '../../../..')` (the extraction root) and
passes `--repo REPO`; the predicate refuses when `--repo` carries no
`.github/workflows/cloud.yml`. The tests assert exit 1 (NO_SEAL) and get exit 2 (INFRA) —
68 identical `2 !== 1` assertion failures. `git archive cloud internal deploy` cannot ever
contain `.github/`, so the extraction, not main, is what failed.

## 2. The honest run (full tree + a real `.git`, origin/main pinned to the CI sha)

```sh
S=$(mktemp -d)/mainclone
git clone -q /Volumes/SATECHI/github/barkpark $S
cd $S && git checkout -q bf97452bb38488d04cfbb596c2528a3f34ad5baf
git update-ref refs/remotes/origin/main bf97452bb38488d04cfbb596c2528a3f34ad5baf
```

Then every `console-unit` step exactly as `.github/workflows/console-harness.yml` runs it,
including the recording pass-through `curl` shim on the seal step:

```sh
node --check cloud/priv/static/app.js                                  # rc=0
node --test cloud/priv/static/__app.test.mjs                           # 914/914 pass
node cloud/priv/static/__preview__/smoke.mjs                           # all 103 scenarios rendered
shim=$(mktemp -d); log=$shim/curl-calls.log; : > "$log"
printf '#!/bin/sh\necho "$*" >> %s\nexec /usr/bin/curl "$@"\n' "$log" > "$shim/curl"; chmod +x "$shim/curl"
PATH="$shim:$PATH" node --test cloud/priv/static/__preview__/seal-predicate.test.mjs  # 75/75 pass
wc -c < "$log"                                                          # 0 -> hermetic
node cloud/priv/static/__preview__/breakpoint-sweep.mjs                 # rc=0
node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs     # 51/51 pass
node cloud/priv/static/__css_check.mjs                                  # 0 error(s), rc=0
bash scripts/console-path-escape-check.sh --selftest                    # 172 passed, 0 failed
bash scripts/console-path-escape-check.sh                               # OK
```

## 3. Cross-check the LIVE gate (a completed conclusion, not an absence)

```sh
gh api repos/FRIKKern/barkpark/commits/bf97452bb38488d04cfbb596c2528a3f34ad5baf/check-runs \
  --paginate -q '.check_runs[]|select(.name|test("Console"))|"\(.name) \(.status) \(.conclusion)"'
# Console gate completed success
# Console client unit harness completed success
# Console path-escape ratchet completed success
# Dispatch (console paths) completed success
```

Browser jobs on the same sha, also `success`: `CSSOM parity (authored CSS vs browser)`,
`Billing tier floor (rendered)`, `Overflow guard (rendered)`. Nothing on bf97452bb is
`failure`; the only non-success rows are `skipped` (Break-glass harness, instance).

`Console gate` is a LIVE required context:

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.contexts[]'
# Elixir gate / PR references an active task / Cloud gate / Console gate
```

## 4. `__app.test.mjs` true count and EOF ownership

```sh
git show origin/main:cloud/priv/static/__app.test.mjs | wc -l      # 15528
git show origin/main:cloud/priv/static/app.js | wc -l              # 20959
```

914 tests on origin/main. The primary checkout at `/Volumes/SATECHI/github/barkpark`
measures 721 because its local `main` (a31faa52d) is NOT a descendant of origin/main —
`git merge-base --is-ancestor origin/main HEAD` fails, and the file is 10894 lines there
(4799 lines short). Any wave-37 anchor read from the primary checkout is stale by
construction; read anchors with `git show origin/main:<path>`.

EOF owner of `__app.test.mjs` on origin/main: line **15516**,
`test("cch-w35-s4 THE TWIN FENCE (zero reach today, and it CAN lose): evidence beats the read-scoped sentence", ...)`,
closing at line 15528 (last line of file).

## 5. What this licenses / does not license

- Licenses: no wave-37 slice inherits a red. No repair needs sequencing first.
- Does NOT license: any claim that a green here means an assertion was made. The sweep's
  own output says `heights ... VACUOUSLY GREEN` (zero height-bearing @media) and `themes ...
  COVERAGE, NOT YIELD`. `__css_check` reports 277 raw-px font-size lines as report-only (R4).
