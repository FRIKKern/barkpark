# cch w69 — cli-receipt-on-main: re-derivation recipes

Verifier lane `cli-receipt-on-main`. Every fact below is re-derivable by the command
under it. All runs were made against a **clean extraction of `origin/main`**, not the
shared checkout — the shared checkout was 1 commit BEHIND `origin/main` at verify time
(local HEAD `a653550420`, origin/main `05a98dd2ca`) and therefore did NOT contain
#11711's Go bytes.

## 0. Build a trustworthy origin/main tree (do this FIRST)

    D=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C $D; cd $D

Do NOT `go build` in the primary checkout to judge main: it is a shared tree that
other sessions mutate, and it can be behind.

## 1. `cc` shadows the C compiler — the Go gate fails for a fake reason

    cd $D && go build ./...        # => "# runtime/cgo / error: unknown option '-E'"
    cd $D && CC=/usr/bin/clang go build ./...   # => clean, rc 0

`cc` on this host is the Claude wrapper. Any Go-gate red must be re-run with
`CC=/usr/bin/clang` before it is reported.

## 2. Post-#11711 main is green on the CLI surface

    cd $D && export CC=/usr/bin/clang
    go build ./...                 ; echo "BUILD_RC=$?"   # BUILD_RC=0
    go vet ./internal/cli/...      ; echo "VET_RC=$?"     # VET_RC=0
    go test ./internal/cli/... ./internal/cloudclient/...  # all ok, rc 0

## 3. #11711 is on main; #11706 is main's HEAD

    git log origin/main -1 --oneline -- internal/cloudclient/client.go
    # 840effe8ac fix(cli): decode a control-plane refusal's reason/required/scope/details (supersedes #10086) (#11711)
    git log origin/main -1 --oneline
    # 05a98dd2ca test(cloud): the delete route's untested arms get tests that can lose ... (#11706)

Both sequencing-law prerequisites are MERGED. Nothing in this lane is round-2-gated.

## 4. Delete + rollback both funnel through cloudError → *CloudRefusal

    grep -n 'cloudError(status, raw)' $D/internal/cloudclient/client.go   # 2620 (rollback), 2638 (delete)
    grep -n 'func cloudError' $D/internal/cloudclient/client.go           # 366
    grep -n 'type CloudRefusal struct' -A 10 $D/internal/cloudclient/client.go

Wire shapes both sides emit `{ok:false, error:<code>, detail:<sentence>}`:

    grep -n 'error: code, detail: detail' $D/cloud/lib/barkpark_cloud/web/router.ex  # 7385 (site rollback), 7122 (site delete); 3038 is an unrelated 422 minter

So `CloudRefusal.Code` AND `.Detail` are both populated on the refusal paths.

## 5. The precedent to clone is on a DIFFERENT error type

    grep -n 'rollbackFail\|rollbackExit\|rollbackErrLabel' $D/internal/cli/cloud_rollback_cmd.go
    grep -n 'type RollbackError struct' $D/internal/cloudclient/client.go   # 3271

`cloud_rollback_cmd.go` is the INSTANCE rollback (`Client.Rollback`, client.go:3290),
which mints `*RollbackError` via its own `decodeRollbackError`. The SITE paths mint
`*CloudRefusal`. Cloning the idiom means `errors.As(err, &*CloudRefusal)`, not a new
`SiteDeleteError` — D837's "four files" pricing predates #11711 and is now stale.

## 6. Today's actual CLI behaviour on a typed site refusal

    grep -n 'cloudFail(out, "delete site"\|cloudFail(out, "roll site back"' $D/internal/cli/cloud_site_cmd.go  # 1246, 1144
    grep -n 'func cloudFail' -A 8 $D/internal/cli/cloud12_cmd.go   # cloud12_cmd.go:103

`cloudFail` branches only on the substring `unauthorized`; every other refusal is
`useError(out, "failed", ..., exitGeneric)`. A 409 `identity_refused` therefore exits
**1**, labelled `failed`, not `exitConflict` (6). No test pins the current strings:

    grep -rn 'delete site:\|roll site back' $D/internal/cli/*_test.go    # ZERO hits

## 7. identity_refused DOES reach DELETE /v1/sites/:id

    grep -n 'identity_refused' $D/cloud/lib/barkpark_cloud/sites/deploy.ex     # 1831-1832 in teardown/2
    sed -n '7073,7132p' $D/cloud/lib/barkpark_cloud/web/router.ex              # the 4-tuple relay arm
    sed -n '2417,2437p' $D/cloud/test/barkpark_cloud/web/router_sites_test.exs # the route-level test

Chain: `BoxRelay.teardown` pre-wire refusal (box_relay.ex:86-88, keyed on
`update_unavailable_reason == "identity_refused"`) → `Deploy.teardown/2` returns
`{:error, 409, teardown_unreachable(bp, :identity_refused), "identity_refused"}` →
the route's `{:error, status, detail, code}` arm emits it. Route-level test asserts
status 409, `error == "identity_refused"`, `detail =~ "the instance rejected our
access credential"`, and zero box calls.
