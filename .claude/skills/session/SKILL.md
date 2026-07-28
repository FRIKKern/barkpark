---
name: session
description: Open, log, checkpoint, and close a persistent Barkpark session record so work survives context limits, machine switches, and new conversations. Invoke at the START of any substantial work session ("start a session", "track this session", "begin session tracking") — and when invoked MID-conversation, the open captures the FULL active thread so far (first checkpoint distills the entire conversation, trail backfilled, transcript covers turn one onward), after every milestone during the session (a paper published, a task closed, an epic wave sealed, a successful git push), before context is likely to run out or before a long/risky operation ("checkpoint", "save progress", "write a checkpoint"), and at the END of a work session ("wrap up", "end of session", "close out", "hand off to another machine", "I'm done for now"). Produces a `type:session` document on the Barkpark server (via `bp session open|log|publish`) carrying metadata, a milestone event trail, synthesis blocks (current task, progress, key files, decisions, next steps, learnings), and an optional scrubbed transcript upload — the counterpart skill `session-resume` reads it back on the next machine or session.
---

# session — persistent session lifecycle

A Barkpark session is a `type:session` document that survives the conversation. It has
four verbs, all via the `bp` CLI (Codex-compatible — pure prose + `bp`, no harness-specific
tooling required):

- `bp session open <slug> --file <meta.json>` — create/update metadata. POST to the
  session upsert endpoint. The JSON payload MUST carry `"slug"` too — the positional
  arg is not injected into the body (a slug-less payload 422s with `missing_slug`).
  On CREATE, `blocks` defaults to `[]`; on subsequent metadata-only
  updates, existing `blocks` are left untouched (the upsert only replaces what you send).
- `bp session touch <slug> --conversation <uuid> --harness <h> --account <a> --machine <m>
  --cwd <c>` — register or refresh this harness conversation on the session's
  conversation registry (upsert by `--conversation` id). The server stamps
  `first_seen` (once) and `last_active` (every touch) — never client-supplied.
- `bp session log <slug> --kind <k> [--ref <r>] [--note <n>] [--conversation <uuid>]` —
  append one event to the trail. The server stamps `ts`. `kind` MUST be exactly one of
  `paper-published`, `task-closed`, `epic-wave-complete`, `push`, `note` — anything else
  is a 422. `--conversation` is optional provenance (which conversation logged the
  event), not required.
- `bp session publish <slug> --file <session.json>` — same upsert endpoint as `open`, used
  for checkpoints and the final close. Send `blocks` + whatever fields changed
  (`status`, `ended_at`, `transcript`, …). A metadata-only payload (no `blocks` key) does
  NOT wipe existing blocks.
- `bp session view <slug> -o json` — read metadata + events + blocks + `rev` back. Used by
  `session-resume`, not normally needed here.

Auth: `open`/`log`/`publish`/`view` are ingest-tier (`BARKPARK_INGEST_TOKEN`, with the
normal bearer token as fallback) — a 401 here usually means neither is configured in this
environment; check `bp whoami -o json` and the shell environment before assuming the
feature is broken. `link-task` is the one verb NOT on the ingest tier: it writes a task,
so it uses the regular bearer token (`BARKPARK_TOKEN`) like every other `bp task` call.

## 1. Open (once, at session start)

Pick a slug and HOLD ON TO IT for the rest of the conversation — every later command in
this skill and in `session-resume` needs it:

```bash
SLUG="session-$(date +%Y-%m-%d)-<short-topic-slug>"   # e.g. session-2026-07-26-session-handoff-skills
```

Best-effort transcript session id (Claude Code only — do not block on this, it's advisory):

```bash
CWD_SLUG=$(pwd | sed -e 's#[/.]#-#g')
CANDIDATE_UUID=$(ls -t "$HOME/.claude/projects/$CWD_SLUG"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)
```

If `$HOME/.claude/projects/$CWD_SLUG` doesn't exist, the computed slug is wrong (harness
versions vary in exactly what they fold) — fall back to listing the directory and
grepping for the repo name instead of giving up: `ls "$HOME/.claude/projects/" | grep
<repo-name>`.

Build the metadata payload. Sessions are **private and unwalled** on the server: the
`session` schema is `visibility: "private"` (a session carries cwd, hostname and git
state, so it is never anonymously readable — every read costs an ingest token), and
sessions are NOT in the publish wall's walled types. So `description` and `tags` are
**recommended, not enforced** — include them anyway, they are what makes a session
findable later. Use the `sessions` tag plus one topic tag:

```bash
WORK="${TMPDIR:-/tmp}/bp-session-$$"
mkdir -p "$WORK"
cat > "$WORK/meta.json" <<JSON
{
  "slug": "$SLUG",
  "title": "Session: <short human title>",
  "harness": "claude-code",
  "session_uuid": "${CANDIDATE_UUID:-}",
  "cwd": "$(pwd)",
  "machine": "$(hostname -s)",
  "git_head": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
  "git_branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "open",
  "description": "<what this session is doing — at least 20 characters, concrete>",
  "tags": [
    {"tag": "sessions", "strength": 80, "rationale": "This document is a tracked Barkpark work session."},
    {"tag": "<topic-tag>", "strength": 50, "rationale": "<why this topic tag applies — at least 20 chars>"}
  ]
}
JSON
bp session open "$SLUG" --file "$WORK/meta.json"
```

Tags on a session are free-form — the server does not require them to be registered
`type:tag` docs (that check is the publish wall, which sessions are outside of). If you
want a session's tags to line up with the rest of the corpus, pick from what's already
there: `bp doc ls tag`.

**Register this conversation.** Right after `open`, touch the session's conversation
registry so it's visible which harness conversations have worked on it. `$CONV_UUID` is
the same value the transcript-locating step above derives (`$CANDIDATE_UUID`) — if that
came back empty, generate one now and reuse it for the rest of this conversation (do not
regenerate per touch, or every checkpoint spawns a new registry entry):

```bash
CONV_UUID="${CANDIDATE_UUID:-$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')}"
ACCOUNT=$(jq -r '.oauthAccount.emailAddress // empty' ~/.claude.json 2>/dev/null)
[ -z "$ACCOUNT" ] && ACCOUNT=$(jq -r '..|.email? // empty' ~/.codex/auth.json 2>/dev/null | head -1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(git config user.email 2>/dev/null)
[ -z "$ACCOUNT" ] && ACCOUNT="$USER@$(hostname -s)"
bp session touch "$SLUG" --conversation "$CONV_UUID" --harness claude-code --account "$ACCOUNT" --machine "$(hostname -s)" --cwd "$(pwd)"
```

(Verify the `~/.claude.json` jq path against the real file on this machine — `jq
'.oauthAccount'` — and correct the snippet above if the key differs there.)

**Capture the full active thread, immediately.** Open is NOT just metadata: unless this
is genuinely turn one of a fresh conversation, run a first checkpoint (§3) right after
`bp session open`, and distill it from the ENTIRE conversation so far — every decision,
milestone, and file touched since the thread began, not just what happens after this
point. Backfill the trail too: one `bp session log` per milestone that already happened
(a paper published earlier in the thread, a task closed, a push) so the events reflect
the whole session, not its tail. The transcript side needs no special handling — the
harness JSONL contains the thread from turn one, so the checkpoint's scrub-and-upload
covers it in full.

## 2. Log (after every milestone, non-blocking)

Fire one of these right after the milestone happens — don't batch them up for later:

```bash
bp session log "$SLUG" --kind paper-published    --ref <paper-slug>
bp session log "$SLUG" --kind task-closed        --ref <task-doc-id>
bp session log "$SLUG" --kind epic-wave-complete --ref <wave-paper-slug>
bp session log "$SLUG" --kind push               --ref "$(git rev-parse HEAD)"
bp session log "$SLUG" --kind note               --note "<short free text>"
```

Keep `--note` short — it rides the query string, not a JSON body.

**Non-blocking:** if `bp session log` fails (network hiccup, transient 5xx, whatever),
print a loud warning and move on — a failed log entry is never a reason to abort or retry
the underlying milestone (the push already happened, the task is already closed; don't
re-run those to satisfy the log).

## 3. Checkpoint (periodically, and always before close)

Rewrite the synthesis blocks from scratch each time — this is the living summary of the
session, not an append-only log. Use exactly these six sections:

```bash
cat > "$WORK/checkpoint.json" <<JSON
{
  "slug": "$SLUG",
  "blocks": [
    {"id": "current-task", "type": "heading", "level": 2, "text": "Current task"},
    {"id": "current-task-body", "type": "paragraph", "content": [{"type": "text", "value": "<what's being worked on right now, one or two sentences>"}]},
    {"id": "progress", "type": "heading", "level": 2, "text": "Progress"},
    {"id": "progress-body", "type": "paragraph", "content": [{"type": "text", "value": "<concretely what's done so far>"}]},
    {"id": "key-files", "type": "heading", "level": 2, "text": "Key files"},
    {"id": "key-files-body", "type": "paragraph", "content": [{"type": "text", "value": "<absolute paths central to this work>"}]},
    {"id": "decisions", "type": "heading", "level": 2, "text": "Decisions"},
    {"id": "decisions-body", "type": "paragraph", "content": [{"type": "text", "value": "<choices made and why, so they aren't re-litigated next session>"}]},
    {"id": "next-steps", "type": "heading", "level": 2, "text": "Next steps"},
    {"id": "next-steps-body", "type": "paragraph", "content": [{"type": "text", "value": "<the immediate next actions, in order>"}]},
    {"id": "learnings", "type": "heading", "level": 2, "text": "Learnings"},
    {"id": "learnings-body", "type": "paragraph", "content": [{"type": "text", "value": "<gotchas, dead ends, anything that would save the next session time>"}]}
  ]
}
JSON
```

Then attach a scrubbed transcript, if one exists:

```bash
# Claude Code: <cwd-slug> = cwd with every "/" AND "." replaced by "-" (reuses $CWD_SLUG
# computed in step 1 — recompute the same way if this is a fresh shell).
TRANSCRIPT=$(ls -t "$HOME/.claude/projects/$CWD_SLUG"/*.jsonl 2>/dev/null | head -1)
# If that's empty but you expect a transcript, the slug fold is probably still off — try
# ls "$HOME/.claude/projects/" | grep <repo-name> to find the real directory by hand.
# Codex: check ~/.codex/sessions/ for the equivalent transcript file; if this harness's
# transcript location isn't one of the above, locate it per that harness's own docs.

TRANSCRIPT_ID=""
if [ -n "${TRANSCRIPT:-}" ] && [ -f "$TRANSCRIPT" ]; then
  .claude/skills/session/helpers/scrub.sh "$TRANSCRIPT" > "$WORK/scrubbed.jsonl"
  SIZE=$(wc -c < "$WORK/scrubbed.jsonl")
  if [ "$SIZE" -gt 104857600 ]; then
    echo "checkpoint: scrubbed transcript is ${SIZE} bytes (>100MB cap) — bp media upload will reject it. Split it first, e.g. tail the last N lines or gzip it, then upload the smaller file." >&2
  else
    UPLOAD_JSON=$(bp media upload "$WORK/scrubbed.jsonl" -o json)
    TRANSCRIPT_ID=$(echo "$UPLOAD_JSON" | jq -r '.document._id // .document.id // .id // empty')
    [ -n "$TRANSCRIPT_ID" ] || echo "checkpoint: uploaded the transcript but couldn't parse its doc id out of: $UPLOAD_JSON — inspect the response shape and set 'transcript' by hand." >&2
  fi
else
  echo "checkpoint: NO transcript found for this session — publishing synthesis-only. This is a real gap, not silently ignored: the resume skill will have no transcript to offer." >&2
fi

# Fold status/ended_at/transcript into the same payload as "blocks" — status stays "open"
# mid-session (close, step 4, overrides it to "closed"); transcript is only added when the
# upload above produced an id.
EXTRA_FIELDS="{\"status\": \"open\"}"
[ -n "$TRANSCRIPT_ID" ] && EXTRA_FIELDS=$(echo "$EXTRA_FIELDS" | jq --arg t "$TRANSCRIPT_ID" '. + {transcript: $t}')
jq -s '.[0] * .[1]' "$WORK/checkpoint.json" <(echo "$EXTRA_FIELDS") > "$WORK/checkpoint-final.json"
bp session publish "$SLUG" --file "$WORK/checkpoint-final.json"
```

Touch the conversation registry again (bumps `last_active`, reusing the SAME `$CONV_UUID` from §1 — never a fresh one):

```bash
bp session touch "$SLUG" --conversation "$CONV_UUID" --harness claude-code --account "$ACCOUNT" --machine "$(hostname -s)" --cwd "$(pwd)"
```

## 4. Close (session end)

Repeat step 3 in full (fresh blocks, fresh transcript checkpoint), but override
`EXTRA_FIELDS` to also carry `status: closed` and `ended_at` before the final publish:

```bash
EXTRA_FIELDS=$(jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status: "closed", ended_at: $t}')
[ -n "$TRANSCRIPT_ID" ] && EXTRA_FIELDS=$(echo "$EXTRA_FIELDS" | jq --arg t "$TRANSCRIPT_ID" '. + {transcript: $t}')
jq -s '.[0] * .[1]' "$WORK/checkpoint.json" <(echo "$EXTRA_FIELDS") > "$WORK/checkpoint-final.json"
bp session publish "$SLUG" --file "$WORK/checkpoint-final.json"
```

Touch the conversation registry one last time (same `$CONV_UUID`), so its final `last_active` reflects the close:

```bash
bp session touch "$SLUG" --conversation "$CONV_UUID" --harness claude-code --account "$ACCOUNT" --machine "$(hostname -s)" --cwd "$(pwd)"
```

Then link every task this session claimed, stamped, or closed — note the calling
convention: the positional argument is the **task doc id**, and the session slug rides
`--add`:

```bash
bp session link-task <task-doc-id> --add "$SLUG"
```

Finally, print the handoff line so the human (or the next session) knows what to do:

```
On the other machine: /session-resume <slug>
```
