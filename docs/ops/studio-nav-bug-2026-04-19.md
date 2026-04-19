---
title: Studio navigation bug — root cause analysis
date: 2026-04-19
author: Worker W4.1 (Task #9 / Subtask 1)
status: diagnosed, fix not applied (research-only scope)
severity: P0 — Studio is interactively unusable in production
---

# Studio navigation bug (`https://api.barkpark.cloud/studio/production`)

## 1. Summary

The multi-pane Studio at `https://api.barkpark.cloud/studio/production` renders
its initial HTML correctly but **every `phx-click` in the page (structure nav,
doc list, profile, publish/delete, API-tester Run All, …) is silently dead**.
The cause is **not** a JS-load regression and **not** a router change: the
LiveView WebSocket upgrade at `wss://api.barkpark.cloud/live/websocket` is
rejected by Phoenix's default `check_origin` with **HTTP 403**, because
production `/opt/barkpark/.env` still carries the bootstrap values
`PHX_HOST=89.167.28.206` / `PHX_SCHEME` unset (→ `http`) that `deploy.sh`
writes on first install. Phoenix therefore advertises its own origin as
`http://89.167.28.206` and refuses the browser's `Origin:
https://api.barkpark.cloud`. With no socket, no event routing; the UI is
stuck on server-rendered state. Prior regression pattern #8 (LiveView JS not
loaded) does **not** apply here — the JS loads and evaluates fine.

This was literally predicted five commits ago in
`docs/ops/caddy-api-tls.md:196`:

> Phoenix `check_origin`. If Phoenix rejects WebSocket upgrades because the
> origin is now `https://barkpark.cloud` instead of the old IP,
> `api/config/prod.exs` must be updated. Out of scope for this slice; file a
> 1.0.1 ticket if it bites.

It has bitten.

---

## 2. Reproduction transcript

Commands were run from the repo checkout at `/home/doey/GitHub/barkpark`
on 2026-04-19 ~12:50–12:53 UTC.

### 2.1 HTTP-level sanity — page loads, 200 OK

```console
$ curl -sI https://api.barkpark.cloud/studio/production
HTTP/2 200
cache-control: max-age=0, private, must-revalidate
content-type: text/html; charset=utf-8
content-length: 45284
via: 1.1 Caddy
x-request-id: GKfDEDMQm0gKi44AADXy
```

### 2.2 Script tags and phx-click wiring are present in the DOM

```console
$ curl -s https://api.barkpark.cloud/studio/production \
    | grep -nE 'phx-click|<script|/live/|phoenix' | head
484: <div class="presence-me-group" phx-click="show-profile">
518:   <div id="item-post" phx-click="select" phx-value-id="post" phx-value-pane="0" class="pane-item">
539:   <div id="item-page" phx-click="select" phx-value-id="page" phx-value-pane="0" class="pane-item">
…
884: <script src="/assets/phoenix.js"></script>
885: <script src="/assets/phoenix_live_view.js"></script>
886: <script>
     …
     let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
       params: { _csrf_token, user_id, user_name, user_color },
       hooks: Hooks
     });
     liveSocket.connect();
```

- Scripts are at the **bottom of `<body>`**, not in `<head>` — golden rule
  #4 is satisfied.
- `data-phx-main`, `data-phx-session`, `data-phx-static`, and
  `<meta name="csrf-token">` are all rendered — LiveView mount payload is
  correct.

### 2.3 Self-hosted JS bundles load and expose expected globals

```console
$ curl -sI https://api.barkpark.cloud/assets/phoenix.js
HTTP/2 200   content-type: text/javascript   content-length: 24283

$ curl -sI https://api.barkpark.cloud/assets/phoenix_live_view.js
HTTP/2 200   content-type: text/javascript   content-length: 110686
```

Bundle heads/tails confirm the IIFE exports:

- `phoenix.js`: `var Phoenix=(()=>{… D(W,{Channel:…,LongPoll:…,Presence:…,Serializer:…,Socket:…}); … return F(W);})();` → `Phoenix.Socket` is defined.
- `phoenix_live_view.js`: `var LiveView=(()=>{…Bi(_n,{LiveSocket:…,ViewHook:…,createHook:…,isUsedInput:…}); … return Ji(_n);})();` → `LiveView.LiveSocket` is defined.

So `new LiveView.LiveSocket("/live", Phoenix.Socket, …)` in the inline
bootstrap script is a valid call. The client code is **not** the regression.

### 2.4 Smoking gun — WebSocket upgrade is rejected by origin

Probed `/live/websocket` with varied `Origin:` headers (all over HTTPS via
Caddy, `?vsn=2.0.0&_csrf_token=x`):

```console
$ for origin in "http://89.167.28.206" "http://89.167.28.206:4000" \
                "https://api.barkpark.cloud" "http://localhost:4000" ""; do
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Connection: upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
      -H "Origin: $origin" \
      "https://api.barkpark.cloud/live/websocket?vsn=2.0.0&_csrf_token=x")
    printf "origin=%-32s code=%s\n" "${origin:-<none>}" "$code"
  done
origin=http://89.167.28.206             code=400   ← origin accepted, 400 because curl is not a real WS client
origin=http://89.167.28.206:4000        code=400   ← origin accepted
origin=https://api.barkpark.cloud       code=403   ← origin REJECTED by Phoenix check_origin
origin=http://localhost:4000            code=403   ← origin REJECTED
origin=<none>                           code=400
```

The 403-vs-400 split is Phoenix's standard `check_origin` fingerprint
(403 = origin rejected before upgrade handshake; 400 = origin accepted but
upgrade otherwise unsatisfied). A real browser sitting on
`https://api.barkpark.cloud` hits the 403 path every time, so the LiveSocket
never transitions to `open` and `phx-click` events are never transmitted.

Verbose trace for the 403 path:

```console
$ curl -sv -H "Origin: https://api.barkpark.cloud" … \
    https://api.barkpark.cloud/live/websocket?vsn=2.0.0&_csrf_token=x
> GET /live/websocket?vsn=2.0.0&_csrf_token=x HTTP/2
> Origin: https://api.barkpark.cloud
> Connection: upgrade
> Upgrade: websocket
< HTTP/2 403
< via: 1.1 Caddy
< content-length: 0
```

Caddy forwarded the upgrade headers cleanly — the 403 is emitted by Phoenix
(Bandit), not by Caddy. Caddy is not the problem.

### 2.5 Secondary evidence — longpoll fallback also refused

```console
$ curl -sX POST -H "Content-Type: application/x-www-form-urlencoded" \
    "https://api.barkpark.cloud/live/longpoll?vsn=2.0.0" -d ""
{"status":410}
```

`410` is the "stale/disconnected session" body from Phoenix LiveView when the
token the client sent is not a live session — benign for an anonymous poke,
but confirms the longpoll endpoint is reachable. Even if the browser fell
back to longpoll, it would go through the same `check_origin` gate in the
Phoenix socket transport and also be 403'd with a real browser origin.

### 2.6 Live browser repro

Chrome DevTools MCP was unavailable in this environment (`Target closed`
error on both `new_page` and `list_pages`). SSH to the server was also
unavailable (`Permission denied`). Because the HTTP-level probes above are
definitive for `check_origin`, a browser repro is not strictly required to
confirm the diagnosis — the 403 on `/live/websocket` with the real browser's
`Origin` header is the only failure mode that would manifest as "click-dead
multi-pane Studio" without any console errors beyond a WebSocket failure
message.

**Cannot verify in this worktree without mutating — browser repro and
server-side `journalctl` grep for `check_origin` log lines are recommended
in the fix-verification step below.**

---

## 3. Diff analysis

No commit to `studio_live.ex`, `root.html.heex`, `app.html.heex`, `router.ex`,
`runtime.exs`, or `prod.exs` introduced the regression. The Phoenix code is
fine. The regression is a **configuration drift**, introduced by
**a95c6b1 — feat(demo+ops): Phase 7 Track D — hosted demo + hardening (#8)**
and its follow-ups (caddy TLS evidence commits) which cut `api.barkpark.cloud`
over to HTTPS via Caddy without running Step 3 of
`docs-site/ops/adding-a-domain.md` on the production `.env`:

```markdown
## Step 3 — Phoenix env
Edit `/opt/barkpark/.env`:
    PHX_SCHEME=https
    PHX_HOST=your-domain.example
```

That step was *skipped or deferred*. Relevant files:

- `api/config/runtime.exs:56` — `host = System.get_env("PHX_HOST") || "example.com"`
- `api/config/runtime.exs:61` — `url: [host: host, port: PORT, scheme: System.get_env("PHX_SCHEME", "http")]`
- `deploy.sh:118` — on fresh install writes `PHX_HOST=$IP` (the host's first IPv4), and does **not** write `PHX_SCHEME`. On re-runs, `deploy.sh:123–128` preserves the existing `.env` except for `DATABASE_URL`, so the stale `PHX_HOST=89.167.28.206` survives forever.
- `docs/ops/caddy-api-tls.md:196` — explicitly called out this risk as a "1.0.1 ticket if it bites." It bit.

Suspect commit chain (none of these *caused* the regression in code, but the
cutover happened within this window without touching `.env`):

```text
a95c6b1 feat(demo+ops): Phase 7 Track D — hosted demo + hardening (#8)
… (caddy TLS commits, preview slice commits)
7d45f18 fix(ci): npm dist-tag retag workflow  ← HEAD
```

The fix is not a revert. Nothing in source needs to change.

---

## 4. Root cause

**One-line hypothesis:** `/opt/barkpark/.env` still has
`PHX_HOST=89.167.28.206` and no `PHX_SCHEME=https`, so Phoenix's default
`check_origin` (derived from the endpoint `url: [host: …, scheme: …]` config)
whitelists only `http://89.167.28.206` and rejects the browser's real
`Origin: https://api.barkpark.cloud` with HTTP 403, preventing the LiveView
WebSocket from ever connecting.

**Supporting evidence:**

1. `/live/websocket` returns **403** when `Origin: https://api.barkpark.cloud`
   and **400** when `Origin: http://89.167.28.206[:port]` (§2.4). Only
   `check_origin` mismatch produces that 403/400 asymmetry in Phoenix.
2. The accepted-origin set (`http://89.167.28.206`) matches byte-for-byte
   what `deploy.sh:118` writes on a fresh install (`PHX_HOST=$IP`, no
   `PHX_SCHEME`, defaults in `runtime.exs:61` → scheme `"http"`).
3. The page's initial HTML, script inventory, mount payload, CSRF meta,
   and JS globals are all correct (§2.1–§2.3) — there is no client-side
   regression.
4. `root.html.heex` wires scripts in `<body>` (not `<head>`), so past
   regression pattern #8 (and its partner #4) is ruled out.
5. `handle_event("select", …)`, `handle_event("show-profile", …)`, and
   every other Studio event are present in `studio_live.ex:189–509` — no
   server-side handler was accidentally removed.
6. The hosted-TLS task explicitly flagged this as a follow-up
   (`docs/ops/caddy-api-tls.md:196`) and nothing has been committed since
   that updates the runtime env on the server.

Alternative hypotheses (ruled out, ranked by how long I spent chasing them):

- *`force_ssl` regression (past mistake #5)* — ruled out: `prod.exs` has
  `force_ssl` commented; page returns 200 with a `Set-Cookie`.
- *Blocking script in `<head>` (past mistake #4)* — ruled out: all scripts
  are at the end of `<body>` with `src=…` (no `async`, but not in `<head>`
  either, so not blocking HTML parse).
- *Self-hosted phoenix.js / phoenix_live_view.js not exposing the right
  globals* — ruled out by inspecting the IIFE return in §2.3.
- *Recent pane-component refactor (06c3bb8 / d493116) broke phx-click
  wiring* — ruled out: rendered HTML still has
  `phx-click="select" phx-value-id=... phx-value-pane=0` on every pane item.
- *Caddy stripping `Upgrade`/`Connection` headers* — ruled out by the
  403/400 asymmetry: both responses come from Phoenix-Bandit, meaning Caddy
  is proxying the upgrade through; if Caddy had stripped upgrade headers,
  every origin would 400 identically.

---

## 5. Proposed fix

**File:** `/opt/barkpark/.env` on the production server (not in the repo).

**Change:** add/replace the two lines below, preserving `DATABASE_URL`,
`SECRET_KEY_BASE`, `PORT`, `MIX_ENV`, and any `PREVIEW_JWT_SECRET` already
there.

**Before (current):**
```dotenv
PHX_HOST=89.167.28.206
# (no PHX_SCHEME line)
```

**After:**
```dotenv
PHX_HOST=api.barkpark.cloud
PHX_SCHEME=https
```

**Why this is the right fix:**

- It matches `docs-site/ops/adding-a-domain.md` Step 3 to the letter — the
  runbook that was supposed to run during Phase 7 Track D but didn't.
- Phoenix's `check_origin` will then advertise `https://api.barkpark.cloud`,
  accepting browser WebSocket upgrades from the production URL.
- Preview-signed URLs, emails, and any `Endpoint.url/0` callers also start
  producing correctly-scoped absolute URLs (currently they emit
  `http://89.167.28.206/...`).
- **No source-code change.** No revert. No rebuild beyond a `systemctl
  restart barkpark.service` to re-read the env file.

**Belt-and-braces alternative** (only if Step 3 of the runbook is refused
for policy reasons): add an explicit allowlist in `api/config/runtime.exs`
around line 61:

```elixir
config :barkpark, BarkparkWeb.Endpoint,
  url: [host: host, port: String.to_integer(System.get_env("PORT", "4000")),
        scheme: System.get_env("PHX_SCHEME", "http")],
  check_origin: [
    "https://api.barkpark.cloud",
    "http://api.barkpark.cloud",
    "//" <> host
  ],
  ...
```

This is a code change (ships through the normal release path) and is not
preferred: it duplicates knowledge that already belongs in the env file.

---

## 6. Rollback plan

Not a commit revert — this is a runtime-env bug.

**If the fix fails** (e.g. Phoenix fails to boot because of a typo in the
`.env`), revert `/opt/barkpark/.env` to exactly these two lines and restart:

```bash
ssh root@89.167.28.206
sed -i.bak \
  -e 's|^PHX_HOST=.*|PHX_HOST=89.167.28.206|' \
  -e '/^PHX_SCHEME=/d' \
  /opt/barkpark/.env
systemctl restart barkpark.service
```

The Studio will return to its current behaviour (page renders, clicks dead).
No data loss, no schema migration, nothing else to undo.

If, during fix-forward, someone also touched `api/config/runtime.exs` to add
an explicit `check_origin` list (the belt-and-braces alternative in §5),
revert that commit cleanly:

```bash
git revert <sha-of-the-check_origin-commit>
git push origin main
# then on the server
cd /opt/barkpark && make deploy
```

---

## 7. Verification plan

After the `.env` edit + `systemctl restart barkpark.service`:

### 7.1 Curl — origin no longer rejected

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Connection: upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Origin: https://api.barkpark.cloud" \
  "https://api.barkpark.cloud/live/websocket?vsn=2.0.0&_csrf_token=x"
# Expect: 400 (origin accepted, curl just isn't a real WS client).
# Must NOT be 403.
```

Simultaneously, the mismatched-origin case must still be 403:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Connection: upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Origin: https://evil.example" \
  "https://api.barkpark.cloud/live/websocket?vsn=2.0.0&_csrf_token=x"
# Expect: 403. Confirms check_origin is still gating, just whitelisting
# the right origin now.
```

### 7.2 Browser click test

1. Hard-reload `https://api.barkpark.cloud/studio/production` (bypass cache).
2. DevTools → Network → filter `ws` → confirm `wss://api.barkpark.cloud/live/websocket?...` becomes **101 Switching Protocols**, not 403.
3. Click **Post** (or any left-nav schema). URL should change to
   `/studio/production/post`, a doc list pane should slide in.
4. Click a document. URL should change to `/studio/production/post/<id>`,
   editor pane should appear on the right.
5. Click **Profile** (top-right presence chip). Profile modal should open.

### 7.3 Server-side journal check

```bash
ssh root@89.167.28.206 \
  'journalctl -u barkpark -n 500 --no-pager | grep -iE "check_origin|origin not allowed|CONNECTED TO Phoenix\.LiveView\.Socket"'
```

Expect to see `CONNECTED TO Phoenix.LiveView.Socket` lines for each browser
tab, and **zero** `origin not allowed` lines after the restart timestamp.

### 7.4 Smoke the public API at the same time

The env change also affects `Endpoint.url/0`. Sanity-check that public-read
routes still return 200:

```bash
curl -sI https://api.barkpark.cloud/v1/data/query/production/post
# Expect: 200
```

---

## Follow-ups to file (out of scope for this report)

- **`deploy.sh` hardening:** when `.env` exists, re-align `PHX_HOST`/`PHX_SCHEME` the same way it re-aligns `DATABASE_URL`, so re-running `deploy.sh` on a host that has since been put behind a domain self-corrects.
- **Post-domain runbook checklist:** promote `docs-site/ops/adding-a-domain.md` Step 3 to a `Makefile` target (`make domain-cutover DOMAIN=foo`) so it cannot be skipped.
- **Add a boot-time self-check:** in `Barkpark.Application.start/2`, log a warning if `PHX_HOST` resolves to a literal IPv4 address while `PHX_SCHEME == "https"` — an early signal that origin config is mis-shaped.
- **CI smoke:** after deploy, hit `/live/websocket` with a real browser `Origin` header and fail the job on 403. A single `curl` assertion would have caught this within a minute of the Phase 7 Track D cutover.

ROOT_CAUSE: production `/opt/barkpark/.env` still has `PHX_HOST=89.167.28.206` and no `PHX_SCHEME=https`, so Phoenix `check_origin` 403-rejects the LiveView WebSocket from `https://api.barkpark.cloud`, leaving every `phx-click` silently dead.
FIX: `/opt/barkpark/.env` → `PHX_HOST=api.barkpark.cloud` + `PHX_SCHEME=https`, then `systemctl restart barkpark.service` (no code change; matches `docs-site/ops/adding-a-domain.md` Step 3).
