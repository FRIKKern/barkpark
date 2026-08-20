# cch-w35 — the merge half has no proving gate (re-derivation recipes)

Verifier lane `merge-half-gate`, wave 35, measured against `origin/main` `c73bbc07c` on 2026-08-06.
Every row is a command, not a claim. Run them from the barkpark repo root unless noted.

## 0. A clean origin/main tree to measure in

The primary checkout is BEHIND origin/main on `scripts/required-checks-verify.sh`
(`git diff --stat origin/main -- scripts/required-checks-verify.sh` → `20 insertions, 189 deletions`),
so the local file is a different guard. Measure in an extracted tree:

```
rm -rf /tmp/mainfull && mkdir -p /tmp/mainfull && git archive origin/main | tar -x -C /tmp/mainfull
cd /tmp/mainfull && git init -q && git add -A     # §13 of required-checks.test.sh needs a git index
```

Without `git init && git add -A`, `required-checks.test.sh --hermetic` reports
`110 passed, 1 failed` with two `fatal: not a git repository` lines — a HARNESS artifact,
predicted verbatim by required-checks-drift.yml's own checkout comment. With the index: `111 passed, 0 failed`.

## 1. The merge-half diff shape dispatches FALSE on all four required contexts

```
printf 'scripts/required-checks-verify.sh\n.github/workflows/bp-graph-drift.yml\n' > /tmp/mh
cd /tmp/mainfull
echo "CLOUD:$(bash scripts/cloud-path-escape-check.sh --match cloud </tmp/mh)" \
     "CONSOLE:$(bash scripts/console-path-escape-check.sh --match console </tmp/mh)" \
     "COMPILE:$(bash scripts/elixir-path-escape-check.sh --match compile </tmp/mh)" \
     "TEST:$(bash scripts/elixir-path-escape-check.sh --match test </tmp/mh)"
```

→ `CLOUD:false CONSOLE:false COMPILE:false TEST:false`. Same answer for a scripts-only diff
(`printf 'scripts/required-checks-verify.sh\n'`).

## 2. …and the UNFILTERED path-escape ratchets cannot red on it either

They run on every PR (`Cloud gate` / `Console gate` / `Elixir gate` each `needs:` their
`path-escape` job, which has no `if:` and no dispatcher dependency), but their input is the
whole tree's `cloud/lib + cloud/test` / `cloud/priv/static` / `api/lib + api/test` reads —
which the merge-half diff cannot change.

```
cd /tmp/mainfull
printf '\n# merge-half slice touch\n' >> scripts/required-checks-verify.sh
printf '\n# merge-half slice touch\n' >> .github/workflows/bp-graph-drift.yml
for s in cloud console elixir; do bash scripts/$s-path-escape-check.sh >/dev/null 2>&1; echo "$s=$?"; done
```

→ `cloud=0 console=0 elixir=0`. Four required contexts render GREEN having executed zero lines
of the diff.

## 3. origin/main's verify selftest is 18 probes, not 16

```
cd /tmp/mainfull && bash scripts/required-checks-verify.sh --selftest 2>&1 | tail -4
```

→ `ok 18/18 …` / `SELFTEST OK`. The local dirty checkout says `16/16` — it predates the
advisory-prose clause (probes 17 and 18). `required-checks-drift.yml`'s header still says
"72 assertions" and verify's "16 mutation clauses"; the real numbers are 111 and 18.

## 4. Remedy (a) — adding the merge-half scripts to CLOUD_PATHS — is mechanically viable and dishonest

```
cd /tmp/mainfull
perl -0pi -e "s{scripts/cloud-path-escape-check.test.sh'}{scripts/cloud-path-escape-check.test.sh\nscripts/required-checks-verify.sh\nscripts/required-checks.test.sh'}" scripts/cloud-path-escape-check.sh
bash scripts/cloud-path-escape-check.sh; echo rc=$?
bash scripts/cloud-path-escape-check.sh --match cloud </tmp/mh
bash scripts/cloud-path-escape-check.sh --selftest 2>&1 | tail -2
```

→ ratchet `rc=0`, dispatch `true`, harness `124 passed, 0 failed`. It works — and it buys a
green `Cloud gate` by running the cloud Elixir compile+test suite, which executes no line of the
shell guard. Wave 35's own thesis, one layer up.

## 5. Remedy (b) — register `Required-check spec gate` — its documented blocker is DEAD

`.github/required-checks.json` holds it out under `S7 EXCLUDED BY DECISION`, grounded solely in
open PR #8222 ("Re-evaluate once #8222 lands or is rebased").

```
gh pr view 8222 --json number,state,mergeable   # → {"state":"CLOSED","mergeable":"CONFLICTING"}
```

Deadlock sweep over the live open set:

```
gh pr list --state open --limit 30 --json number,headRefOid --jq '.[]|[.number,.headRefOid]|@tsv' \
| while IFS=$'\t' read -r n h; do
    echo "PR#$n $(gh api "repos/:owner/:repo/commits/$h/check-runs?per_page=100" \
      --jq '[.check_runs[]|select(.name=="Required-check spec gate")|.conclusion]|join(",")')"
  done
```

→ 9 of 12 open PRs render it `success`; #6086, #6057 and #2907 render it ABSENT and would
deadlock until pushed. The job is workflow-level path-UNFILTERED (`on: pull_request:` with no
`paths:`), unmatrixed, single stable name, and green on main and on the last three merged heads.

## 6. The live repo-protection-claim census (what a new clause must red on)

```
cd /tmp/mainfull && grep -rn "no branch protection" \
  --include="*.yml" --include="*.sh" --include="*.md" --include="*.js" --include="*.ex" .
```

Live, un-retracted, in gate surfaces:
- `.github/workflows/bp-graph-drift.yml:15`
- `scripts/check-bp-graph-drift.sh:27`   ← NOT named in the wave direction

Live, un-retracted, in charter prose (all currently blanket-exempt under §13's precedent):
`bp-cloud-console-hardening-charter.md:1412,4282`, `bp-chat-tui-charter.md:386`,
`bp-connectors-charter.md:541,801,1243`, `bp-cloud-gui-remake-charter.md:1294`,
`bp-studio-space-priority-charter.md:1405`, `bp-pd-everything-editable-charter.md:83`,
`bp-truth-grip-charter.md:134`, `bp-search-template-charter.md:103`

Correct retraction, must stay green: `docs/ops/merge-gates.md:239`.
Untracked ledger files carrying the string: 3 (`grep -rln "no branch protection" tooling/grip/ledger | wc -l`).

## 7. Where the clause can live and still be hermetic

`advisory_prose_check` runs only in verify's full and `--ci` modes, both of which call
`live_protection` / `deadlock_check` — GitHub API. Its real-tree scan therefore lives in the
ADVISORY (credentialed) drift job. The hermetic, real-tree, mutation-canaried precedent is
`§13 prose_admin_hits()` in `scripts/required-checks.test.sh:1101-1130`: `git ls-files -- '*.md'`,
exemptions for `tooling/grip/ledger/` and `.claude/workflows/*charter.md`, ONE scan driven twice.
That function runs inside `Required-check spec gate`. Its `*.md`-only scope is why it would miss
both live gate-surface offenders in §6.

## 8. Fence

`scripts/required-checks-{generate,apply,floor,verify}.sh`, `scripts/required-checks.test.sh`,
`scripts/{cloud,console}-path-escape-check.sh`, `.github/required-checks.json` and
`.github/workflows/required-checks-drift.yml` are IN FENCE by the Wave-11 dispensation
(`git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '234,243p'`).
`.github/workflows/bp-graph-drift.yml` AND `scripts/check-bp-graph-drift.sh` are NOT.
