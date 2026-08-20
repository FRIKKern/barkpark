# Re-derivation recipe — cch-w42 cross-tab team-pin race

Baseline: `origin/main` @ `a476352a4f794e22437be9826b418ffe28d182d9`.
The local checkout (`a31faa52d`) is BEHIND main — its `cloud/priv/static/app.js`
is 18,689 lines vs main's 21,157 and is dirty. Every command below reads
`git show origin/main:` deliberately; do not substitute the worktree file.

## 1. The two facts that make the race

```sh
git show origin/main:cloud/priv/static/app.js | grep -n 'bp\.active-team'
# 116:    var teamPin = localStorage.getItem("bp.active-team");   <- inside api()
# 5269:        localStorage.setItem("bp.active-team", id);          <- switcher, then reload()
git show origin/main:cloud/priv/static/app.js | grep -c 'addEventListener("storage'
# 0   -> no cross-tab invalidation exists
git show origin/main:cloud/priv/static/app.js | grep -n 'loadMe()'
# 8171 / 12772 / 19125 only -> /v1/me is read once per page life
```

## 2. Drive the race on main's bytes (node, no browser)

```sh
D=$(mktemp -d)
git show origin/main:cloud/priv/static/app.js > "$D/main-app.js"
cp <this repo>/tooling/grip/ledger/cch-w42-pinrace.driver.mjs "$D/pinrace.mjs"   # see §4
node "$D/pinrace.mjs"
```

Expected decisive lines:

```
STEP1 loadMe request headers: {... "x-barkpark-team":"team-XXXX-1111"}
STEP2 header-scoped POST /v1/instances -> x-barkpark-team: team-YYYY-2222
STEP3 check(a) team_authority.team_id === meCache.team.id  -> true (cannot lose)
STEP3 check(b) team_authority.team_id === localStorage pin -> false (loses here)
STEP4 path-scoped GET path team: team-XXXX-1111 | header sent: team-YYYY-2222
```

## 3. Why check (a) is a tautology (server side)

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1431,1433p;1462,1470p'
# team:  team && %{id: team.id, ...}
# team_authority: team && %{team_id: team.id, ...}
# ONE `team` variable -> the two keys are equal or both nil, on every reachable answer.
```

Gate families (counts on main):

```sh
R=$(mktemp); git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > $R
grep -c 'Auth.require_team_admin(conn' $R          # 17  header-scoped
grep -c 'Auth.require_primary_team_admin(conn' $R  #  7  header-scoped
grep -c 'Auth.require_primary_team_owner(conn' $R  #  3  header-scoped
grep -c 'with_team_role(conn' $R                   #  8  PATH-scoped (header ignored)
grep -c 'current_team' $R                          # 168 header-resolved reads
```

`resolve_team/2` (`cloud/lib/barkpark_cloud/web/auth.ex:121-128`) is the header
reader; `require_team_role/3` (`:364`) never consults it.

## 4. Smoke corpus gap

```sh
git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -c team_authority   # 0
git show origin/main:cloud/priv/static/__preview__/mock.js       | grep -c team_authority   # 0
```

The `me()` fixture (`scenarios.mjs:959`) emits no `team_authority` key at all —
any leg-1 consumer reading it renders its fail-closed arm across all 104
scenarios until the fixture is extended.

The driver source lives in the wave Paper; it is 120 lines of `node:vm` sandbox
with a MUTABLE `localStorage` object and a recording `fetch`, modelled on
`__app.test.mjs`'s existing sandbox, plus `store["bpcloud.session"]` (the key is
`STORE` at `app.js:14`) so `api()` attaches auth and therefore the team pin.
