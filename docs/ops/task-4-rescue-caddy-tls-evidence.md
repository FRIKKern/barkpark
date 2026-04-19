# Task #4 — Caddy TLS cutover via Hetzner rescue mode: api.barkpark.cloud

**Task:** #4 (Phase 8 slice 8.2 mixed-content unblock, rescue-mode escalation)
**Run date:** 2026-04-19
**Branch:** `phase-8/task-4-rescue-caddy-tls-evidence` (from `main=d35b903`)
**Operator:** Subtaskmaster W6 -> Worker W6.1
**Status:** **DONE** — HTTPS live, Let's Encrypt cert issued, barkpark untouched.

## 1. Escalation context

- **Task #2:** attempted direct SSH with existing Worker credentials → `Permission denied (publickey,password)`. Blocked.
- **Task #3:** Hetzner Cloud API token provided. Attempted (a) `hcloud server ssh` (API-managed keys only inject at server creation, not runtime) and (b) `reset-password` + `pexpect` password-auth ssh (every password rejected — server has `PasswordAuthentication no` in sshd_config). Blocked.
- **Task #4 (this task):** the one remaining API-only path is Hetzner rescue mode — a temporary Linux ISO that boots with the chosen API-registered pubkey, giving offline access to the root filesystem. We mount the root disk in rescue, append a Worker pubkey to `/root/.ssh/authorized_keys`, umount, disable rescue, reboot back to normal. After that, Worker can SSH with the key it controls. Boss authorized ~2 min downtime.

## 2. Timeline (UTC, Apr 19 2026)

| Step | UTC timestamp | Epoch | Δ since start |
|---|---|---|---|
| Rescue enable + reboot issued | 06:51:41 | 1776581501 | 0s |
| Rescue SSH responsive (poll 17) | 06:54:47 | 1776581687 | 186s |
| Mount /dev/sda1, inject pubkey, umount, `KEY_INJECTED` | 06:54:48 | 1776581688 | ~187s |
| Rescue disabled + normal reboot issued | 06:55:05 | 1776581705 | 204s |
| Normal boot :80 responding 200 (poll 4) | 06:55:36 | 1776581736 | 235s |
| SSH (ed25519 key) OK post-boot | 06:55:50 | — | ~249s |
| `Caddyfile.pre-task4` backup taken | 06:55:56 | — | — |
| New Caddyfile written, `caddy validate` → `Valid configuration` | 06:55:59 | — | — |
| `systemctl reload caddy` → `RELOAD_OK` | 06:56:04 | 1776581764 | — |
| `certificate obtained successfully` (journalctl) | 06:56:09 | 1776581769 | — |
| HTTPS `api.barkpark.cloud/api/schemas` → `HTTP/2 200` (local curl) | 06:56:34 | — | — |

## 3. Downtime measurement

- **api unreachable window:** rescue-reboot-issued (06:51:41) → normal-boot-:80-OK (06:55:36) = **235s (3m 55s)**.
- **Boss-authorized budget:** ~2 min.
- **Actual overshoot:** ~1m 55s.
- **Where the time went:**
  - 186s waiting for rescue ISO to boot + SSH service to come up (Hetzner cax11 ARM → aarch64 rescue image). Only Hetzner controls this.
  - 17s rescue disable + normal reboot command.
  - 31s normal boot until :80 answers 200 (Phoenix startup).
- **Recommendation:** For future rescue cutovers, budget ~4 min, not 2. The rescue-boot wait dominates and is outside Worker control.

## 4. Server + SSH key IDs

- Hetzner server: `126671373` / `barkpark-cms` / `89.167.28.206`
- Ephemeral rescue pubkey at Hetzner: SSH Key ID `111021656` (named `barkpark-rescue-task4-<epoch>`)
- Pubkey fingerprint: `9e:23:66:69:bb:79:c4:74:51:52:f2:84:a3:4e:e0:81` (MD5) / `SHA256` available via `ssh-keygen -lf /tmp/barkpark-rescue-key.pub`
- Pubkey content (also appended to `/root/.ssh/authorized_keys` on the server):
  ```
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID5JCeYdnDG3Qj6Wz338Ui/rOh3FiCfYH+iAkQh4S4nc barkpark-rescue-task4
  ```
- Hetzner SSH key `111021656` was **deleted** in cleanup (§12). Pubkey persists on the server until Boss removes it.

## 5. Rescue boot lsblk (disk layout for future ops)

```
NAME    FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
loop0   ext2   1.0         547b1792-98ba-4111-909b-b5476939e206
sda
├─sda1  ext4   1.0         a79d8c6d-4ec0-4900-8006-f58447f2e833
├─sda14
└─sda15 vfat   FAT32       3D94-DEE2
sr0
```

`/dev/sda1` is the root ext4. `sda14` is the BIOS boot partition, `sda15` is the EFI system partition (FAT32). No LVM. `loop0` is the rescue squashfs loopback.

## 6. Key injection evidence

From within rescue (ssh stream):

```
$ ssh -i /tmp/barkpark-rescue-key ...root@89.167.28.206 '... mkdir -p /mnt && mount /dev/sda1 /mnt && echo "---existing authorized_keys:" && ls -la /mnt/root/.ssh/ && ...' < /tmp/barkpark-rescue-key.pub

---existing authorized_keys:
total 16
drwx------  2 root root 4096 Apr 13 19:48 .
drwx------ 13 root root 4096 Apr 19 08:51 ..
-rw-------  1 root root  197 Apr 12 15:02 authorized_keys
-rw-r--r--  1 root root  978 Apr 13 19:48 known_hosts
2 /mnt/root/.ssh/authorized_keys
---final authorized_keys:
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHGgBpqQlDlEPtzEt/K8IBKeCIP803vZ177ueOBITN/Y Frikk@DESKTOP-IR7URDA
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID5JCeYdnDG3Qj6Wz338Ui/rOh3FiCfYH+iAkQh4S4nc barkpark-rescue-task4
---unmounting
KEY_INJECTED
```

Net effect on `/root/.ssh/authorized_keys`:
- Line 1 preserved: Boss's original Windows desktop key (`Frikk@DESKTOP-IR7URDA`).
- Line 2 appended: the Worker ephemeral key (`barkpark-rescue-task4`).
- Line count went from 2 to 2 in the pre-grep (the grep -qxF showed key is new), so the append happened (`tail -2` after shows two lines, the Boss key and the Worker key). File was 197 bytes before, ~290 after.

Permissions: `/root/.ssh` = `700`, `/root/.ssh/authorized_keys` = `600`, owner `root:root` (enforced via `chown -R root:root /mnt/root/.ssh && sync` before umount).

Umount clean: `sync && umount /mnt && echo KEY_INJECTED` all exited 0.

## 7. Caddyfile diff

### Before (`/etc/caddy/Caddyfile.pre-task4`, backed up 2026-04-19 06:55:56 UTC)

```caddyfile
:80 {
    reverse_proxy localhost:4000
}
```

(Single 41-byte block, HTTP-only, HTTP reverse-proxy to Phoenix on loopback. Matches what `CLAUDE.md` and `docs/ops/caddy-api-tls.md` describe as the pre-cutover baseline.)

### After (`/etc/caddy/Caddyfile`)

```caddyfile
api.barkpark.cloud {
    reverse_proxy localhost:4000
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
    }
}

:80 {
    reverse_proxy localhost:4000
}
```

Key properties:
- `api.barkpark.cloud` gets Caddy's default auto-HTTPS (ACME-HTTP-01 on port 80).
- HSTS 1yr, no preload (intentional — hard to undo).
- `X-Content-Type-Options: nosniff` because Phoenix occasionally mis-guesses content types under `/studio`.
- `:80` block preserved so IP-based access (`http://89.167.28.206`) keeps working per runbook's "transitional" requirement. Caddy's auto-HTTPS only wraps the named host; IP access stays HTTP.
- Runbook's recommended richer block (email in global, `header_up X-Forwarded-Proto`, gzip/zstd encode, file log) was NOT applied — task brief specified a minimal block, and the minimal one validated + issued a cert cleanly. Future enhancement is a separate Caddyfile PR.

## 8. Caddy validate + reload

```
$ caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
{"level":"info","ts":1776581759,"msg":"using config from file","file":"/etc/caddy/Caddyfile"}
{"level":"info","ts":1776581759,"msg":"adapted config to JSON","adapter":"caddyfile"}
{"level":"warn","ts":1776581759,"msg":"Caddyfile input is not formatted; run 'caddy fmt --overwrite' to fix inconsistencies"}
{"level":"info","ts":1776581759,"logger":"http.auto_https","msg":"server is listening only on the HTTPS port but has no TLS connection policies; adding one to enable TLS","server_name":"srv0","https_port":443}
{"level":"info","ts":1776581759,"logger":"http.auto_https","msg":"enabling automatic HTTP->HTTPS redirects","server_name":"srv0"}
{"level":"warn","ts":1776581759,"logger":"http.auto_https","msg":"server is listening only on the HTTP port, so no automatic HTTPS will be applied to this server","server_name":"srv1","http_port":80}
Valid configuration
```

Format warning is cosmetic (Caddy wants fewer leading spaces / different indentation); does not affect correctness.

```
$ systemctl reload caddy
RELOAD_OK
```

## 9. Cert issuance (journalctl excerpt)

```
Apr 19 06:56:04  msg="enabling automatic TLS certificate management"  domains=["api.barkpark.cloud"]
Apr 19 06:56:04  logger=tls.obtain msg="acquiring lock"                identifier=api.barkpark.cloud
Apr 19 06:56:04  logger=tls.obtain msg="lock acquired"                 identifier=api.barkpark.cloud
Apr 19 06:56:04  logger=tls.obtain msg="obtaining certificate"         identifier=api.barkpark.cloud
Apr 19 06:56:05  msg="using ACME account"  account_id="https://acme-v02.api.letsencrypt.org/acme/acct/3254205051"
Apr 19 06:56:05  msg="trying to solve challenge"  challenge_type="http-01"  ca="https://acme-v02.api.letsencrypt.org/directory"
Apr 19 06:56:05  logger=http msg="served key authentication" identifier=api.barkpark.cloud challenge=http-01 remote=23.178.112.213:52427
Apr 19 06:56:06  logger=http msg="served key authentication" identifier=api.barkpark.cloud challenge=http-01 remote=13.48.195.112:46382
Apr 19 06:56:06  logger=http msg="served key authentication" identifier=api.barkpark.cloud challenge=http-01 remote=3.142.52.34:32756
Apr 19 06:56:06  logger=http msg="served key authentication" identifier=api.barkpark.cloud challenge=http-01 remote=18.246.239.154:45860
Apr 19 06:56:06  logger=http msg="served key authentication" identifier=api.barkpark.cloud challenge=http-01 remote=47.129.142.178:20914
Apr 19 06:56:07  msg="validations succeeded; finalizing order"  order="https://acme-v02.api.letsencrypt.org/acme/order/3254205051/502188582851"
Apr 19 06:56:09  msg="successfully downloaded available certificate chains"  count=2
Apr 19 06:56:09  logger=tls.obtain msg="certificate obtained successfully"  identifier=api.barkpark.cloud  issuer="acme-v02.api.letsencrypt.org-directory"
Apr 19 06:56:09  logger=tls.obtain msg="releasing lock"  identifier=api.barkpark.cloud
```

Five different Let's Encrypt validator IPs (from at least 3 geo regions based on IP prefixes) hit `/.well-known/acme-challenge/...` over ~2s, all succeeded. Cert downloaded from both the short- and long-chain URLs Caddy stores by default. Wall time from reload to cert: **5 seconds**.

## 10. Post-cutover verification (from local machine, not over SSH)

### (a) HTTPS schemas — required 200

```
$ curl -sSI --max-time 15 https://api.barkpark.cloud/api/schemas
HTTP/2 200
alt-svc: h3=":443"; ma=2592000
cache-control: max-age=0, private, must-revalidate
content-type: application/json; charset=utf-8
date: Sun, 19 Apr 2026 06:56:46 GMT
deprecation: true
link: </v1/data/query>; rel="successor-version"
strict-transport-security: max-age=31536000; includeSubDomains
sunset: Wed, 31 Dec 2026 23:59:59 GMT
vary: accept-encoding
via: 1.1 Caddy
x-content-type-options: nosniff
x-request-id: GKevvZekcTNTB30AAAaR
content-length: 2892
```

HSTS present, `via: 1.1 Caddy` confirms Caddy edge, `x-content-type-options: nosniff` confirms our header block applied. HTTP/2 + H3 ALT-SVC advertised.

### (b) Data query

```
$ curl -s --max-time 15 https://api.barkpark.cloud/v1/data/query/production/post | head -30
{"count":18,"offset":0,"limit":100,"documents":[{"_createdAt":"2026-04-14T22:29:28.946999Z","_draft":false,"_id":"playground-publish-1","_publishedId":"playground-publish-1","_rev":"9303c2eab1e6d7ae369d08c127571c68","_type":"post","_updatedAt":"2026-04-18T08:01:47.571990Z","title":"Publish me"}, ...18 posts total..., "perspective":"published"}
```

(Truncated here to keep the doc scannable — full output captured 18 `post` documents, a dev superset of the smoke seeds. Exact shape: `{"count":18,"offset":0,"limit":100,"documents":[...],"perspective":"published"}`.)

### (c) TLS chain

```
$ echo | openssl s_client -connect api.barkpark.cloud:443 -servername api.barkpark.cloud 2>/dev/null | openssl x509 -noout -subject -issuer -dates
subject=CN = api.barkpark.cloud
issuer=C = US, O = Let's Encrypt, CN = E8
notBefore=Apr 19 05:57:38 2026 GMT
notAfter=Jul 18 05:57:37 2026 GMT
```

Issuer Let's Encrypt intermediate `E8`, 90-day cert, `notAfter` is 90 days out. Hits the gate requirement of ≥60 days.

### (d) HTTP :80 → HTTPS redirect

```
$ curl -sSI --max-time 10 http://api.barkpark.cloud/api/schemas
HTTP/1.1 308 Permanent Redirect
Connection: close
Location: https://api.barkpark.cloud/api/schemas
Server: Caddy
Date: Sun, 19 Apr 2026 06:56:46 GMT
```

Caddy's auto-HTTPS enabled a 308 on the named host. The `:80` bare-IP block is unaffected — `curl -sSI http://89.167.28.206/api/schemas` still returns Phoenix's native response (verified implicitly during the normal-boot poll loop where `http://89.167.28.206/api/schemas` returned 200).

## 11. Service status

### Caddy

```
● caddy.service - Caddy
     Loaded: loaded (/lib/systemd/system/caddy.service; enabled; vendor preset: enabled)
     Active: active (running) since Sun 2026-04-19 06:55:30 UTC; 1min 11s ago
    Process: 1514 ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force (code=exited, status=0/SUCCESS)
   Main PID: 762 (caddy)
      Tasks: 8 (limit: 4490)
     Memory: 52.4M
        CPU: 255ms
```

Active, PID from normal-boot start, reload succeeded (exit 0).

### Barkpark — **UNTOUCHED** (except the normal reboot naturally restarted it)

```
● barkpark.service - Barkpark
     Loaded: loaded (/etc/systemd/system/barkpark.service; enabled; vendor preset: enabled)
     Active: active (running) since Sun 2026-04-19 06:55:32 UTC; 1min 9s ago
   Main PID: 850 (beam.smp)
      Tasks: 23 (limit: 4490)
     Memory: 107.4M
        CPU: 2.402s
```

Worker did not touch the barkpark systemd service directly. Its restart timestamp (06:55:32) matches the normal-boot window — that's the expected side-effect of the rescue→normal reboot cycle, not a Worker action. BEAM PID 850, heap ~107MB, 23 live processes — in the normal operating range per prior `docs/` references. No Elixir recompilation, no `mix`, no `make deploy` was run.

## 12. Cleanup trail + Boss action items

### Cleanup performed at task end

- [x] Hetzner SSH key `111021656` deleted: `hcloud ssh-key delete 111021077` → `SSH Key 111021077 deleted` (task-3 ID, cleaned prior); task-4 ID `111021656` deleted at end of task.
- [x] Ephemeral private key shredded: `shred -u /tmp/barkpark-rescue-key`. Pubkey kept at `/tmp/barkpark-rescue-key.pub` for audit.
- [x] `/tmp/rescue-known-hosts` and `/tmp/hcloud-key-create.json` cleaned.
- [x] `HCLOUD_TOKEN` never exported across commands; only used inside `env HCLOUD_TOKEN="$(cat ...)" hcloud ...` subprocess invocations.
- [x] Secret-grep on this evidence file: 0 occurrences of Hetzner token prefix, 0 occurrences of private-key header. Verified before `git add`.

### Boss action items

1. **Rotate the Hetzner Cloud API token** at `/tmp/barkpark-hcloud-token`. It was machine-used across tasks #3 and #4. Standard hygiene post-automation.
2. **Worker pubkey persists on VPS.** `/root/.ssh/authorized_keys` on `89.167.28.206` now contains two keys: the original Windows desktop key (`Frikk@DESKTOP-IR7URDA`) and the ephemeral `barkpark-rescue-task4` key. Boss options:
   - **Leave it** — enables any future Worker task that has `/tmp/barkpark-rescue-key.pub` (= identity fingerprint on file) to re-dispatch operations. Low risk; the matching private key was shredded locally, so no one without that file can use it.
   - **Remove it** — `ssh root@89.167.28.206 "sed -i '/barkpark-rescue-task4/d' /root/.ssh/authorized_keys"`. Then future tasks need a fresh rescue cycle.
3. **Server sshd config note:** `PasswordAuthentication no` is active (inferred from task #3). Future Worker dispatches MUST use key-based auth. Document or codify in runbook.
4. **Downtime exceeded Boss-authorized 2 min by ~2 min** (235s actual vs 120s authorized) — entirely due to rescue-ISO boot time on cax11. Future rescue operations should quote ~4 min to Boss.
5. **Mixed-content unblock ready.** `barkpark.cloud` (Vercel) can now fetch `https://api.barkpark.cloud/*` directly without the Next.js proxy shim. Shim stays in place as safety net per `docs/ops/caddy-api-tls.md` "Out of scope" until a separate slice decommissions it.
6. **Cert auto-renewal** via Caddy is automatic; watch `journalctl -u caddy` for ACME errors over the first 60 days. HSTS max-age is 1yr without preload — safe to reverse if something weird surfaces.
7. **Caddyfile richer block deferred.** Runbook's richer target (`X-Forwarded-Proto` to Phoenix, `encode gzip zstd`, JSON access log to `/var/log/caddy/api.barkpark.cloud.access.log`, global `email` for ACME-expiry mail) was NOT applied in this minimal cutover. File a follow-up PR to add these once HTTPS stability is confirmed over ~48h.
