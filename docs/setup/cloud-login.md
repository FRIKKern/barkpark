<!-- doc-tier: human | canonical-for: bp-cloud-device-login | budget: 1400tok -->
# Logging in to Barkpark Cloud

`bp` stores a Barkpark Cloud session token in `~/.config/barkpark/config.json`
(`0600`). Two ways to get it: a **device-link browser flow** (default on a
terminal) and an **email + password fallback** (CI and headless). Both end the
same way — signed in, then auto-connected to a barkpark, no token copied by hand.

## Device-link login on a TTY

Run bare `bp login` (or pick **Barkpark Cloud** in the first-run wizard) on a
TTY; `bp` prints a box:

```
  ╭───────────────────────────────────────────────╮
  │ Log in to Barkpark Cloud                      │
  │                                               │
  │ Visit  https://barkpark.cloud/activate        │
  │ Enter code  WXYZ-2345                         │
  ╰───────────────────────────────────────────────╯
  Or log in with email:  bp login --email you@example.com

  Press Enter to open your browser (or copy the URL above)…
  Waiting for you to approve in the browser…
```

`bp` opens `https://barkpark.cloud/activate`. Approve there — riding your
existing barkpark.cloud session, or logging in if you aren't yet. **Two-factor
is handled by the web login**, so the CLI never sees your password or 2FA code.
The approve page shows the requesting machine (host, IP, user-agent) with
**Approve** / **Deny** buttons — it never auto-approves.

Once you approve, the poll returns and stores the token. You're signed in — and
`bp` keeps going.

## After sign-in: auto-register

Signing in isn't the finish line. `bp` resolves your fleet and lands you in a
working barkpark — for `bp login` and the wizard's **Barkpark Cloud** target
alike.

- **One barkpark** (usual case) — `bp` fetches its admin credentials and
  connects automatically:

  ```
  Connected to <name> — <url>
  ```

  then the connection summary. On a full terminal `bp login` ends with
  `Press Enter to open the desk (or type n to stay here)` — Enter drops you
  into the desk against the just-connected barkpark; `n` leaves `Run 'bp' any
  time to open the desk.` The wizard instead announces the auto-pick and
  continues straight into the desk.
- **Several barkparks** — `bp` prints a numbered list to pick from. If stdin is
  piped, it prints the fleet plus a one-line connect command.

### Complete non-connecting outcomes

You're always signed in; none of these dead-end:

- **Empty fleet** — no barkparks yet; `bp` shows how to launch or deploy one;
  exits 0.
- **Still provisioning** — `<name> has no address yet`; you stay logged in —
  re-run `bp setup` (wizard) or `bp setup --target cloud` (login) once it's up.
- **No admin token** — the wizard offers to paste one (same Connect path);
  `bp login` points at `bp setup --target cloud`; either way you finish signed in.
- **Already connected elsewhere** — an active server that isn't this barkpark:
  `bp is currently connected to <server> — leaving that as is.` plus a one-line
  connect command. `bp` does **not** take over.
- **Fleet unreachable** — login still succeeded; `bp` warns on stderr
  (`logged in, but couldn't reach your fleet … — try bp barkparks`), exits 0.

## `-o json` and headless

The success envelope is unchanged from password login:

```json
{ "ok": true, "cloud_url": "https://api.barkpark.cloud", "team_id": "…" }
```

All device-flow chrome and auto-register narration go to stderr, so `bp login
-o json` stays machine-parseable. **The headless path never prompts and never
auto-connects** — `-o json` / `-o yaml` and non-TTY streams get token storage
only; the envelope is byte-identical to before.

## Email + password fallback (CI, headless)

The device flow needs a browser and a TTY. On a headless box or in CI, pass
credentials and `bp` uses the password path verbatim — no box or polling:

```bash
bp login --email you@example.com          # prompts for the password
BARKPARK_PASSWORD=… bp login --email you@example.com   # non-interactive (CI)
```

The device flow engages **only** with no credential inputs (no `--email` /
`--user`, `--password` / `--pass`, `BARKPARK_PASSWORD`) and both streams a TTY;
any credential flag or non-TTY stream falls through to the password path,
untouched. `--device` forces it. `--url <base>` overrides the control-plane URL
(defaults to the saved `CloudURL`, else the baked-in `https://api.barkpark.cloud`).

## Security notes

- **Single-use, 10-minute codes.** The `XXXX-XXXX` code and device code are each
  consumed on first use (a replayed poll fails closed) and expire 600s after
  start. **Deny** cancels a request immediately.
- **Approval needs your browser session** — preserving the 2FA gate; the CLI can
  never approve itself, and no token ever rides in the URL.

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Code expired** before you approved | Rerun `bp login` for a fresh code and window. |
| **Browser didn't open** | Copy the printed `https://barkpark.cloud/activate` URL to any device and enter the code. |
| **`slow_down` / rate-limited poll** | The CLI backs off automatically; just wait. |
| **Headless machine, no browser** | Use email + password: `bp login --email you@example.com`. |
| **Approve page won't load / logged out** | Log in to barkpark.cloud in the same browser first, then reopen the link. |
| **Signed in but no barkpark connected** | `bp` says so and points at `bp setup` to connect one. |
