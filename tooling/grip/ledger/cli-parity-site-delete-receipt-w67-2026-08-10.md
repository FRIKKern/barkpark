# Re-derivation recipes — wave 67 verifier lane `cli-parity-copy` (2026-08-10)

Every row below is a single literal command. Run from the repo root unless the row
says otherwise. `origin/main` was `f53167087a` when these were taken; the working
checkout was **838 commits behind** it (`git rev-list --count HEAD..origin/main`),
so every source read here is `git show origin/main:` and every Go run is against a
clean archive, never the checkout.

## Clean archive (the substrate every Go proof below ran on)

    mkdir -p /tmp/omain && git archive origin/main | tar -x -C /tmp/omain

## R1 — the receipt was corrected exactly ONCE, not twice

    git log --oneline -S 'is torn down on its box and deregistered' origin/main -- internal/cli/cloud_site_cmd.go
    git log --oneline -S 'the box teardown ran first' origin/main -- internal/cli/cloud_site_cmd.go
    git log --oneline -S 'renderSiteDeleted' origin/main -- internal/cli/cloud_site_cmd.go

The first returns two shas because `-S` counts occurrence-count changes: `095fa7233d`
ADDED the old sentence, `3d84ad07be` REMOVED it. The second and third return only
`3d84ad07be`. Prove the direction of each with:

    git show 095fa7233d -- internal/cli/cloud_site_cmd.go | grep -n 'torn down on its box'
    git show 3d84ad07be -- internal/cli/cloud_site_cmd.go | grep -nE '^[-+].*(torn down on its box|box teardown ran first|site deregistered)'

## R2 — `-o json` flattens every typed refusal code to the literal `"failed"`

Drop this into the clean archive as `internal/cli/zz_probe_test.go` (package `cli`),
stand an `httptest` server that answers the DELETE with a chosen status+body, call
`(&cloudclient.Client{BaseURL: srv.URL, Token: "tok"}).DeleteSpawnSite`, hand the
error to `cloudFail(out, "delete site", err)` with `out.output = "json"`, and log the
stdout. Then:

    cd /tmp/omain && CC=clang go test ./internal/cli/ -run TestProbeJSONRefusalFlattening -v

Pure source re-derivation of the same fact, no test needed:

    git show origin/main:internal/cli/cloud12_cmd.go | sed -n '/^func cloudFail/,/^}/p'
    git show origin/main:internal/cli/errors.go     | sed -n '/^func renderErrorEnvelope/,/^}/p'

`cloudFail` emits code `"auth"` for a message containing `unauthorized` and code
`"failed"` for everything else; `renderErrorEnvelopeDetailed` puts that literal in
`error.code`. The typed code survives only inside the human `error.message` prose.

## R3 — the no-box branch of the delete route is unreachable

    git show origin/main:cloud/priv/repo/migrations/20260627150000_create_sites.exs | sed -n '11,20p'
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '633,643p'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7056,7060p'
    git log --oneline origin/main -- cloud/priv/repo/migrations | grep -i 'sites' 

`sites.barkpark_id` is `references(:barkparks, on_delete: :delete_all), null: false`
and no later migration alters it; `get_barkpark/1` is a bare `Repo.get` with no
status filter. So `bp == nil` requires a sites row whose barkparks row is gone —
which the FK deletes. `box_present: not is_nil(bp)` is a constant true on the wire.

## R4 — the success-claim registry's reach over a new `renderSiteDeleted` arm

    git show origin/main:internal/cli/success_claim_registry_test.go | sed -n '/func TestSiteClaimsAreProbedWithResponseTypes/,/^}/p'
    git show origin/main:internal/cli/success_claim_registry_test.go | sed -n '/^var requiredEnrollments/,/^}/p'

Names are split on `/`, so a `renderSiteDeleted/box-present` VARIANT needs no edit to
`requiredEnrollments` or `siteResponseTypedRows`; the `siteRenderPrefix` arm covers it
automatically. What is NOT covered: adding a field to `SiteDeleteResult` and never
varying it in a pair — the existing row varies only `OK`/`Status`.

## R5 — the CLI's own delete tests do not pin the real envelope's key set

    git show origin/main:internal/cli/cloud_site_cmd_test.go | sed -n '1282,1310p'

`deleteEnvelope` is a CLI-side fixture, so a new key on the real 200 reds nothing here.

## R6 — this epic's fence excludes `internal/`, in writing, on an open row

    bp task get cch-w65-bl-bp-cloud-status-conflates-absent-and-never-checked -o json

Its description ends: "OUT OF cloud-console-hardening's FENCE (`internal/cloudclient/`
+ `internal/cli/`). Filed rather than paid by widening the fence into `internal/`."

## R7 — full gate on the clean archive

    cd /tmp/omain && CC=clang go build ./... && CC=clang go vet ./internal/cli/... && CC=clang go test ./internal/cli/...
