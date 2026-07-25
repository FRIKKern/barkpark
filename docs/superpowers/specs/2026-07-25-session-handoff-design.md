<!-- doc-tier: human | canonical-for: session-handoff-design | budget: 9000tok -->

# Session Handoff — first-class `session` type + upload/resume skill pair

**Date:** 2026-07-25 · **Status:** approved design, pre-implementation
**Wish:** "With a Barkpark skill we should be able to upload our conversation to Barkpark so we can continue somewhere else with the same context." (Claude Code, Codex, or any harness with `bp` configured.)

## Decisions (user-approved)

| Question | Decision |
|---|---|
| Payload | **Both, linked** — distilled synthesis is the primary document; scrubbed raw transcript attached |
| Content model | **First-class `session` type** (approach B) — blocks body, opens in the real paper editor; server-side generalization included |
| Task linkage | Tasks reference the sessions they were worked in (`sessions[]` on type:task) |
| Resume | Full skill pair: `session-upload` + `session-resume` |
| Target server | Whatever the project's active `bp` context points at (`bp whoami`) — no pinning |
| Secrets | Pattern-scrub transcript before upload (no confirm step) |
| CLI surface | Dedicated `bp session` verb group |

## Flow

```
UPLOAD (machine A, end of session)                    RESUME (machine B)
──────────────────────────────────                    ──────────────────
conversation in context                               /session-resume <slug>
   │  1. distill → synthesis blocks                        │
   │  2. locate transcript JSONL                           │  bp session view <slug>
   │     (harness-aware path)                              │  → synthesis loads into context
   │  3. scrub secrets (helpers/scrub.sh)                  │  → metadata: cwd, git HEAD, harness
   │  4. bp media upload transcript ────┐                  │  → transcript URL on demand
   │  5. bp session publish <slug> ─────┼──► Barkpark ◄────┘
   │     (type:session, blocks body,    │    server the
   │      metadata fields, media ref)   │    project is
   │  6. stamp touched tasks:           │    connected to
   │     sessions[] += session ref ─────┘
   └─ 7. print resume one-liner
```

## 1. Server: `session` schema

New content type `session`. Blocks body (portable-doc) + structured fields:

| Field | Type | Notes |
|---|---|---|
| `title` | string | required |
| `harness` | string enum | `claude-code` \| `codex` \| `other` |
| `session_uuid` | string | harness-native session id |
| `cwd` | string | working directory on origin machine |
| `machine` | string | hostname of origin machine |
| `git_head` | string | commit SHA at upload time |
| `git_branch` | string | branch at upload time |
| `started_at` / `ended_at` | datetime | session bounds |
| `transcript` | reference, refType `mediaAsset` | scrubbed JSONL; optional (synthesis-only uploads allowed) |
| `status` | string enum | `open` \| `resumed` \| `superseded` |

Schema defined in code following the `api/lib/barkpark/tasks/schema.ex` pattern, **registered by the Bulldocs plugin** (sessions depend on paper machinery, which is Bulldocs — no new plugin). Slug convention: `session-YYYY-MM-DD-<topic>`.

Session docs do **not** list their tasks — backlinks (`bp doc backlinks`) give the reverse view from the task-side references.

## 2. Server: paper-editor + ingest generalization

The paper machinery is hard-gated to `type == "paper"` today. Generalize to a **blocks-type whitelist** `{paper, session}`:

| File | Change |
|---|---|
| `api/lib/barkpark/content/papers.ex` | `upsert_paper` / `apply_paper_block_op` take a type param, default `"paper"` (existing callers unmoved); `@paper_type` unpinned behind the param |
| `api/lib/barkpark/plugins/bulldocs.ex` | ingest + ops routes accept `type` from the whitelist; manifest gains the `bp session` verb group |
| `api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex` | accept + validate `type` param; unknown/non-whitelist type → 422 |
| `api/lib/barkpark_web/studio/pane_builder.ex` | editor dispatch at `:415` and backlinks-open at `:202` key on the whitelist instead of `== "paper"` → sessions open in the real paper pane |
| `api/lib/barkpark/content/papers/block_ops.ex` | `apply_document_block_op/4` already generalized — wire the HTTP ops path through it for non-paper types |

Publish wall (description + published tags) applies to sessions the same as papers; the upload skill supplies both.

## 3. Server: task → session reference

- One additive field in `api/lib/barkpark/tasks/schema.ex`: `sessions` — arrayOf reference, `refType: "session"`. A task worked across three sessions references all three.
- `POST /v1/tasks/:id/sessions` mirroring the existing `/papers` endpoint pattern (`schema.ex:671`).

## 4. CLI: `bp session` verb group

Manifest-driven (like `bp task`), served from the Bulldocs manifest:

```
bp session publish <slug> --file session.json    # ingest: metadata fields + blocks + transcript ref
bp session view <slug>                           # read-back: metadata + synthesis blocks
bp session link-task <task-id> <slug>            # POST /v1/tasks/:id/sessions
```

Patch (rare) rides the generalized ops endpoint; no dedicated verb in v1.

## 5. Upload skill — `.claude/skills/session-upload/`

`SKILL.md` + `helpers/scrub.sh`. Procedure is pure prose + `bp` CLI so Codex can execute it from AGENTS.md. Steps:

1. **Distill.** The in-session model writes the synthesis as paper blocks from a fixed template: current task · progress · key files · decisions · next steps · learnings (the PRIOR SESSION SYNTHESIS shape).
2. **Locate transcript** (harness-aware): Claude Code → `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` (connectors charter D135); Codex → its sessions dir. Not found → publish synthesis-only and say so loudly in the output and in the session doc.
3. **Scrub** via `helpers/scrub.sh`: replace known token shapes with `[REDACTED]` — `bp_admin_*`, `Bearer <token>`, values of `BARKPARK_*_TOKEN`, GitHub `ghp_*`/`github_pat_*`, AWS `AKIA*` + secret pairs, APNs `.p8` bodies, generic `-----BEGIN * PRIVATE KEY-----` blocks. Output to scratchpad, never in-repo.
4. **Upload transcript:** `bp media upload --file <scrubbed>.jsonl` (100 MB endpoint cap — over-cap fails loud with split instructions, never truncates silently).
5. **Publish session:** `bp session publish session-YYYY-MM-DD-<topic> --file session.json` with metadata (harness, uuid, cwd, machine, git head/branch, bounds, transcript ref, `status: open`), description, tags (`session` + topic tag, published `type:tag` docs per publish wall).
6. **Stamp tasks:** `bp session link-task` for every task claimed/stamped/closed during the conversation. Session publishes **first**, then stamps — a failed stamp lists exactly which tasks weren't linked.
7. **Print the resume one-liner** for the other machine.

## 6. Resume skill — `.claude/skills/session-resume/`

Takes a slug. Steps: `bp session view <slug>` → load synthesis + metadata into context → **warn if cwd/repo/branch mismatch** the metadata → mark session `status: resumed`. Transcript is offered as a `/files/…` URL for drill-down, never auto-downloaded. No-arg form does nothing clever; SKILL.md documents the one-liner query for listing recent sessions (by type + `session` tag, newest first).

## Error handling

- Publish failure → nothing half-linked (session-first ordering; failed task stamps enumerated).
- Transcript missing / over-cap → loud, synthesis-only fallback recorded in the doc.
- Resume of nonexistent slug → fail loud + print the listing query.
- Resume in wrong repo/branch → warning, not a block.

## Testing

- **Elixir:** ingest with `type: session` round-trips; non-whitelist type → 422; pane_builder dispatches session → paper pane; `POST /v1/tasks/:id/sessions` appends and dedupes; existing paper paths untouched (default param regression).
- **Skill smoke:** upload from a live session → resume in a fresh session against local server; verify synthesis fidelity, transcript link, task backlinks.

## Out of scope (YAGNI)

- Auto-upload on session end (manual invocation only, v1)
- Cross-server session sync / mirroring
- Studio UI custom session pane (paper pane is the UI)
- Auto-list in resume skill (documented query instead)
- Diff/merge of concurrent sessions
