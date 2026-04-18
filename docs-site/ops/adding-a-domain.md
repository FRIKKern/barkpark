---
title: Adding a domain
nav_category: Ops
status: stub
---

> Part of Track A docs-site IA — Ops category. Stub: written while
> `barkpark.dev` DNS does NOT exist. The Vercel demo currently runs over
> HTTPS talking to an HTTP API via server-side proxy. Follow these steps
> once you register a domain pointing at `89.167.28.206`.

## Step 1 — DNS

Register a domain. Add an `A` record pointing at `89.167.28.206` for the apex
(and typically `www` too):

| Host  | Type | Value            | TTL |
|-------|------|------------------|-----|
| `@`   | A    | `89.167.28.206`  | 300 |
| `www` | A    | `89.167.28.206`  | 300 |

Verify propagation: `dig +short your-domain.example`.

## Step 2 — Caddy config diff

Edit `/etc/caddy/Caddyfile` on the prod box.

Current HTTP-only block:

```caddy
:80 {
    reverse_proxy localhost:4000
}
```

New HTTPS block (Caddy auto-issues a Let's Encrypt cert on first request):

```caddy
your-domain.example, www.your-domain.example {
    encode zstd gzip
    reverse_proxy localhost:4000

    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
    header X-Content-Type-Options "nosniff"
    header Referrer-Policy "strict-origin-when-cross-origin"
}
```

Validate + reload:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

## Step 3 — Phoenix env

Edit `/opt/barkpark/.env`:

```bash
PHX_SCHEME=https
PHX_HOST=your-domain.example
```

Restart the app:

```bash
systemctl restart barkpark.service
```

## Step 4 — Let's Encrypt

Caddy auto-issues and renews the cert on first HTTPS request. No manual cert
work. Watch for `certificate obtained`:

```bash
journalctl -u caddy -f | grep -i certificate
```

## Step 5 — Firewall

Close the direct Phoenix port so Caddy is the only ingress:

```bash
sudo ufw delete allow 4000/tcp
sudo ufw status
```

Verify from a laptop that `http://89.167.28.206:4000` times out while
`https://your-domain.example` still serves.

## Step 6 — Re-enable `force_ssl` in `api/config/prod.exs`

Uncomment:

```elixir
config :barkpark, BarkparkWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]
```

The `rewrite_on: [:x_forwarded_proto]` option trusts the Caddy-set
`X-Forwarded-Proto` header — this is what avoids the 301-loop burn documented
in `/home/doey/GitHub/barkpark/CLAUDE.md` → "Past Mistakes" #5. Without it,
Phoenix sees the incoming scheme as `http` (because Caddy terminates TLS) and
redirects back to HTTPS forever.

Rebuild + restart:

```bash
make rebuild
```

## Step 7 — Smoke test

```bash
curl -I https://your-domain.example/healthz                 # expect 200
curl -sL "https://your-domain.example/v1/data/query/production/post?perspective=published" | head -50
```

Also check from the demo app:

```bash
curl -I "https://<vercel-deployment>/api/barkpark/query/post"  # expect 200
```

## Related

- `apps/demo/README.md` — mixed-content caveat that disappears once this is
  done.
- `.doey/plans/research/w4-phase7-hosted-demo.md` §5 — design rationale for
  the Caddy TLS path.
- `/home/doey/GitHub/barkpark/CLAUDE.md` — the golden rule about never
  enabling `force_ssl` without verified `X-Forwarded-Proto` trust.
