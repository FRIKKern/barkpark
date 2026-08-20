# Re-derivation recipe — claim-registry collision (site-spawner wave 8, arm 2)

Every fact below is re-derivable from `origin/main` alone. NOTE: the primary
checkout may be BEHIND origin/main (it was 12 commits behind at 32cbb43 when this
was written) and `internal/cli/success_claim_registry_test.go` did not exist in it —
so `go test ./internal/cli/...` in the checkout is a VACUOUS green for this gate.
Test against an origin/main extraction:

    D=$(mktemp -d); git archive origin/main -- go.mod go.sum internal cmd docs scripts | tar -x -C $D
    cd $D && CC=clang go test -count=1 -run 'SuccessClaim|AutoupdateReceiptNames' ./internal/cli/ -v

  (residual reds elsewhere in that package are extraction artifacts — 14 tests read
  cloud/priv/static/__fixtures__, .cursor/, scaffy/, which the archive above omits.)

| fact | command |
|---|---|
| the gate + its 17 rows | `git show origin/main:internal/cli/success_claim_registry_test.go` |
| the A1/A2/A3 ruling + census | `git show origin/main:docs/decisions/success-claim-census.md` |
| enrolled source files (8, none site) | `git show origin/main:internal/cli/success_claim_registry_test.go \| grep -oE '── [a-z0-9_]+\.go' \| sort -u` |
| no site verb enrolled | `git show origin/main:internal/cli/success_claim_registry_test.go \| grep -c 'cloud_site\|SpawnSite'` → 0 |
| the four-outcome grammar | `git show origin/main:internal/cli/cloud_deploy_cmd.go \| sed -n '264,272p;483,505p'` |
| site receipts are inline, not render fns | `git show origin/main:internal/cli/cloud_site_cmd.go \| grep -n '✓'` |
| create's binding line is a REQUEST echo | `git show origin/main:internal/cli/cloud_site_cmd.go \| sed -n '244,252p'` (`req.DocType`) |
| census's 12 site-spawner glyphs | `for f in $(git ls-tree --name-only origin/main deploy/ \| grep site-spawner); do git show origin/main:$f \| grep -c ✓; done` → 4,4,4 |
| PDS row still open (merge-gated) | `bp task get pds-w23-success-claim-registry` |

Mutation proofs (run inside the extraction $D):

1. GATE CAN FAIL — rewrite `autoupdateReceipt` in `internal/cli/cloud_autoupdate_cmd.go`
   so every branch returns a verb-keyed string ignoring `policy`; rerun the gate.
   Expect 4 RED registry rows + `TestAutoupdateReceiptNamesTheContradiction`.
2. CONSTANT STRING FAILS — a render printing one fixed line reds
   (`prints the SAME line`), refuting "a non-empty string passes".
3. THE ESCAPE HATCH — a render that echoes only the REQUEST (`content: %s docs`
   off `req.DocType`) PASSES when the row's Backed/Contradicted pair differs in
   that echoed field. The property constrains the render, never the provenance of
   the two values; the row author must supply SERVER responses.
