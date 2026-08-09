# Re-derivation recipes — refusal status + copy ruling (cch wave 62, verifier)

All commands read `origin/main` (fetched), not the working checkout.

## Charter authority

```sh
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -nE '\| D(691|714|715|716|722|732|734) \|' | cut -c1-1200
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '1070p' | fold -w 200   # D734 in full
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -niE 'BoxRelay|box_relay|teardown|Sites.Deploy|rollback_failed'   # → NO status ruling for the site-write seam
```

## Status: the two instance triggers already emit 409

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'identity_refused'          # 3411/3412 and 3582/3583
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '4111,4117p'                    # the defp relay_admin_post/3 fence
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '4139,4165p'                    # relay_admin/4 @spec — NO :identity_refused
```

## Status: the site-write seam

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1655,1690p;1720,1765p'     # unreachable/2 catch-all + {:error,502,...}
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7255,7290p'                   # flat error:"rollback_failed" + detail, NO code
git grep -n 'Deploy.rollback\|Deploy.teardown' origin/main -- cloud                                 # 2 prod call sites: router.ex:7009, :7258
```

## Console behaviour (pure functions, vm sandbox mirroring `__app.test.mjs`)

```sh
git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
# then evaluate /tmp/app_main.js in a vm context exposing __bpTestHook (copy the
# sandbox literal from cloud/priv/static/__app.test.mjs lines 26-76) and call:
#   rollbackRefusalTerminal("identity_refused")  -> false
#   rollbackConflictCopy("identity_refused", {}) -> {"Couldn't start the rollback","Please try again in a moment."}
#   siteRollbackFailure(502, {error:"rollback_failed", detail:"…unreachable…"})
#                                                -> {"A deploy is already running", …}
#   friendly({error:{code:"suspended"}})          -> THROWS TypeError: key.replace is not a function
#   friendly({error:"suspended"})                 -> ERRORS.suspended verbatim
```

## Shipped copy to echo (never mint a fifth phrasing — charter D734)

```sh
git show origin/main:cloud/priv/static/app.js | sed -n '19005,19025p'   # usageUnavailableText
git show origin/main:cloud/priv/static/app.js | sed -n '179,210p'       # ERRORS: not_live / no_admin_token / instance_unreachable / suspended
git show origin/main:cloud/priv/static/app.js | sed -n '8385,8417p'     # rollbackConflictCopy arms
git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | sed -n '93p'   # the nine whitelisted reasons
```

## The reader gap

```sh
git grep -rn 'update_unavailable_reason' origin/main -- cloud/lib/barkpark_cloud/web/router.ex   # → no hits: barkpark_json/4 never emits it
git show origin/main:cloud/priv/static/app.js | grep -c 'update_unavailable_reason'               # → 0
```
