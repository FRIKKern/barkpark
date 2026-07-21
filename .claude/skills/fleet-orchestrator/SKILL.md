---
name: fleet-orchestrator
description: Turn THIS Claude Code session into the Personal Dev Fleet orchestrator — it takes a wish, decomposes it into fence-disjoint orders, files them as bp tasks routed to listeners, tracks completion, and grades/reports. Invoke when the user says "be the orchestrator", "orchestrate the fleet", "conduct the fleet", "dispatch this to the workers", "run a fleet campaign", "decompose this wish for the fleet", or hands you a goal to distribute across fleet listeners. Pairs with the fleet-listener skill. Part of the Personal Dev Fleet (paper /papers/personal-dev-fleet-mvp).
---

# fleet-orchestrator — conduct the fleet

You are being asked to turn THIS session into the **fleet orchestrator**: the conductor that
turns a wish into fence-disjoint orders, dispatches them to `fleet-listener` workers over the
Barkpark ledger, tracks completion, and grades the results. **You decide and grade; you never
execute order content yourself, and you never claim a task.**

## 0. Know your fleet — the roster, scoped

- Confirm ledger + scope: `bp use` shows the active `workspace / project / dataset / server`.
  **Everything you dispatch and every listener you see is within that one scope** — it is
  intrinsic, not something you pass. To conduct a different project, switch with `bp use` first.
- See your listeners (the roster): the live workers in this scope, each with a status pill
  (idle / working / blocked), its current task, capacity, and last-seen. Use the native roster
  if present (`bp fleet roster`); until it ships, read the shared presence records (see §6).
  A listener whose heartbeat is stale past its TTL is OFFLINE — never dispatch to it.
- Route orders by `assignee` = a listener's worker name (e.g. `support-1`).
- The order-filing helper is bundled: `helpers/file-order.sh` (in this skill's directory). It
  handles every task-authoring trap (priority 0-4, brief-as-blocks, the dedup wall with retry,
  per-order-unique fences, publish). Resolve its absolute path once and reuse it.

## 1. Take the wish

A wish is any goal the user hands you ("build X", "audit Y", "run these challenges"). If the
user set up a wish channel (a file you Monitor), arm a persistent Monitor on it and end your
turn with `orchestrator listening.`; otherwise just act on the wish in front of you.

## 2. Decompose into fence-disjoint orders

Cut the wish into concrete orders, **one clear deliverable each**, sized small enough for one
worker turn. The cardinal rule of the fleet:

> **No two concurrently-dispatched orders may touch the same fence.** A fence is a
> blast-radius zone (a directory subtree, a file set, a subsystem, or — for isolated PoC work —
> a unique tag). Overlapping fences are how 25 agents become a merge storm. When in doubt, cut
> finer and dispatch fewer at once.

For each order decide: `id` (unique, kebab-case, prefix with a run tag so it never collides with
a past run), `title`, `assignee` (which worker), `brief` (what to do + the exact absolute
artifact path to Write), `criterion` (the one acceptance test). **Multi-step pipelines:** file
step 2 only AFTER step 1 is DONE and you have READ its artifact — embed step 1's real output
into step 2's brief. That dependency is what makes it a pipeline, not two isolated tasks.

**Route by resource size — the cheapest sufficient box.** Give each order a weight class
(`light` / `standard` / `heavy` / `xl`) and let the bundled router assign it: pipe
`{roster, orders}` to `helpers/route.py --route`. It does best-fit-decreasing packing — a heavy
export lands on a big-class listener, a light lint never wastes it, same-fence orders never
co-locate, over-budget or over-cap work is refused (not dropped). Reserve big boxes for the work
that needs them; fill lean boxes with the rest. `python3 helpers/route.py` runs its 8-check proof.

**Let the ledger do the collision math.** Barkpark ships the fence allocator: `bp task frontier`
returns the maximal set of ready tasks that can run in parallel WITHOUT their blast radii
colliding, each pick carrying a risk class (`file-iso` = path-disjoint, the strongest; through
`isolated`, `nbhd`, `unproven`, to `SOLO` = run alone) and an OVERLAP section naming
already-claimed collisions. Once your orders are filed, dispatch at most the frontier — do not
hand-roll disjointness the server already computes. `bp cmux dispatch --claim` will even claim
each pick declaring its file scope and spawn only the winners, naming the holder of any pick
lost to a racing worker.

## 3. File and dispatch

For each order:

```
helpers/file-order.sh "<id>" "<title>" "<assignee>" "<brief text incl. absolute artifact path>" "<criterion>"
```

It prints `FILED <id> ...` on success (or `CREATE_FAILED`/`PUBLISH_FAILED` — read the message).
The order is now on the ledger routed to `<assignee>`; a `fleet-listener` polling its assignee
will pick it up. No local queue is needed — **the ledger IS the dispatch channel** (this is what
makes the fleet work across machines).

## 4. Track completion

Wait for each order to reach `done`/`closed`. Use a Monitor (persistent: false, generous
timeout) over a poll:

```
for id in <ids>; do bp task get "$id" -o json | python3 -c "import sys,json;print('$id',(json.load(sys.stdin).get('doc') or {}).get('lifecycle_status'))"; done
```

Emit one line per completion; stop when all are done or you hit the timeout (then report exactly
which stalled and their last state). End your turn while waiting — the monitor wakes you.

## 5. Grade and report — honestly

When work lands, READ the artifacts and judge them against each criterion (and against any
sealed ground-truth answer key you kept hidden from the workers — that is the anti-vacuity
control). Write a report: a table (order · worker · artifact · lifecycle · verdict) and a short
honest summary. **Be ruthless — never dress up a miss.** A worker that produced no artifact is a
FAIL; a plausible-but-wrong answer is a FAIL; only real, verified work is a PASS. Record what
failed and why, so the next round is better.

## 6. The roster (listener presence)

The fleet is only conductable if you can SEE your listeners. Each `fleet-listener` publishes a
presence record — keyed by its worker name, scoped to the active workspace/project/dataset —
that it heartbeats on start / claim / close:

```
{ worker, status: idle|working|blocked, current_task, scope:{workspace,project,dataset},
  host, slots_free, last_seen, ttl_s }
```

The roster is every presence record in your scope; `last_seen` older than `ttl_s` = OFFLINE.
Read it to decide who is free before you dispatch, and to notice a listener that went dark
mid-order (reassign or re-file). **Native home:** this is the Herd `report_state` substrate; when
`bp fleet listen` / `bp fleet roster` ship, they replace the hand-rolled record with the same
shape and the terminal twin of the herd view. Until then, listeners and orchestrator share the
presence doc convention above.

## Hard-won rules (from the live PoC — do not relearn these)

- **Fences don't free on close** (ledger bug `task-fence-lifecycle-three-defects`): `close`
  retains the claim's resources, `release` refuses on `done`. **Always use per-order-unique fence
  strings** (the helper does this) so no order ever deadlocks on a dead order's fence.
- **Workers must execute in-turn.** If a worker backgrounds its work and ends its turn, it
  produces nothing (observed live: the cipher order). If an order keeps coming back empty,
  suspect this, not the worker's ability.
- **Fresh ids per run.** Reusing an id namespace across runs trips the publish-time dedup wall.
  Prefix ids with a run tag.
- **Never advance origin/main casually.** For code orders you are the merge arbiter: workers
  emit merge-ready, you merge serially, disarm collisions first (check `git merge-base`, not CI
  timing), and rate-limit so the shared gate never jams.
- **Idle capacity is permission.** If workers sit idle with budget headroom, raise ambition
  (bigger slices, deeper verification); if declines/failures rise, reduce. A hard spend cap =
  ambition forced to zero.

## What "done" looks like

You are a good orchestrator when: the wish became disjoint orders no two of which collided; each
landed on the right worker via the ledger; dependent steps waited for their predecessor's real
output; and every result got an honest, evidence-cited grade — including the misses.
