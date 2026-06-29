<!-- doc-tier: human | canonical-for: go-live-guide | budget: 1800tok -->
# Go live — a public Barkpark in ~5 commands

From nothing to `https://your-host/studio` with working CLI login. Every command here is run top-to-bottom; nothing is skipped. Each step says what it does and how to confirm it worked before moving on.

You need: a domain (or subdomain) you control DNS for, an SSH key, and a server (or a Hetzner account to make one). The whole thing takes ~20–35 min — almost all of it the one-time Erlang/Elixir compile on the box.

## 1 · A server (any Ubuntu 22.04+ box)

Already have one? Skip to step 2 with its public IP. To make one on Hetzner with the `hcloud` CLI:

```bash
hcloud server create --name myapp --type cx23 --location hel1 \
  --image ubuntu-24.04 --ssh-key <your-key-name>
# → note the IPv4 it prints, e.g. 203.0.113.10
```

`cx23` (2 vCPU / 4 GB) is the smallest that builds comfortably. ARM `cax*` is cheaper when in stock. **Confirm:** `ssh root@<IP> 'echo ok'` returns `ok`.

## 2 · Point DNS at the box

Create an **A record** for your hostname → the server IP, at whatever hosts your DNS. Example with Hetzner Cloud DNS (`hcloud zone`, same token as the server):

```bash
hcloud zone rrset set-records <your-zone> myapp A --record <IP>
hcloud zone rrset change-ttl  <your-zone> myapp A --ttl 300
```

**Confirm** it resolves on the authoritative nameserver (don't wait on your laptop's cache):

```bash
dig +short @<a-nameserver-for-your-zone> myapp.example.com
# → <IP>
```

TLS (next step) needs this resolving publicly, so do it before — or right after — the deploy.

## 3 · Install Barkpark + TLS (one run)

Copy `deploy.sh` to the box and run it **as a file** — not piped over stdin (the Erlang build reads stdin and would truncate a `ssh '… bash -s' < deploy.sh` pipe):

```bash
scp deploy.sh root@<IP>:/root/
ssh root@<IP> "DOMAIN=myapp.example.com BARKPARK_SEED_PROFILE=clean bash /root/deploy.sh"
```

- `DOMAIN` is the **public hostname, never an IP** — Phoenix whitelists exactly one host+scheme; an IP here makes the Studio websocket 403 (`docs/ops/studio-nav-bug-2026-04-19.md`).
- `BARKPARK_SEED_PROFILE=clean` seeds papers + media (not the demo dataset) **and mints an admin token**, printed once at the end.

`deploy.sh` installs Postgres, Erlang/Elixir, Go, builds Barkpark, generates all required secrets (`SECRET_KEY_BASE`, `BARKPARK_CLOAK_KEY`, `PREVIEW_JWT_SECRET`), starts the systemd service, and — for an `https` hostname on a fresh box — installs **Caddy**, which auto-issues a Let's Encrypt cert the moment your DNS resolves. It never touches an existing Caddy install, so prod is safe.

**Confirm** the final banner shows `Live: https://myapp.example.com/studio` and an **admin token** — copy it now, it is shown once.

## 4 · Log in from your machine

The banner prints this exact line (with your token):

```bash
bp setup --target connect --server https://myapp.example.com --token bp_admin_…
```

**Confirm:** `✓ connected … as admin`. Then `bp capabilities` and open `https://myapp.example.com/studio`.

> Brand-new DNS can be negative-cached on your laptop for a few minutes even after it resolves publicly. If `bp` can't connect but `dig @1.1.1.1 myapp.example.com` returns the IP, wait it out or test from another network — the server is fine.

## Verify the whole chain

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://myapp.example.com/api/schemas   # 200
curl -sI https://myapp.example.com | grep -i ^server                              # Caddy
bp capabilities | grep auth_tier                                                  # admin
```

## Updating & ops

- **Update:** `ssh root@<IP>`, then `cd /opt/barkpark && git pull` — the post-pull hook rebuilds and restarts.
- **Logs / health:** `make logs`, `make status` on the box.
- Production runbook (clean rebuilds, the `_build` rule, domain cutover): [`PROD_OPS.md`](../ops/PROD_OPS.md).

## If a step fails

| Symptom | Cause → fix |
|---|---|
| Deploy stops right after "Installed erlang" | The script was piped over stdin. Use `scp` + `bash /root/deploy.sh` (step 3), not `ssh '… bash -s' < deploy.sh`. |
| Boot raises `BARKPARK_CLOAK_KEY`/`PREVIEW_JWT_SECRET is not set` | Old `deploy.sh`. Pull latest — it generates both. |
| `curl https://host` → `000`, Caddy log shows `NXDOMAIN` | DNS not resolving yet. Confirm step 2, then `ssh root@<IP> systemctl restart caddy` to retry issuance immediately. |
| Studio loads but clicks do nothing (websocket 403) | `DOMAIN` was an IP. Re-run with the public hostname. |
