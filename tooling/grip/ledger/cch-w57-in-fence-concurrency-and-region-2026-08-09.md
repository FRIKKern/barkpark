# cch wave 57 — in-fence concurrency + app.js REGION fence: re-derivation recipes

Measured 2026-08-09 against `origin/main` @ `0239dd4ee`. Every row re-derives from scratch.

## 1. Every open PR touching the bare fence (`cloud/**`), with its cloud file list

```
gh pr list --state open --limit 80 --json number,title,files,mergeable,headRefName,updatedAt \
  --jq '.[]|select([.files[].path]|any(test("^cloud/")))|{n:.number,t:.title,m:.mergeable,b:.headRefName,u:.updatedAt,f:[.files[].path|select(test("^cloud/"))]}'
```

Eleven PRs. Epic attribution (slice id out of the PR body):

```
for p in 11008 11007 10944 10811 10400 10154 10129 10085 10006 9956 6028; do echo "== $p =="; \
  gh pr view $p --json body --jq '.body' | grep -oE '(cch|dr|gr)-w?[0-9a-z-]*-s[0-9]+[a-z0-9-]*' | sort -u | head -3; done
```

## 2. Which contended file each PR opens

```
gh pr diff <N> | awk '/^\+\+\+ b\//{f=$2} /^@@/{print f, $0}'
```

- `app.js`: 10006 (hunks 921-1332 + the `__bpTestHook` literal), 6028 (4557-5672 + the literal).
- `registry.ex`: 10944 only — hunks `:53` and `:5202-5310` (the `custom_host` region). `delete_barkpark`
  (`:697`) is untouched.
- `billing.ex`, `archive_store.ex`: ZERO open PRs.
- `__preview__/`: 10006 (`mock.js:232`) only.

## 3. Net app.js line shift #10006 would impose

```
gh pr diff 10006 | awk '/^\+\+\+ b\/cloud\/priv\/static\/app.js/{a=1;next} a&&/^diff --git/{a=0} \
  a&&/^\+/&&!/^\+\+\+/{p++} a&&/^-/&&!/^---/{m++} END{print "added="p" removed="m" net="p-m}'
```
`added=147 removed=17 net=130` — of which +126 sit ABOVE line 1500, so every wave-57 app.js anchor
below ~1330 shifts +126 if #10006 lands first.

## 4. Why #10006 cannot merge today

```
gh pr view 10006 --json mergeStateStatus,statusCheckRollup \
  --jq '[.mergeStateStatus, ([.statusCheckRollup[]|select(.conclusion!="SUCCESS" and .conclusion!="SKIPPED")|.name]|join(","))]|@tsv'
```
`BLOCKED` + `Billing tier floor (rendered)`, `Console gate`. `Console gate` is one of the four
REQUIRED contexts (`git show origin/main:.github/required-checks.json | jq -r '.protection.required_status_checks.checks[].context'`).
The root failure is a REFUSAL, not a defect:

```
gh run view <run> --log-failed | grep -i 'refused to measure'
```
→ `The sweep refused to measure (exit 2) — an ENVIRONMENT or COVERAGE fault, not a layout defect.`
Base is 196 commits behind main (`git rev-list --count $(gh pr view 10006 --json baseRefOid --jq .baseRefOid)..origin/main`).

## 5. The REGION fence anchors, and their drift

```
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '208,218p'
git show origin/main:cloud/priv/static/app.js | grep -n 'function api(\|function deployRow\|function deployConsoleHtml'
```
D379 cites s4 `:108-147` (still true — `api()` at 108-146) and s3 `deployConsoleHtml :11637-11661`
(FALSE — it is at `:13118`; `deployRow` at `:13023`; line 11637 today is inside `loadSite`).

Wave-57 target ranges, read on main:
```
git show origin/main:cloud/priv/static/app.js | sed -n '6480,6540p;7405,7510p;14650,14800p'
```
6480-6540 = `overviewDunningBannerHtml` / `suspendedCardBannerHtml`; 7405-7510 =
`confirmDecommission` / `runDecommission` / `retryInstance` / `removeInstance`; 14650-14800 =
`renderBillingCancel` / `openCancelPlanModal` / `billingStatusLabel` / `billingStatusBadge` /
`billingPeriodLine`. None fall in s4, s3, or the drifted s3 anchor.

## 6. The quarantine is CSS-only

```
git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md | sed -n '20,45p' | grep -n 'GR11\|GR25'
```
GR11 freezes `app.css` token blocks / `index.html` / `styleguide.html`; GR25 reads
"forbids EDITING, not CONSUMING … Slices render the existing classes freely; nobody edits the
dep-pill/status-pill CSS rule blocks." Neither reaches `app.js`.

## 7. The fence has no gate

```
ls scripts/ | grep -iE 'region|fence'
```
→ only `pds-crown-fence-arithmetic-2026-07-20.md`, a PDS markdown ledger. Nothing enforces D379.

## 8. The cross-epic reservation is still live

```
bp task get task-54326937e919e2cf -o json | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('doc',d);print(c.get('status'),c.get('claim'))"
bp task get dr-bl-console-failure-class-pill -o json | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('doc',d);print(c.get('status'),c.get('claim'))"
```
Both `published None` — open and unclaimed, both aimed at `deployRow`/`deployConsoleHtml`
(app.js 13000-13200). Wave 57 must not enter that band.
