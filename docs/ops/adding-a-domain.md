---
title: Adding a domain
nav_category: Ops
status: stub
---
<!-- doc-tier: agent | canonical-for: domain-tls-cutover | budget: 900tok -->

> **Caddy terminates TLS, not Phoenix.** It auto-issues/renews Let's Encrypt
> certs while Phoenix serves plain HTTP on loopback; `Plug.SSL` was rejected —
> terminate at the edge, forward `X-Forwarded-Proto`.

**Two estates, two hosts.** Measured 2026-09-02: `api.barkpark.cloud` (and the
apex, and `www`) resolves to `178.105.92.191` — the **Cloud control plane**
(`deploy/README.md`), not the pull-deployed CMS at `89.167.28.206`. Nothing in
the zone points at the CMS. Each step acts on one box; know which one first.

## Step 1 — DNS

`A` records for apex + `www` → the target box's IP (TTL 300). Verify:
`dig +short your-domain.example`.

## Step 2 — Caddy config

There is **no `:80 { reverse_proxy localhost:4000 }` block to replace.**
`deploy.sh` exits 2 without `DOMAIN` (its "Required: DOMAIN" guard) and its
"12. TLS (Caddy)" section writes a `$DOMAIN { … }` block — only when Caddy is
absent ("Caddy already installed — leaving its config untouched"), so prod's
multi-site Caddy was never written by it.

**Cloud-managed box: do not hand-edit.** Its Caddyfile opens `# Managed by bp
setup (cloud-4) — barkpark.cloud automatic TLS.` … `Do not edit by hand.`;
`renderCaddyfile`/`CaddySteps` (`internal/cli/setup/caddy.go`) rewrite it whole
on every provision, so an edit is clobbered. Change `CaddyOpts`, re-run.

Elsewhere, add the site block:

```caddy
your-domain.example, www.your-domain.example {
    encode zstd gzip
    reverse_proxy localhost:4000
    handle_errors { ... }  # verbatim: deploy/caddy/barkpark-maintenance.caddy
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
    header X-Content-Type-Options "nosniff"
    header Referrer-Policy "strict-origin-when-cross-origin"
}
```

`handle_errors` is **not optional** — it is the branded 503 + `Retry-After`
maintenance page (`MaintenanceHandler`, `internal/caddyfile/caddyfile.go`);
omit it and every restart shows a raw 502. Then `caddy validate --config
/etc/caddy/Caddyfile && systemctl reload caddy`.

## Step 3 — Phoenix env

In `/opt/barkpark/.env`: `PHX_SCHEME=https`, `PHX_HOST=your-domain.example`;
`systemctl restart barkpark.service`. `make domain-cutover DOMAIN=…` does this
from a workstation (backs up `.env`, updates, restarts, verifies HTTP +
websocket) — but `SSH_HOST` defaults to the CMS box; override it for any other.

## Step 4 — Let's Encrypt

Auto-issued/renewed by Caddy on first HTTPS request. Watch:
`journalctl -u caddy -f | grep -i certificate`.

## Step 5 — Firewall (owner-signed hardening, not a cutover step)

`deploy.sh` **opens** the app port — its "10. Firewall" step runs `ufw allow
"$APP_PORT"/tcp` — and measured 2026-09-02 both `89.167.28.206` and guerrilla
still answer on `:4000`. Only the managed path closes it: `ufwDenyAppPortStep`
(`ufw deny 4000`) ends `CaddySteps`, leaving `:443` alone public.

So `sudo ufw delete allow 4000/tcp` contradicts that `ufw allow` line and needs
owner sign-off; re-running `deploy.sh` reopens the port. If taken, verify bare
`:4000` times out and HTTPS still serves.

## Step 6 — `force_ssl` stays OFF (not a cutover step)

`api/config/prod.exs` keeps `force_ssl` commented out **by standing decision** —
Golden Rule #5 / Past Mistake #5 — with its Sobelow `Config.HTTPS` row
justified-baselined against `config/prod.exs` in `api/.sobelow-skips`
(task-f76e9b7b). Caddy already redirects `:80 → :443`, so a Phoenix-side
redirect buys nothing. **Finish the cutover at Step 5 and stop here.**

Turning it on is a separate, owner-sign-off change; all four must hold first:

1. `curl -sI https://your-domain.example/v1/data/query/production/post` → `200`
   (TLS live), and
2. the same URL over `http://` → `30x` to `https://` — Caddy, not Phoenix, owns
   the redirect.
3. No bare-HTTP ingress is left. The 7-day `http://89.167.28.206` block under
   Pitfalls is a **blocker**: `force_ssl` would 301 it to
   `https://89.167.28.206`, which has no certificate.
4. The Sobelow baseline row is re-fingerprinted in the same PR, or the security
   gate reds.

Only then uncomment the block `prod.exs` already carries. `rewrite_on:
[:x_forwarded_proto]` is mandatory — without it Phoenix sees `http` and
redirects forever. Skip `hsts: true` (Caddy emits HSTS at Step 2), then
`make rebuild`.

## Step 7 — Smoke test

Probe the domain you just cut over. Not `/api/schemas` — it answers
`Deprecation: true`, `Sunset: 2026-12-31`, successor `/v1/data/query` (measured
2026-09-02) — nor `/v1/schemas/<dataset>`, which is admin-token gated.

```bash
D=your-domain.example
curl -fsS "https://$D/v1/data/query/production/post?perspective=published" | head -c 200
curl -sI "https://$D/studio" | head -3   # 200, or 30x to /login when gated
```

## Pitfalls

- **HSTS: do NOT add `preload`** — hard to undo.
  `max-age=31536000; includeSubDomains` is the ceiling.
- **Let's Encrypt rate limit: 5 duplicate certs per 7 days.** Past 5, issuance
  fails — wait it out or use the staging CA
  (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`).
- **7-day bare-IP grace window.** The CMS still serves `http://89.167.28.206`
  on `:80` and `:4000` (measured 2026-09-02). Keep a transitional
  `http://89.167.28.206 { reverse_proxy localhost:4000 }` block ≥7 days
  post-cutover; drop it at zero bare-IP traffic. ACME HTTP-01 issuance *and*
  renewal need port 80 — keep the HTTP path until one renewal completes.

## Rollback

Snapshot first: `sudo cp -a /etc/caddy/Caddyfile
/etc/caddy/Caddyfile.pre-tls-$(date +%Y%m%d-%H%M%S)`. To revert, restore it and
`caddy validate && systemctl reload caddy` (graceful — `restart` drops
in-flight connections; use it only if reload fails). If Caddy is wedged, stop
it, restore, start, check `systemctl status caddy`. Neither survives the next
provision on a Cloud-managed box — fix `CaddyOpts` instead.

## Related

- `web/README.md` — Vercel demo; mixed-content caveat disappears after this
  TLS work.
