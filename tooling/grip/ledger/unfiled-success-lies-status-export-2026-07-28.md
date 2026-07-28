# Re-derivation recipes — two glyph-less success-lies: `barkpark status` and `bp export` (PDS wave 23, 2026-07-28)

Verifier lane `v12-unfiled-success-lies`. Both sites are invisible to a census
keyed on the ✓ glyph in `internal/cli/*.go`: one lives in a bash script
(`bin/barkpark`), the other prints no receipt at all. Every recipe below is
read-only except #4/#5, which start throwaway loopback servers in a scratch dir.

| # | Claim | Command |
|---|---|---|
| 1 | `barkpark status` decides "server running" from a bare `kill -0` on a pidfile — no port, no HTTP. The honest primitive `listener_pid()` is defined FOUR LINES ABOVE it (`bin/barkpark:135-137`) and is already used by `start_server` and `stop_server`; only `cmd_status` ignores it | `git show origin/main:bin/barkpark \| sed -n '135,142p;178,190p;240,247p'` |
| 2 | LIE DIRECTION A (false RUNNING): a pidfile pointing at any live non-server process prints `server running (pid N) — http://localhost:4000`, exit 0 | `export BARKPARK_HOME=$(mktemp -d); mkdir -p $BARKPARK_HOME; sleep 300 & echo $! > $BARKPARK_HOME/server.pid; bash bin/barkpark status; echo EXIT=$?; kill %1` |
| 3 | LIE DIRECTION B (false STOPPED), observed with NO setup on this host: `~/.barkpark/server.pid` is absent, `status` prints `server stopped` exit 0, while `beam.smp` holds `:4000` and `GET /api/schemas` returns 200 | `ls ~/.barkpark/server.pid; bash bin/barkpark status; echo EXIT=$?; curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4000/api/schemas; lsof -nP -tiTCP:4000 -sTCP:LISTEN` |
| 4 | `bp export` (documented `for backup`) exits **0** with a SILENTLY TRUNCATED file when the server truncates a **close-delimited** body mid-stream — 3 of N docs on stdout, EMPTY stderr, exit 0. `export.go:77` returns `scanner.Err()` under the comment "Export is finite: a clean EOF means every document streamed" | `python3 <FIXTURE> closedelim 4711 & sleep 1; bp -s http://127.0.0.1:4711 export > /tmp/e.ndjson; echo EXIT=$?; wc -l /tmp/e.ndjson; wc -c /tmp/e.ndjson` — `<FIXTURE>` is the throwaway server described at the bottom of this file (it is NOT in the repo; recreate it) |
| 5 | The same truncation over **chunked-without-terminator** or a **short Content-Length** IS caught: `export: unexpected EOF`, exit 1. So the path is honest in two framings and silent in the third — the difference is invisible to the caller | same as #4 with `chunkedabrupt 4712` / `contentlength 4713` |
| 6 | Ctrl-C truncation is exit-0 BY EXPLICIT DESIGN, stated in the source: `// Ctrl-C cancels the context, ending the stream cleanly (exit 0).` and the gate `if err != nil && sigCtx.Err() == nil` | `git show origin/main:internal/cli/export_cmd.go \| sed -n '60,74p'` |
| 7 | No count is ever emitted, in ANY outcome — the callback only does `out.outf("%s", line)`; there is no tally, no trailing receipt, nothing on stderr | `git show origin/main:internal/cli/export_cmd.go \| grep -n 'outf\|errf\|count'` |
| 8 | PREREQUISITE DEFECT: `bp export` cannot succeed against ANY server today. The client sends `Accept: application/x-ndjson` (`export.go:47`) but the `:scoped_api` pipeline is `plug(:accepts, ["json"])` (`router.ex:143`) → 406, surfaced to the operator as the opaque `export: unknown error` | `curl -s -o /dev/null -w 'ndjson=%{http_code}\n' -H 'Accept: application/x-ndjson' https://guerrilla.barkpark.cloud/v1/data/export/production; curl -s -o /dev/null -w 'json=%{http_code}\n' -H 'Accept: application/json' https://guerrilla.barkpark.cloud/v1/data/export/production; bp export; echo EXIT=$?` |
| 9 | Prior art: the pidfile lie is UNFILED for `status`; the SIBLING `pds-barkpark-stop-4000-fallback` (P2, published, open) covers `stop` in the same file and already names `listener_pid`. `pds-bl-export-no-serialization` is the workspace-BUNDLE route, not the NDJSON dataset export — closed as superseded | `bp task get pds-barkpark-stop-4000-fallback -o json; bp task get pds-bl-export-no-serialization -o json` |
| 10 | Server side never sees a partial write either: `export_controller.ex:22` does `{:ok, acc} = chunk(acc, line)`, a MatchError on `{:error, :closed}` — a disconnected client crashes the streaming process inside a `Repo.transaction` | `git show origin/main:api/lib/barkpark_web/controllers/export_controller.ex` |
| 11 | ENV TRAP for anyone re-running the briefed command: `timeout` does not exist on this macOS host (`command not found`, exit 127) — the briefed `timeout 3 bp export` measures nothing. Use `gtimeout`, or background + `kill -INT` | `timeout 3 true; echo EXIT=$?` |

Fixture for #4/#5 (not committed by this lane; body inlined so it can be recreated):
a raw-socket Python server that answers any `/export/` path with 3 NDJSON docs
and then (a) `closedelim`: `Connection: close`, no `Content-Length`, clean FIN;
(b) `chunkedabrupt`: chunked framing, no terminating `0\r\n\r\n`, abrupt close;
(c) `contentlength`: declares 4x the bytes it sends, then closes.
