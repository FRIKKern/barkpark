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
CLI — not the SDK this increment). Invoked
`--workspace <id> [--mcp-config-b64 <b64>] -- <claude args…>`:

0. Parses `--mcp-config-b64` (D127, knob 3's CONFIG half) — a SHIM-OWN flag
   `cloud_build_args/2` emits ONLY when the workspace has ≥1 connected tool
   connector (GitHub/Linear) whose descriptor survives
   `CloudPolicy.cloud_mcp_servers/2`. Its value is base64(`{"mcpServers":…}`), the
   workspace's connector-scoped HTTP MCP servers (`{type:http,url}`, credential-less,
   `headersHelper` stripped). With 0 tool connectors the flag is absent and the
   argv is byte-identical to W12. The Elixir argv NEVER carries `--mcp-config`,
   `--strict-mcp-config`, or a host path — those are shim-owned (step 4).
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
3. Injects the frame base64-embedded to `/tmp/turn.jsonl`, and — when
   `--mcp-config-b64` was present — decodes it to `/tmp/bp-cloud-mcp.json` IN the
   sandbox (never a host path).
4. One-shot `claude <claude args> < /tmp/turn.jsonl` with an isolated HOME + clean
   cwd (D112 — a dirty HOME/cwd leaks SessionStart hook frames into the customer
   NDJSON). When an MCP config was materialized, the exec gains `--mcp-config
   /tmp/bp-cloud-mcp.json --strict-mcp-config` (knob 3's tools reach the turn;
   `--strict-mcp-config` means ONLY these servers, no host merge). The W12 deny
   belt is untouched — `--tools ""` + `--disallowedTools` still strip every host
   built-in (Bash/Edit/Write/…), so knob 3 adds connector tools WITHOUT re-opening
   host reach. `ANTHROPIC_API_KEY` is injected from the SHIM's OWN env only (never
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

# Wave 12 — the shim's LOCAL boundary: the vercel child's env allowlist (D121–D125)

Wave 11 wired the `:cloud` profile and proved the *remote* boundary is narrow — the
in-sandbox turn exec carries EXACTLY one `--env ANTHROPIC_API_KEY` pair, and
`vercel sandbox exec` forwards ONLY explicit `--env` pairs. Wave 12's verify round
found the leak that framing missed: the **LOCAL** `vercel` CLI child was spawned
with a **full env inherit**, so the shim's own environment — including the minted
per-session `BARKPARK_API_TOKEN` and the operator's `ANTHROPIC_API_KEY` — was
handed verbatim to every `vercel` invocation on the host.

### The fix — an explicit env allowlist on every local `vercel` spawn (D121)

`cloud-sandbox-runner.mjs`'s `run()` (the single choke point through which
create / exec / teardown all spawn `vercel`) now passes `env: vercelChildEnv()`:

- **Allowed:** `HOME`, `PATH`, `TMPDIR`, and every `VERCEL_*`-prefixed var
  (`VERCEL_AUTH_TOKEN` / `VERCEL_OIDC_TOKEN` are the CLI's auth env, confirmed from
  `vercel --help`; org/project id vars are unconfirmed by name, so the whole
  namespace is prefix-allowed rather than leaked-by-omission).
- **Never crosses:** `BARKPARK_*` and `ANTHROPIC_API_KEY`. The key is read from the
  shim's OWN env in `runTurn()` to build the single `--env ANTHROPIC_API_KEY=…`
  pair — it crosses the *remote* boundary as an explicit flag, never as an ambient
  var of the local child.

### `w12-shim-confinement-proof.sh`

The **black-box confinement proof** (D122) — hermetic, provisions NO real sandbox.
`CLOUD_SANDBOX_VERCEL_BIN` points the shim at a generated fake `vercel` that records
every invocation's argv (NUL-delimited, so the multi-line in-sandbox script
survives) + full env and emulates just enough of create→exec→remove for the shim to
complete. It drives the REAL `cloud-sandbox-runner.mjs` end to end with planted
`HOST_SECRET` / `BARKPARK_API_TOKEN` / `ANTHROPIC_API_KEY=sk-test` and asserts:

- **(a)** the turn exec (located by its `-lc` argv token — never by capture-file
  ordering, since the no-snapshot fallback's `npm i -g` exec shifts numbering)
  carries EXACTLY one `--env`: `ANTHROPIC_API_KEY=sk-test`;
- **(b)** `HOST_SECRET` / `BARKPARK_API_TOKEN` / `ANTHROPIC_API_KEY` are ABSENT from
  every captured child env, while `PATH` is still forwarded (the allowlist reverses
  the pre-fix leak without starving `vercel`);
- **(c)** the in-sandbox bash script isolates `HOME=/tmp/bp-cloud-home` +
  `cd /tmp/bp-cloud-cwd` (D112);
- **(d)** `--workspace global` AND a missing `--workspace` both exit 2 with ZERO
  vercel invocations (the fail-closed principal gate, front-run).

No GNU `timeout` is used (absent on darwin — the shim self-terminates in <1s against
the fake). `--check` lints the shim + verifies the allowlist is wired into `run()`
and prints the plan without spawning anything.

```bash
scripts/connectors/w12-shim-confinement-proof.sh --check   # lint + allowlist check + plan, spawns nothing
scripts/connectors/w12-shim-confinement-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
```

This proof finally rides CI: `.github/workflows/connectors.yml` gains
`scripts/connectors/**` in its `paths` and a BLOCKING `shim-confinement` job (node +
bash + the fake vercel; no Postgres) — the shim was invisible to every path filter
before Wave 12. The **live host-denial observation** (a real Firecracker VM
refusing a host touch) rides the same human gate,
`connectors-hg-live-isolated-cloud-turn`; this proof asserts the *launch contract*
(what the shim REQUESTS/confines), never a fabricated live denial.

# Wave 14 — the session-sandbox lifecycle: the Cloud Runner as a real multi-turn Barkpark Chat SESSION (D134–D143)

Waves 11–13 made the `:cloud` profile a SINGLE isolated one-shot `claude -p` turn
(interactive stdin INTO a sandbox is impossible — D108). Wave 14 makes it a
first-class multi-turn Barkpark Chat SESSION with continuity ACROSS turns. The
continuity mechanism (D134, run-proven live on guerrilla): create the sandbox
ONCE, STOP it after each turn (auto-snapshots, Persistent=true), and let the NEXT
turn's `vercel sandbox exec` auto-resume it with `/tmp` intact — `/tmp` lives on
the persisted xfs root (`/dev/vdb`), so the pinned `HOME=/tmp/bp-cloud-home` and
the `claude` transcript under it survive the stop/resume cycle. The sandbox stays
one-shot per turn; the memory lives in the SESSION binding + the sandbox
filesystem, NOT a held interactive subprocess.

### The shim's session-sandbox lifecycle (this slice, D137/D138)

`cloud-sandbox-runner.mjs` grew two ADDITIVE pre-`--` flags + one sideband frame +
a mode-dependent teardown. Flag-less invocations are BYTE-IDENTICAL to the pre-D137
shape (the W11/W12 proofs drive the shim flag-less and stay untouched; unknown
pre-`--` flags were already ignored):

- **`--sandbox-id <id>`** — REUSE the session-bound sandbox (turn N): skip
  `createSandbox()` entirely and exec straight into `<id>`, which auto-resumes from
  its stop-snapshot. Zero `sandbox create` invocations.
- **`--keep-sandbox`** — the teardown VERB flips from `vercel sandbox remove` to
  `vercel sandbox stop` (auto-snapshots so the next turn resumes; NEVER remove — a
  removed sandbox cannot resume). Applies on the normal `finally` path AND the
  SIGTERM/SIGINT/SIGHUP traps (best-effort stop). Flag-less teardown stays REMOVE.
- **`bp_sandbox` sideband frame** — a keep-mode CREATE (turn 1) emits EXACTLY ONE
  NDJSON line on stdout BEFORE any claude output:
  `{"type":"bp_sandbox","subtype":"created","sandbox_id":"<id>"}`. The Elixir
  Recorder (W14-2) pattern-matches `type:"bp_sandbox"`, persists the id as the
  session's durable binding (D136), and SWALLOWS the frame — never broadcast to
  SSE/ChatLive, never appended as a message (the customer NDJSON stays clean). A
  reuse turn creates nothing and emits none; a flag-less create emits none.

The Elixir side (W14-1) emits `--keep-sandbox` on turn 1 (create), and
`--sandbox-id <id> --keep-sandbox` on turn N (reuse), with the claude session-
identity flags (`--session-id` / `--resume`) after `--`.

### Timeout + snapshot economics (D138)

Stop-after-turn makes the existing 10m `--timeout` bound ONE turn (not the whole
chat), and think-time between turns is free (a stopped sandbox does not bill). The
timeout is also the crash-safety net if the shim dies before stopping. Cost caveat:
`vercel sandbox remove` does NOT delete stop-snapshots (~246MB each, 30d expiry),
and stopped sandboxes are INVISIBLE to `sandbox ls`, so a long keep-mode session
accrues snapshot storage. Keep-mode create caps it at the source WHERE the pinned
CLI supports it — the shim PROBES `vercel sandbox create --help` (a local help
print, no API round-trip, no provisioning) for `--keep-last-snapshots` /
`--snapshot-expiration` and appends them only if advertised; otherwise the accrual
is documented here and swept by the backlogged reaper
(`connectors-cloud-sandbox-reaper`). The shim never passes a flag the CLI rejects.

### `w14-session-sandbox-proof.sh`

The hermetic black-box lifecycle proof (D141), same fake-`vercel` technique as
`w12-shim-confinement-proof.sh`. It drives the REAL `cloud-sandbox-runner.mjs` for
three legs and asserts from the recorded argv + the shim's stdout:

- **(a) REUSE** — `--sandbox-id <id>` ⇒ ZERO real `sandbox create` invocations, and
  the `-lc` turn exec targets the supplied id;
- **(b) TEARDOWN VERB** — `--keep-sandbox` ⇒ teardown invokes `sandbox stop` and
  NEVER `sandbox remove`; flag-less ⇒ the legacy `create + exec + remove` sequence
  with `sandbox stop` NEVER invoked (byte-preserved);
- **(c) SIDEBAND FRAME** — a keep-mode create emits EXACTLY ONE valid
  `bp_sandbox` `created` NDJSON line first (before any claude frame), carrying the
  created id; a flag-less create emits none.

`CLOUD_SANDBOX_SNAPSHOT` is set so create takes the snapshot path (no `npm i -g`
exec noise). No real Vercel, no GNU `timeout` (the shim self-terminates against the
fake). `--check` lints the shim + verifies the lifecycle markers and prints the
plan without spawning anything.

```bash
scripts/connectors/w14-session-sandbox-proof.sh --check   # lint + lifecycle markers + plan, spawns nothing
scripts/connectors/w14-session-sandbox-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
```

It rides CI in the same BLOCKING `shim-confinement` job as the W12 proof
(`.github/workflows/connectors.yml`; node + bash + fake vercel, no Postgres). The
**live multi-turn** conversation (a real key, two turns, codeword-recall across
turns, zero orphans + snapshot cleanup) is the NEW named human gate
`connectors-hg-live-cloud-multiturn` (D142) — this proof asserts the launch
contract only, never a fabricated live conversation.

# Wave 34 — host prerequisites: the deploy install + the LOUD preflight (D265–D267)

Everything above proves the runner's *behavior* hermetically (fake `vercel`, bogus
key). This section is the **host contract** — what a real box needs before a
`:cloud` turn can actually run, and how the deploy satisfies it.

## The install (D265) — the wrapper, not the shebang

ClaudeChat picks a provider turn by resolving the **bare** name
`cloud-sandbox-runner` with `System.find_executable` on the live BEAM `PATH`
(`…:/usr/local/bin:…`, `/proc`-proven on guerrilla). That PATH has **no `node`**
and the unit carries no `Environment=` override, so `cloud-sandbox-runner.mjs`'s own
`#!/usr/bin/env node` shebang is a **silent no-op** — a `:cloud` turn returns
`{:stop, :binary_not_found}` the moment it starts.

`deploy/instance-deploy.sh` therefore installs **two** files every deploy
(re-copied so they track the checkout), guarded LOUD but non-fatal:

| Installed | Source | Mode | Why |
|---|---|---|---|
| `/usr/local/bin/cloud-sandbox-runner.mjs` | `scripts/connectors/cloud-sandbox-runner.mjs` | `0644` | the runner, versioned with the checkout |
| `/usr/local/bin/cloud-sandbox-runner` | generated 2-line wrapper | `0755` | the executable ClaudeChat's bare name resolves to |

The wrapper is exactly:

```sh
#!/bin/sh
exec /usr/local/bin/barkpark-node /usr/local/bin/cloud-sandbox-runner.mjs "$@"
```

`barkpark-node` is the dependency-free ELF the deploy already places for the
connectors bridge (COPY, ProtectHome-safe). Because the wrapper **basename is the
default**, ClaudeChat's `:sandbox_runner` config stays **unset**. On-host proof
after an auto-deploy:

```bash
which cloud-sandbox-runner                       # /usr/local/bin/cloud-sandbox-runner
readlink -f "$(which cloud-sandbox-runner)"      # same (a real file, not a dangling link)
head -2 /usr/local/bin/cloud-sandbox-runner      # #!/bin/sh  +  exec …/barkpark-node …
```

The install Case in `deploy/instance-deploy_test.sh` (Case 15) is non-vacuous by
design: file-presence alone would green a shebang-only no-op, so the load-bearing
assertion is on the wrapper **content** (`exec …/barkpark-node`) plus a byte-`cmp`
of the installed `.mjs` against the source.

## The preflight (D267) — `preflight-vercel.sh`

A fast, **non-creating** gate an operator runs before attempting a live turn (and
that CI self-tests). Four checks, cheapest-first, each miss LOUD + named + `exit 1`:

```bash
scripts/connectors/preflight-vercel.sh                 # exit 0 all green, exit 1 (named) at first miss
scripts/connectors/preflight-vercel.sh --scope <team>  # override the team scope (default: guerrilla)
scripts/connectors/preflight-vercel.sh --self-test     # offline hermetic self-test (fake vercel; no real Vercel)
```

| # | Check | Prereq it names |
|---|---|---|
| 1 | `command -v vercel` | the Vercel CLI is installed (`npm i -g vercel`) |
| 2 | `vercel whoami` | the CLI is authenticated — `vercel login` or ambient `VERCEL_*` (the runner's local child allowlists `HOME`/`PATH`/`TMPDIR`/`VERCEL_*` only) |
| 3 | `vercel sandbox list --scope guerrilla` | the team exists and holds the Sandbox entitlement — the entitlement-grade **non-creating** probe (`--scope guerrilla`, D111) |
| 4 | `ANTHROPIC_API_KEY` set | the ambient key the isolated turn authenticates Claude with — **never** a run-secret (D110/D23) |

It **never** runs `vercel sandbox create`: that path carries the **10-minute**
create backstop (`CLOUD_SANDBOX_TIMEOUT`, `cloud-sandbox-runner.mjs:84`) — exactly
the stall the preflight exists to catch *before* it happens. Portability: the
script shells **no** bare `timeout` (macOS has neither `timeout` nor `gtimeout`);
each probe reads stdin from `/dev/null` so a would-be prompt gets EOF instead of
hanging.

The **live** credentialed turn still rides the human gate
`connectors-hg-live-isolated-cloud-turn` — this preflight only certifies the host
is *ready* for it.

## The live-turn driver (W35, D270) — `w35-live-turn-driver.sh`

The instrument the human sitting drives to close the live-success gates. Neither
committed harness can: `w11-isolated-turn-proof.sh` injects a **bogus** key and
hard-asserts the 401 (a real-key success FAILS it), and
`w14-session-sandbox-proof.sh` is hermetic (fake vercel, no real sandbox). The
driver runs the REAL shim with a REAL `ANTHROPIC_API_KEY` and asserts SUCCESS —
it never modifies the proven harnesses.

```bash
scripts/connectors/w35-live-turn-driver.sh bake         # LIVE: warm snapshot (npm pin check BEFORE create); prints export CLOUD_SANDBOX_SNAPSHOT=<id>
scripts/connectors/w35-live-turn-driver.sh single       # LIVE: one real turn; asserts result frame is_error absent/false
scripts/connectors/w35-live-turn-driver.sh multiturn    # LIVE: --session-id turn 1, --resume turn 2; asserts codeword recall
scripts/connectors/w35-live-turn-driver.sh teardown <id>  # LIVE: remove + snapshot sweep + ls/snapshots-ls clean asserts
scripts/connectors/w35-live-turn-driver.sh --self-test  # hermetic (fake vercel, no credentials) — what CI runs
```

Every live mode runs `preflight-vercel.sh` FIRST and refuses loud. Key custody
(D110): the key rides the driver's own env → the shim's single `--env` pair,
never argv/logs — the self-test plants a key and proves it. Egress honesty:
with `CLOUD_SANDBOX_SNAPSHOT` set the create argv carries `--allowed-domain`;
without it the driver **warns loudly** that the turn is allow-all (the lock
rides ONLY the snapshot branch). An EXIT trap removes session sandboxes, deletes
stop-snapshots, and asserts both `sandbox ls` and `sandbox snapshots ls` are
clean — spend bound ≤2 sandboxes / ≤10m each / snapshots deleted same sitting
(D279). The self-test includes a **mutation leg** (drop the `--resume` flag ⇒
the wiring check goes RED). The ONE consolidated human packet for all five live
gates: [`connectors/docs/live-gates-packet.md`](../../connectors/docs/live-gates-packet.md).

## Gate

```bash
bash -n scripts/connectors/d10-vercel-sandbox-coldstart.sh scripts/connectors/d10-local-claude-cli-coldstart.sh \
  && shellcheck -S error scripts/connectors/d10-vercel-sandbox-coldstart.sh scripts/connectors/d10-local-claude-cli-coldstart.sh \
  && scripts/connectors/d10-vercel-sandbox-coldstart.sh --check \
  && scripts/connectors/d10-local-claude-cli-coldstart.sh --check \
  && node --check scripts/connectors/cloud-sandbox-runner.mjs \
  && bash -n scripts/connectors/w11-isolated-turn-proof.sh \
  && scripts/connectors/w11-isolated-turn-proof.sh --check \
  && shellcheck -S error scripts/connectors/w12-shim-confinement-proof.sh \
  && scripts/connectors/w12-shim-confinement-proof.sh \
  && shellcheck -S error scripts/connectors/w14-session-sandbox-proof.sh \
  && scripts/connectors/w14-session-sandbox-proof.sh \
  && shellcheck -S error scripts/connectors/preflight-vercel.sh \
  && scripts/connectors/preflight-vercel.sh --self-test \
  && shellcheck -S error scripts/connectors/w35-live-turn-driver.sh \
  && scripts/connectors/w35-live-turn-driver.sh --self-test
```

## What Wave 11 does NOT do (filed as backlog)

The D24 5-knob `bypassPermissions` reversal (only the never-emits-bypass argv test
rides along), the D22 warm pool, D9 per-workspace keys, multi-workspace routing,
in-sandbox MCP tools, interactive multi-turn, SDK/token auth, the real Vercel
deploy, and a sandbox reaper cron are all scope-outs (D115). The **live-key** model
turn is the human gate `connectors-hg-live-isolated-cloud-turn`. This slice proves
isolation + spawn + env-injection + the stream wire with a bogus key, up to that
gate. Do **not** start P2 (the Chat SDK bridge) from here.
