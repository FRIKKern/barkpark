<!-- doc-tier: agent | canonical-for: paperflow-tasks-cutover | budget: 600tok -->
# Barkpark as paperflow's Task Store — Cutover procedure (W7)

> Tested 2026-05-28. W7 flip: executed and verified live.

**Key facts (A3):** since 2026-05-28 `.beads/FROZEN` is set — tasks are `type:task` documents in Barkpark's own Postgres; `bd` is a shim over `/v1/tasks`. There is no separate goal/phase/event type: a "goal" is a root task (no `content.parent_id`), a "phase" is ordered sibling tasks, nesting is recursive via `content.parent_id`.

## Prerequisites

- Barkpark running on `:4000` — after the flip every `bd` command routes through it
- paperflow installed + W7 binaries on PATH (see Step 2)
- LaunchAgent keeping barkpark alive on macOS (see `docs/setup/SETUP.md`)

## Step 1 — confirm barkpark stays up

```bash
kill <phx.server-pid>
curl -s localhost:4000/api/schemas | head -c 60   # must come back up
```

## Step 2 — install bridge binaries

Copy to `~/.local/bin/`: `bd-shim`, `paperflow-flip-to-tasks`, `paperflow-flip-rollback`, `paperflow-import-bd`, `paperflow-doctor`, `paperflow-active-scope`, `paperflow-doc-meta`, `paperflow-mirror-phase`, `paperflow-dock-daemon`.

Copy to `~/.local/lib/`: `barkpark-mirror.sh`.

`bd-shim` is a `bd`-CLI-compatible wrapper. It translates `bd show/list/ready/update/dep` into barkpark HTTP calls and falls through to the real `bd` for anything it doesn't handle. There is no `epic` translation — goal/phase/event types and `bd epic` were intentionally removed; close the root task with `bd close <id>`.

## Step 3 — configure dual-write and verify readiness (7/7 gate)

```bash
export PAPERFLOW_MIRROR_GOALS=1
export PAPERFLOW_BARKPARK_URL=http://localhost:4000
~/.local/bin/paperflow-doctor --ensure-tasks --gate-for-flip   # must be ok:true, exit 0
```

7 checks: `barkpark_reachable`, `dual_write_enabled`, `active_goal_mirrored`, `importer_run_recent`, `orphan_task_count`, `shim_on_path`, `gate_e_recent_run`. All must pass.

## Step 4 — the atomic flip

```bash
~/.local/bin/paperflow-flip-to-tasks --dry-run   # preview 6 phases
~/.local/bin/paperflow-flip-to-tasks --apply     # the cutover
```

Phases: pre-flight gate → freeze `bd` writes → import to barkpark (rate-limits are non-fatal, importer grinds through) → PATH swap (`bd` → `bd-shim`) → pointer repoint (noop, `doc_id == bd-id`) → restore stock git hooks → verify + flag.

## Verify post-flip

```bash
bd --version          # → bd-shim 0.1.0 → http://localhost:4000
bd ready              # → live barkpark tasks
bd list --json        # → task docs from barkpark
```

## Rollback — one move (idempotent)

```bash
paperflow-flip-rollback
```

Removes the `bd` symlink, restores `core.hooksPath`, removes `FROZEN` markers. Original Dolt store is intact.

## Troubleshooting

- **`bd` commands error or hang** — barkpark is down. Probe: `curl -s localhost:4000/api/schemas`. Restart: `launchctl kickstart -k gui/$(id -u)/dev.pelle.barkpark`.
- **`bd epic close <id>` says "not found"** — expected and permanent. Close root tasks with `bd close <id>`.
- **Import emits HTTP 429** — non-fatal; importer continues.
