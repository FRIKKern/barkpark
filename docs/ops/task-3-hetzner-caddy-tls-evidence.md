# Task #3 — Caddy TLS via Hetzner Cloud API

**Task:** #3 (Phase 8 slice 8.2 mixed-content unblock, auth recovery via hcloud API)
**Run date:** 2026-04-19
**Branch:** `phase-8/task-3-hetzner-caddy-tls-evidence` (from `main=d35b903`)
**Operator:** Subtaskmaster W6 -> Worker W6.1
**Status:** **BLOCKED** — both `hcloud server ssh` and `reset-password` recovery paths failed.

## 1. Context & escalation path

Task #2 blocked on Worker SSH pubkey not being authorized on `root@89.167.28.206`.
Boss provisioned a Hetzner Cloud API token at `/tmp/barkpark-hcloud-token` and dispatched
task #3 to automate auth recovery via the Hetzner API. This evidence doc captures the
automation attempt end-to-end and documents why both recovery options failed.

No remote state was modified beyond a `reset-password` action that Boss must now address
(see §10 Boss action items).

## 2. hcloud CLI install

Already installed locally:

```
$ which hcloud
/home/doey/.local/bin/hcloud

$ hcloud version
hcloud 1.62.0
```

No install step needed.

## 3. Server identification

Token verified; server present:

```
$ env HCLOUD_TOKEN="$(cat /tmp/barkpark-hcloud-token)" hcloud server list -o "columns=id,name,ipv4,status"
ID          NAME           IPV4              STATUS
125203742   doey-server    204.168.223.106   running
126671373   barkpark-cms   89.167.28.206     running
```

| ID | Name | IPv4 | Status |
|---|---|---|---|
| 126671373 | barkpark-cms | 89.167.28.206 | running |

## 4. SSH key registration

Generated ephemeral ed25519 keypair locally, then registered pubkey with the Hetzner
project-scoped key store.

- **Key name at Hetzner:** `barkpark-worker-1776580350` (Hetzner SSH Key ID `111021077`)
- **Pubkey fingerprint:** `SHA256:b10kGqJOgmVol8pV8K8LofNTEnzpnsBArbZApduzths` (ED25519)
- **Pubkey path (kept for audit):** `/tmp/barkpark-worker-key.pub`
- **Private key:** `shred -u /tmp/barkpark-worker-key` after task (see §8).

Key was later **deleted from Hetzner** during cleanup (§8) since cutover never completed:

```
$ hcloud ssh-key delete 111021077
SSH Key 111021077 deleted
```

## 5. Shell-access recovery

### Option A — `hcloud server ssh` (failed)

```
$ env HCLOUD_TOKEN="$(cat /tmp/barkpark-hcloud-token)" hcloud server ssh 126671373 -- 'hostname && uname -a'
Permission denied, please try again.
Permission denied, please try again.
root@89.167.28.206: Permission denied (publickey,password).
---EXIT: 255
```

**Why it failed:** Registering an SSH key in the Hetzner project via API adds it to the
project's key inventory, but Hetzner only injects such keys into `authorized_keys` at
**server creation time** (via cloud-init). It does not retroactively push keys onto
already-running servers. The `hcloud server ssh` subcommand is a thin `ssh root@IP`
wrapper that relies on the local agent or standard SSH key paths — it does not
provision keys on the remote either.

### Option B — `reset-password` + inject pubkey with pexpect (failed)

Reset root password via Hetzner API, then drove `ssh` with password auth via
Python `pexpect` to append the ephemeral pubkey to `/root/.ssh/authorized_keys`.

```
$ env HCLOUD_TOKEN=... hcloud server reset-password 126671373 -o json >/tmp/hcloud-reset.json
$ jq 'keys' /tmp/hcloud-reset.json
[ "root_password" ]
```

(Password itself was read inline into `HCLOUD_ROOT_PW` env var for a single pexpect
invocation, never printed or written to disk beyond the single JSON file that was
then `shred -u`-ed.)

Wait of 15s for reset to propagate, then pexpect-driven ssh:

```
$ HCLOUD_ROOT_PW=... python3 /tmp/inject-key.py
root@89.167.28.206's password: [REDACTED]
Permission denied, please try again.
root@89.167.28.206's password: [REDACTED]
pexpect.exceptions.TIMEOUT: Timeout exceeded.
---EXIT: 1
```

Two password attempts rejected. Per the task HARD STOP (`Both Option A and Option B
shell-recovery fail → STOP`), did not retry further.

**Root cause hypothesis:** the server's `/etc/ssh/sshd_config` almost certainly has
`PasswordAuthentication no`. That would explain:
- Task #2's original `publickey,password` rejection with no prompt — server simply had
  no matching key.
- Today's Option A failing the same way.
- Today's Option B producing a password prompt (sshpass-less pexpect sees the prompt
  because sshd still prints one) but rejecting any entered password, because the
  sshd is configured to refuse password auth entirely regardless of correctness.

A less-likely alternative hypothesis: Hetzner's `reset-password` action on a
long-running Debian/Ubuntu server without a compatible cloud-init / qemu-guest-agent
silently fails to apply the new password (historically Hetzner's `reset-password` has
only been guaranteed on servers with their qemu-ga integration). Either way, the
fix is Boss-side.

## 6. Caddyfile diff

**NOT APPLIED** — could not SSH into the server to read, back up, or write the
Caddyfile. Reference target configuration is reproduced in task #2's evidence
(`docs/ops/task-2-caddy-tls-evidence.md` §3) and in the runbook at
`docs/ops/caddy-api-tls.md`.

## 7. Cert issuance

N/A — cutover not applied.

## 8. Post-cutover verification

N/A — pre-cutover state unchanged from task #2 (HTTPS port 443 still refuses TCP; HTTP
port 80 still serves via Caddy → Phoenix).

## 9. Service status

From external probe only (no SSH): Caddy is running (port 80 answers with `Via: 1.1 Caddy`)
and Phoenix is running (302 redirect to `/studio/production`). Neither service was
touched by this task. `barkpark` systemd status was not read and not altered.

## 10. Secret hygiene + Boss action items

### Secret hygiene (what this task did and verified)

- [x] Hetzner API token value never appeared in any committed file, msg body, or logged command. It was only referenced inline via `env HCLOUD_TOKEN="$(cat /tmp/...)"` which scopes the value to one process.
- [x] Reset root password never written to disk beyond the raw `hcloud server reset-password -o json` output at `/tmp/hcloud-reset.json`, which was `shred -u`-ed immediately after use. The password was never echoed to stdout, never logged, never msg'd. Password prompt input was redacted from captured output with `sed -E 's/password:.*$/password: [REDACTED]/'` in the single line where pexpect echoed it.
- [x] Ephemeral SSH private key `shred -u /tmp/barkpark-worker-key` at task end; pubkey (`/tmp/barkpark-worker-key.pub`) kept for audit with fingerprint in §4.
- [x] Registered Hetzner SSH key `111021077` deleted from Hetzner project during cleanup.
- [x] Grep check on this evidence file confirms zero occurrences of either the Hetzner API token prefix or the reset root password (run before `git add`).

### Boss action items

1. **Rotate the Hetzner Cloud API token** at `/tmp/barkpark-hcloud-token`. It was used by automation; even though it was never logged, best practice is to rotate after machine use.
2. **Root password was reset via Hetzner API.** The new password was captured by this task, used in two failed ssh attempts, and shredded. The old root password is now invalid; the new one is unrecoverable from this session. Boss options:
    a. Use Hetzner Cloud Console web-based console (server → `Console` tab) to log in directly to the VM, manually set a known password via `passwd`, and/or add the pubkey from `/tmp/barkpark-worker-key.pub` to `/root/.ssh/authorized_keys` so the Worker can be re-dispatched.
    b. Or enable rescue mode via `hcloud server enable-rescue --ssh-key <id>` which reboots into a temporary rescue OS with the registered pubkey, mount the root disk, append the Worker pubkey to `/mnt/root/.ssh/authorized_keys`, disable rescue, reboot. Disruptive but 100% API-driven.
    c. Or run the runbook (`docs/ops/caddy-api-tls.md` § "Boss manual steps") manually from the web console, bypassing any Worker re-dispatch.
3. **Check sshd config** on the server: `grep -i PasswordAuthentication /etc/ssh/sshd_config`. If `no`, that confirms the root-cause hypothesis and informs the Worker-authorization plan (must be pubkey path).
4. **Mixed-content unblock still pending.** `barkpark.cloud` (Vercel) cannot yet fetch `https://api.barkpark.cloud/*` because port 443 has no listener. The Next.js API proxy shim at `apps/demo/app/api/barkpark/*` shipped in Phase 7D continues to paper over this; nothing broke — it just didn't improve.
5. **Caddy auto-renewal:** not applicable yet (no cert). Once cutover lands, monitor `journalctl -u caddy` over the first 60 days for ACME-renewal.

## 11. Blockers / caveats

**Primary blocker:** both API-driven recovery paths for root shell access failed, most
likely because the server runs with `PasswordAuthentication no` AND the Hetzner key
store only injects pubkeys at server creation time — not at runtime. Task brief's
stated Option B (`sshpass` with captured pw) is structurally impossible on any modern
hardened Debian/Ubuntu image regardless of which pw-driver tool is used.

**Secondary concern:** executing Option B invalidated the old root password. If Boss
had any other automation or manual path relying on the prior root pw, that is now
broken until Boss sets a new one via the Hetzner web console or rescue mode.

**Caveats:**
- `sshpass` is not installed on this Worker host and cannot be installed without sudo.
  Python `pexpect` was used as a functionally-equivalent substitute — same result.
- The task brief's Option B ran once (with one retry within pexpect — two password
  attempts in the same session count as the single command attempt); did not re-invoke
  the reset-password action.
- No barkpark service action was taken; it remains Active (inferred from the HTTP 302
  still being served via Caddy on port 80).
