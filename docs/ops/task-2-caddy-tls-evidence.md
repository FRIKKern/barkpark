# Task #2 — Caddy TLS Evidence: api.barkpark.cloud

**Task:** #2 (Phase 8 slice 8.2 mixed-content unblock)
**Run date:** 2026-04-19
**Branch:** `phase-8/task-2-caddy-tls-evidence` (from `main=d35b903`)
**Operator:** Subtaskmaster W6 -> Worker W6.1
**Status:** **BLOCKED** on SSH auth to prod VPS.

## 1. Pre-cutover state (Phase 1 test)

```
$ curl -sSI --max-time 10 https://api.barkpark.cloud/
curl: (7) Failed to connect to api.barkpark.cloud port 443 after 48 ms: Couldn't connect to server
---EXIT-A: 7
```

```
$ curl -sSI --max-time 10 http://api.barkpark.cloud/
HTTP/1.1 302 Found
Cache-Control: max-age=0, private, must-revalidate
Content-Length: 84
Content-Security-Policy: base-uri 'self'; frame-ancestors 'self';
Content-Type: text/html; charset=utf-8
Date: Sun, 19 Apr 2026 06:20:47 GMT
Location: /studio/production
Referrer-Policy: strict-origin-when-cross-origin
Vary: accept-encoding
Via: 1.1 Caddy
X-Content-Type-Options: nosniff
X-Permitted-Cross-Domain-Policies: none
X-Request-Id: GKetxtsVPunAnf4AAtpB
---EXIT-B: 0
```

```
$ curl -sSI --max-time 10 https://api.barkpark.cloud/api/schemas
curl: (7) Failed to connect to api.barkpark.cloud port 443 after 2 ms: Couldn't connect to server
---EXIT-C: 7
```

**Interpretation:** **needs-cutover.**
- HTTP (port 80) works: Caddy is live (`Via: 1.1 Caddy`), DNS points correctly, Phoenix responds with a 302 to `/studio/production`.
- HTTPS (port 443) refuses TCP connection — Caddy has no vhost on `:443`, no cert issued. Matches runbook "current" baseline (HTTP-only `:80` block) exactly.
- No `api.barkpark.cloud`-specific block yet; Phoenix-wide 302 redirect is the default root handler responding to any Host.

## 2. DNS verification

```
$ dig api.barkpark.cloud +short
89.167.28.206

$ dig api.barkpark.cloud A +short @1.1.1.1
89.167.28.206
```

Both system resolver and Cloudflare 1.1.1.1 agree: `api.barkpark.cloud` → `89.167.28.206`. DNS is not the blocker.

## 3. Caddyfile diff (NOT APPLIED — SSH blocked)

Could not read current Caddyfile or write new one; SSH authentication to `root@89.167.28.206` failed before any remote action. Runbook-specified target configuration documented here for reference so Boss can apply manually:

```caddyfile
{
  email ops@barkpark.cloud
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

http://89.167.28.206 {
  reverse_proxy localhost:4000
}
```

## 4. Cert issuance journal

N/A — cutover not applied.

## 5. Post-cutover verification

N/A — cutover not applied. Pre-cutover probes in §1 confirm this is the "before" state.

## 6. Service status

Cannot read remote systemd status without SSH. From external probe: Phoenix is clearly up (HTTP 302 with `Via: 1.1 Caddy` on port 80 — Caddy reached Phoenix on `localhost:4000`), and Caddy is running on port 80. Port 443 is closed (TCP refused — not timed out — so the host is reachable but nothing is listening on 443).

## 7. Next-step gotchas for Boss

- **SSH key for Worker needs authorization on `root@89.167.28.206`** before a Worker can execute Phase 2. Current state: `Permission denied (publickey,password).` Options:
  1. Boss runs the runbook manually (the "Boss manual steps" section of `docs/ops/caddy-api-tls.md` is written exactly for this).
  2. Boss installs the Worker's public key under `/root/.ssh/authorized_keys` (or creates a dedicated deploy user) and re-dispatches this task.
- **DNS is already correct** — no registrar work needed. `api.barkpark.cloud` → `89.167.28.206` confirmed from two resolvers.
- **Port 80 / 443 on Hetzner firewall.** Port 80 is definitely open (HTTP curl succeeded). Port 443 TCP is refused, which can mean either (a) nothing listens (likely — Caddy has no `:443` vhost) or (b) firewall drop. Boss should visually confirm 443 is allowed in the Hetzner Cloud Console → Firewalls tab before applying, since Let's Encrypt HTTP-01 also needs port 80 open (already verified).
- **When applied, the Caddyfile in §3 gives:**
  - Auto-issued Let's Encrypt cert via HTTP-01.
  - HSTS (1yr, no preload).
  - Gzip + Zstd compression.
  - `X-Forwarded-Proto` to Phoenix so a later `force_ssl` flip won't loop.
  - Transitional `http://89.167.28.206` block so in-flight SDK clients keep working for 7 days.
- **Rollback anchor:** snapshot `/etc/caddy/Caddyfile.pre-tls-YYYYMMDD-HHMMSS` per runbook step 1 BEFORE editing.
- **Do NOT touch barkpark systemd service** during cutover — only Caddy reload is needed. Barkpark stays Active the whole time.

## 8. Blockers / caveats

**Primary blocker: SSH authentication denied.**

```
$ ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@89.167.28.206 'hostname && uname -a'
Permission denied, please try again.
Permission denied, please try again.
root@89.167.28.206: Permission denied (publickey,password).
---EXIT: 255
```

Task brief said "Boss pre-authorized ssh to 89.167.28.206 for this task only," but the authentication actually failed: no key accepted, and password auth fell through three attempts then denied. Per task HARD STOP condition #1 (`SSH auth fails -> STOP ... do NOT retry`), stopped immediately after the single attempt.

No remote state was modified. No Caddyfile edited, no backup made, no systemctl action taken. Barkpark systemd remains untouched (it was untouched before and it remains so).

All pre-cutover probes captured above match the runbook's "current" baseline, so once SSH is unblocked the Phase 2 steps should apply cleanly against the state that was observed today.
