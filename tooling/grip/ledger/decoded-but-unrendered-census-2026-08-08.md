# Decoded-but-unrendered census — re-derivation recipe (2026-08-08, origin/main 31bbb79b)

Sizes the arm the register's S3 widening needs: every field carrying a `json:` tag in
`internal/cloudclient` with ZERO render in `internal/cli/**`, plus the per-struct laundering
probe over the payload key-set census's UNREAD arm.

## 0. Pristine tree

    rm -rf /tmp/dbu && mkdir -p /tmp/dbu \
      && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C /tmp/dbu

## 1. Gates (baseline green on origin/main)

    cd /tmp/dbu && CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go test ./internal/cli/...
    # NOTE: CGO_ENABLED=0 on the TEST run too. With cgo on, `cc` resolves to the
    # Claude wrapper alias and internal/cli fails "runtime/cgo: error: unknown option '-E'".
    ln -s /Volumes/SATECHI/github/barkpark/cloud/deps /tmp/dbu/cloud/deps   # mix.lock identical to HEAD
    cd /tmp/dbu/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/payload_key_set_census_test.exs

## 2. The census itself (go/types, sound — not a grep)

Two passes, kept separately on purpose:

* NAME-MATCHING (`/tmp/census/main.go`): a field is "read" if its Go identifier appears as a
  selector, or its json key as a string literal, anywhere in non-test `internal/cli`. Upper
  bound on reads → **18 dark**. This is the pass that LAUNDERS: it cannot tell
  `DeploymentPage.NextCursor` (read) from `SiteDeploymentPage.NextCursor` (dark).
* TYPE-RESOLVED (`/tmp/tcensus/main.go`, `golang.org/x/tools/go/packages`): every selector in
  `internal/cli/**` is resolved through `go/types` to the exact field *object*. Sound.

        cd /tmp/dbu && CGO_ENABLED=0 GOFLAGS=-mod=mod go run /tmp/tcensus/main.go /tmp/dbu

  → `json-tagged cloudclient fields: 415 ; type-resolved DARK: 116`.
  Reconciliation: `grep -c 'json:"' internal/cloudclient/client.go` = 425;
  `grep -c 'json:"-"\|json:",'` = 10 skipped (explicit no-decode / empty key). 415 + 10 = 425. ✓

Slices of the 116:
* 45 sit on anonymous response envelopes inside `cloudclient` itself.
* 71 sit on NAMED exported types with no reader in `internal/cli`, `cmd/`, or `cloudclient`.
* 6 of those 71 are REQUEST fields written by composite literal (`SiteCreate` ×5,
  `SpawnSiteCreate` ×1) — a known false positive of the selector-only detector, because a
  `KeyValueExpr` key is an `Ident`, not a `SelectorExpr`.
* **65 = the honest read-path dark population** the S3 floor should be set against.

## 3. The laundering probe (`/tmp/census/launder.exs`)

Per censused pair: emitted keys MINUS the paired struct's own tags, INTERSECT the file-global
union. That set is what passes UNREAD only because a foreign struct declares the name.

    cd /tmp/dbu/cloud && CC=clang MIX_ENV=test mix run --no-start /tmp/census/launder.exs

Result — the blind spot is POPULATED today, on exactly one pair:

    site_deployment_json/3 -> SiteDeployment: emitted=31 on_paired_struct=23 LAUNDERED=4 unread=4
        artifact_url  (declared only by: Deployment)
        detail        (declared only by: SiteStage, WebhookProxyError)
        git_ref       (declared only by: Deployment)
        image_tag     (declared only by: Deployment)

All other six pairs: LAUNDERED=0. Two per-struct D260 guards already exist in the test file
(lines ~875 and ~900) but they pin `DeployCensus` / `DeployCensusSite` only — nothing pins
`SiteDeployment`, which is the pair that is actually laundering.
