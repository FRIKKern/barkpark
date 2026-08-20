# cgsi-v1 — orphan selftests: do they actually pass today?

Ring: pre-wiring proof. Wiring a RED selftest into CI plants a red on main and invites
the next person to delete the step. Every arm below was RUN, not read.

All five scripts are byte-identical to origin/main (bf499f54), so these results are
authoritative for main even though the shared checkout sits at 228090798b:

    for f in scripts/cloud-static-gz-guard.sh api/scripts/sobelow-fresh-finding-guard.sh \
             scripts/studio-scrim-threshold-control.mjs scripts/workflow-portability-check.sh \
             scripts/pds-live-hetzner-placement-group.sh; do
      git show origin/main:$f | diff -q - $f >/dev/null && echo "SAME $f"; done

## Results

| arm | rc | verdict |
|---|---|---|
| `bash scripts/cloud-static-gz-guard.sh --selftest` | 0 | 10 passed, 0 failed |
| `bash scripts/cloud-static-gz-guard.sh` | 0 | 4 OK lines on today's tree |
| `(cd api && bash scripts/sobelow-fresh-finding-guard.sh --selftest)` | 0 | 4 fixtures + 2 disarm mutants, both caught |
| `(cd api && bash scripts/sobelow-fresh-finding-guard.sh)` | 0 | pre-plant exit 0 -> post-plant exit 1; probe removed |
| `node scripts/studio-scrim-threshold-control.mjs --self-test` | 0 | matrix + generator-deleted control |
| `node scripts/studio-scrim-threshold-control.mjs` | 0 | matrix only; prints "did NOT prove the control can fail" |
| `bash scripts/workflow-portability-check.sh --selftest` | 0 | 47 passed, 0 failed |
| `bash scripts/workflow-portability-check.sh` | 0 | 4 engines, 0 failures, 0 warnings |
| `bash scripts/pds-live-hetzner-placement-group.sh --selftest-offline` | 0 | credential-free arm PASS |

## Rerun

    cd <repo> && bash scripts/cloud-static-gz-guard.sh --selftest; echo rc=$?
    cd <repo> && bash scripts/cloud-static-gz-guard.sh; echo rc=$?
    cd <repo>/api && bash scripts/sobelow-fresh-finding-guard.sh --selftest; echo rc=$?
    cd <repo>/api && bash scripts/sobelow-fresh-finding-guard.sh; echo rc=$?   # needs mix+deps, ~2min
    cd <repo> && node scripts/studio-scrim-threshold-control.mjs --self-test; echo rc=$?
    cd <repo> && bash scripts/workflow-portability-check.sh --selftest; echo rc=$?
    cd <repo> && bash scripts/pds-live-hetzner-placement-group.sh --selftest-offline; echo rc=$?

## Wiring verdicts

- **cloud-static-gz-guard.sh — WIRE IT, both arms.** Zero CI callers repo-wide
  (`grep -rn cloud-static-gz-guard .github Makefile docs scripts tooling` hits only
  tooling/grip/ledger rows). Both arms green, hermetic (mktemp fixture repo), no network,
  no toolchain beyond git+bash. Best in-fence wiring target in this set. An open task
  already names it: `cch-cloud-gz-guard-ci-wiring`. Subject set is `cloud/**` +
  `.gitignore` + `cloud/Dockerfile` + `cloud/lib/barkpark_cloud/web/router.ex`.
  KNOWN LIMIT (het-w1-s3-residuals e3): STATIC_DIR is cloud-only, so nothing guards
  `api/priv/static`.

- **sobelow-fresh-finding-guard.sh — the BARE arm is ALREADY WIRED; only `--selftest`
  is orphaned.** security.yml:276 `run: bash scripts/sobelow-fresh-finding-guard.sh`
  under `defaults.run.working-directory: api`. The assignment's premise ("defined at
  line 63, never invoked") is HALF WRONG. What is true and worse: the whole `sobelow`
  job carries `continue-on-error: true` (security.yml:228), so both arms are advisory.
  `--selftest` is cheap and hermetic (no mix, no network) and can be wired ahead of the
  bare run as `... --selftest && ...`; the bare arm needs a full `mix sobelow`.
  BONUS FACT from the bare run: pre-plant scan exit=0 — main is GREEN on sobelow today,
  so the transition assertion is currently the only non-vacuous one.

- **workflow-portability-check.sh --selftest — NOT AN ORPHAN.** Line 115 is
  `exec bash "$HERE/workflow-portability-check.test.sh"`, and shell-harnesses.yml:589
  already runs that .test.sh directly; :596 runs the bare arm on `.claude/workflows`.
  Wiring `--selftest` too would be a second name for a wired suite — no new coverage.
  NOTHING TO DO HERE.

- **studio-scrim-threshold-control.mjs --self-test — GREEN but DO NOT WIRE BLIND.**
  Zero CI callers. It drives Playwright resolved from js/package.json against a
  file:// fixture — CI needs an explicit browser install step (`npx playwright install
  chromium`) or it reds for an environment reason, not a guard reason. Its subject set
  is scripts/fixtures/studio-scrim-threshold.html only, NOT root.html.heex, so it
  cannot catch the live cascade regression it was written about. Wire only with the
  browser step; note the bare arm self-declares "this run did NOT prove the control
  can fail", so `--self-test` is the only arm worth a gate.

- **PDS family — one script, and `--selftest-offline` IS the only CI-able arm.**
  Confirmed from the script's own usage block (:964ff): `--selftest` refuses at exit 3
  without a credential (two of its four credential states are PROCEED states and would
  pass vacuously); `--harvest-only` needs a credential; `--selftest-offline` scrubs
  every HCLOUD_*/HETZNER_* var, re-execs, counts survivors (must be zero), and runs the
  same four mutation blocks. Zero CI callers today (`grep -rn pds-live-hetzner .github`
  is empty). Green, rc 0.

## Safety

`git status --porcelain` diffed before and after every run. The only deltas across the
whole session are two ledger files written by OTHER concurrent sessions of this wave;
nothing I ran left a byte behind. The sobelow bare arm plants
`api/lib/barkpark/sobelow_fresh_finding_guard.ex` in the TRACKED tree for the duration
of one scan — verified absent afterwards (`ls` -> No such file). That transient tracked
mutation is itself a wiring caveat: it is unsafe to run concurrently with another
session's `mix` in the same checkout.
