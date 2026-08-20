# cch-w42 free-band reconfirm — re-derivation recipes (2026-08-07)

Measured against `origin/main` = `a476352a4f794e22437be9826b418ffe28d182d9`.
Every row is a command, not a memory. Re-run before quoting.

## 1. The eight predicate anchors (app.js, 21157 lines on main)

```sh
git fetch origin main -q && git rev-parse origin/main
git show origin/main:cloud/priv/static/app.js | grep -n \
 'function providerCanWrite\|function notifCanManage\|function canMintAnyAbility\|function canManageOnboarding\|function billingCanManage\|function billingIsOwner\|function assignableRoles\|function membersContext'
```

2426 providerCanWrite · 3582 notifCanManage · 4012 canMintAnyAbility ·
6112 canManageOnboarding · 13473 billingCanManage · 13474 billingIsOwner ·
18071 assignableRoles · **18079 membersContext** (18077 is its doc comment).

## 2. The complete console-JS PR roster (four, not seven)

```sh
gh pr list --state open --limit 100 --json number,title,files \
 --jq '.[] | select(.files[]?.path | test("cloud/priv/static/app.js|cloud/priv/static/__app.test.mjs")) | "\(.number) \(.title)"'
```

9955 · 10005 · 10006 · 6028. (10085 = binding census + console-harness.yml;
10086 = internal/cli only; 9956 = auth.ex/router.ex only.)

## 3. Mergeability of every open console PR

```sh
for pr in 9955 10005 10006 10085 10086 9956 6028; do
  git fetch -q origin refs/pull/$pr/head:refs/prs/$pr 2>/dev/null
  printf '%s ' $pr
  git merge-tree --write-tree origin/main refs/prs/$pr >/dev/null 2>&1 && echo CLEAN || echo CONFLICT
done
```

CLEAN: 9955 10005 10006 9956 · CONFLICT: 10085 10086 6028.

## 4. Band occupancy — per-PR hunks translated through each PR's OWN merge-base

```sh
for pr in 9955 10005 10006 6028; do
  mb=$(git merge-base origin/main refs/prs/$pr)
  echo "=== $pr (mb $mb) ==="
  git diff -U0 "$mb" refs/prs/$pr -- cloud/priv/static/app.js | grep '^@@'
  git show "$mb":'cloud/priv/static/app.js' | grep -n 'function providerCanWrite\|function notifCanManage\|function canMintAnyAbility\|function canManageOnboarding\|function billingCanManage\|function billingIsOwner\|function assignableRoles\|function membersContext'
done
```

Never compare a PR hunk number against a main line number — the bases differ
by hundreds of lines (10005's base puts providerCanWrite at 2352, main at 2426).

## 5. Nobody is racing `team_authority`

```sh
git show origin/main:cloud/priv/static/app.js | grep -c team_authority   # 0
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n team_authority
for pr in 9955 10005 10006 6028; do mb=$(git merge-base origin/main refs/prs/$pr)
  printf '%s ' $pr; git diff "$mb" refs/prs/$pr -- cloud/priv/static/app.js | grep -c '^+.*team_authority'; done
```

## 6. The test-file insert window

```sh
git show origin/main:cloud/priv/static/__app.test.mjs | wc -l    # 16033
git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '16012,16018p'
```

10005 appends at EOF of a 15614-line base (`@@ -15614,0 +15635,168 @@`) — a
pure EOF append. Insert at main:16015 (the blank line before the LAST test),
never at EOF.

## 7. The two team_admin? implementations agree extensionally

```sh
git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex | sed -n '44,72p'
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1030,1045p'
git show origin/main:cloud/lib/barkpark_cloud/accounts/team_membership.ex | sed -n '30,46p'
```

`Authz`: `role in ~w(owner admin)`. `Accounts`: `rank(role) >= 2`, ranks
`%{"member"=>1,"admin"=>2,"owner"=>3}`, unknown ⇒ 0, and the changeset
`validate_inclusion`s the column to those three. No reachable value separates
them. A guard asserting divergence cannot lose.

## 8. The local charter is NOT the charter

```sh
git diff --stat origin/main -- .claude/workflows/bp-cloud-console-hardening-charter.md
```

171 lines missing in the worktree copy — D458..D467 absent locally. Read the
charter with `git show origin/main:` or you are reading wave 40's rules.
