# Registration trigger — live re-run, 2026-08-19 (read-only)

Verifier V1 of the gate-wiring / spec-generator wave. Strictly read-only: no
`required-checks-apply.sh --confirm`, no branch-protection PUT. Live protection was
read but never written.

## Anchor

- `origin/main` = `bf499f54b63135b8ae078305b83f2b5b2c078877` (the wave digest quoted
  `122fd0df81`; main has moved since).
- The primary checkout HEAD is `228090798b`, **14 commits behind** origin/main. Every
  script exercised below was proven byte-identical to origin/main first — otherwise
  these numbers would be a claim about a stale tree, not about main.

## Re-derivation

```sh
cd /Volumes/SATECHI/github/barkpark
S=$(mktemp -d)

# 0. prove the scripts you are about to run ARE main's
for f in scripts/registration-deadlock-sweep.sh scripts/required-checks-floor.sh \
         scripts/required-checks-verify.sh .github/required-checks.json; do
  git diff --quiet HEAD origin/main -- "$f" && echo "SAME $f" || echo "DIFF $f"
done

# 1. spec gate colour on main HEAD + the app_id read off a REAL run (never assumed)
gh api "repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
  --jq '.check_runs[]|select(.name=="Required-check spec gate")|"\(.name) app=\(.app.id) \(.status)/\(.conclusion)"'

# 2. candidate spec = main's spec + the fifth context
git show origin/main:.github/required-checks.json > $S/rc-base.json
jq '.protection.required_status_checks.checks += [{"context":"Required-check spec gate","app_id":15368}]' \
  $S/rc-base.json > $S/rc-cand.json

# 3. the sweep — quote evaluated/skipped, NEVER the bare rc
bash scripts/registration-deadlock-sweep.sh --spec $S/rc-cand.json \
  --ref-file $S/rc-base.json --require-new-context; echo "sweep rc=$?"

# 4. the floor, both arms
bash scripts/required-checks-floor.sh --reference $S/rc-base.json $S/rc-cand.json; echo "floor rc=$?"
bash scripts/required-checks-floor.sh --acknowledge-growth --reference $S/rc-base.json $S/rc-cand.json; echo "ack rc=$?"

# 5. live protection, READ ONLY
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '.required_status_checks.checks[].context, "enforce_admins=\(.enforce_admins.enabled)"'
```

## What it printed, 2026-08-19

- `Required-check spec gate app=15368 completed/success` on `bf499f54b6`.
  **app_id 15368 is now READ, not assumed** — closing the permanent-deadlock typo
  class cch-w37 warns about. Every one of the 39 check runs on main HEAD is app 15368
  (`github-actions`); there is no second publisher to confuse it with.
- Sweep: `swept 60 open PR(s); evaluated 21, skipped 39 (draft 1, conflicting 27,
  already-blocked 11, other 0); casualties: 0`, **rc 0**, and 21 `ok` rows. It also
  printed `PARTIAL COVERAGE: 39 PR(s) were skipped and say nothing either way.`
  It proposed a context main does not require (`+ Required-check spec gate`), so the
  ORDERING TRAP is not tripped — this is a real evaluation, not a short-circuit.
- Floor: **rc 2** without `--acknowledge-growth` (`Re-run with --acknowledge-growth
  once a human has decided each added name belongs`), **rc 0** with it
  (`superset held; growth ACKNOWLEDGED, 5 context(s)`). Both arms behave.
- Live protection: exactly four contexts, `enforce_admins=true`. Unchanged.

## The trigger fires — and the caveat that must ship beside it

The S7 exclusion row in `.github/required-checks.json` writes its own replacement
trigger: *"the spec gate is green on main HEAD, and a fresh
`scripts/registration-deadlock-sweep.sh` run for this context reports zero
casualties."* Both halves are literally satisfied today.

But the denominator is the whole question, and it is transient. 39 of 60 open PRs say
nothing either way; 11 of those are BLOCKED, a moving state (the wave's earlier
snapshot recorded 61/21/13-blocked). Any authorising sentence must quote
`evaluated 21, skipped 39` and the PARTIAL COVERAGE line — never `rc 0`.

`cch-w36-…-after-census-green` is `lifecycle=cancelled` (SUPERSEDED DUPLICATE). The
live row is `cch-w37-bl-register-spec-gate-human-gate`, `lifecycle=open`, which makes
step 3 (the PUT) an explicit **human gate**. Not taken.

## Incidental, worth a look elsewhere

`required-checks-verify.sh` exits 0 today, but its deadlock detector defaults to
`recent_pr_head()` (:575, :600) — this run measured `872177ca71`, a PR head, **not**
main. A green verify is therefore not a statement about main HEAD unless `--sha` is
passed. Not in this verifier's fence; filed for the wave.
