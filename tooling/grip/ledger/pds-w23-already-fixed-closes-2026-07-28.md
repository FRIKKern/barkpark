# PDS wave 23 — re-derivation recipes for the four "already fixed?" rows

Written by the wave-23 VERIFIER (v6-already-fixed-closes), 2026-07-28. Every row below
was adjudicated by opening the code on `origin/main` AND running the test that pins it.
Never by a grep hit and never by a PR subject line.

## pds-bl-blob-sidecar-byte-verify — CLOSE-ELIGIBLE

    git show origin/main:internal/cli/cloud_workspace_cmd.go | sed -n '/^func putOneBlob/,/^}/p'
    git show origin/main:internal/cli/cloud_workspace_cmd.go | sed -n '/^func fetchOneBlob/,/^}/p'
    CC=clang go test ./internal/cli/ -run 'TestBlobUploadByteMismatchIsANamedFailure|TestBlobFetchSizeMismatchIsANamedFailure|TestBlobFetchAbsentDeclaredSizeIsNotAPass' -v

Both legs compare and fail loudly; the NULL-declared-size case is reported unverified,
not counted as proof; the uploaded receipt says "received by the target", never "stored".

## pds-bl-manifest-writes-fails-open — DO NOT CLOSE (server half only)

    git show origin/main:api/lib/barkpark/plugins/capabilities.ex | grep -n 'Keyword.fetch!(opts, :writes)'
    sed -n '600,615p' api/test/barkpark/plugins/cli_commands_manifest_test.exs   # non-GET ⇒ writes==true guard
    git show origin/main:internal/manifest/manifest.go | grep -n 'Writes '       # still a plain bool
    git show origin/main:internal/cli/usage.go | sed -n '299,315p'               # soleReadVerb still `if sole.Writes`

## pds-bl-close-audit-gaps — DO NOT CLOSE (both holes stand)

    git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '536,556p'   # closed_by only under `%{"claim" => claim}`
    grep -rn 'Tasks.close(' api/lib/barkpark/plugins/tasks/web/board_live.ex  # no caller_token_id
    cd api && CC=clang mix test test/barkpark/tasks/close_test.exs

## pds-bl-deploy-success-without-advance — DO NOT CLOSE (verb still exits 0)

    git show origin/main:internal/cli/cloud_deploy_cmd.go | sed -n '204,222p'
