# pds-w30 write-fence LIVE probe — re-derivation recipes (wave 30 VERIFY, 2026-07-31)

The first PDS proof driven against a real server. Target: `https://guerrilla.barkpark.cloud`,
dataset `production`, through the real Caddy edge. Everything below re-derives from scratch.

## R0 — The installed `bp` CANNOT prove anything about #8603

    bp --version                                    # {"commit":"f59aaf717", build 2026-07-31T06:54:48Z}
    git show f59aaf717:internal/cli/run.go | grep -c screenWriteReceipt      # 0
    git show origin/main:internal/cli/run.go | grep -c screenWriteReceipt    # 3
    gh pr view 8603 --json mergedAt                 # 2026-07-31T17:32:46Z  (AFTER the build stamp)

VERDICT: the fence merged ~10h after the installed binary was built. Any live run through
`/Users/pelle/.local/bin/bp` exercises the PRE-FENCE code. Build from `origin/main` first:

    git worktree add --detach <dir> origin/main
    cd <dir> && CC=/usr/bin/clang go build -o <sp>/bp-v9 ./cmd/barkpark   # NOT ./cmd/bp (does not exist)

## R1 — Which route does a doc write take, and is it the fenced one?

    <sp>/bp-v9 doc create scratch --set title=x --dry-run
    # POST https://guerrilla.barkpark.cloud/v1/data/mutate/production

`doc` is NOT intercepted in `internal/cli/cli.go` (contrast `chat`/`tasks`/`listen`/`export`),
so it lands in `runCommand` → `screenWriteReceipt` (run.go:248). `doc create` carries
`writes=true` in the manifest (93 write verbs total).

## R2 — The live round trip (create → independent oracle → delete → gone)

    T=pdsW30FenceProbe; ID=pds-w30-fence-probe-$(date +%s)
    <sp>/bp-v9 doc query $T -o json                                  # rc=4 not_found  ← refuse-if-exists precheck
    <sp>/bp-v9 doc create $T --set _id=$ID --set title=pds-w30-fence-probe -o json --yes
    curl -s -H "Authorization: Bearer $TOK" \
      "https://guerrilla.barkpark.cloud/v1/data/query/production/$T?perspective=drafts"
    <sp>/bp-v9 doc delete $T $ID -o json --yes
    for P in published drafts raw; do curl -s -H "Authorization: Bearer $TOK" \
      ".../v1/data/query/production/$T?perspective=$P"; done                # count:0 on all three

The receipt's `_rev` (`cd79e534fcb4a1b8ca1cdbe479ffc299`) matched the independent curl read
byte-for-byte. Five write verbs driven live (create, patch, publish, unpublish, delete) — all
returned a non-empty JSON object, all passed the fence at rc=0. **The fence does not red honest
production traffic on the `doc` noun.**

## R3 — The prod write-guard did NOT fire (the direction's premise is refuted)

    <sp>/bp-v9 doc patch $T $ID --set title=probe-v2 -o json < /dev/null   # rc=0, WRITE LANDED, no --yes
    sed -n '1829,1840p' internal/cli/run.go                                # func isProd

`isProd` returns true only for a server NAMED prod/production or a URL containing
`api.barkpark.cloud`/`prod`. Guerrilla's manifest identity is `{"name":"barkpark",
"base_url":"https://guerrilla.barkpark.cloud"}` — neither matches. `--yes` is a NO-OP against
guerrilla; the dataset being called `production` is irrelevant to the guard.

## R4 — Can the 204 carve-out be driven live through `bp`? NO.

    <sp>/bp-v9 chat approve <id> --decision deny
    # rc=2  {"error":{"code":"usage","message":"bp chat takes no arguments besides `ls` and `unarchive` …"}}
    grep -n 'case "chat"' -A 6 internal/cli/cli.go        # :165 → runChat builtin, never manifest dispatch
    grep -rn "send_resp(conn, :no_content\|send_resp(conn, 204" api/lib   # exactly 4 emitters

The four 204 emitters are chat `approval`, SCIM users, SCIM groups, pulse OPTIONS-preflight.
`scim` and `pulse` are not manifest nouns (26 nouns; neither appears). The only manifest write
verb that 204s is `chat approve`, and `cli.go:165` swallows the whole `chat` noun into the
builtin TUI. **The 204 arm is unreachable from the CLI today; it stays fake-proven.**

The SERVER half is now L1 though — a real 204 exists and is producible:

    curl -s -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
      -d '{"request_id":"pds-w30-nonexistent-ask","decision":"deny"}' \
      "https://guerrilla.barkpark.cloud/v1/chat/sessions/<idle-session-id>/approval" -D -
    # HTTP/2 204, via: 1.1 Caddy, zero-byte body, NO content-type header

(Safe on an idle session: `chat_controller.ex:305-333` skips the whole inner `with` when no
Recorder holds the ask and still `send_resp(conn, :no_content, "")`.)

## R5 — Can the edge inject a non-JSON 2xx? YES — the fence's threat model is live.

    curl -s  https://guerrilla.barkpark.cloud/  -w "%{http_code} %{content_type}\n"   # 302 text/html
    curl -sL https://guerrilla.barkpark.cloud/  -w "%{http_code} %{content_type} %{size_download}\n"
    # 200 text/html 517831   ← /login
    grep -n "client := &http.Client{Timeout" internal/cli/run.go     # :1221 — no CheckRedirect
    grep -rn "CheckRedirect" internal/                                # 5 hits, NONE in doRequest

`doRequest` uses Go's default redirect policy (follows up to 10). The same host serves a 517 KB
`text/html` 200 one redirect away from `/`. A write POST that gets 3xx'd (Go downgrades it to
GET and drops the body) would return an HTML 200 that pre-fence `bp` printed as success.

## R6 — Charter symbol drift

    git grep -c refuseEvidencelessWriteReceipt origin/main -- internal/      # rc=1, zero hits
    git grep -n refuseEvidencelessWriteReceipt origin/main -- .claude/workflows/bp-pds-charter.md
    # :6867 — the wave-29 dispatch table names a symbol that does not resolve

Same class as the `hzResGone` finding: the charter's table cites a pre-rename symbol. The
shipped name is `screenWriteReceipt` (charter :2596 has it right).
