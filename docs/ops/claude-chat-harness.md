<!-- doc-tier: agent | canonical-for: claude-chat-wire-harness | budget: 3000tok -->
# Studio Claude-chat wire-contract harness

The Studio chat rail, approval cards, and resume premise ride the real `claude`
CLI's stream-json frames. Those frames are an UNVERSIONED wire contract we do not
own. This harness catches a breaking CLI change before it silently breaks the
product. Three legs, in ascending cost. Charter decision: D67.

## Leg 1 — per-PR fixture replay (already free)

Bare `mix test` already replays the frozen frame fixtures + the six-file chat
suite on every PR — no new machinery, no cost, no opt-in:

```
mix test test/barkpark_web/live/studio/chat_live_test.exs \
         test/barkpark_web/studio/claude_chat_test.exs \
         test/barkpark/studio_chat_test.exs \
         test/barkpark/studio_chat/recorder_test.exs \
         test/barkpark/studio_chat/titles_test.exs \
         test/barkpark/studio_chat/plan_papers_test.exs
```

The fixtures are the real v2.1.205 captures committed under
`api/test/fixtures/claude_chat/{workflow_progress,background_tasks,foreground_task}.ndjson`
(wave-10 S1). **They stay FROZEN (charter D62)** — a fixture is a provenance
record of what the binary emitted, never edited to make a test pass. A wire
change that breaks parsing surfaces here as a red on the fixture-fed tests.

## Leg 2 — nightly real-binary smoke

The fixtures prove we still parse *captured* frames; only the real binary proves
the frames themselves have not changed. `scripts/claude-chat-e2e.sh` drives the
actual CLI through OUR seam (the `:binary` override keeps `build_args`) and proves
the resume premise end-to-end. `scripts/claude-chat-nightly.sh` wraps it for cron
(CLAUDE_BIN precedence + timestamped log + preserved exit code).

- **Cost:** ~$0.43 and ~40s per run (haiku-pinned, charter D56). Run it at most
  once locally per change; otherwise rely on the committed 5/0 baseline.
- **`:real_binary` tag** — excluded from the default lane; opt in only via the
  scripts or `CLAUDE_BIN=… mix test --only real_binary`.

### Why guerrilla is the only viable host

GH-hosted CI runners have **neither the `claude` binary nor an authenticated
session** — they cannot run leg 2 at all. Guerrilla is the one host with a
native, authenticated, pinned install:

- root `claude auth login` completed (OAuth session persisted),
- native install at `/usr/local/bin/claude`,
- **autoUpdates: false** — the pin (below) only holds if the binary cannot
  silently move under us.

### Install the cron (explicit ops step — run ON guerrilla)

This is a deliberate lead/ops action performed on the guerrilla host itself. Do
NOT ssh to prod from a worktree. As root on guerrilla, first ensure the log dir
exists (`mkdir -p /var/log/barkpark`), then — after confirming
`/usr/local/bin/claude --version` matches `scripts/claude-pinned-version.txt`:

```cron
# /etc/cron.d/barkpark-claude-chat-nightly — 03:17 UTC nightly wire smoke
17 3 * * *  root  CLAUDE_BIN=/usr/local/bin/claude CLAUDE_CHAT_LOG_DIR=/var/log/barkpark /opt/barkpark/scripts/claude-chat-nightly.sh >> /var/log/barkpark/claude-chat-nightly.cron.log 2>&1
```

A non-zero exit (version drift OR a broken wire proof) lands in the log and the
cron mailer. Investigate before the next deploy.

## Leg 0 — the version pin (guards legs 1 & 2)

The pinned CLI version lives in exactly ONE place:
`scripts/claude-pinned-version.txt` (currently **2.1.206**, proven green live —
5/0 real-binary run). Three consumers read it:

- `scripts/claude-chat-e2e.sh` — asserts `"$CLAUDE_BIN" --version` matches and
  **REFUSES** on mismatch (never silent-skips),
- `scripts/claude-chat-nightly.sh` — inherits the assertion through the e2e call,
- the `:real_binary` suite — a cheap first test (`describe "version pin"`, no API
  spend) asserts the same.

PATH decoys are real and this is why the refusal is loud: the **cmux wrapper is
first on PATH** and a **stale npm-global 2.1.84** can shadow the intended binary.
A green run against the wrong version would be a lie about the wire contract.
Upgrading is a deliberate act: bump the pin file, then re-run the smoke.

## Kill-signal — when to abandon the raw wire

The raw stream-json wire is a maintenance bet, not a permanent home. **Two
breaking wire changes in a single quarter triggers an Agent SDK re-score**
(provider-horizon rev 4): at that cadence the cost of chasing an unversioned
surface exceeds the cost of moving to the versioned Agent SDK. Record each
breaking change (date + what broke) so the count is auditable when the trigger
fires.
