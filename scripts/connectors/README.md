# Connectors — D10 cold-start harness

Reproducible cold-start benchmark for **D10** of the Barkpark **Connectors** epic:
*which runtime executes a per-workspace Cloud agent turn?* The decision is
**RATIFIED** in the charter (commit `b27b05e1`); these scripts make its numbers
reproducible instead of vibes.

- Charter: [`.claude/workflows/bp-connectors-charter.md`](../../.claude/workflows/bp-connectors-charter.md) — decisions **D5, D10, D21, D22, D23, D24**.
- Wave paper: `connectors-wave-2-2026-07-13`.
- Task: `task-6672a70bea19dc11` (Wave 2 / P1, slice W2-1).

## TL;DR — D10 is decided

**Winner: Vercel Sandbox (Firecracker microVM), snapshot-baked `claude` image + warm pool.**
It preserves today's `claude`-CLI-subprocess shape (the pure argv/env machinery in
`claude_chat.ex` survives; `Port.open` → a sandbox `exec` on the same
`{exe,args,env,cwd} → NDJSON` contract) and its isolation primitives are GA:
`--network-policy deny-all` + `--allowed-domain` + `--env` credential injection
satisfy D5's "no host access, connector-scoped credentials" bar.

- **Rejected — own containers:** re-invents the Firecracker isolation + warm-pool +
  credential layer Vercel ships GA, at a weaker default boundary.
- **Retained as a documented complement (not primary) — plain Messages-API agent:**
  zero VM cold-start, naturally multi-tenant, but a different engine that discards
  ~1348 lines of `claude_chat.ex`. It is the escape hatch if in-sandbox first-token
  ever blows the UX target. Its own harness is the sibling slice
  `d10-messages-api-ttfb.sh` (W2-2).

## The numbers (Wave-2 verify fleet, headless, `vercel` authed as `frikk`, all torn down)

| leg | seconds | note |
|---|---|---|
| exec round-trip floor (`true` ×3, avg) | **2.70** | CLI control-plane round trip; subtract to isolate in-VM work |
| fresh `vercel sandbox create` (cold baseline) | **7.54** | |
| per-boot `npm i -g @anthropic-ai/claude-code` | **7.50** | inside a fresh sandbox |
| snapshot bake (`vercel sandbox snapshot <vm> --stop`) | **5.52** | **one-time**, off the hot path |
| create-from-snapshot (`vercel sandbox create --snapshot <id>`) | **3.02** | |
| + `claude` init (~in-VM) | **~0.60** | |
| **⇒ claude-ready from snapshot** | **~3.62** | the hot path |

### Verdict: per-boot-install is DEAD; snapshot + warm-pool wins

`create + per-boot-install` = **7.54 + 7.50 ≈ 15s** *before the model even starts* —
dead on arrival against any interactive UX target. Baking the `claude` image into a
**snapshot once** (5.52s, off the hot path) and booting from it lands at **~3.62s to
claude-ready**. A **warm pool** of pre-booted snapshot VMs (D22) removes even the
3.02s create leg from the hot path — a UX-latency lever, not a correctness
requirement.

## The one number we do NOT fabricate: in-sandbox first-token (D23)

Model first-token *inside the sandbox* is **credential-gated**. The env-injection
seam is already PROVEN in-sandbox (no key → `Not logged in`; bogus key →
`Invalid API key` — the failure mode *changes*, so the CLI reads the injected key
exactly as `Port.open` does). Only a **valid** `ANTHROPIC_API_KEY` / Claude OAuth
token is missing (absent from this shell and from guerrilla run-secrets).

So the harness stops exactly at that wall. The **human-gated** measurement step is:

```
vercel sandbox exec <SNAPSHOT_VM> --env ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY -- bash -lc 'time claude -p "say ok"'
```

`d10-vercel-sandbox-coldstart.sh` runs this **verbatim** when `ANTHROPIC_API_KEY` is
set and reports the number; when it is unset it **prints this exact command and
exits 0** — never a fabricated number ([[distrust-vacuous-green]]).

## The 10s bar is a UX goal, NOT a Linear correctness gate (D21)

Primary-source Linear docs: the `AgentSession` 10s clock is satisfied by **any**
activity (a canned `thought` ack), and the real turn has a **30-minute**
recoverable stale window. So **sandbox cold-start does not bind 10s.** The
criterion splits:

- **ack-latency ≤10s** — the **P2 bridge's** job (ack-first, boot-async), a hard P2
  requirement — *not the sandbox's*.
- **real-turn ≤30min** — trivially cleared by any boot.

Barkpark *adds* a self-imposed UX target — first real token within ~10s of the ack
on the warm path — as a product goal, **not** attributed to Linear. Linear ack ≠
sandbox cold-start.

## Scripts

Both scripts take `--check` — lint the plan and print the reference table
**without provisioning any sandbox or calling any API**. This is what CI runs.

### `d10-vercel-sandbox-coldstart.sh`

Reruns the decomposed measurement above (floor / create / npm / snapshot /
create-from-snapshot) and the credential-gated D23 first-token leg. **Always tears
down every sandbox and snapshot it creates** via an EXIT trap (even on error /
Ctrl-C).

```bash
scripts/connectors/d10-vercel-sandbox-coldstart.sh --check   # plan + reference table, provisions nothing
scripts/connectors/d10-vercel-sandbox-coldstart.sh           # LIVE: provisions, measures, tears down (needs `vercel` authed; billable, ~1 min)
ANTHROPIC_API_KEY=sk-ant-... scripts/connectors/d10-vercel-sandbox-coldstart.sh   # LIVE + runs the D23 first-token leg
```

### `d10-local-claude-cli-coldstart.sh`

The **self-hosted / operator** baseline (D5): the local `claude` CLI as a plain
subprocess — no microVM boot. Decomposes one turn into `init` (process → the
`system`/`init` stream event) + `ttft` (init → first model token, ~5s API round
trip). It resolves the **real** binary, deliberately **skipping the cmux wrapper
shim** that `command -v claude` resolves to first on the dev host (timing the shim
would misreport the operator profile). Override with `CLAUDE_BIN=/abs/path`.

```bash
scripts/connectors/d10-local-claude-cli-coldstart.sh --check   # resolve real binary + plan, NO API call
scripts/connectors/d10-local-claude-cli-coldstart.sh           # LIVE: one streamed turn, timed (spends API budget; needs `claude auth login`)
```

# Wave 11 — the Cloud execution-profile runner (D107–D115)

The architectural crux: run a workspace's `claude` turn **inside an isolated Vercel
Sandbox** instead of on the host, behind a shared execution-profile seam so the same
Studio-chat Session/runtime layer dispatches to either profile:

- **`:self_hosted`** (default) — the host `claude` CLI subprocess, full host access
  (today's behavior, byte-identical).
- **`:cloud`** — the sandboxed runner below, NO host access, gated on a concrete
  workspace principal.

The Elixir seam lives in `api/lib/barkpark_web/studio/claude_chat.ex`
(`command/2` → `{sandbox_runner(), cloud_build_args/2}` under
`config :barkpark, :claude_chat, execution_profile: :cloud`) and
`api/lib/barkpark/studio_chat/runtime/claude.ex` (threads `workspace_id` into
`session_opts`). It rides the SAME `{exe,args,env,cwd} → NDJSON` `Port.open`
contract — only the executable changes.

### `cloud-sandbox-runner.mjs`

The **shim** the `:cloud` profile spawns (dependency-free Node over the `vercel`
CLI — not the SDK this increment). Invoked `--workspace <id> -- <claude args…>`:

1. Buffers the FIRST `{"type":"user",…}` frame from its own stdin (interactive
   stdin INTO a sandbox is impossible — D108; the shim's own local stdin works).
2. `vercel sandbox create` — mandatory `--timeout`, `--scope guerrilla` (Pro team;
   Hobby's quota overrun pauses creation 30 days), tags `purpose=cloud-turn` +
   `workspace=<id>`. The **production** path boots from a `claude`-baked snapshot
   (`$CLOUD_SANDBOX_SNAPSHOT`) with the egress allowlist `--allowed-domain
   api.anthropic.com`; the **fallback** path (no snapshot) boots plain node24 and
   `npm i -g @anthropic-ai/claude-code`, which needs the npm registry, so the
   egress lock rides the snapshot, not this path (the Firecracker no-host-access
   boundary is intrinsic to every sandbox regardless).
3. Injects the frame base64-embedded to `/tmp/turn.jsonl`.
4. One-shot `claude <claude args> < /tmp/turn.jsonl` with an isolated HOME + clean
   cwd (D112 — a dirty HOME/cwd leaks SessionStart hook frames into the customer
   NDJSON). `ANTHROPIC_API_KEY` is injected from the SHIM's OWN env only (never
   `Barkpark.Secrets`, never the connector seal — D110). stdout NDJSON streams
   verbatim; diagnostics go to stderr.
5. Teardown (an Elixir Port has NO OS relationship to a remote microVM — D111):
   `vercel sandbox remove` at turn-complete AND on SIGTERM/SIGINT/SIGHUP/exit
   (REMOVE, never stop — stopped sandboxes accrue snapshot storage). `--timeout`
   is the backstop; env-clamped slot concurrency caps parallel turns.

`vercel sandbox exec` does NOT propagate the in-VM exit code, so the terminal
`result` frame's `is_error` — not the process exit code — is the auth-outcome
source of truth the Studio side classifies (`auth_failure?/1`).

### `w11-isolated-turn-proof.sh`

The **honest bogus-key proof** (D113c). `--check` lints the shim + fixture and
provisions nothing (CI). LIVE mode creates ONE real sandbox, injects a **bogus**
`ANTHROPIC_API_KEY`, drives one isolated turn through the shim, and asserts the
terminal frame `type:result is_error:true api_error_status:401 "Invalid API key"`
(field-matched to `api/test/fixtures/claude_chat/unauthed_stream.ndjson`), then
proves `vercel sandbox ls` shows zero running orphans. A bogus key producing the
401 IS the wire-level proof that env-injection reached the sandboxed claude
exactly as `Port.open` does.

```bash
scripts/connectors/w11-isolated-turn-proof.sh --check   # lint + plan, provisions nothing (CI)
scripts/connectors/w11-isolated-turn-proof.sh           # LIVE: one bogus-key isolated turn + teardown (needs `vercel` authed)
```

**The LIVE MODEL turn** (a valid `ANTHROPIC_API_KEY`) and the real per-workspace
Vercel deploy are NAMED human gates (`connectors-hg-live-isolated-cloud-turn`) —
this harness never fabricates a model answer.

## Gate

```bash
bash -n scripts/connectors/d10-vercel-sandbox-coldstart.sh scripts/connectors/d10-local-claude-cli-coldstart.sh \
  && shellcheck -S error scripts/connectors/d10-vercel-sandbox-coldstart.sh scripts/connectors/d10-local-claude-cli-coldstart.sh \
  && scripts/connectors/d10-vercel-sandbox-coldstart.sh --check \
  && scripts/connectors/d10-local-claude-cli-coldstart.sh --check \
  && node --check scripts/connectors/cloud-sandbox-runner.mjs \
  && bash -n scripts/connectors/w11-isolated-turn-proof.sh \
  && scripts/connectors/w11-isolated-turn-proof.sh --check
```

## What Wave 11 does NOT do (filed as backlog)

The D24 5-knob `bypassPermissions` reversal (only the never-emits-bypass argv test
rides along), the D22 warm pool, D9 per-workspace keys, multi-workspace routing,
in-sandbox MCP tools, interactive multi-turn, SDK/token auth, the real Vercel
deploy, and a sandbox reaper cron are all scope-outs (D115). The **live-key** model
turn is the human gate `connectors-hg-live-isolated-cloud-turn`. This slice proves
isolation + spawn + env-injection + the stream wire with a bogus key, up to that
gate. Do **not** start P2 (the Chat SDK bridge) from here.
