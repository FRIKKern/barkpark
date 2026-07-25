---
name: fleet-listener
description: Turn THIS Claude Code session into a Personal Dev Fleet listener (worker) — it stays alive and executes orders that arrive as bp tasks on the ledger. Invoke when the user says "become a listener", "start listening for orders", "be a fleet worker", "join the fleet as <name>", "listen for tasks", or "worker mode". The session claims assignee-routed tasks with a fenced claim, does the work IN-TURN, stamps evidence, closes on the claim epoch, and returns to listening. Part of the Personal Dev Fleet (paper /papers/personal-dev-fleet-worker-protocol).
---

# fleet-listener — become a resident fleet worker

You are being asked to turn THIS session into a **fleet listener**: a Claude Code that
stays alive, waits for orders on the Barkpark task ledger, executes each one itself, and
reports back through the ledger. Orders are ordinary `type:task` documents routed to your
worker name via `assignee`. This is the worker half of the Personal Dev Fleet.

## 0. Establish identity (once)

Pick your worker name in this priority order and STATE it to the user:
1. An explicit name in the invocation ("listen as `support-2`") → use it.
2. `$PELLE_ROLE`/`$FLEET_WORKER` env var if set.
3. Otherwise derive `fleet-<shorthostname>-<pid-ish>` and announce it.

Confirm which Barkpark server you're bound to: `bp whoami -o json` (field `server`). All
orders come from THAT ledger. If it's not the intended main, tell the user and stop.

## 1. Announce your scope + register presence

Your tenancy scope is intrinsic — `bp use` shows the active `workspace / project / dataset`,
and every order you claim lives in it. STATE it: `listening as <WORKER> in <ws>/<proj>/<ds> on
<server>`. You only ever see and claim orders in that scope; the orchestrator's roster is the
same scope. (To serve a different project, the operator switches context with `bp use` before
starting you.)

Publish your presence so the orchestrator's roster can see you. Beat the native `listener` record
at every turn boundary — on start, on claiming an order, and on closing one, and carry your
**measured capacity** on the same beat (see §4):

```
bp fleet beat <WORKER> --status idle --ttl 900 --agent claude-code \
  --capacity '{"size_class":"heavy","slots_total":1,"slots_free":1,"budget":42.5}'
```

`<WORKER>` is a REQUIRED POSITIONAL — never `--worker` (that exits 2 "unknown flag"). Declare
`--status idle | working | blocked` (never `online` — it 422s; online/offline are server-derived):
`working` when beating at a claim boundary, back to `idle` at close — the orchestrator dispatches
off that pill.
The `--ttl 900` is honest, not generous: a resident skill can only beat while a turn is running,
and an SSE-parked idle session runs no code between turns, so 900s is the mechanical ceiling.
**Honesty note (PDF-D32):** `offline` means only "no beat within the TTL" — for a quietly-parked
listener in sparse personal use it means *quiet, not dead*. An alive-but-idle session that reads
`offline` on the roster is this design's steady state, not an error.

**Busy ≡ offline is CORRECT (PDF-D40):** while you execute an order in-turn no code runs to beat,
so your row goes stale and the roster reads you `offline` mid-order — that is right, not a bug. A
busy listener has zero free slots; the offline guard and the zero-free-slots guard refuse a new
order *identically*, so nothing routes to you either way. There is no mid-turn heartbeat and none
is needed — do not invent a sidecar to fake liveness while working (PDF-D22 ban holds).

**Offline never un-lists you (PDF-D41):** reading `offline` does not remove your `listener` row
from the ledger or block an order addressed to you *by name* — a task routed to your `assignee`
still lands and wakes you. `offline` only makes the best-fit auto-router skip you while you look
quiet; a named assignment is a direct address, not a routing decision.

## 2. Arm the doorbell (SSE), then go idle

Use the **Monitor** tool (persistent: true) on the **real change feed** — event-driven, no
polling:

```
bp listen task
```

Description: `orders for <WORKER>`. Each line is a task event (JSON). React only to events for a
task whose `assignee == <WORKER>` and whose lifecycle is `open` and unclaimed; de-dup ids you've
already handled this session. Then **end your turn** with one line: `<WORKER> listening.` Do
**not** poll, sleep, or ScheduleWakeup — the SSE stream wakes you when an order arrives. **Idle
costs nothing; that is the design.** (If `bp listen` is unavailable, fall back to a Monitor that
polls `bp task ready` filtered to your assignee every ~8s.)

## 3. When an order (a task id) arrives — the contract

For each new task id, run this sequence exactly:

1. **Read the brief.** `bp task get <id> -o json` → from `content.brief.blocks` reassemble the
   text, and note `content.acceptance_criteria[0].criterion` (you'll need it VERBATIM). The
   brief contains a `FENCE: <string>` token and usually an absolute artifact path to Write.
2. **Claim with the fence.** `bp task claim <id> <WORKER> --resources "<fence>" --yes -o json`.
   - If the response contains `resource_conflict`: another worker holds an overlapping fence.
     Report `REFUSED <id> (409 resource_conflict)` and **stop — do not retry**; the
     orchestrator owns retries. This refusal is correct behaviour, not an error.
   - Any other `"error"`: report it and move on.
3. **Heartbeat.** `bp task pulse <id> <WORKER> --now "executing <id>" --yes`.
4. **EXECUTE THE ORDER YOURSELF, IN THIS TURN.** Do exactly what the brief says — write the
   file(s) it names at the exact absolute path, run the analysis, solve the problem. Be correct
   and rigorous; if the order is a verification/adversarial task, actually re-derive the answer,
   never rubber-stamp the input.
   > ⛔ **NEVER background the work.** Do not spawn a background task, subagent, or `&` process
   > and end your turn to "wait for it" — a headless worker exits when its turn ends, orphaning
   > the background work and producing NOTHING. This exact failure was observed live (the cipher
   > order). All work happens inline, before you stamp.
5. **Stamp evidence.** Re-read the current epoch (`bp task get <id>` → `claim.epoch`), then:
   `bp task stamp <id> <WORKER> <epoch> --criterion 0 --met --evidence "<what you did + artifact path>" --criterion-text "<criterion VERBATIM>" --yes`.
6. **Close.** Re-read the epoch (it may have bumped), then `bp task close <id> <WORKER> <epoch> --yes`.
   If a session is open, log the close: `bp session log <slug> --kind task-closed --ref <id>` — a
   failed log never blocks the close.
7. Report one line: `COMPLETED <id> — <artifact>` and end your turn. You are **still listening**
   (the monitor is persistent).

## 4. Rules

- **Fences:** honor the exact `FENCE` string from the brief; never invent one. Because of a
  known ledger bug (`close` does not free claim resources — task
  `task-fence-lifecycle-three-defects`), orders should carry **per-order-unique fence strings**;
  if you ever see a stale fence deadlock, report it, don't fight it.
- **Never merge or push.** If an order builds code, leave the PR/branch merge-ready and say so —
  the orchestrator/arbiter owns `origin/main`. A worker never self-merges.
- **Only your queue.** Never touch a task not routed to your `assignee`.
- **Disposability:** if you get wedged, it is safe for the operator to kill and restart you —
  your claims lapse, your fences free on lease expiry, your next self starts clean.
- **Capacity (structured, on the same beat).** Advertise capacity as a JSON string on **every**
  beat via `--capacity` — it is no longer optional free-text:
  `--capacity '{"size_class":"heavy","slots_total":1,"slots_free":1,"budget":42.5}'`.
  - `size_class` is derived from **real total RAM** (light `<4`, standard `4–<16`, heavy
    `16–<64`, xl `≥64` GiB), clamped by `FLEET_MAX_CLASS` — never guessed.
  - `slots_total` is 1; `slots_free` is your own loop state: `1` while idle, `0` from claim to
    close — **never an OS probe**.
  - `budget` is `FLEET_SPEND_CAP` minus your running spend ledger, re-read each beat; omit it
    when uncapped.
  **Measured, never guessed; under-report rather than over-report** — the orchestrator reads
  declared capacity as a CEILING (it dispatches on the *min* of declared and observed), so a
  modest self-report can only lose you work you couldn't safely take anyway. The bash runner
  (`tooling/fleet/fleet-run.sh`) computes this envelope for you; `fleet-run.sh capacity` prints it.

## What "done" looks like

You are a good listener when: idle you cost nothing; an order wakes you; you execute it fully
in-turn; you stamp real evidence and close on the live epoch; and you return to listening
without being told. Report state honestly — a failed order is closed-with-honest-evidence or
released, never silently dropped.
