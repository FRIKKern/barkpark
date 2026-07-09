<!-- doc-tier: human | canonical-for: bp-cloud-device-login | budget: 1400tok -->
# Logging in to Barkpark Cloud

`bp` connects to Barkpark Cloud with a login session token stored in
`~/.config/barkpark/config.json` (mode `0600`). There are two ways to get
that token: a **device-link browser flow** (the default on a terminal) and an
**email + password fallback** (for CI and headless machines). Both end in the
same place — a session token you never have to see or copy by hand.

## Default: device-link login on a TTY

Run bare `bp login` (or pick **Barkpark Cloud** in the first-run wizard) on an
interactive terminal and `bp` starts a device-link handshake. It prints a box:

```
  Log in to Barkpark Cloud

    ┌──────────────────────────────────────────────┐
    │  Open   https://barkpark.cloud/activate        │
    │  Code   WXYZ-2345                              │
    └──────────────────────────────────────────────┘

  Opening your browser… (or copy the URL to any device)
  Waiting for approval…
```

`bp` tries to open your browser at `https://barkpark.cloud/activate`. Approve
there — riding your existing barkpark.cloud session, or logging in if you
aren't yet. **Two-factor is handled by the web login**, so the CLI never sees
your password or 2FA code. The approve page shows the requesting machine (host,
IP, user-agent) so you can confirm it's really you, with **Approve** and
**Deny** buttons — it never auto-approves.

Once you approve, the CLI's poll returns the session token and stores it at
`~/.config/barkpark/config.json` (`0600`). You're logged in.

### `-o json`

The final success envelope is unchanged from the password path:

```json
{ "ok": true, "cloud_url": "https://barkpark.cloud", "team_id": "…" }
```

All device-flow chrome (the box, spinner, "opening your browser" line) goes to
stderr, so `bp login -o json` stays machine-parseable.

## The wizard's Barkpark Cloud target

On a fresh machine, `bp` starts the first-run wizard. **Barkpark Cloud — log in
and pick your barkpark** now sits alongside Connect / Local / Deploy as a
first-class choice. Pick it and:

1. The device-link flow above logs you in.
2. `bp` lists the barkparks on your team; you pick one by number.
3. It fetches that barkpark's admin credentials and connects — you land in the
   ordinary connected state, ready to run commands.

Cloud login **is** a complete setup — no separate `bp login` step needed. If
your fleet is empty, `bp` tells you how to launch or deploy one and exits
successfully (you're still logged in). If a barkpark has no admin token yet,
`bp` explains and lets you paste one or finish logged-in without connecting.

## Headless / CI fallback: email + password

The device flow needs a browser and an interactive terminal. On a headless box
or in CI, pass credentials and `bp` uses the password path verbatim — no box,
no browser, no polling:

```bash
bp login --email you@example.com          # prompts for the password
BARKPARK_PASSWORD=… bp login --email you@example.com   # non-interactive (CI)
```

The device flow engages **only** when there are no credential inputs (no
`--email`/`--user`, no `--password`/`--pass`, no `BARKPARK_PASSWORD`) and both
stdin and stdout are a TTY. Any credential flag or a non-TTY stream falls
straight through to the password path — existing scripts are untouched.

Force the device flow explicitly with `--device`:

```bash
bp login --device        # always use the browser link flow
```

`--url <base>` overrides the control-plane URL (defaults to the saved
`CloudURL`, else the baked-in `https://barkpark.cloud`).

## Security notes

- **Single-use codes.** The `XXXX-XXXX` code and the underlying device code are
  each consumed on first successful use; a replayed poll fails closed.
- **10-minute expiry.** A device-link session expires 600 seconds after start.
  An expired code can't be approved or polled.
- **Approval needs your browser session.** The approve page requires an
  authenticated barkpark.cloud session, which is what preserves the 2FA gate —
  the CLI can never approve itself.
- **No token in the URL.** The link carries only the short code; the session
  token is delivered to the CLI over the polled channel, never in a URL.
- **Deny** cancels a request immediately — use it if you didn't start the login.

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Code expired** before you approved | Rerun `bp login` — you get a fresh code and 10-minute window. |
| **Browser didn't open** | Copy the printed `https://barkpark.cloud/activate` URL to any device (phone, another laptop) and enter the code there. |
| **`slow_down` / rate-limited poll** | The CLI backs off automatically; just wait. If it persists, rerun `bp login`. |
| **Headless machine, no browser** | Use the email + password fallback: `bp login --email you@example.com` (or `BARKPARK_PASSWORD` in CI). |
| **Approve page won't load / you're logged out** | Log in to barkpark.cloud in the same browser first, then reopen the activate link (or re-type the code). |
