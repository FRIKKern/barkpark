<!-- doc-tier: human | canonical-for: session-handoff-design | budget: 9000tok -->

# Session Handoff — first-class `session` type + upload/resume skill pair

**Date:** 2026-07-25 · **Status:** approved design, pre-implementation
**Wish:** "With a Barkpark skill we should be able to upload our conversation to Barkpark so we can continue somewhere else with the same context." (Claude Code, Codex, or any harness with `bp` configured.)

## Decisions (user-approved)

| Question | Decision |
|---|---|
| Payload | **Both, linked** — distilled synthesis is the primary document; scrubbed raw transcript attached |
| Content model | **First-class `session` type** (approach B) — blocks body, opens in the real paper editor; server-side generalization included |
| Capture cadence | **Event-driven living document** — opened at session start, `bp session log` per milestone (paper published, task closed, epic wave sealed, git push), checkpoint refreshes synthesis + transcript, close finalizes. Not command-only. |
| Logging mechanism | **Agent discipline v1** (skills/workflows/checklists instruct the log calls); **server auto-log is the filed next step** (v1.5: `X-Barkpark-Session` header, task-close/paper-publish endpoints append server-side) |
| Task linkage | Tasks reference the sessions they were worked in (`sessions[]` on type:task) |
| Resume | Full skill pair: session lifecycle skill + `session-resume` |
| Target server | Whatever the project's active `bp` context points at (`bp whoami`) — no pinning |
| Secrets | Pattern-scrub transcript before upload (no confirm step) |
| CLI surface | Dedicated `bp session` verb group |

## Lifecycle

```
SESSION LIFECYCLE (living document on the server)          RESUME (machine B)
─────────────────────────────────────────────────          ──────────────────
bp session open  ──► log ── log ── log ── … ──► checkpoint ──► close
   (at start,         │      │      │              │             │
    status:open,   paper    task   git push    synthesis     final synthesis
    metadata       published closed            refresh +     + final scrubbed
    seeded)                                    transcript    transcript,
                                               snapshot      status: closed
                                                                  │
/session-resume <slug> ◄──────────────────────────────────────────┘
   bp session view → synthesis + metadata + event trail into context
   → transcript URL on demand → status: resumed
```

**Crash safety is the point:** a session that dies mid-flight never runs its close — but every paper, task, and push is already on the server as an event with a ref, so a resume still stands on the real trail. The synthesis is the readable summary; the events are the ground truth between checkpoints.

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
| `status` | string enum | `open` \| `closed` \| `resumed` \| `superseded` |
| `events` | arrayOf object | append-only trail: `{ts, kind, ref?, note?}`; kinds: `paper-published` \| `task-closed` \| `epic-wave-complete` \| `push` \| `note` |

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

**Visibility + wall (amended at final review).** `session.json` is `visibility: "private"` — a session carries cwd, hostname, git branch/HEAD and a transcript ref, so it must never be anonymously readable (the `form_response` precedent). Sessions are also deliberately **unwalled**: they stay out of `AuthoringWall`'s `@walled_types` (`~w(paper task)`). `description` + `tags` are RECOMMENDED for discoverability and the upload skill still supplies both, but nothing on the server enforces them for a session. Rationale: the real risk was anonymous exposure, which `private` closes; wall enforcement would gate machine-generated lifecycle records for no curation benefit. All three surfaces (schema, `AuthoringWall`, skill prose) agree on this.

## 3. Server: task → session reference

- One additive field in `api/lib/barkpark/tasks/schema.ex`: `sessions` — arrayOf reference, `refType: "session"`. A task worked across three sessions references all three.
- `POST /v1/tasks/:id/sessions` mirroring the existing `/papers` endpoint pattern (`schema.ex:671`).

## 4. CLI: `bp session` verb group

Manifest-driven (like `bp task`), served from the Bulldocs manifest:

```
bp session open <slug> --file meta.json          # create at session start: metadata, status: open
bp session log <slug> --kind <kind> [--ref <id>] [--note "…"]   # append one event (server stamps ts)
bp session publish <slug> --file session.json    # upsert synthesis blocks + metadata (checkpoint/close)
bp session view <slug>                           # read-back: metadata + events + synthesis blocks
bp session link-task <task-id> <slug>            # POST /v1/tasks/:id/sessions
```

Block-level patch (rare) rides the generalized ops endpoint; no dedicated verb in v1. `log` is deliberately one cheap call — it must be frictionless enough to run after every milestone.

## 5. Session lifecycle skill — `.claude/skills/session/`

`SKILL.md` + `helpers/scrub.sh`. Procedure is pure prose + `bp` CLI so Codex can execute it from AGENTS.md.

**Open (session start):** `bp session open session-YYYY-MM-DD-<topic>` with metadata (harness, uuid, cwd, machine, git head/branch, `started_at`, `status: open`), description, tags (`session` + topic tag — recommended for discoverability, not server-enforced; sessions are unwalled per §2). Slug stays in conversation context.

**Log (every milestone, agent-driven v1):** one `bp session log` call per event. Wired into the places milestones already happen:

| Milestone | Where the log call is written in |
|---|---|
| Paper published | paper-publish procedure (`docs/cheatsheets/papers.md` note) |
| Task closed | fleet-listener close step; session-completion checklist step 3 |
| Epic wave complete | `bp-epic-cycle` workflow (wave seal step) |
| Git push | session-completion checklist step 4 (after `git push` succeeds) |

Log failures are **non-blocking**: never fail a task close or a push because the session log call failed — warn loudly and continue.

**Checkpoint (procedure, on demand / after big milestones):**
1. **Distill.** The in-session model rewrites the synthesis blocks from the fixed template: current task · progress · key files · decisions · next steps · learnings (the PRIOR SESSION SYNTHESIS shape) → `bp session publish`.
2. **Locate transcript** (harness-aware): Claude Code → `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` (connectors charter D135); Codex → its sessions dir. Not found → synthesis-only, said loudly in the output and in the session doc.
3. **Scrub** via `helpers/scrub.sh`: replace known token shapes with `[REDACTED]` — `bp_admin_*`, `Bearer <token>`, values of `BARKPARK_*_TOKEN`, GitHub `ghp_*`/`github_pat_*`, AWS `AKIA*` + secret pairs, APNs `.p8` bodies, generic `-----BEGIN * PRIVATE KEY-----` blocks. Output to scratchpad, never in-repo.
4. **Upload transcript snapshot:** `bp media upload --file <scrubbed>.jsonl` (100 MB endpoint cap — over-cap fails loud with split instructions, never truncates silently); update the `transcript` ref.

**Close (session end):** final checkpoint + `status: closed` + **stamp tasks** — `bp session link-task` for every task claimed/stamped/closed during the conversation (belt-and-braces over the per-event logs). Then print the resume one-liner for the other machine.

## 5b. Toward auto-log (v1.5 — filed as a bp task, built next)

Remove reliance on agent discipline for the events Barkpark itself witnesses: `bp` sends an `X-Barkpark-Session: <slug>` header whenever a session is open (`--session` flag / `BARKPARK_SESSION` env / config binding), and the task-close and bulldocs-publish endpoints append the event server-side when the header is present. Git pushes stay agent/hook-logged (Barkpark never sees them). Harness hooks (PostToolUse on `git push`) remain out of scope — harness-specific plumbing for the least portability.

## 6. Resume skill — `.claude/skills/session-resume/`

Takes a slug. Steps: `bp session view <slug>` → load synthesis + metadata + **event trail** into context (the trail is ground truth for anything after the last checkpoint — an `open` session with no synthesis still resumes from its events) → **warn if cwd/repo/branch mismatch** the metadata → mark session `status: resumed`. Transcript is offered as a `/files/…` URL for drill-down, never auto-downloaded. No-arg form does nothing clever; SKILL.md documents the one-liner query for listing recent sessions (by type + `session` tag, newest first).

## Error handling

- Publish failure → nothing half-linked (session-first ordering; failed task stamps enumerated).
- `bp session log` failure → non-blocking: warn loudly, never abort the milestone that triggered it.
- Transcript missing / over-cap → loud, synthesis-only fallback recorded in the doc.
- Resume of nonexistent slug → fail loud + print the listing query.
- Resume in wrong repo/branch → warning, not a block.
- Resume of a crashed (`open`, stale) session → allowed; the event trail is the context.

## Testing

- **Elixir:** ingest with `type: session` round-trips; non-whitelist type → 422; `session log` appends with server timestamp and rejects unknown kinds; events are append-only; pane_builder dispatches session → paper pane; `POST /v1/tasks/:id/sessions` appends and dedupes; existing paper paths untouched (default param regression).
- **Skill smoke:** open at session start → log a paper-publish, a task-close, a push → checkpoint → close → resume in a fresh session against local server; verify event trail, synthesis fidelity, transcript link, task backlinks. Crash case: open + logs, no close → resume works from the trail.

## Out of scope (YAGNI)

- Harness hooks for auto-logging (PostToolUse on `git push` etc.) — harness-specific, least portable
- Cross-server session sync / mirroring
- Studio UI custom session pane (paper pane is the UI)
- Auto-list in resume skill (documented query instead)
- Diff/merge of concurrent sessions

Server-side auto-log via `X-Barkpark-Session` is **not** out of scope — it is v1.5, filed as a bp task (§5b).
