# The Fleet Worker Protocol — provider-neutral

Any AI agent that can (a) run shell commands **or** (b) speak MCP can be a Personal Dev Fleet
worker. Nothing here is specific to one vendor. Claude Code, OpenAI Codex, and any MCP-capable
agent all drive the identical contract; only *how you launch a headless turn* differs, and that
is one line (`tooling/fleet/fleet-run.sh` → `agent_exec`).

## Two universal spines

1. **CLI spine** — the `bp` command-line tool. Any agent with a shell tool runs the loop directly.
2. **MCP spine** — `bp mcp serve` exposes eight task tools (`task_ready`, `task_next`, `task_show`,
   `task_close`, `task_create`, `task_prime`, `task_stamp`, `task_pulse`) over Model Context
   Protocol. Both Claude Code and Codex connect to it natively:
   - Claude Code / Cursor / Claude Desktop: add `bp mcp serve` as an MCP server.
   - Codex: `codex mcp add barkpark -- bp mcp serve`.

The doorbell — `bp listen task` — is a plain SSE stream any process can consume. Scope
(workspace / project / dataset) is intrinsic: whatever `bp use` is set to is the fleet's world.

## The contract (identical for every agent)

An **order** is a `type:task` document routed to your worker name via `assignee`, carrying a
`brief` (what to do + the absolute path to write) and one `acceptance_criteria` entry.

1. **Listen.** Watch `bp listen task` (or poll `bp task ready`), react only to orders whose
   `assignee` is you and whose lifecycle is `open` + unclaimed.
2. **Claim with the fence.** `bp task claim <id> <you> --resources "<FENCE from the brief>" --yes`.
   A `resource_conflict` (409) means another worker holds an overlapping fence — **stand down, do
   not retry**; the orchestrator owns retries.
3. **Heartbeat.** `bp task pulse <id> <you> --now "<what you're doing>" --yes`.
4. **Execute IN-TURN.** Do exactly what the brief says, yourself, in this turn. Write the file(s)
   it names at the exact absolute path. **Never background the work or spawn anything that
   outlives the turn** — a headless agent exits when its turn ends, orphaning background work and
   producing nothing. (This was observed live and is the single most important rule.)
5. **Stamp.** `bp task stamp <id> <you> <epoch> --criterion 0 --met --evidence "<what you did>"
   --criterion-text "<the criterion, verbatim>" --yes` (get `<epoch>` from `bp task get`).
6. **Close.** Re-read the epoch, then `bp task close <id> <you> <epoch> --yes`. Return to step 1.

## Capacity in the beat (measured, never vibed)

Every heartbeat carries a **measured** capacity envelope so the orchestrator routes heavy work to
big boxes and light work to lean ones from real data, not static config:

```
bp fleet beat <you> --status idle --ttl 30 --agent <kind> \
  --capacity '{"size_class":"heavy","slots_total":1,"slots_free":1,"budget":42.5}'
```

- **`size_class`** — from **real total RAM** (Darwin `sysctl -n hw.memsize`, Linux `MemTotal`),
  inclusive thresholds light `<4` / standard `4–<16` / heavy `16–<64` / xl `≥64` GiB, then clamped
  by `FLEET_MAX_CLASS` (a CEILING, `min(observed, declared)` at the edge — PDF-D6/D36).
- **`slots_free`** — the loop's OWN control-flow state: `1` idle, `0` from claim to close. Never an
  OS probe; a busy worker advertises zero and the router skips it (same effect as offline).
- **`budget`** — `FLEET_SPEND_CAP` minus the running spend ledger (`${FLEET_HOME:-~/.barkpark-fleet}/
  <worker>/spend.jsonl`, one append-only row per closed order), re-read every beat; omitted when
  uncapped. Cap reached ⇒ budget floors ⇒ the orchestrator's ambition drops to zero and dispatch
  halts — the fleet brake. A malformed ledger line is a loud abort, never coerced to a number.

`tooling/fleet/fleet-run.sh` measures and threads all of this; `fleet-run.sh capacity` prints the
envelope. The orchestrator reads declared capacity as a CEILING — under-report, never over-report.

## Rules (all agents)

- **Never merge or push.** Code orders leave a merge-ready PR; the orchestrator is the arbiter.
- **Honor the exact fence.** Use per-order-unique fence strings (a known ledger bug means `close`
  does not yet free a fence — `task-fence-lifecycle-three-defects`).
- **Only your orders.** Never touch a task not routed to your `assignee`.
- **Disposable.** If you wedge, it is safe to be killed and restarted; your claims lapse and
  fences free on lease expiry.

## Onboarding a new agent kind

Add one adapter line to `fleet-run.sh`'s `agent_exec`:

| Agent | Headless one-shot |
|---|---|
| Claude Code | `claude -p "$P" --dangerously-skip-permissions` |
| OpenAI Codex | `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$P"` |
| Anything else | set `FLEET_AGENT=custom FLEET_AGENT_EXEC='youragent … {{PROMPT}}'` |

That is the whole vendor surface. The ledger, the fences, the presence, the routing, the
orchestrator — all provider-neutral by construction.
