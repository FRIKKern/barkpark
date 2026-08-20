<!-- doc-tier: human | canonical-for: connectors-live-gates-packet | budget: 6000tok -->

# The live gates — ONE consolidated human packet (W35, D270/D271/D279)

Five gates in this epic are genuinely human-held: they need a real credential, a
real third-party account, or a real browser — things no CI runner has. This is
the ONE packet for all five. Every command is pre-written, every expected output
is named, every gate carries its failure signature. **Nothing here may be
fabricated**: if a step fails, the gate fails, and the honest state is "NOT
PASSED".

Status of every gate below: **NOT PASSED** until a human runs it and pastes the
named output into the gate task's evidence.

---

## G5 — The Anthropic sitting (THE CROWN: drives `w35-live-turn-driver.sh`)

One sitting with a real `ANTHROPIC_API_KEY` closes the live rows the whole
Cloud-runner track has been building toward:

- `connectors-hg-live-isolated-cloud-turn` (one real turn, real key, success)
- `connectors-hg-live-cloud-multiturn` (real conversation recall across turns)
- `connectors-egress-live-enforcement-reconfirm` (the locked turn ran from a snapshot)
- `connectors-live-credential-embed-reconfirm` (key crossed only as the shim's `--env` pair)
- the `connectors-cloud-sandbox-mcp-tools` crit-a observation and the
  `connectors-p4-tool-connectors-mcp` two-server probe ride the same sitting
  where applicable (observe, then stamp what you SAW).

**Spend bound (D279): at most 2 sandboxes, at most 10 minutes each
(`CLOUD_SANDBOX_TIMEOUT=10m` is the backstop), and every snapshot deleted in the
same sitting.** The driver's EXIT trap tears down even on Ctrl-C.

### Commands (in order; stop at the first failure)

```bash
# 0. Key custody (D110): the key lives in THIS shell's env only — never argv,
#    never a run-secret, never pasted into any file.
export ANTHROPIC_API_KEY='sk-ant-…'          # from your own vault

# 1. Preflight (non-creating, loud):
bash scripts/connectors/preflight-vercel.sh
# EXPECT: "PREFLIGHT OK: vercel present + authenticated, sandbox entitlement
#          under scope 'guerrilla', ANTHROPIC_API_KEY set."

# 2. Bake the warm snapshot (the deny-all egress lock rides ONLY the snapshot
#    branch of cloud-sandbox-runner.mjs — without this, turns are allow-all):
bash scripts/connectors/w35-live-turn-driver.sh bake
# EXPECT: "W35 BAKE OK: snapshot <id> (claude 2.1.211 baked; …)"
#         "    export CLOUD_SANDBOX_SNAPSHOT=<id>"
export CLOUD_SANDBOX_SNAPSHOT=<id>           # paste the printed id

# 3. The isolated single turn (closes connectors-hg-live-isolated-cloud-turn):
bash scripts/connectors/w35-live-turn-driver.sh single
# EXPECT: "W35 SINGLE PASS: result frame is_error=false; text: …W35-LIVE-OK…"
#         then "W35: TEARDOWN CLEAN: …"

# 4. The multiturn session (closes connectors-hg-live-cloud-multiturn):
bash scripts/connectors/w35-live-turn-driver.sh multiturn
# EXPECT: "W35 MULTITURN PASS: codeword recalled through --resume <uuid> on sandbox <id>"
#         then "W35: TEARDOWN CLEAN: no session sandboxes or stop-snapshots remain"

# 5. Delete the bake snapshot — SAME SITTING (D279):
vercel sandbox snapshots delete "$CLOUD_SANDBOX_SNAPSHOT"
vercel sandbox snapshots ls                   # EXPECT: no w35 snapshot remains
vercel sandbox ls --scope guerrilla           # EXPECT: no w35 sandbox remains
```

### Failure signatures (do NOT fabricate past any of these)

| You see | It means | Do |
|---|---|---|
| `PREFLIGHT FAIL [anthropic-key]` / `[vercel-*]` | host prerequisite missing | fix the named miss; nothing was created |
| `W35 FAIL [bake-npm-pin]` | the pinned claude does not resolve on the npm registry | check `scripts/connectors/cloud-claude-pinned-version.txt`; nothing was created |
| `W35 WARN [egress-allow-all]` | you skipped step 2 — the turn would run UNLOCKED | export the bake snapshot id; do not count an unlocked turn as the egress gate |
| `single` red with a result frame carrying `is_error:true` / `Invalid API key` | the key is bad — this is w11's 401 wire, not a driver bug | fix the key; the gate is NOT passed |
| `W35 FAIL [multiturn-recall]` | filesystem resumed but conversation did not — `--resume` wiring vs model paraphrase | paste the full output into the gate task; investigate before any retry |
| `W35 FAIL [teardown-lingering-*]` | an artifact survived teardown | run the printed manual `vercel sandbox remove` / `snapshots delete` commands NOW (spend is accruing) |

---

## G1 — Telegram (BotFather; polling — NO public URL needed)

Full walkthrough: `connectors/docs/telegram-smoke.md` (follow it verbatim).
Digest: in Telegram, message **@BotFather** → `/newbot` → it replies with a
token. Then:

```bash
export TELEGRAM_BOT_TOKEN='123456789:AAH…'
# bridge + API up per telegram-smoke.md, then DM the bot.
# EXPECT: "[smoke] polling (getUpdates). No public URL needed." and a real reply
# in your Telegram client, backed by one minted Session.
```

Failure signature: `401 Unauthorized` from `api.telegram.org` = bad token; no
updates arriving = you DM'd the wrong bot or privacy mode swallowed the message.
A reply that did not come from a real `/v1/chat` session does not pass the gate.

## G2 — Slack (app manifest; the public route is GREEN)

Full walkthrough: `connectors/docs/slack-install.md`. The public-URL blocker is
CLEARED: `https://guerrilla.barkpark.cloud/connectors/health` returns **200**
(verified 2026-08-17). Create the app from the manifest in that doc and hand the
bridge the four values (`SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`,
`SLACK_SIGNING_SECRET`, redirect URL byte-matching
`${PUBLIC_URL}/connectors/oauth/slack/callback`).

Two non-negotiables from the doc:

- **`socket_mode_enabled` stays `false`** — socket mode bypasses the
  signature-verified HTTP envelope the tenant resolution rides on (a silent
  cross-tenant leak, not a convenience).
- The webhook route answering **404 at zero installs is BY DESIGN** (fail-closed
  opacity) — it flips only when a real install mounts. A 404 before any install
  is not a failure signature; a 404 AFTER a successful install is.

Failure signature: Slack's `url_verification` challenge not echoed = signing
secret mismatch; `invalid_auth` on OAuth = client id/secret pair wrong.

## G3 — Linear (OAuth; D90)

Create a Linear OAuth app, set `LINEAR_CLIENT_ID` / `LINEAR_CLIENT_SECRET`, run
the connect flow, then prove the D90 refresh path: the callback seals
`{access_token, refresh_token?, expires_at?}`; refresh fires at header-build
inside the `LINEAR_TOKEN_REFRESH_SKEW_MS` window; on refresh FAILURE the bridge
serves the stored token AND logs loudly (named degraded mode — there is no
on-401 leg, the bridge never sees provider 401s). Gate task:
`connectors-linear-live-oauth-gate` (live OAuth + live refresh + live tool call).

Failure signature: a 401 from Linear's GraphQL during the tool call = the token
aged past 24h without a refresh — that is exactly the D90 path under test, so
capture the loud degraded-mode log line; do not just retry until it greens.

## G4 — GitHub (fine-grained PAT; D74, verbatim)

> Create a fine-grained PAT at github.com/settings/personal-access-tokens/new →
> Repository access → Only select repositories → one repo → Repository
> permissions → Contents: Read-only and/or Issues: Read-only (Metadata:
> Read-only is auto-added) → send as `Authorization: Bearer <PAT>` to
> `https://api.githubcopilot.com/mcp/`.

The PAT's own scope is the ONLY blast-radius bound (D74 names this widening in
writing) — which is why it must be fine-grained, read-only, single-repo. The
stub already proves the wire; this gate is the one live call.

Failure signature: `401 Bad credentials` = PAT pasted wrong/expired;
`403`/empty tool list = the PAT's repo/permission selection is too narrow for
the probe you ran. Never substitute a classic PAT.

---

## After the sitting

For each gate you passed: paste the NAMED expected output (verbatim lines, not
a summary) into the gate task's evidence and close it on your claim epoch. For
each gate you did not pass: stamp `--miss` with what actually happened. The
epic's honesty rests on this packet never being marked passed by anyone who did
not run it.
