---
name: session-resume
description: Pick up a Barkpark session record left by a previous conversation or a different machine and load it back into context — metadata, milestone events, and the synthesis blocks (current task, progress, key files, decisions, next steps, learnings). Invoke when the user says "resume session <slug>", "continue where I left off", "pick up the other session", "load my last session", "what was I doing", or hands you a `session-...` slug. Warns loudly if the cwd, git repo, or branch don't match what the session recorded — a mismatch usually means you're on the wrong machine or checkout for this handoff. Pairs with the `session` skill, which produced the record.
---

# session-resume — pick up a session left by another conversation/machine

## 1. Find the slug

If the user gave you a slug (`session-YYYY-MM-DD-<topic>`), use it directly. Otherwise
list recent sessions and ask, or take the newest:

```bash
bp doc query session -o json | jq -r '.documents[] | select(.status != "superseded") | ._id'
```

## 2. Load it

```bash
bp session view <slug> -o json
```

This returns metadata, the event trail, the synthesis `blocks`, and `rev`. Read the
`blocks` into context as the primary "what was happening" summary — that's the whole
point of the checkpoint template (current task / progress / key files / decisions / next
steps / learnings). Skim the event trail for milestones (pushes, task closes, paper
publishes, epic waves) to sanity-check the blocks against what actually happened.

## 3. Warn on mismatch — don't silently proceed

Compare the session's recorded metadata against where you actually are, and print an
explicit warning for every divergence (don't just note it quietly and continue):

```bash
[ "$(pwd)" = "<metadata.cwd>" ]                              || echo "WARNING: cwd differs from the session's recorded cwd (<metadata.cwd>) — you may be resuming into the wrong checkout." >&2
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "<metadata.git_branch>" ] || echo "WARNING: current branch differs from the session's recorded branch (<metadata.git_branch>)." >&2
[ "$(hostname -s)" != "<metadata.machine>" ]                 && echo "NOTE: resuming on a different machine than the session was opened on (<metadata.machine>) — this is the normal cross-machine handoff case, not necessarily wrong." >&2
```

A cwd or branch mismatch is a strong signal something's off (wrong worktree, wrong repo
clone); a machine mismatch alone is the expected cross-machine handoff and just worth
noting.

## 4. Mark it resumed

This is a metadata-only upsert — **do not include a `blocks` key** in this payload, or
you'll wipe the synthesis blocks you just loaded (omitting the key preserves them; sending
an empty array does not):

```bash
WORK="${TMPDIR:-/tmp}/bp-session-resume-$$"
mkdir -p "$WORK"
cat > "$WORK/resume.json" <<JSON
{"status": "resumed"}
JSON
bp session publish <slug> --file "$WORK/resume.json"
```

## 5. Offer the transcript — never auto-fetch it

If `metadata.transcript` is set, it's a reference to a `mediaAsset` doc. Resolve it to a
URL and print the URL for the human to open — do not download or dump its contents into
context automatically (it's a full transcript, potentially large, and was scrubbed for
sharing, not for silent ingestion):

```bash
bp doc get mediaAsset <transcript-doc-id> -o json | jq -r '.document.fileInfo.url // .document.content.fileInfo.url // .fileInfo.url'
```

(The exact envelope key can vary slightly by `bp` version — `fileInfo.url` is the field
that matters; if none of those paths resolve, print the raw JSON and let the human spot
it.) If `metadata.transcript` is unset, say so plainly — that session was synthesis-only,
there's nothing to offer.
