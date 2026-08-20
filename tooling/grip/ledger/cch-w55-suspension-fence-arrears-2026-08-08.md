# cch wave 55 — the suspension/billing fence ledger arrears, re-derivation recipes

Verifier `v8-ledger-truth-and-arrears`, 2026-08-08T13:2xZ. `origin/main` = `4b0a8a5d3d72848373d18c3aeb19efb913356351`.
Nothing here was written to the ledger — this is the arrears Decide inherits.

## The census (re-derive; never quote)

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections; \
d=json.load(sys.stdin); p=[c for c in d['children'] if not str(c['doc_id']).startswith('drafts.')]; \
k=collections.Counter(c['lifecycle_status'] for c in p); \
print('children',len(d['children']),'published',len(p),dict(k),'live',k['open']+k['considering']+k['in_progress'])"
```

`children 745 published 725 {'done': 317, 'considering': 1, 'open': 360, 'cancelled': 45, 'in_progress': 2} live 363`

w54-s7's receipt closed at **live 360**; three rows were filed since. `cch-w54-s7` criterion 8
("live at or below 340") is **arithmetically unreachable** and stays an honest MISS —
`cch-bl-live-count-criteria-must-be-deltas-not-absolute-floors` (open, 0/1) already owns the shape fix.

## The one-short scan (finds the arrears; do not close on it blind)

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[c for c in d['children'] if not str(c['doc_id']).startswith('drafts.') and c['lifecycle_status'] in ('open','in_progress')]
for c in rows:
    p=c.get('criteria_progress') or {}
    if p.get('total',0)>0 and p['met']>=p['total']-1: print(c['doc_id'], c['lifecycle_status'], p)"
```

17 hits. Three are never-claimed 0/1 stubs and must be excluded on `claim.epoch != null`
(w54-s7's receipt names this trap; the claim lives at `.doc.claim`, **not** `.claim`).

## The eight closable rows

| row | state | met/total | carrier PR | merge sha | claim |
|---|---|---|---|---|---|
| `cch-w54-s2-suspension-closes-the-three-mint-and-reveal-paths` | in_progress | 8/9 | #10848 | `4a26d181b` | **LIVE** — worker `epic-builder-a-suspended-instance-stops-minting-studi`, epoch 5, no `expired_at` |
| `cch-w54-s6-decommission-sweeps-dns-by-value-not-by-name` | in_progress | 8/9 | #10851 | `981ee6f51` | **LIVE** — worker `epic-builder-decommission-sweeps-dns-by-value-not-by-`, epoch 5, no `expired_at` |
| `cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows` | open | 8/10 | #10852 | `9b8e75f55` | LAPSED 13:07:01Z, prev `epic-builder-the-ledger-arrears-pays-twenty-five-merg`, epoch 6 |
| `cch-w54-s8-the-guard-suite-refuses-an-absent-object-database` | open | 7/8 | #10853 | `5d07f73e8` | LAPSED 12:58:03Z, prev `epic-builder-the-guard-suite-refuses-an-absent-object`, epoch 7 |
| `cch-w53-s4-sign-out-everywhere-ends-the-live-stream` | open | 10/11 | #10849 | `a23b5bc03` | LAPSED 13:03:01Z, prev `epic-builder-sign-out-everywhere-ends-the-live-stream`, epoch 5 |
| `cch-w53-s6-oauth-exchange-stops-skipping-two-factor` | open | 10/11 | #10850 | `d08f1cc8f` | LAPSED 13:00:02Z, prev `epic-builder-oauth-exchange-stops-skipping-two-factor`, epoch 7 |
| `cch-w49-bl-required-checks-drift-calls-its-own-job-blocking` | open | **2/2** | #10728 | `7907b78e9` | LAPSED 10:34:00Z, prev `epic-builder-the-guard-suite-stops-exiting-green-afte`, epoch 3 |
| `cch-w51-bl-two-factor-and-identity-changes-leave-no-audit-trail` | open | **4/4** | #10727 | `8af8c2adf` | LAPSED 10:58:01Z, prev `wave-53-reviewer`, epoch 4 |

The last two have **no unmet criterion at all** — they are pure bookkeeping debt.

Every merge sha above is an ancestor of `origin/main`, and every carrier PR HEAD carries all four
required contexts green (read on the HEAD, never the merge commit):

```sh
for h in 325a0d789 247abffb2 23614d5cc 64ed912a6 6e82406ca 05bfc62d8 017170cd0 7802bb2d5; do echo "== $h"; \
gh api "repos/:owner/:repo/commits/$h/check-runs" --paginate \
  --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|[.name,.conclusion]|@tsv' | sort -u; done
```

## The close recipe (D-recipe from `cch-w47-bl-four-merged-round-1-rows-all-need-a-re-claim-not-just-one`)

A lapsed claim reads `claim.worker = null` with `claim.previous_worker` preserved. **Closing on the
printed worker/epoch fails the CAS silently.** Re-claim on `previous_worker`, READ THE NEW EPOCH BACK,
then close — **adjacent calls**, because leases lapse on a ~15-minute timer.

**Re-claiming WIPES `claim.now`.** All eight notes are captured verbatim in the verifier's report and
must land in the close reason. The two live-claim rows (`w54-s2`, `w54-s6`) close directly on epoch 5
with their own worker; on 409 they have lapsed and fall back to the re-claim recipe.

## The blocked row

`cch-w54-s1-the-stop-nothing-performs-and-the-lifecycle-state-register` — open, 11/12, PR **#10847
OPEN / MERGEABLE / BLOCKED**. Claim LAPSED 13:07:01Z, prev
`epic-builder-the-console-stops-painting-a-stop-nothin`, epoch 6.

Exactly one required context is red — `Cloud gate`, failing solely because
`Cloud control-plane (compile + format) (27.0, 1.18.1)` exits 1 on `mix format --check-formatted`
naming **one file**, `cloud/test/barkpark_cloud/lifecycle_state_manifest_test.exs`, in two
pure-whitespace hunks. `mix compile --warnings-as-errors` **passed** in the same job.

```sh
gh api "repos/:owner/:repo/commits/3fc1b9befbac11ad2bc89b7f712bd33b188b4d9b/check-runs" --paginate \
  --jq '.check_runs[]|select(.conclusion=="failure")|[.name,.id]|@tsv'
gh api repos/:owner/:repo/actions/jobs/93103798132/logs | sed -n '/not formatted/,/exit code/p'
```

`cch-w54-s5` (0/10) is a hard AFTER-GATE on this merge, so the format-and-push is the wave's
highest-leverage act.

## Two slug resolutions no surveyor could surface

- `cch-w53-s4` → **`cch-w53-s4-sign-out-everywhere-ends-the-live-stream`**. PR #10849's title says
  "live SSE stream"; the slug says "live-stream". Slug-shaped search misses it.
- `cch-w54-s7` → **`cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows`**.

## Charter bookkeeping, re-derived

```sh
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE "^\| D[0-9]+ " | grep -oE "[0-9]+" | sort -n | tail -1
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -cE "^\| D[0-9]+ \|"
```

Ceiling **D617**, **578** rows (not 579), **zero** duplicate D-numbers on main. PR **#10766 is still
OPEN** and titled "D617-D628" — the D617 collision is real but has not landed yet.
