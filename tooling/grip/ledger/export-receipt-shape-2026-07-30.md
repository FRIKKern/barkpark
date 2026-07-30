# export-receipt-shape — re-derivation recipes (PDS wave 25, S7)

Every row below is a single command that re-derives the fact from scratch.
Facts are stated against `origin/main` (74a88d1cd at capture time), never the worktree.

## 1. Phoenix/Plug/Bandit CANNOT emit HTTP chunked trailers — no API exists

    cd api && CC=clang MIX_ENV=test mix run --no-start -e '
    IO.inspect(Plug.Conn.__info__(:functions) |> Enum.filter(fn {n,_} -> String.contains?(Atom.to_string(n), "trail") end), label: "Plug.Conn")
    IO.inspect(Plug.Conn.Adapter.behaviour_info(:callbacks) |> Enum.filter(fn {n,_} -> String.contains?(Atom.to_string(n), "trail") end), label: "Adapter callbacks")
    IO.inspect(Bandit.Adapter.__info__(:functions) |> Enum.filter(fn {n,_} -> String.contains?(Atom.to_string(n), "trail") end), label: "Bandit.Adapter")'

Expected: all three `[]`. Corroborate the negative from the dep sources:

    cd api && grep -rn trailer deps/plug/lib/ | wc -l        # 0
    cd api && grep -rni trailer deps/bandit/lib/ | wc -l     # non-zero, but REQUEST-side only
                                                             # (http1/socket.ex:257 "Encountered trailers in
                                                             #  chunked request; ignoring")

Conclusion: a trailer-based export receipt is not implementable without patching Plug + Bandit.
The sidecar / terminal-line design space is FORCED.

## 2. Today's only completeness signal on the server is a LOG LINE

    git show origin/main:api/lib/barkpark_web/controllers/export_controller.ex | sed -n '55,68p'

Expected: `Logger.warning("export truncated: client socket closed mid-stream ... delivered=#{delivered}
... The 200 was already on the wire — this backup is INCOMPLETE.")`. It fires ONLY on client
hangup (`chunk/2 -> {:error, reason}`), not on a server-side stream failure.

## 3. The pin is a STUBBED ADAPTER, so wire framing is untested at the ConnCase layer

    git show origin/main:api/test/barkpark_web/contract/export_test.exs | sed -n '9,20p;100,129p'

Expected: a fake adapter with `def chunk(_state, _body), do: {:error, :closed}` plus a
`capture_log` assertion. Real chunked framing (terminating chunk present/absent) is NOT
exercised — any S7 framing claim needs a loopback/Bandit test, not a ConnCase test.

## 4. Three line-oriented consumers of GET /v1/data/export/:dataset

    grep -rn 'data/export' js/packages web/app web/src scripts/ internal/ 2>/dev/null | grep -v node_modules

Expected consumers: `internal/apiclient/export.go` (scanner -> onDoc, `internal/cli/export_cmd.go`
prints each line verbatim and counts it as a document), `js/packages/core/src/export.ts`
(`parseLine` -> `yield ... as BarkparkDocument`), plus the SDK README/changeset. web/ source: NONE
(only `web/.next/**` build artefacts match). scripts/: NONE.
=> A terminal receipt LINE in the NDJSON body is a breaking body-shape change for both SDK and CLI.

## 5. The multipart abort-on-truncation pattern IS test-proven — at two layers, unevenly

    CC=clang go test ./internal/backup/ -run TestBackupDirtySourceClose -v
    CC=clang go test ./internal/hetzner/objstore/ -run PutLarge -v

`TestBackupDirtySourceClose` asserts the pg_dump error surfaces AND that no `.manifest.json` was
written; it does NOT assert the dump object is absent, and it runs against an in-memory fake.
The real abort is at `internal/hetzner/objstore/client.go:308-311` (body read error -> `abort()`),
covered by `TestPutLargeAbortsOnPartFailure` — which exercises an UploadPart HTTP 500, not a
body-read error. The body-read-error abort path has NO direct test.

## 6. The prior-art sidecar precedent (different verb family — do NOT merge with S7)

    grep -n 'full_meta_ok\|FULL_META' scripts/pds-pull-proof.sh | head

`bp-export-v1` tar bundles already ship a `.meta` sidecar read by `full_meta_field()`.
That is the cloud workspace-bundle family, related to S7 only by pattern.
