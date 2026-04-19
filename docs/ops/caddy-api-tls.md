# Caddy TLS cutover for `api.barkpark.cloud`

**Status:** Runbook. Boss-executed. No agent ever ssh's the prod box.
**Owner:** Boss (manual prod-side execution).
**Resolves blocker:** §13.C B5 — Vercel HTTPS → Phoenix HTTP mixed-content. After this cutover `barkpark.cloud` can fetch `https://api.barkpark.cloud/*` directly from the browser, and the Next.js API-proxy shim at `apps/demo/app/api/barkpark/*` becomes optional (we keep it in place during the transition as a safety net).
**Supersedes:** the production hostname `http://89.167.28.206:4000` stays reachable during transition but is marked deprecated.

---

## Why

Right now Phoenix listens on port 4000 over plain HTTP behind Caddy (Caddy reverse-proxies port 80 → `localhost:4000`). `CLAUDE.md` notes `force_ssl` is disabled in `prod.exs` because prior attempts caused 301 redirect loops when no cert was present. The 1.0 launch moves `apps/demo` to `https://barkpark.cloud` on Vercel, and modern browsers block mixed-content fetches from HTTPS origins to HTTP backends. Two workable fixes exist:

1. **Vercel-side proxy** — already shipped in Phase 7D as `apps/demo/app/api/barkpark/[...path]/route.ts`. Extra hop; works today; keeps the backend on plain HTTP.
2. **Terminate HTTPS at Caddy for `api.barkpark.cloud`** (this doc). Removes the proxy hop, makes direct browser fetches from `barkpark.cloud` legal, enables SDK consumers in the wild to point at `https://api.barkpark.cloud` without a proxy.

We do **both**: TLS termination here becomes canonical; the Next.js proxy stays as a fallback for any route that breaks post-cutover. The Vercel-side proxy is deleted in a follow-up PR (not in this slice).

## Preconditions

Check these BEFORE touching the Caddyfile. Any `no` = stop.

| Check | How | Expected |
|---|---|---|
| DNS A record `api.barkpark.cloud` → `89.167.28.206` | `dig +short api.barkpark.cloud A` (from any machine) | `89.167.28.206` |
| Port 80 reachable from internet | `curl -sS -o /dev/null -w '%{http_code}\n' http://89.167.28.206/` | Any HTTP response, not timeout |
| Port 443 reachable from internet | `curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 https://89.167.28.206/` or `nc -zv 89.167.28.206 443` | TCP open (the TLS handshake will fail until Caddy has a cert; that's fine) |
| Hetzner firewall / security group allows 80 + 443 | Hetzner Cloud Console → server cax11 → Firewalls tab | Rules present for TCP/80 and TCP/443 |
| Caddy version on prod | `caddy version` on prod box (during manual step) | ≥ v2.7.x (auto-HTTPS supported in all modern versions; we want a recent one) |
| Phoenix listens only on `localhost:4000` | `ss -tlnp \| grep 4000` on prod box | Bound to `127.0.0.1:4000` (not `0.0.0.0`) — unchanged by this work |
| Email for Let's Encrypt registered | Set `email` directive in Caddyfile global block (Boss picks address; used for renewal warnings) | Valid mailbox Boss reads |

If `dig` shows the old IP or NXDOMAIN, create the A record at the `barkpark.cloud` registrar FIRST, wait for TTL to expire, re-check. Do not proceed until it resolves.

## Caddyfile diff

**Current** (`/etc/caddy/Caddyfile` — HTTP-only, bare-IP or default host):

```caddyfile
:80 {
  reverse_proxy localhost:4000
}
```

(If the existing file uses a hostname or has extra directives, adjust accordingly — the snippet above is the minimum assumed shape from `CLAUDE.md`.)

**Proposed** (auto-HTTPS for `api.barkpark.cloud`, keep HTTP on the bare IP as a transitional fallback):

```caddyfile
{
  email ops@barkpark.cloud
  # Auto-HTTPS is ON by default. No explicit ACME config needed.
  # Uncomment for a staging issuance during validation:
  # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

api.barkpark.cloud {
  reverse_proxy localhost:4000 {
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For  {remote_host}
    header_up Host             {host}
  }

  encode gzip zstd

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options    "nosniff"
    Referrer-Policy           "strict-origin-when-cross-origin"
  }

  log {
    output file /var/log/caddy/api.barkpark.cloud.access.log {
      roll_size 50mb
      roll_keep 5
    }
    format json
  }
}

# Transitional: keep HTTP on bare IP reachable while DNS + clients migrate.
# Remove this block 7 days after cutover verified successful.
http://89.167.28.206 {
  reverse_proxy localhost:4000
}
```

Key properties:

- `api.barkpark.cloud` uses Caddy's default auto-HTTPS: ACME-HTTP-01 challenge on port 80, cert stored under `/var/lib/caddy` (default).
- `X-Forwarded-Proto` is forwarded so Phoenix sees the original `https` scheme; this is what eventually lets us re-enable `force_ssl` in `prod.exs` without redirect loops.
- HSTS max-age is 1 year. Do **not** add `preload` until we're sure we want it forever (HSTS preload is hard to undo).
- The bare-IP `:80` route is preserved so in-flight clients pointing at `http://89.167.28.206:4000` via the old Caddy route continue working during cutover.

**Phoenix config note (NOT part of this slice):** once the TLS terminator is stable, a follow-up PR should set `force_ssl: [hsts: false, rewrite_on: [:x_forwarded_proto]]` in `api/config/prod.exs`. Keeping it disabled for now is deliberate — `CLAUDE.md` Golden Rule #5 warns against surprise redirect loops.

## Boss manual steps

Execute in order on the prod box. Abort and roll back on any unexpected output.

```sh
# 0. Before ssh'ing, from a dev machine:
dig +short api.barkpark.cloud A
# Expected: 89.167.28.206

# Then ssh:
ssh root@89.167.28.206

# 1. Snapshot existing config — mandatory rollback anchor.
sudo cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-tls-$(date +%Y%m%d-%H%M%S)
ls -l /etc/caddy/Caddyfile.pre-tls-*

# 2. Edit the Caddyfile (vi/nano) to match the "Proposed" block above.
#    Replace the entire contents. Do not leave the old ":80 { ... }" block
#    if it conflicts; the transitional `http://89.167.28.206` block replaces it.

# 3. Validate syntax BEFORE reloading. Caddy lints offline.
sudo caddy validate --config /etc/caddy/Caddyfile
# Expected: "Valid configuration" (any error → fix and re-validate; do NOT reload)

# 4. Create log dir if absent (first time only).
sudo mkdir -p /var/log/caddy && sudo chown caddy:caddy /var/log/caddy

# 5. Reload Caddy (graceful; zero-downtime).
sudo systemctl reload caddy
# If reload is not supported on this systemd unit, use:
# sudo caddy reload --config /etc/caddy/Caddyfile
# NEVER restart (systemctl restart caddy) unless reload fails — restart drops in-flight connections.

# 6. Watch the cert issuance. First request triggers ACME-HTTP-01.
sudo journalctl -u caddy -f --no-pager
# In another terminal (or after backgrounding), probe:
curl -sS -I https://api.barkpark.cloud/api/schemas
# Expected: HTTP/2 200 (or 401 if auth required; the point is TLS handshake succeeded)
# If you see "SSL_ERROR_SYSCALL" or "self-signed", re-check journalctl for ACME errors.

# 7. Smoke-test end-to-end.
curl -sS https://api.barkpark.cloud/api/schemas | head -c 200
curl -sS https://api.barkpark.cloud/v1/data/query/production/post | head -c 200
curl -sS -o /dev/null -w '%{http_code}\n' https://api.barkpark.cloud/
# Expect non-5xx on all three. Any 5xx or curl: (7) → roll back (see below).

# 8. Verify HSTS + HTTP/2.
curl -sS -I https://api.barkpark.cloud/ | grep -iE 'strict-transport|http/'

# 9. From a Vercel preview deploy (or any dev machine), verify mixed-content is gone:
#    Hit https://<vercel-preview>.vercel.app/blog with devtools open. Network tab should
#    show no blocked requests to http://89.167.28.206.
```

When all smoke tests pass, update DNS for `api.barkpark.cloud` if a CNAME migration is still pending, then announce to the Subtaskmaster that cutover is complete.

## Verification checklist

- [ ] `dig +short api.barkpark.cloud A` → `89.167.28.206`
- [ ] `curl -sSI https://api.barkpark.cloud/` → `HTTP/2` and `strict-transport-security` header present
- [ ] `curl -sS https://api.barkpark.cloud/api/schemas` returns JSON (not HTML error, not 301)
- [ ] `curl -sSI http://api.barkpark.cloud/` → `301` redirecting to `https://` (Caddy does this automatically)
- [ ] Phoenix journal (`journalctl -u barkpark -f`) shows requests arriving with `x-forwarded-proto: https`
- [ ] No 5xx spike in Uptime Kuma for the first 30 minutes after reload
- [ ] Browser load of `https://barkpark.cloud` (staging Vercel) shows no mixed-content warnings

## Rollback

Two rollback tiers. Pick the minimum that restores service.

### Tier 1 — Revert Caddyfile (30 seconds)

```sh
ssh root@89.167.28.206
# Find the snapshot from step 1:
ls -lt /etc/caddy/Caddyfile.pre-tls-* | head -1
# Restore:
sudo cp -a /etc/caddy/Caddyfile.pre-tls-YYYYMMDD-HHMMSS /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
# Verify plain HTTP still proxies:
curl -sS -o /dev/null -w '%{http_code}\n' http://89.167.28.206/api/schemas
# Expected: 200 or the pre-existing status
```

### Tier 2 — Nuclear (if Caddy is wedged)

```sh
sudo systemctl stop caddy
sudo cp -a /etc/caddy/Caddyfile.pre-tls-YYYYMMDD-HHMMSS /etc/caddy/Caddyfile
sudo systemctl start caddy
sudo systemctl status caddy --no-pager | head -30
```

During Tier 1 or Tier 2 rollback, the Vercel-side proxy (`apps/demo/app/api/barkpark/*`) continues to work because it talks to Phoenix over the private loopback via the Hetzner IP. Site stays up.

## Known pitfalls

- **Certificate issuance rate limit.** Let's Encrypt caps 5 duplicate certs per 7 days. If you thrash the cutover more than 5 times, Caddy will fail to issue — either wait out the window or use the staging ACME CA (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`) for practice runs.
- **Phoenix `check_origin`.** If Phoenix rejects WebSocket upgrades because the origin is now `https://barkpark.cloud` instead of the old IP, `api/config/prod.exs` must be updated. Out of scope for this slice; file a 1.0.1 ticket if it bites.
- **Caddy auto-HTTPS needs port 80 for HTTP-01 challenge.** Do not remove the transitional `http://89.167.28.206` block until cert renewal has completed at least once (typically 30–60 days in). Renewal also uses port 80.
- **Mixed content from other origins.** If `apps/demo` hardcodes `http://89.167.28.206` anywhere (env-var leak, hardcoded string, doc snippet), it will still break under HTTPS. Grep `apps/demo/` for the old IP before declaring done.
- **Grace window for clients on the old URL.** The transitional `http://89.167.28.206` block stays for **7 days minimum** after cutover so any SDK pointed at the old origin keeps working. Remove in a follow-up commit once telemetry confirms zero traffic on the bare-IP route.

## Out of scope

- Phoenix-native TLS (via `Plug.SSL` + cowboy). We terminate at Caddy; Phoenix keeps serving HTTP on loopback.
- Re-enabling `force_ssl` in `prod.exs`. Follow-up PR once `X-Forwarded-Proto` is confirmed flowing.
- Domain-wide HTTPS for `barkpark.cloud` apex — that is owned by Vercel and lives in `docs/ops/vercel-dns-connect.md`.
- Removing the Next.js proxy at `apps/demo/app/api/barkpark/*`. Keep as safety net; drop in a follow-up PR.
