# cli-receipt-sweep — re-derivation recipes (PDS wave 48 verify)

Scope: `internal/cli` success receipts. All facts derived against `origin/main`
(local `main` is a31faa52d, OFF origin/main 467f7e28 — always `git show origin/main:`).

## R1 — migrate's count is the REQUEST, not the write return

    git show origin/main:internal/cli/migrate_cmd.go | sed -n '374,384p'
    git show origin/main:internal/cli/migrate_cmd.go | sed -n '478,487p'

`migrateWriteBatch` binds `respBody` but uses it ONLY on non-2xx (`classifyError`);
on 2xx it `return nil` and the body is discarded. Caller does `written += len(batch)`.

## R2 — the server is ATOMIC, so R1 is LATENT not live (non-destructive proof)

    S=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['server'])")
    T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
    curl -s -X POST "$S/v1/data/mutate/production" -H "Authorization: Bearer $T" \
      -H 'Content-Type: application/json' \
      -d '{"mutations":[{"createOrReplace":{"_type":"post","_id":"w48-probe-ok","title":"ok"}},{"createOrReplace":{"_id":"w48-probe-poison"}}]}' \
      -w '\nHTTP=%{http_code}\n'
    # -> HTTP=422 validation_failed
    curl -s "$S/v1/data/doc/production/w48-probe-ok" -H "Authorization: Bearer $T" -w '\nHTTP=%{http_code}\n'
    # -> HTTP=404 not_found  => the VALID sibling rolled back; no partial success

Structural corroboration (results length == mutations length on any 2xx):

    git show origin/main:api/lib/barkpark/content/mutations.ex | sed -n '70,92p'   # Enum.map_reduce, Repo.rollback on error
    git show origin/main:api/lib/barkpark/content/mutations.ex | grep -n 'defp apply_one'  # catch-all -> {:error, :malformed}

## R3 — bp task create echoes its own request while claiming server acceptance

    git show origin/main:internal/cli/tasks_create_cmd.go | sed -n '116,122p'   # born := body["lifecycle_status"]
    git show origin/main:internal/cli/tasks_create_cmd.go | sed -n '261,266p'   # body built locally, defaulted "open"
    git show origin/main:internal/cli/tasks_create_cmd.go | grep -n 'firstMutationID(respBody)'

`respBody` IS parsed (for the id) — the honest value is reachable in the SAME bytes.

## R4 — bp task stamp is the exemplar, not a hole

    git show origin/main:internal/cli/tasks_stamp_cmd.go | sed -n '70,92p'

No HTTP in the file because the POST goes through the shared manifest dispatch
(`runCommand`); it then calls `confirmStampLanded` — a real second read (PDS-D359/D361).

## R5 — the success-claim registry already exists; migrate + task create are NOT in it

    git show origin/main:internal/cli/success_claim_registry_test.go | sed -n '1,45p'   # A1/A2/A3 taxonomy, PDS-D313
    git show origin/main:internal/cli/success_claim_registry_test.go | sed -n '700,724p' # requiredEnrollments floor (21 names)
    git show origin/main:internal/cli/success_claim_registry_test.go | grep -c 'Name:'   # 47 rows
    git show origin/main:internal/cli/success_claim_registry_test.go | grep -n 'migrate\|taskCreate'  # NO MATCHES

## R6 — gates green (note: `CC=clang` resolves to a non-compiler on this host)

    CC=/usr/bin/clang go build ./...; echo "BUILD_RC=$?"
    CC=/usr/bin/clang go vet ./internal/cli/...; echo "VET_RC=$?"
    CC=/usr/bin/clang go test ./internal/cli/...; echo "TEST_RC=$?"
    CC=/usr/bin/clang go test ./internal/cli/ -run 'SuccessClaim|ClaimsAreProbed'

`CC=clang` (as written in the wave direction) yields `error: unknown option '-E'`
on `runtime/cgo` and a `[build failed]` for `internal/cli`. Also: the direction's
`go build ./... | tail -5; echo $?` reports the rc of `tail`, not of `go build`.

## R7 — glyph population (evidence AGAINST using it as the census)

    git ls-tree -r --name-only origin/main -- internal/cli/ | grep '\.go$' | grep -v '_test.go' \
      | while read f; do n=$(git show origin/main:$f | grep -c '✓'); [ "$n" -gt 0 ] && echo "$n $f"; done | sort -rn

TOTAL 122 in non-test CLI Go files. The registry header names three measured reasons
a glyph grep is the WRONG population (vercel_cmd.go's 13 are interpolated; `bp status`
and `bp export` claim success with no glyph; api/lib's 47 glyphs are LiveView chrome).
