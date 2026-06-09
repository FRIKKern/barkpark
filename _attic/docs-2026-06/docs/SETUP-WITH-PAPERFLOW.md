ARCHIVED — do not load; facts moved to docs/setup/paperflow-cutover.md
<!-- doc-tier: cold | canonical-for: paperflow-cutover-legacy | budget: 1200tok -->
# Barkpark as paperflow's Task Store — Integration & Cutover (W7)

> Tested 2026-05-28 on Elixir 1.19.5 / Postgres 17.9 / macOS — the W7 flip, executed and verified live.

paperflow historically tracked tasks in Beads (`bd`, a local Dolt store). Wave 7 retires `bd` onto barkpark's Postgres document substrate: everything becomes a `type:task` document. There is no separate goal/phase/event type — a "goal" is just a **root task** (no `content.parent_id`), a "phase" is just **ordered sibling tasks**, and a task nests under another task via `content.parent_id` (recursive). A task's "rail" is its direct child tasks in chronological order — fetched via `GET /v1/tasks?parent=<doc_id>`, and also returned inline as the `children` field (plus `child_count`) on `GET /v1/tasks/:doc_id`. This guide is the integration plus the atomic cutover. Every step below was executed and verified live.

## Prerequisites

| Prerequisite | Why |
|---|---|
| A working barkpark on `:4000` | Post-flip, every `bd` command routes through it (see [SETUP.md](./SETUP.md)) |
| paperflow installed | The host that consumes the task store |
| W7 binaries on paperflow `main` | The bridge + flip tooling, copy-deployed below |

## Step 1 — barkpark as a persistent service

The integration **requires barkpark up**: after the flip, every `bd` command routes through it. Use the LaunchAgent from [SETUP.md](./SETUP.md#keep-alive-on-macos) so the server survives logout/reboot.

Verify the `KeepAlive` respawn works before you depend on it:

```bash
# find the phx.server PID and kill it; launchd should bring it straight back
kill <phx.server-pid>
curl -s localhost:4000/api/schemas | head -c 60     # → comes back up
```

If it doesn't respawn, fix the LaunchAgent before going further — the flip assumes barkpark is always reachable.

## Step 2 — install the bridge binaries

These came from paperflow `main` — this is a **copy-deploy**; wiring them into `install.sh` is a separate task.

To `~/.local/bin/`:

```
bd-shim
paperflow-flip-to-tasks
paperflow-flip-rollback
paperflow-import-bd
paperflow-doctor
paperflow-active-scope
paperflow-doc-meta
paperflow-mirror-phase
paperflow-dock-daemon
```

To `~/.local/lib/`:

```
barkpark-mirror.sh
```

### What `bd-shim` is

`bd-shim` is a `bd`-CLI-compatible wrapper. It translates `bd show / list / ready / update / dep` into barkpark HTTP calls, and **falls through to the real `bd`** for any command it doesn't handle. (There is no `epic` translation — the goal/phase/event types and `bd epic` were intentionally removed; everything is a task. See [Removed: goal/phase/event and `bd epic`](#removed-goalphaseevent-and-bd-epic).) Environment:

| Var | Default |
|---|---|
| `BARKPARK_URL` | `http://localhost:4000` |
| `BARKPARK_TOKEN` | `barkpark-dev-token` |

## Step 3 — configure dual-write and verify readiness

```bash
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL=http://localhost:4000
~/.local/bin/paperflow-doctor --ensure-tasks --gate-for-flip   # must be ok:true, exit 0 (7/7)
```

The gate runs 7 checks — all must pass before the flip is allowed:

| # | Check |
|---|---|
| 1 | `barkpark_reachable` |
| 2 | `dual_write_enabled` |
| 3 | `active_goal_mirrored` |
| 4 | `importer_run_recent` |
| 5 | `orphan_task_count` |
| 6 | `shim_on_path` |
| 7 | `gate_e_recent_run` |

## Step 4 — the atomic flip

Tested — `--apply` exited 0 and was verified live.

```bash
~/.local/bin/paperflow-flip-to-tasks --dry-run   # preview the 6 phases, executes nothing
~/.local/bin/paperflow-flip-to-tasks --apply     # the real cutover
```

The 6 phases (from the tested run):

| Phase | Action |
|---|---|
| 0 | **Pre-flight gate** — re-runs the 7 checks from Step 3. |
| 1 | **Freeze `bd` writes** — drops a `FROZEN` marker per store. |
| 2 | **Import for real** — `paperflow-import-bd --apply` POSTs all `.beads` task rows to barkpark (idempotent `createIfNotExists`). NOTE: barkpark may emit HTTP 429 rate-limits mid-import — the importer grinds through them. |
| 3 | **PATH swap** — symlinks `~/.local/bin/bd → ~/.local/bin/bd-shim`. The real `bd` stays reachable for shim passthrough. |
| 4 | **Pointer repoint** — noop today (`doc_id == bd-id`). |
| 5 | **Restore stock git hooks** — unsets `core.hooksPath` on both stores. |
| 6 | **Verify + flag.** |

## Verify post-flip

Tested results:

```bash
bd --version                          # → bd-shim 0.1.0 → http://localhost:4000
bd ready                              # → live barkpark tasks
bd list --json                        # → task docs from barkpark (root tasks are "goals")
```

## Rollback — one move

Tested via dry-run.

```bash
paperflow-flip-rollback               # or: paperflow-flip-to-tasks --rollback
```

It reads `~/.paperflow/flip-rollback.env` and:

1. Removes the `bd` symlink (restores `/opt/homebrew/bin/bd`).
2. Restores `core.hooksPath` on both stores.
3. Removes the `FROZEN` markers.

It is **idempotent**. The original Dolt store was never written during the new-store era, so it survives intact — rollback returns you to pre-flip Beads cleanly.

## Removed: goal/phase/event and `bd epic`

This is an accepted, deliberate removal — **not** a fixable bug. The model collapsed: **everything is a task.** There is no `goal` / `phase` / `event` document type. A "goal" is just a root task (a task with no `content.parent_id`); a "phase" is just ordered sibling tasks; nesting is recursive via `content.parent_id`. Consequently:

- **`bd epic close <goal-id>`, `bd create --type epic`, `bd epic` and friends are gone.** They do not work because there is no epic/goal type to close — close the root task with `bd close <id>` like any other task. If the shim returns "not found" for an epic command, that is the removed surface, not a defect to polish.
- **The `/v1/rail/*` surface (goal-path / event / diff) and `RailController` were removed.** A task's rail is its direct child tasks: `GET /v1/tasks?parent=<doc_id>`, also returned inline as the `children` field (with `child_count`) on `GET /v1/tasks/:doc_id`. A task references papers via `content.papers[]` (`POST /v1/tasks/:doc_id/papers {add,remove}`). Reads and writes on `/v1/tasks` authenticate with `Authorization: Bearer barkpark-dev-token`.

## Known rough edges (honest)

These are real, observed in the tested run:

1. **The import hit HTTP 429 rate-limits** mid-run. Non-fatal — the importer grinds through.
2. **barkpark must stay up.** If `bd` ever errors, first check barkpark, then restart it:

```bash
curl -s localhost:4000/api/schemas                          # is barkpark alive?
launchctl kickstart -k gui/$(id -u)/dev.pelle.barkpark      # restart it
```

## Troubleshooting

- **`bd` commands error or hang.** barkpark is down. Probe with `curl -s localhost:4000/api/schemas` (there is no `/health` endpoint). Restart with `launchctl kickstart -k gui/$(id -u)/dev.pelle.barkpark`.
- **`paperflow-doctor --gate-for-flip` not `ok:true`.** One of the 7 checks failed — read which. Common cause: `dual_write_enabled` (export `PAPERFLOW_MIRROR_GOALS=1`) or `shim_on_path` (ensure `~/.local/bin` is on `PATH`).
- **`bd epic close <goal-id>` (or any `bd epic` / `--type epic`) says "not found".** Expected and permanent — the goal/phase/event types and `bd epic` were intentionally removed; everything is a task. Close the root task with `bd close <id>` instead. See [Removed: goal/phase/event and `bd epic`](#removed-goalphaseevent-and-bd-epic).
- **Import emits HTTP 429.** Expected rate-limiting from barkpark; non-fatal, the importer continues.
- **Need to abort the cutover.** Run `paperflow-flip-rollback` — idempotent, restores the pre-flip state, and the original Dolt store is intact.