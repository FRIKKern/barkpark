<!-- doc-tier: agent | canonical-for: cli-credential-mint | budget: 800tok -->
# Minting a control-plane credential from `bp` — DECIDED

**The question** (`ssw11-bl-no-pat-mint-verb-in-bp`): does `bp` gain a
device-flow or session-backed mint verb, or is console-only the contract?
**Decision: SESSION-BACKED, in `bp`.** Console-only is rejected — it makes every
second client (a CI job, a fresh box, a spawn) start with a browser.

## Measured, by running

| Probe | Result |
|---|---|
| `bp cloud token` (and `pat`/`tokens`) | `{"error":{"code":"usage","message":"unknown command …"}}` — no verb, any spelling |
| `bp token` | EXISTS — a DIFFERENT credential: an **api/ workspace** token, read-only |
| `POST /v1/tokens` (cloud router) | exists, `Auth.require_user` — **session-only** |

The gap was never the server: the plane has minted PATs all along. `bp` had no
verb, and `bp token` is a look-alike for another service.

## The decisions

- **CRED-1 · Session-backed, NOT a second device flow.** `bp login` already runs
  the RFC 8628 device flow and persists a cloud SESSION token;
  `bp cloud token` rides it. The session-only gate on `/v1/tokens`
  is the escalation firewall — a leaked `read` PAT can never mint itself a `root`
  one — and is preserved, never worked around.
- **CRED-2 · The plaintext is NEVER printed by default.** `--out <path>` writes
  it to a NEW 0600 file (`O_EXCL` — an existing path is refused, never truncated;
  it may hold a live credential). `--reveal` is the explicit, warned opt-in to
  stdout. With neither flag the command refuses **before any request is issued**:
  the plaintext is unrecoverable after the mint, so a late refusal burns a real
  credential. `-o json` carries the row, never the secret.
- **CRED-3 · The role cap stays the SERVER's.** `create_personal_access_token`
  caps a plain member at `read`; `write`/`deploy`/`root` need owner/admin. The
  CLI does not re-implement that gate (m0 rule C2 — only the server knows a
  per-team role): it issues the request and turns the plane's `403 forbidden`
  (`required: admin`, `scope: team`) into a sentence naming the cap, exit `3`.
- **CRED-4 · Ability and expiry VALUES are checked client-side** — a typo gate,
  not a role gate. `parse_expiry/1` silently rewrites an off-menu integer (`45`)
  to the default validity, handing back a window nobody asked for. Accepted:
  `7 · 30 · 60 · 90 · 365`, or `never` (an explicit `0`; an OMITTED key means the
  server's default — a different instruction).

## Where it lives

`internal/cloudclient/tokens.go` (`MintPAT`/`ListPATs`/`RevokePAT` — the
plaintext is a SEPARATE return value; the `PAT` row struct has no field that can
hold it, so no caller leaks it by printing a row) and
`internal/cli/cloud_token_cmd.go` (the verb, sinks, refusals). Arms:
`cloud_token_cmd_test.go` — the no-leak arm AND its quiet control on `--reveal`,
plus the pre-mint refusal asserted by ZERO requests reaching the fake plane — and
`cloudclient/tokens_test.go`.

Minting against PRODUCTION stays an owner action: nothing here ran against a real
control plane — every test uses a fake plane and a fixture string.
