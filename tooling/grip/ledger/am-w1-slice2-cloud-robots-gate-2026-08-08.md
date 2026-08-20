# Re-derivation recipes — anonymous-metering W1 slice 2, cloud half (robots.txt)

Verified 2026-08-08 against `origin/main` @ `5b68852f4` in a throwaway detached worktree
(the primary checkout is 671 commits behind origin and its cloud tree is missing
27,490 lines of tests — never quote a run from it as an origin fact).

Setup used for every run below:

    git worktree add /tmp/om --detach origin/main
    ln -s /Volumes/SATECHI/github/barkpark/cloud/deps /tmp/om/cloud/deps
    cd /tmp/om/cloud && CC=clang MIX_ENV=test mix compile

## 1 — the gate slice 2 extends is green on origin

    cd /tmp/om/cloud && CC=clang mix test test/web/static_allowlist_test.exs
    # 4 tests, 0 failures

## 2 — the gate CAN fail (mutation)

    # append `__preview__` to `only: ~w(...)` at cloud/lib/barkpark_cloud/web/router.ex:418
    cd /tmp/om/cloud && CC=clang mix test test/web/static_allowlist_test.exs
    # 4 tests, 1 failure — "/__preview__/mock.js must NOT be web-reachable (got 200)"

## 3 — both vacuous directions for slice 2 (the file alone ships a 404)

Probe script (`mix run --no-start`, no DB):

    import Plug.Test
    alias BarkparkCloud.Web.Router
    opts = Router.init([])
    c = Router.call(conn(:get, "/robots.txt"), opts)
    IO.puts("#{c.status} #{inspect(Plug.Conn.get_resp_header(c, "content-type"))} #{inspect(c.resp_body)}")

- file present, allowlist unchanged  -> `404 ["application/json; charset=utf-8"] "{\"error\":\"not_found\"}"`
- allowlist carries `robots.txt`, file absent -> same 404
- both  -> `200 ["text/plain"] "User-agent: *\nDisallow: /\n"`
- existing gate stays GREEN in all three states -> it cannot notice a missing robots.txt

## 4 — the allowlist edit must APPEND, never prepend

`scripts/cloud-static-gz-guard.sh` check 4 anchors on the literal `only: ~w(index.html`.

    cd /tmp/om && bash scripts/cloud-static-gz-guard.sh
    # appended  -> rc 0, "OK: ... serves the siblings (`gzip: true` near line 418)"
    # prepended -> rc 1, "cannot find the `at: \"/\"` Plug.Static allowlist ... looked for `only: ~w(index.html`"

## 5 — other cloud gates are inert to the edit

    cd /tmp/om/cloud && CC=clang mix format --check-formatted lib/barkpark_cloud/web/router.ex   # rc 0
    cd /tmp/om && bash scripts/cloud-path-escape-check.sh                                        # rc 0

## 6 — live L1 (no edge interception)

    curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://barkpark.cloud/robots.txt
    # 404 application/json; charset=utf-8   -> the app answers, not Caddy
    curl -s https://guerrilla.barkpark.cloud/robots.txt | head -3
    # api already serves the 203-byte Phoenix stub (every rule commented out = allow-all)
