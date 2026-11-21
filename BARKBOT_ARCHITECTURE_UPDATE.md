# BarkBot Architecture Update - Claude Code Integration

## User Requirement Clarification (2026-11-08)

**Original assumption:** Build custom LLM API harness calling Anthropic/OpenAI HTTP APIs with user-provided keys.

**Actual requirement:** Use **Claude Code** (Claude Desktop's agent) running on each Hetzner Linux instance, authenticated via user's own Claude subscription (not API keys).

## Key Changes Required

### 1. Execution Engine

**Was:** Custom Go binary (`barkbot-runner`) calling `api.anthropic.com` with API keys

**Now:** Claude Code CLI/daemon running on each host, authenticated via:
- User's Claude subscription (not API key)
- Official authentication flow (likely browser-based OAuth or similar)
- Non-transferable credentials (no token copying/extraction)

### 2. Authentication Model

**Was:** 
- Plugin stores encrypted API keys in PostgreSQL
- Runner receives API key via command-line flag
- User provides API key via web form

**Now:**
- User authenticates Claude subscription directly on each Hetzner host
- One-time setup per bot/host (persistent auth)
- Plugin does NOT store/handle subscription credentials
- Clear failure if credentials missing (no silent mock fallback in production)

### 3. Capability Scope

**Current prototype provides:**
- ✅ Job queue and lifecycle (pending → running → completed/failed/cancelled)
- ✅ Conversation/message persistence
- ✅ Web UI (3-pane dark charcoal layout)
- ✅ Cancellation propagation
- ✅ Timeout enforcement
- ✅ Bot configuration (name, model, workspace isolation)
- ✅ Computer identity tracking

**Must add for Claude Code:**
- 🔄 Persistent workspace/filesystem per bot (isolated directories)
- 🔄 Shell/tool access (git, npm, docker, curl, etc.)
- 🔄 Browser/desktop readiness (for Claude Code GUI tools if supported)
- 🔄 Connector/service access (MCP servers, APIs - explicitly provisioned per bot)
- 🔄 Durable run context (multi-turn sessions survive restarts)
- 🔄 Real cancellation (SIGTERM → Claude Code graceful shutdown)

**Permission model required:**
- Explicit per-bot capability grants (not blanket root)
- Non-root default execution
- Protected/secret paths (no access to /etc/shadow, other users' homes)
- Scoped repository access (bot-specific repos only)
- Confirmation for destructive operations (send emails, purchase, delete data, cloud mutations)
- Traceable tool actions (audit log of commands executed)

### 4. Claude Code Integration Strategy

#### Option A: Official CLI (Preferred if exists)

```bash
# Hypothetical - needs verification
claude-code run \
  --session-id "barkbot-job-abc123" \
  --workspace /barkpark/workspaces/bot-my-assistant \
  --prompt "User message here" \
  --output /tmp/result.json \
  --timeout 300s
```

**Unknowns to investigate:**
- Does Claude Code have a CLI?
- Can it run non-interactively (without desktop GUI)?
- How does subscription auth work on Linux servers?
- Can it output structured JSON results?
- How to cancel running jobs?
- Does it support workspace isolation?

#### Option B: IPC with Claude Desktop Process

If Claude Code requires desktop environment:
- Run Xvfb (virtual X server) on Hetzner instance
- Launch Claude Desktop in headless mode
- Drive via IPC/automation (electron-based messaging?)

#### Option C: Cursor Cloud Agent Infrastructure

**User might be hinting at:** Use same tech stack as Grok Bot itself
- Grok Bot likely uses Cursor's cloud agent infrastructure
- That's already Claude Code + Linux + isolated workspaces
- Could BarkBot instances BE Cursor cloud agents?

**This would explain:**
- "Right and accesses just like GrokBot have" = Cursor agent permissions
- Subscription auth via Cursor account (already solved)
- Browser/desktop/connector access (already wired)
- Persistent workspaces (already managed)

### 5. Current Prototype Status

#### ✅ What's Built (Reusable)

**Database schema:**
- `barkbot_bots` - bot configuration (keep: name, model, workspace_id, computer specs)
- `barkbot_jobs` - job lifecycle (keep: all fields except `api_key_encrypted`)
- `barkbot_conversations` - chat persistence (keep: everything)
- `barkbot_messages` - message history (keep: everything)

**Backend context modules:**
- `Barkpark.Plugins.Barkbot.Jobs` - job CRUD and lifecycle (keep)
- `Barkpark.Plugins.Barkbot.Bots` - bot CRUD (remove API key encryption logic)
- `Barkpark.Plugins.Barkbot.Conversations` - message persistence (keep)

**Web UI:**
- `chat_live.ex` - 3-pane layout matching screenshot (keep structure)
- `barkbot.css` - dark charcoal theme (keep)
- Left sidebar bot navigation (keep)
- Right panel computer status (keep)
- Activity feed (keep)

**Runner orchestration:**
- `Barkpark.Plugins.Barkbot.Runner` - job execution wrapper (needs rewrite for Claude Code)
- Timeout enforcement (keep concept, reimplement)
- Cancellation via SIGTERM (keep concept, adapt to Claude Code)

#### ❌ What Needs Replacement

**Go binary:**
- `cmd/barkbot-runner/` - custom API harness (replace with Claude Code adapter)
- `providers/anthropic.go` - direct API calls (not needed)
- `providers/openai.go` - direct API calls (not needed)
- `providers/mock.go` - keep for unit tests only

**API key handling:**
- Remove `api_key_encrypted` field and encryption logic
- Remove API key input from web forms
- Add "Authenticate Claude" setup instructions per bot

#### 🔄 What Needs Investigation

1. **Claude Code on Linux servers:**
   - Installation method (apt, snap, AppImage, docker?)
   - Authentication flow (browser OAuth? token file? env var?)
   - CLI vs daemon vs desktop requirement
   - Workspace isolation support
   - Non-interactive execution

2. **Cursor Cloud Agent option:**
   - Can we provision Cursor agents as BarkBot backends?
   - How to route jobs to specific agents?
   - Subscription licensing (1 agent = 1 subscription?)
   - Control plane API access

3. **Permission/capability model:**
   - Filesystem boundaries (chroot? user permissions? Docker volumes?)
   - Command whitelisting/auditing
   - MCP server provisioning
   - Confirmation hooks for destructive actions

## Updated Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ BarkBot Web UI (LiveView)                                   │
│ - Bot selector, chat interface, computer status             │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ Barkpark API (Phoenix + PostgreSQL)                         │
│ - Job queue: pending → running → completed/failed           │
│ - Conversation/message persistence                          │
│ - Bot configuration (NO API keys stored)                    │
│ - Workspace isolation (workspace_id foreign keys)           │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ Claude Code Adapter (Elixir/Go wrapper)                     │
│ - Launches Claude Code CLI/process per job                  │
│ - Maps job → Claude Code session                            │
│ - Streams output → PostgreSQL                               │
│ - Enforces timeouts (kill process on exceed)                │
│ - Propagates cancellation (SIGTERM → graceful shutdown)     │
│ - Assumes auth already configured on host                   │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ Claude Code Process (per job)                               │
│ Running on dedicated Hetzner Linux host                     │
│                                                              │
│ - Authenticated via user's Claude subscription              │
│ - Isolated workspace: /barkpark/workspaces/<bot-id>/        │
│ - Shell/tool access: git, npm, docker, curl, ...            │
│ - Browser/desktop (if supported by Claude Code)             │
│ - MCP servers (explicitly provisioned per bot)              │
│ - Permission boundaries enforced by OS user/chroot/Docker   │
│                                                              │
│ Computer identity:                                          │
│ - Hostname: hetzner-nbg1-cx33-001                          │
│ - CPU: 4 vCPU (AMD EPYC)                                   │
│ - Memory: 8 GB RAM                                          │
│ - Location: Hetzner Nuremberg                              │
└─────────────────────────────────────────────────────────────┘
```

## Immediate Next Steps

### 1. Research Phase (No Code Changes Yet)

**Investigate Claude Code:**
- [ ] Check if Claude Desktop has Linux CLI
- [ ] Check Anthropic docs for server/headless mode
- [ ] Test authentication on Linux server (via parent's verification)
- [ ] Determine structured output format
- [ ] Find cancellation mechanism

**Investigate Cursor Cloud Agents:**
- [ ] Can we provision agents programmatically?
- [ ] What's the API surface?
- [ ] How does subscription/licensing work?
- [ ] Can BarkBot manage its own fleet of Cursor agents?

### 2. Prototype Adapter (Once Research Complete)

Replace `cmd/barkbot-runner/` with:

**Option A: Claude Code CLI wrapper**
```go
// cmd/barkbot-claude-adapter/main.go
func main() {
    // Assume claude-code binary exists and user authenticated
    cmd := exec.Command("claude-code",
        "run",
        "--workspace", workspace,
        "--prompt", prompt,
        "--output", outputJSON,
    )
    
    // Set timeout, handle SIGTERM, stream logs
}
```

**Option B: Cursor agent dispatcher**
```elixir
# lib/barkpark/plugins/barkbot/cursor_adapter.ex
def execute_job(job) do
  # Call Cursor API to dispatch to agent
  # Agent runs job in isolated workspace
  # Stream results back to Barkpark
end
```

### 3. Update Documentation

- [ ] Remove API key setup instructions
- [ ] Add Claude subscription auth instructions
- [ ] Document workspace isolation setup
- [ ] Document permission model configuration
- [ ] Add capability provisioning guide (MCP servers, repo access)

### 4. Testing Strategy

**Unit tests (mock only):**
- Keep mock provider for Go tests
- Adapter tests assume Claude Code installed

**Integration tests:**
- Require real Claude subscription
- Require authenticated Linux host
- Test workspace isolation
- Test cancellation
- Test permission boundaries

**Manual testing:**
- User authenticates on test Hetzner instance
- Create bot via UI
- Submit job
- Verify execution in isolated workspace
- Test cancellation mid-run
- Verify filesystem isolation

## Compatibility with Current Work

### ✅ Compatible (No Changes Needed)

- Database schema (minus `api_key_encrypted` field)
- Job lifecycle state machine
- Web UI structure and styling
- Conversation/message persistence
- Bot configuration (name, model, workspace)
- Computer identity tracking
- Timeout/cancellation concepts

### 🔄 Needs Adaptation

- Runner implementation (replace API harness with Claude Code adapter)
- Authentication flow (remove API key forms, add subscription setup docs)
- Bot creation UI (remove API key field, add auth status indicator)
- Error messages (distinguish "not authenticated" from other failures)

### ❌ Discard

- `cmd/barkbot-runner/providers/anthropic.go`
- `cmd/barkbot-runner/providers/openai.go`
- API key encryption/decryption logic
- API key environment variable handling

## Open Questions for User

1. **Claude Code availability:**
   - Have you verified Claude Code runs on Linux servers?
   - Is it a CLI, daemon, or desktop app?
   - What's the authentication method?

2. **Cursor agent option:**
   - Should BarkBot instances BE Cursor cloud agents?
   - Do you have API access to provision agents?
   - How would subscription licensing work?

3. **Permission model:**
   - What's the enforcement mechanism? (Docker containers? Linux users? chroot?)
   - Should each bot run as its own OS user?
   - How to handle MCP server provisioning?

4. **Deployment:**
   - Install Claude Code on every Hetzner instance?
   - Or route to centralized Cursor agent infrastructure?
   - One bot per server, or multiple bots per server?

## Recommendation

**Wait for parent's independent verification of "official Claude subscription/server unattended constraints" before proceeding.**

Once we know:
- How Claude Code authenticates on Linux servers
- Whether it supports non-interactive execution
- How workspace isolation works
- Structured output format

Then we can:
1. Replace `cmd/barkbot-runner/` with appropriate adapter
2. Update bot setup to require Claude auth instead of API keys
3. Test on one Hetzner instance
4. Document the full setup workflow

**Current prototype is 90% compatible** - only the runner execution layer needs replacement. All UI, database, job queue, and orchestration logic can be reused.
