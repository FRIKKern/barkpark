# Re-derivation recipe — team-scoped deployment reachability (deploy-reliability wave 9, v8)

Taken 2026-08-07 ~03:00–03:10Z. origin/main at `95642c550`. The primary checkout was 528
commits BEHIND origin/main, so every Elixir run below is in a DETACHED worktree cut from
origin/main — running the same test in the primary checkout FAILS on a stale
`deployments_active_site_env_index` (charter D10 re-key, migration
`20260805190000_rekey_active_deployment_index_on_environment.exs`), which is staleness,
not a regression.

## 0. Build the origin/main worktree (once)

    git worktree add --detach /tmp/wt-main origin/main
    cp -R /Volumes/SATECHI/github/barkpark/cloud/deps /tmp/wt-main/cloud/deps
    cd /tmp/wt-main/cloud && CC=clang MIX_ENV=test mix compile

## 1. The existing suite is green at origin/main

    cd /tmp/wt-main/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/web/router_sites_test.exs
    # => 95 tests, 0 failures

Note: every deployments test there logs in an `owner`, never a plain `member`.

## 2. Authority axis — a PLAIN MEMBER with a SESSION token gets 200

`with_team_site(conn, fun)` defaults to `:session` (router.ex:10941) and performs NO role
check — only `current_team` presence. Proof (scratch test, not committed):

    # test file: scratchpad/member_reach_test.exs — member added with Accounts.add_member(team, user, "member")
    cd /tmp/wt-main/cloud && CC=clang MIX_ENV=test mix test /path/to/member_reach_test.exs
    # MEMBER+SESSION status=200 body={"deployments":[{...}]}
    # OWNER+PAT list status=401 body={"error":"unauthorized"}
    # OWNER+PAT singular status=200

## 3. Token axis — `bp login` stores a SESSION token, so the CLI clears the session-only gate

- session plaintext = bare `generate_token()` (accounts.ex:595); PAT plaintext =
  `"bpc_pat_" <> generate_token()` (accounts.ex:881).
- `~/.config/barkpark/config.json` `.cloud_token` is 43 chars with NO `bpc_pat_` prefix.
- `internal/cli/login_device.go:175` — `cfg.CloudToken = res.Login.Token`, the device
  SESSION.

Live, from the real owner's installed binary:

    bp sites deployments search -o table | head -12     # => 200, real rows
    bp cloud deployments                                # => unknown cloud command "deployments"

## 4. The reachable surface is CAUSELESS

Server (same session token, direct HTTP):

    python3 - <<'EOF'
    import json,urllib.request
    cfg=json.load(open('/Users/pelle/.config/barkpark/config.json'))
    url=cfg['cloud_url']+'/v1/sites/7c2025a5-4181-46df-8b00-6151fe3da9d4/deployments?limit=5'
    r=urllib.request.urlopen(urllib.request.Request(url,headers={'Authorization':'Bearer '+cfg['cloud_token']}))
    d=json.load(r); print(sorted(d['deployments'][0].keys())); print(d['next_cursor'])
    EOF

ships 25 keys including `failure_class` (`BOX_AT_CAPACITY_DEFERRED`), `failure_reason_raw`,
`content_rev`, `trigger`, `stage`, plus `next_cursor`.

The client drops all of it: `internal/cloudclient/client.go:1080-1092` — `Deployment` has
11 fields, no `FailureClass`; `ListDeployments` (:1196) sends no `limit`/`before`;
`deploymentRow` / `renderDeploymentsTable` (`internal/cli/sites_cmd.go`) print
STATUS · IMAGE_TAG · GIT_REF · STARTED — and on guerrilla image_tag and git_ref are `—`
on every row.

## 5. The rate an owner could already compute (site `search`, 100 newest rows, 00:21:38Z→02:57:30Z)

    bp sites deployments search -o json | python3 -c "import json,sys,collections; d=json.load(sys.stdin)['deployments']; print(len(d), dict(collections.Counter(x['status'] for x in d)))"
    # 100 {'live': 20, 'deferred': 77, 'failed': 3}

3 failed / 23 terminal = 13.0%; 77/100 rows absorbed by the build cap. Every one of the 77
carries `box_at_capacity` in `failure_reason` — and none of that reaches the table.
