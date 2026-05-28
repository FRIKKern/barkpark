# AI CLI Task Workflow — Paperflow + PortableDoc + Barkpark

> **Tested 2026-05-28 against the live system (bd-shim → barkpark :4000).** Every command and output below was really run against the running stack — nothing is invented. Real `retest-945e28c-*` ids were generalized to `<placeholder>`; the structure is identical to what was tested.

This guide is for an **AI coding agent** (Claude Code, Cursor, Aider, any CLI) — or the human driving it — that wants to track its work as tasks and publish documents on this stack. Lean, plain, copy-pasteable.

## The system

Three pieces, one Postgres store:

- **Barkpark** — the Postgres document store. Tasks *and* papers are documents (`type ∈ {goal, phase, task, event, paper}`).
- **Paperflow** — the orchestration model plus `bd-shim`, a bd-CLI-compatible wrapper. An AI CLI runs `bd …` → bd-shim → barkpark HTTP (`/v1/tasks/*`). Unknown verbs fall through to real `bd`.
- **PortableDoc** — the block format for papers (headings / paragraphs / callouts / lists / code / tables). See [`../../portable-doc/examples/welcome.json`](../../portable-doc/examples/welcome.json).

```
AI CLI ──bd──────► bd-shim ──HTTP──► barkpark /v1/tasks      (task tracking)
       ──papers──► PortableDoc blocks ──► /v1/paperflow/papers  (artifacts)

  Goal hub (type:goal) ties them together:
    content.papers[]  +  the /v1/rail/goal-path event timeline
```

The goal document is the hub: it lists its papers in `content.papers[]`, and its lifecycle is the event timeline at `/v1/rail/goal-path`.

## Prerequisites

- Barkpark running on `:4000` — see [`./SETUP.md`](./SETUP.md).
- The bd-shim integration installed and flipped on — see [`./SETUP-WITH-PAPERFLOW.md`](./SETUP-WITH-PAPERFLOW.md).

Confirm the shim is active:

```bash
bd --version
# bd-shim 0.1.0 → http://localhost:4000
```

Tokens for direct HTTP calls:

- `barkpark-dev-token` — reading tasks, rail, timelines.
- `paperflow-dev-ingest-token` — publishing papers.

## The task lifecycle

The worked example: a **goal** → a **phase** → **two tasks with a dependency**, then drive them to done. Run these in order.

### 1. Create a goal

`bd create` writes to barkpark via the shim — `--type epic` maps to `kind:goal`.

```bash
bd create "my goal" --type epic --label myproj
# ✓ Created issue: <goal-id>
```

### 2. Create a phase

```bash
bd create "build phase" --type task --label kind:phase --label myproj --parent <goal-id>
# ✓ Created issue: <phase-id>
```

### 3. Create two tasks

```bash
bd create "task A" --type task --label myproj --parent <phase-id>
# ✓ Created issue: <task-A>

bd create "task B" --type task --label myproj --parent <phase-id>
# ✓ Created issue: <task-B>
```

### 4. List what landed in barkpark

```bash
bd list --label myproj
# shows the 4 docs: the goal, the phase, task A, task B
```

### 5. Add a dependency

B blocks on A. Bare ids work.

```bash
bd dep add <task-B> <task-A>
# ✓ Added dependency: <task-B> blocks on <task-A>
```

### 6. The dependency-aware ready queue (the centerpiece)

`bd ready` returns only unblocked work. **A appears; B does NOT** — it's waiting on A.

```bash
bd ready
# <task-A>   task A
# (task B is absent — blocked by A)
```

> **Caveat:** `bd ready --label <x>` does **not** yet scope (see Known Limitations #1). `bd ready` returns the **global** ready queue. In a multi-goal store, filter the output client-side by your label / namespace.

### 7. Claim and close A

```bash
bd update <task-A> --claim
# ✓ <task-A> → in_progress

bd close <task-A>
# ✓ <task-A> → done
```

> Claim **before** you close. `bd close` on an unclaimed task returns HTTP 409 (fencing — see Known Limitations #3).

### 8. Ready again → B is now unblocked

This is the whole point: closing a blocker unblocks its dependents.

```bash
bd ready
# <task-B>   task B
# (now appears — A is done)
```

### 9. Inspect

```bash
bd show <id>            # single doc, JSON
bd list --label myproj  # filtered list
```

### 10. Close the goal

```bash
bd epic close <goal-id>
# ✓ <goal-id> → done
```

> `bd epic close` is a **forced** close — it closes the goal regardless of child state (Known Limitations #4).

## Event timeline (the rail)

Every claim and close emits a `mutation_event`. Read the goal's timeline directly:

```bash
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  "http://localhost:4000/v1/rail/goal-path?goal=<goal-id>"
# {"ok":true,"events":[
#   {"kind":"task.closed", ...},
#   {"kind":"task.claimed", ...}
# ]}
```

> **Caveat:** the goal-close event arrives with `kind` `task.closed` (carrying the goal's title), **not** `goal.closed`. Kind does not map 1:1 to type (Known Limitations #5).

## Producing documents / papers (PortableDoc)

An AI CLI publishes a document as a paper — an array of PortableDoc blocks.

```bash
curl -s -X POST \
  -H "Authorization: Bearer paperflow-dev-ingest-token" \
  -H "Content-Type: application/json" \
  http://localhost:4000/v1/paperflow/papers \
  -d '{"slug":"my-paper","style":"article","blocks":[
        {"type":"heading","level":1,"text":"Title"},
        {"type":"paragraph","content":[{"type":"text","value":"Body."}]}
      ]}'
# {"ok":true,"slug":"my-paper","rev":1,"liveview_path":"/papers/my-paper"}
```

Renders at `GET /papers/<slug>`.

**Block-stream variant** — apply one `DocPatchOp` to an existing paper:

```bash
POST /v1/paperflow/papers/:slug/ops
# op ∈ { append-block, insert-after, patch-block, replace-block, remove-block }
```

**Link a paper to a goal** by adding it to the goal's `content.papers[]`.

> **Caveat:** assign a per-block `"id"` to every block if you need the live stream to be exact (Known Limitations #2). See [`../../portable-doc/examples/welcome.json`](../../portable-doc/examples/welcome.json) for the full block vocabulary with ids.

## Known limitations

Five tested residuals. Each has a workaround.

1. **`bd ready --label <x>` ignores the filter** — it returns the global ready queue. Filter client-side by your namespace / label until phase-scoping is wired through the shim.
2. **Papers with blocks that lack an `"id"` render only the LAST block** in the live LiveView (`/papers/:slug`) due to a stream-dedup bug. The stored data and `body_html` are correct — assign per-block ids if you need the live stream exact.
3. **`bd close` on an unclaimed task returns HTTP 409 (fencing).** Claim first (`bd update <id> --claim`), then close.
4. **`bd epic close <goal-id>` is a forced close** — it closes regardless of child state. It is *not* gated on all children being done.
5. **Goal-close events carry kind `task.closed`** (with the goal title), not a distinct `goal.closed`.

## Troubleshooting

**`bd` errors / everything 500s** — check barkpark is up:

```bash
curl -s localhost:4000/api/schemas
```

If it 500s with `config/dev.exs changed, must restart`, that's the dev code-reloader wedge. Recompile in place (incremental, no restart needed):

```bash
cd barkpark/api && mix compile
```

Restart the service if needed:

```bash
launchctl kickstart -k gui/$(id -u)/dev.pelle.barkpark
```

**`bd close` says fenced / 409** — claim the task first (`bd update <id> --claim`), then close.

**Large `bd list --json` piped to a tool truncates** — that's a downstream pipe buffer, not `bd`. Redirect to a file or scope with `--label`:

```bash
bd list --json --label myproj > tasks.json
```

---

See also: [`./SETUP.md`](./SETUP.md) · [`./SETUP-WITH-PAPERFLOW.md`](./SETUP-WITH-PAPERFLOW.md)
