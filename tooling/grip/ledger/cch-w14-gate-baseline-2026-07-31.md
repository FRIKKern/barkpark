# cch-w14 — console gate baseline on origin/main bytes (2026-07-31)

origin/main = `885ace84aba8fde9fb42d0aba557827d2e18aa49`.

## THE RECIPE TRAP (read this before quoting any number)

The wave's MUST-RUN recipe archives **only** `cloud/priv/static`. That scope
manufactures **false reds** in two gates that read repo paths outside it:

- `__app.test.mjs` → 2/754 fail, exit 1 (ENOENT `internal/taskboard/testdata/…`,
  `internal/pdrender/testdata/…`)
- `seal-predicate.test.mjs` → 21/49 fail, exit 1 (clause (b) reads
  `.github/workflows/` + `.github/required-checks.json`; absent ⇒ b=FAIL)

Both are archive artifacts. **Baseline from a full-tree worktree at origin/main**,
or, if you must archive, include the two testdata trees AND `.github/`.

## THE BASELINE (full worktree at 885ace84a, quiet host)

| gate | exit | result | wall |
|---|---|---|---|
| `node --check cloud/priv/static/app.js` | 0 | — | 45ms |
| `node --test cloud/priv/static/__app.test.mjs` | 0 | 754 tests / 754 pass / 0 fail | 497ms |
| `node cloud/priv/static/__css_check.mjs` | 0 | 867 classes, 93 tokens, 576 contrast pairs, 87 allowlisted, 1 demoted (R3), **0 errors** | 866ms |
| `node cloud/priv/static/__preview__/cssom-parity.mjs` | 0 | authored heads **1243** (baseline 1243), MISSES 0, **PARITY PASS** | 2047ms |
| `node cloud/priv/static/__preview__/smoke.mjs` | 0 | all **99** scenarios rendered | 280ms |
| `node --test cloud/priv/static/__preview__/seal-predicate.test.mjs` | 0 | 49 tests / 49 pass / 0 fail | 13171ms |
| `__preview__/overflow-guard.mjs` (`OVERFLOW_GUARD_PORT=…`) | 0 | 5 legs, **OVERFLOW GUARD PASS** | 8256ms |

`overflow-guard` legs: GR108 (0/44 overflowing, 721–1440) · GR109 · GR115 ·
W12 (10 phone widths × 2 themes) · W13 (**106/108** clean, the 2 marked `~` are
`#fleet@769`'s 21px `.fleet-row` residual, explicitly **NOT claimed**).

Registered `section.view` on origin/main `index.html`: **13**.

## RERUN

```sh
W=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark worktree add --detach "$W" origin/main
cd "$W"
node --check cloud/priv/static/app.js; echo "check=$?"
node --test cloud/priv/static/__app.test.mjs           | grep -E '^# (tests|pass|fail)'
node cloud/priv/static/__css_check.mjs                 | tail -1
node cloud/priv/static/__preview__/cssom-parity.mjs    | grep -E 'authored rule heads|MISSES|PARITY'
node cloud/priv/static/__preview__/smoke.mjs           | tail -1
node --test cloud/priv/static/__preview__/seal-predicate.test.mjs | grep -E '^# (tests|pass|fail)'
(cd cloud/priv/static/__preview__ && OVERFLOW_GUARD_PORT=4243 node overflow-guard.mjs | tail -1)
```

## GATING TRUTH (L1 — live API, not the committed file)

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.checks'
# [{"app_id":15368,"context":"Elixir gate"},{"app_id":15368,"context":"PR references an active task"}]
```

`enforce_admins=true`. `.github/required-checks.json` on origin/main *commits*
`Console gate` + `Cloud gate` — they are **NOT in the live PUT**, i.e. advisory.
`grep -rn overflow-guard .github/` → **exit 1**: nothing runs overflow-guard.

## COLLISION FENCE

Open PRs touching `app.css` / `app.js` / `index.html` / `cssom-heads` /
`overflow-guard` / `scenarios.mjs` / `required-checks.json`: **#6028 only**
(`app.js`, `__app.test.mjs`).

- #6028 head `360b67590` has **no parent** (orphan cloud-agent commit) ⇒
  `git merge-base` exits 1, PR is `CONFLICTING`.
- It touches **no** `index.html` and adds **no** `section class="view"`
  (`gh pr diff 6028 | grep '^\+.*section class="view"'` → exit 1). The sweep's
  screen axis is safe.
- All 17 classes its diff emits already have rules in origin/main `app.css`.
  Decisive: origin/main tree + #6028's `app.js` ⇒ `__css_check` **exit 0,
  0 errors** (861 classes — the 867→861 delta is the PR's stale base, not the PR).

Dirty `cloud/priv/static` worktrees: `wf_7ad88081-265-23` (scenarios/smoke),
`wf_8a3a8cbb-52d-21` (shoot.sh), `wf_fe674ef4-19d-15` (whole tree deleted) —
all abandoned 12–16 days (Jul 15/19), **not** live concurrent work.

`bp-cloud-console-instruments-charter.md` is **absent** from origin/main
(`git cat-file -e` exit **128**); `bp-cloud-console-hardening-charter.md` exit 0.
