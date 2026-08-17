# cch-w71 — re-derivation recipes for the three close-by-measurement rows

Verifier: close-by-measurement-pack. All bytes read from `origin/main` (L2). No mutations, no commits.

## Row 1 — teardown-422 (cch-w67-bl-every-teardown-422-...)

Settled by **#11786 = 9a24537df5** (NOT #11846; the row's recorded PR 11542 does not exist).

```
git log origin/main --oneline --grep 11786
# 9a24537df5 fix(sites): a failed teardown speaks teardown — mode-aware teardown_outcome, exit_label(-1) byte-frozen (D849) (#11786)
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '1597,1611p;1735,1745p'
```

`teardown_outcome/1` maps TORN_DOWN→{0,nil}, TEARDOWN_FAILED→{25,...}, (lock_held)→{23,...}, else→{-1,...}.
`teardown_exit_label/1` arms: 23 (deploy running, try again), 25 (teardown failed), -1 (died abnormally), -2 (deadline force-close), fallthrough `teardown failed (exit #{code})`. Teardown speaks teardown, not delete.

## Row 2 — w39 token-mint-403 (fixed since cch-w37-s2; verbatim role sentence)

Console `friendly({error:"forbidden",required:"admin",scope:"team"})` renders VERBATIM:

    You need the admin role on this team — an admin on this team can grant it.

(= `FORBIDDEN_ROLE_COPY.admin`, app.js:259, reached via `forbiddenEvidenceCopy` → `friendly`.)

```
git show origin/main:cloud/priv/static/app.js > /tmp/app39.js
# probe: concat ERRORS={} + FORBIDDEN_ROLE_COPY (258-262) + FORBIDDEN_REASON_COPY (290-298)
#        + forbiddenEvidenceCopy (315-325) + friendly (346-424), then:
# console.log(friendly({error:"forbidden",required:"admin",scope:"team"}))
node probe39.js  # → the sentence above
```

CLI-twin finding (REFINES the surveyor's "no CLI twin"): POST /v1/tokens IS consumed by two internal paths —
`internal/bootstrap/bootstrap.go:379` (read-token mint) and `internal/cli/vercel_cmd.go:553` (vercel deploy mint) —
but NEITHER renders the forbidden required/scope role grammar: bootstrap dumps `status %d: %s` raw snippet,
vercel uses `classifyError(...).errorMessage()`. So no CLI path relays this console sentence; both mint paths are
admin-gated (caller already holds admin, so a 403 is off-path). "No CLI twin RENDERS it" holds; "no consumer" is false.

```
grep -rn '/v1/tokens' internal/ | grep -v _test
git show origin/main:internal/bootstrap/bootstrap.go | sed -n '383,386p'
git show origin/main:internal/cli/vercel_cmd.go | sed -n '557,561p'
```

## Row 3 — delete-receipt (cch-w67-bl-the-cli-site-delete-receipt-flattens-every-typed-refusal; owed since D860e, satisfied by #11784)

```
git show origin/main:internal/cli/cloud_site_cmd.go | sed -n '1240,1250p'
# res, derr := cfg.CloudClient().DeleteSpawnSite(cloudCtx(), id)
# if derr != nil {
#     return siteRefusalFail(out, siteRefusedDelete, ref, derr)   # :1247
# }
```

Delete routes its refusal through `siteRefusalFail(out, siteRefusedDelete, ...)` — the #11784 family grammar
(no_team override, 404→4, 409→6, 401/403→3, 5xx→8, every 422→1), not a flat receipt.
