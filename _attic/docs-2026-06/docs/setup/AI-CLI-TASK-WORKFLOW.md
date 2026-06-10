ARCHIVED — do not load; superseded by docs/setup/TASK-SYSTEM.md (bd/bd-shim era — every command here predates the bp task verbs and the bulldocs ingest path)

# AI CLI Task Workflow — Paperflow + PortableDoc + Barkpark

> **Tested 2026-05-28 against the live system (bd-shim → barkpark :4000).** Every command and output below was really run against the running stack — nothing is invented. Real `retest-945e28c-*` ids were generalized to `<placeholder>`; the structure is identical to what was tested.

This guide is for an **AI coding agent** (Claude Code, Cursor, Aider, any CLI) — or the human driving it — that wants to track its work as tasks and publish documents on this stack. Lean, plain, copy-pasteable.

## The system

Three pieces, one Postgres store:

- **Barkpark** — the Postgres document store. Tasks *and* papers are documents (`type ∈ {task, paper}`). Everything is a **task**: a "goal" is just a *root* task (no `content.parent_id`), a "phase" is just ordered sibling tasks, and a task nests under another task via `content.parent_id` (recursive).
- **Paperflow** — the orchestration model plus `bd-shim`, a bd-CLI-compatible wrapper. An AI CLI runs `bd …` → bd-shim → barkpark HTTP (`/v1/tasks/*`). Unknown verbs fall through to real `bd`.
- **PortableDoc** — the block format for papers (headings / paragraphs / callouts / lists / code / tables). See the worked sample [`../internal/pdrender/testdata/sample_m1.json`](../internal/pdrender/testdata/sample_m1.json), or the authoritative block vocabulary in `api/lib/barkpark/portable_doc/render.ex` (`compose_block`/`compose_inline`).

```
AI CLI ──bd──────► bd-shim ──HTTP──► barkpark /v1/tasks      (task tracking)
       ──papers──► PortableDoc blocks ──► /v1/paperflow/papers  (artifacts)

  A root task ties them together:
    content.papers[]  +  its child tasks (its "rail")
```

A root task is the hub: it lists its papers in `content.papers[]` (managed via `POST /v1/tasks/:doc_id/papers`), and its "rail" is its direct child tasks in chronological order — read them with `GET /v1/tasks?parent=<doc_id>`, or inline as the `children` field on `GET /v1/tasks/:doc_id`.

## Prerequisites

- Barkpark running on `:4000` — see [`./SETUP.md`](./SETUP.md).
- The bd-shim integration installed and flipped on — see [`./paperflow-cutover.md`](./paperflow-cutover.md).

Confirm the shim is active:

```bash
bd --version
# bd-shim 0.1.0 → http://localhost:4000
```

Tokens for direct HTTP calls:

- `barkpark-dev-token` — reading and writing tasks (`/v1/tasks/*`).
- `paperflow-dev-ingest-token` — publishing papers.

## The task lifecycle

Everything is a **task**. The worked example: a **root task** (what you'd call the "goal") → **two child tasks under it with a dependency**, then drive them to done. Run these in order.

### 1. Create the root task (the "goal")

`bd create` writes to barkpark via the shim. A task with no parent is a root task — it plays the "goal" role.

```bash
bd create "my goal" --type task --label myproj
# ✓ Created issue: <root-id>
```

### 2. Create two child tasks under it

Nest each task under the root via `--parent` (the shim writes `content.parent_id`).

```bash
bd create "task A" --type task --label myproj --parent <root-id>
# ✓ Created issue: <task-A>

bd create "task B" --type task --label myproj --parent <root-id>
# ✓ Created issue: <task-B>
```

### 3. List what landed in barkpark

```bash
bd list --label myproj
# shows the 3 docs: the root task, task A, task B
```

### 4. Add a dependency

B blocks on A. Bare ids work.

```bash
bd dep add <task-B> <task-A>
# ✓ Added dependency: <task-B> blocks on <task-A>
```

### 5. The dependency-aware ready queue (the centerpiece)

`bd ready` returns only unblocked work. **A appears; B does NOT** — it's waiting on A.

```bash
bd ready
# <task-A>   task A
# (task B is absent — blocked by A)
```

> **Caveat:** `bd ready --label <x>` does **not** yet scope (see Known Limitations #1). `bd ready` returns the **global** ready queue. In a multi-goal store, filter the output client-side by your label / namespace.

### 6. Claim and close A

```bash
bd update <task-A> --claim
# ✓ <task-A> → in_progress

bd close <task-A>
# ✓ <task-A> → done
```

> Claim **before** you close. `bd close` on an unclaimed task returns HTTP 409 (fencing — see Known Limitations #3).

### 7. Ready again → B is now unblocked

This is the whole point: closing a blocker unblocks its dependents.

```bash
bd ready
# <task-B>   task B
# (now appears — A is done)
```

### 8. Inspect

```bash
bd show <id>            # single doc, JSON
bd list --label myproj  # filtered list
```

### 9. Close the root task

The root task is just a task — close it like any other (claim first, then close).

```bash
bd update <root-id> --claim
bd close <root-id>
# ✓ <root-id> → done
```

> There is **no** epic/goal close surface. `bd epic close`, `GET /v1/tasks/epic/close-eligible`, and the `--type epic` epic concept were **removed** — a root task closes through the ordinary claim → close path. (If your `bd` still offers `bd epic …`, treat it as an **accepted, intentional breakage** — it falls through to real `bd` and does not talk to barkpark.)

## A task's rail (its child tasks)

A task's "rail" is its direct child tasks in chronological order — there is **no** separate event-timeline surface (`/v1/rail/*` was removed). Read the children two ways.

Inline, as the `children` field on the single-task fetch:

```bash
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  "http://localhost:4000/v1/tasks/<root-id>"
# {"ok":true,"task":{ ...,
#   "children":[ {"doc_id":"<task-A>", ...}, {"doc_id":"<task-B>", ...} ],
#   "child_count":2 }}
```

Or directly, as a chronological list, with the `parent` query param:

```bash
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  "http://localhost:4000/v1/tasks?parent=<root-id>"
# {"ok":true,"tasks":[
#   {"doc_id":"<task-A>", ...},   # oldest first
#   {"doc_id":"<task-B>", ...}
# ]}
```

Because parenting is recursive, the same call walks any level: pass any task's id as `parent=` to get that task's own rail.

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

**Link a paper to a task** by adding it to the task's `content.papers[]`:

```bash
curl -s -X POST \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  "http://localhost:4000/v1/tasks/<root-id>/papers" \
  -d '{"add":["my-paper"]}'        # or {"remove":["my-paper"]}
```

> **Caveat:** assign a per-block `"id"` to every block if you need the live stream to be exact (Known Limitations #2). See [`../internal/pdrender/testdata/sample_m1.json`](../internal/pdrender/testdata/sample_m1.json) for a worked block sample with ids.

## Known limitations

Three tested residuals. Each has a workaround.

1. **`bd ready --label <x>` ignores the filter** — it returns the global ready queue. Filter client-side by your namespace / label until label-scoping is wired through the shim.
2. **Papers with blocks that lack an `"id"` render only the LAST block** in the live LiveView (`/papers/:slug`) due to a stream-dedup bug. The stored data and `body_html` are correct — assign per-block ids if you need the live stream exact.
3. **`bd close` on an unclaimed task returns HTTP 409 (fencing).** Claim first (`bd update <id> --claim`), then close.

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

See also: [`./SETUP.md`](./SETUP.md) · [`./paperflow-cutover.md`](./paperflow-cutover.md)
