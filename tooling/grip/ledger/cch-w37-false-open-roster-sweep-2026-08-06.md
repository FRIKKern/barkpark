# cch-w37 — FALSE-OPEN ROSTER SWEEP (verify phase, 2026-08-06)

Every row below was judged against its OWN acceptance criteria and driven by the
pinning test those criteria name, on a checkout of **origin/main bf97452bb**.
Nothing was closed. Re-derivation recipes are literal.

## 0. The checkout that makes these runs legitimate

The primary checkout is at `a31faa52d` with `cloud/priv/static/*` DIRTY — every
run taken there is a claim about a stale, modified tree, and `seal-predicate.test.mjs`
there reports **30 tests** (an older file), not 75.

    git rev-parse HEAD                       # a31faa52d…  (NOT origin/main)
    git status --porcelain cloud/            # 5 modified files

Recipe used for every run in this row:

    S=$(mktemp -d); git clone -q -s /Volumes/SATECHI/github/barkpark $S/clone
    cd $S/clone && git checkout -q bf97452bb38488d04cfbb596c2528a3f34ad5baf
    git update-ref refs/remotes/origin/main bf97452bb38488d04cfbb596c2528a3f34ad5baf

The `update-ref` matters: a local `-s` clone's `origin/main` points at the LOCAL
main (a31faa52d), and five clause-(b) legs of the seal predicate resolve
ancestry against `origin/main`.

## 1. THE 68/75 "MAIN IS RED" REPORT IS AN EXTRACTION ARTIFACT — REFUTED

`git archive origin/main cloud internal deploy | tar -x` omits `.github/`, and the
seal predicate refuses any root without `.github/workflows/cloud.yml`:

    INFRA FAULT …: --repo … carries no .github/workflows/cloud.yml, so it is not a
    checkout of this repository. … Nothing is asserted about clause (b).
    VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT … code=UNREADABLE-REPO-ROOT

exit 2; the suite asserts exit 1 → 68 failures, all `2 !== 1`. On a real checkout:

    cd $S/clone && node --test cloud/priv/static/__preview__/seal-predicate.test.mjs
    # tests 75 / # pass 75 / # fail 0

Intermediate proof that the cause is the repo root and not the code: a FULL
`git archive origin/main` (has `.github/`, no `.git/`) scores 61/75 — only the
14 history-reading clauses fail.

`node --test cloud/priv/static/__app.test.mjs` → **914 pass / 0 fail**.
`bash scripts/required-checks.test.sh --hermetic` → **119 passed, 0 failed**.

**Main's console gate is GREEN. No slice inherits a red.**

## 2. THE TWO "in_progress" ROWS ARE ALREADY `done`

| row | claimed state | measured |
|---|---|---|
| `cch-w35-s4-forbidden-evidence-beats-the-global-slug` | in_progress, epoch 7 | **done**, closed_at 2026-08-06T14:55:37Z, 14/14 criteria met |
| `cch-w36-s2-protection-census-quoted-pattern-fence` | in_progress, epoch 6 | **done**, closed_at 2026-08-06T14:56:07Z, 12/13 met |

    bp task get cch-w35-s4-forbidden-evidence-beats-the-global-slug -o json | \
      python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim']['epoch'],d['claim']['closed_at'])"

s2's single unmet criterion (12: "`116 passed, 0 failed`") is now SATISFIABLE and
better than filed — the hermetic run scores **119 passed, 0 failed**, §18 green
across all six fence clauses. Stamp-only; nothing to build.

## 3. THREE BACKLOG ROWS ARE CLOSABLE — each shipped AND mutation-proven able to lose

All mutations applied to `cloud/priv/static/app.js` in the clone, run, reverted;
baseline restored to 914/914 after each.

| row | ships at | mutation | red test |
|---|---|---|---|
| `cch-w36-bl-confirm-brake-billing-sentence` | app.js:8118-8123 (`var haltFault = operatorReadFault(r)`) | drop the guard from `ctl.fail` | `not ok 96 - cch-w36-s4-r: the Halt confirm dialog's OWN failure arm stops printing the billing sentence too` |
| `cch-w35-bl-newlaunch-hardcodes-plan-limit-on-any-403` | app.js:16314-16332 `newLaunchRefusalToast`, wired at :16354 | `if (slug === "limit_reached")` → `if (slug !== "nope_never")` | `not ok 4 - cch-w36-s1: the /new launch 403 toast BRANCHES ON THE SLUG, never on the status` |
| `cch-w35-bl-operator-403-vanishes-without-naming-authority` | app.js:8039-8058 (bounce toast, D411), :7884-7909 (`operatorReadFault`/`operatorCardBody`), :7743 (fleetRolloutAction) | (D) delete the bounce toast; (E) `status === 403` → `4030` | (D) `not ok 94 - … the fail-closed bounce EMITS one refusal`; (E) 4 reds incl. `not ok 93 - … operatorCardBody is the ONE funnel` |

Merge evidence: PR **#9851** MERGED 2026-08-06T14:36:10Z, merge commit `5b7f1fd12`.
None of the three carries a claim → **no epoch exists**; these are lead-side closes.

Nuance for the ruler: newLaunch criterion 3 says "two SCENARIOS"; the pinning is at
the function through `__bpTestHook`, and `scenarios.mjs` has no launch-403 fixture.

## 4. TWO ROWS ARE STILL-OPEN — with the half that already landed named

**`cch-w33-bl-set-deployment-detail-is-a-third-silent-chop`** — criterion 2 (the
`@doc` describes what the code does) is **MET** on main: registry.ex:6131-6144 now
says the caption is "TRUNCATED … not rejected" and "carries NO `truncated_from`
marker: `detail` is a bare string column with nowhere to put one", plus the
cch-w34-s5 `:text` migration note. Criteria 1/3/4 remain: no production max-length
query, no disclosure mechanism, no losing fixture. `grep -rn truncated_from cloud/lib`
shows the marker at 1834/1844/6089 — never on the `detail` write path
(`set_deployment_detail/2`, registry.ex:6153).

**`cch-w34-bl-merge-truth-blind-outside-workflows`** — criterion 1 UNFIXED. The
scanner still reads one directory:

    scripts/required-checks-verify.sh:378
      files="$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.yml' | sort)"

and criterion 4's live instance survives verbatim: `docs/ops/merge-gates.md:343`
still says "one of the **two** required contexts" while the live set is FOUR.
§18 of `required-checks.test.sh` does NOT cover this: it censuses "main is
unprotected" claims, not wrong COUNTS — which is exactly the third claim shape
criterion 1 asks for.

**The "EMPTY acceptance-criteria list" premise is WRONG.** The row carries **6**
criteria, 0 met (`criteria_progress {'met': 0, 'total': 6}`). No ruling is needed;
it is a normal open row.

## 5. THE DENOMINATOR, MEASURED TWICE

    bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections;d=json.load(sys.stdin);ch=d['children'];pub=[c for c in ch if not c['doc_id'].startswith('drafts.')];print('total',len(ch),'drafts',len(ch)-len(pub));print(collections.Counter(c['lifecycle_status'] for c in pub))"
    total 434 drafts 7
    Counter({'done': 249, 'open': 142, 'cancelled': 35, 'considering': 1})

CONFIRMED: 434 children · 7 `drafts.*` shadow twins · 427 published.
**REFUTED: live is 143, not 144** (142 open + 1 considering). Read twice, identical.
The lone considering row is `cloud-console-operator-audit-log`.

**REFUTED: "the considering row is invisible to clause (a) and would seal
SILENTLY."** That was D83's finding and charter D90 already closed it.
`seal-predicate.mjs:1287-1288`:

    const considering = children.filter((c) => PENDING_STATUSES.includes(c.lifecycle_status));
    const residue = [...live, ...considering];

with `PENDING_STATUSES = ['considering']` (:248) and the comment at :241 stating the
intent verbatim. The fixture `terminal-one-considering-row.json` pins it, and it
passes inside the 75/75 run. Belt and braces: a live run with no successor exits 1
before clause (a) is even reached —
`VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR`.

## 6. NET FOR STANDING LAW 0

Live 143. Closable now: 3 backlog rows (§3), plus 2 already-`done` rows that were
still being counted as work (§2). **143 → 140** once Decide closes §3; the
apparent "12-14 rows of backlog that may not exist" is measured at **3**.
