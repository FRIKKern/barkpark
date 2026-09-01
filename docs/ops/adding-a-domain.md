---
title: Adding a domain
nav_category: Ops
status: stub
---
<!-- doc-tier: agent | canonical-for: domain-tls-cutover | budget: 900tok -->

> **Why Caddy terminates TLS (not Phoenix):** Caddy auto-issues and renews
> Let's Encrypt certs while Phoenix keeps serving plain HTTP on loopback;
> Phoenix-native TLS (`Plug.SSL` + cowboy) was deliberately rejected —
> terminate at the edge and forward `X-Forwarded-Proto`.

Stub: `barkpark.dev` DNS does not exist yet. Follow once a domain points at
`89.167.28.206`.

## Step 1 — DNS

`A` records for apex + `www` → `89.167.28.206` (TTL 300). Verify:
`dig +short your-domain.example`.

## Step 2 — Caddy config

Replace the `:80 { reverse_proxy localhost:4000 }` block in
`/etc/caddy/Caddyfile`:

```caddy
your-domain.example, www.your-domain.example {
    encode zstd gzip
    reverse_proxy localhost:4000

    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
    header X-Content-Type-Options "nosniff"
    header Referrer-Policy "strict-origin-when-cross-origin"
}
```

Then `caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`.

## Step 3 — Phoenix env

In `/opt/barkpark/.env`: `PHX_SCHEME=https`, `PHX_HOST=your-domain.example`.
Then `systemctl restart barkpark.service`. From a workstation,
`make domain-cutover DOMAIN=your-domain.example` does all of this step
(backs up `.env`, updates, restarts, verifies HTTP + websocket).

## Step 4 — Let's Encrypt

Auto-issued/renewed by Caddy on first HTTPS request. Watch:
`journalctl -u caddy -f | grep -i certificate`.

## Step 5 — Firewall

`sudo ufw delete allow 4000/tcp` so Caddy is the only ingress. Verify the
bare `:4000` port times out and HTTPS still serves.

## Step 6 — `force_ssl` stays OFF (not a cutover step)

`api/config/prod.exs` keeps `force_ssl` commented out **by standing decision** —
Golden Rule #5 / Past Mistake #5 — and its Sobelow `Config.HTTPS` row is
justified-baselined against `config/prod.exs` in `api/.sobelow-skips`
(task-f76e9b7b). Caddy already redirects `:80 → :443`, so a Phoenix-side
redirect buys nothing. **Finish the cutover at Step 5 and stop here.**

Turning it on is a separate, owner-sign-off change. All four must hold first:

1. `curl -sI https://your-domain.example/api/schemas` returns `200` — TLS live.
2. `curl -sI http://your-domain.example/api/schemas` returns `30x` to
   `https://` — Caddy, not Phoenix, owns the redirect.
3. No bare-HTTP ingress is left. The 7-day `http://89.167.28.206` block under
   Pitfalls is a **blocker**: `force_ssl` would 301 it to
   `https://89.167.28.206`, which has no certificate.
4. The Sobelow baseline row is re-fingerprinted in the same PR, or the security
   gate reds.

Only then uncomment the block `prod.exs` already carries. `rewrite_on:
[:x_forwarded_proto]` is mandatory — without it Phoenix sees `http` and
redirects forever. Skip `hsts: true`; Caddy emits HSTS at Step 2. Then
`make rebuild`.

## Step 7 — Smoke test

```bash
curl -I https://your-domain.example/api/schemas    # expect 200 (public)
curl -fsSL "https://your-domain.example/v1/data/query/production/post?perspective=published"
```

## Pitfalls (from the 2026 `api.barkpark.cloud` cutover)

- **HSTS: do NOT add `preload`** — preload is hard to undo.
  `max-age=31536000; includeSubDomains` is the ceiling.
- **Let's Encrypt rate limit: 5 duplicate certs per 7 days.** Past 5,
  issuance fails — wait it out or use the staging CA
  (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`).
- **7-day bare-IP grace window.** Keep a transitional
  `http://89.167.28.206 { reverse_proxy localhost:4000 }` block at least
  7 days post-cutover; remove only at zero bare-IP traffic. ACME HTTP-01
  issuance *and renewal* need port 80 — keep the HTTP path until one renewal
  completes (~30–60 days).

## Rollback (two tiers)

Snapshot first — the mandatory rollback anchor:
`sudo cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-tls-$(date +%Y%m%d-%H%M%S)`

- **Tier 1 — revert Caddyfile (~30 s):** restore snapshot, `caddy validate`,
  `systemctl reload caddy` (graceful; `restart` only if reload fails — it
  drops in-flight connections).
- **Tier 2 — nuclear (Caddy wedged):** `systemctl stop caddy`, restore
  snapshot, `systemctl start caddy`, check `systemctl status caddy`.

## Related

- `web/README.md` — Vercel demo; mixed-content caveat disappears after this
  TLS work.
- `CLAUDE.md` Golden Rule #5 + `api/config/prod.exs` — `force_ssl` is off by
  decision; Step 6 does not override them.
