# v-w49 — prior-art adoption + the deploy fence: re-derivation recipes (2026-08-05)

Every row below is a single command that re-derives the fact from scratch. Run from the repo root.

## 1. The charter's fence, verbatim, from origin/main (never the working copy)

```
git show origin/main:.claude/workflows/bp-pds-charter.md | grep -n 'Fence:'
```
Three hits only. The two that enumerate paths:
- `:6920` (wave 23) — ``Fence: `api/**`, `internal/**`, `deploy/**`, `bin/**`, `scripts/pds-*`, `docs/**`, the `pds-*` namespace. **`cloud/**` and `.github/workflows/**` are OUT**``
- `:11065` (wave 36) — ``Fence: `api/**`, `internal/**`, `deploy/**`, `scripts/pds-*`, `docs/**`, the `pds-*` namespace, plus a one-file dispensation for `.github/workflows/elixir.yml``

Waves 37-48 declare NO `Fence:` line at all. `deploy/**` is IN by both surviving enumerations;
`cloud/**` is OUT by name.

## 2. PDS has already edited `deploy/instance-deploy.sh` — merged precedent

```
git log origin/main --format='%h %ad %s' --date=short -- deploy/instance-deploy.sh deploy/cp-deploy.sh | head -3
git show --stat --format='' c80130fb3
```
`c80130fb3` = PR #6421 = the wave-22 slice `pds-w22-deploy-stamp-and-harness`. Touches
`deploy/instance-deploy.sh` + `deploy/instance-deploy_test.sh` only.

## 3. Neither script is hot — no branch, no PR

```
git fetch origin -q
for b in $(git branch -r --sort=-committerdate | head -40 | tr -d ' '); do git diff --name-only origin/main...$b 2>/dev/null | grep -E 'deploy/(instance-deploy|cp-deploy|site-deploy)' | sed "s|^|$b |"; done
gh pr list --state open --limit 100 --json number,files -q '.[] | .number as $n | (.files//[])[].path | select(startswith("deploy/")) | "\($n) \(.)"'
```
Branch sweep: exactly ONE hit, `origin/loop-epic/a-build-that-cannot-read-its-corpus-reco-4-r` →
`deploy/site-deploy-node.sh` (deploy-reliability wave 1, no PR). Zero hits on instance-deploy.sh or
cp-deploy.sh. Open-PR sweep: EMPTY (non-vacuous — `gh pr list … .files` returns 5-13 files per PR).

## 4. But merging ANY `deploy/**` byte deploys BOTH production hosts

```
sed -n '7,29p;76,86p' .github/workflows/deploy.yml
```
`on.push.paths` includes `deploy/**`; the `changes` job regexes are
`^(cloud|deploy|internal|cmd)/` → `cp=true` and `^(api|internal|deploy|connectors|templates)/`
→ `instance=true`. So a deploy/** merge scps + runs `cp-deploy.sh` on CP **and**
`instance-deploy.sh` on guerrilla. In-fence, but not free.

## 5. Cross-epic prior art on the npm crown

```
bp task get jdf-bl-publish-react-preview2 -o json
bp task get task-2abbac8d7975050c -o json
bp task get jarl-dogfood-publishing-epic -o json
```
jdf row: OPEN, 0/3, unclaimed, parent `jarl-dogfood-publishing-epic` (OPEN, 12 children), GH #8342.
Criterion 3 is MERGE-GATED on a **jarl-website** PR — a repo outside this fence.
`task-2abbac8d7975050c`: OPEN, parent `task-2ac1f95237c4a8e5` (the PDS epic), GH #9612,
`acceptance_criteria` is literally `null`.

## 6. jdf's own description carries a rotted count

```
git ls-tree --name-only origin/main js/.changeset/ | grep -c '\.md$'
for f in $(git ls-tree --name-only origin/main js/.changeset/ | grep '\.md$'); do git show origin/main:$f | grep -q '@barkpark/react' && echo "$f"; done | wc -l
```
343 files incl. README → **342 pending changesets**, of which **59** name `@barkpark/react`.
jdf's description says "8 pending changesets name @barkpark/react".

## 7. The version literals, both sides, four packages

```
for p in core react nextjs codegen create-barkpark-app; do echo "$p main=$(git show origin/main:js/packages/$p/package.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')"; done
for p in @barkpark/core @barkpark/react @barkpark/nextjs create-barkpark-app; do echo "$p $(npm view $p version)"; done
npm view @barkpark/core dist-tags --json
```
main: core preview.3 · react preview.1 · nextjs preview.2 · cba preview.0.
registry: core preview.3 · react preview.1 · nextjs preview.3 · cba preview.1.
core dist-tags: `{"latest":"1.0.0-preview.3","preview":"1.0.0-preview.2"}` — internally inconsistent.

## 8. The size-limit cap was moved BY the PR its criterion gates

```
git show origin/main:js/packages/react/.size-limit.json | grep -n 22
git log origin/main --format='%h %ad %s' --date=short -- js/packages/react/.size-limit.json | head -1
```
Entry 2 reads `"limit": "22.75 KB"`; last toucher is `c3b0421cb` = PR #9601 itself.
`pds-w48-react-reference-error-collapse` criterion 6 demands a pass "against .size-limit.json's
**22.5 KB** gzip cap" — a literal that no longer exists on main.
