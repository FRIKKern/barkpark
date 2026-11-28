# BarkBot Prototype Design

## Overview

BarkBot enables each Barkpark instance to function as a persistent AI agent with its own dedicated computer. This prototype implements a minimal vertical slice that genuinely executes bounded AI tasks via configurable model/provider.

## Architecture

### Core Principle
**1 BarkBot = 1 Dedicated Barkpark Instance = 1 Dedicated Server**

```
┌─────────────────────────────────────────┐
│  User (via Web UI or API)              │
└──────────────┬──────────────────────────┘
               │ Create job, check status
               ▼
┌─────────────────────────────────────────┐
│  BarkBot Plugin (Elixir)                │
│  - Job queue (PostgreSQL)               │
│  - Job lifecycle FSM                    │
│  - Per-bot configuration                │
│  - Result storage                       │
└──────────────┬──────────────────────────┘
               │ Shell to runner
               ▼
┌─────────────────────────────────────────┐
│  BarkBot Runner (Go)                    │
│  - Executes AI jobs in isolation        │
│  - Configurable model provider          │
│  - Time/resource limits                 │
│  - Real cancellation                    │
│  - Workspace management                 │
└──────────────┬──────────────────────────┘
               │ API calls
               ▼
┌─────────────────────────────────────────┐
│  LLM Provider (Anthropic/OpenAI)        │
│  - Configured per bot                   │
│  - API key from bot secrets             │
└─────────────────────────────────────────┘
```

## Components

### 1. BarkBot Plugin (Elixir)
- **Location:** `api/lib/barkpark/plugins/barkbot.ex`
- **Responsibilities:**
  - Job queue management (PostgreSQL table `barkbot_jobs`)
  - Job lifecycle: `pending → running → completed | failed | cancelled`
  - Per-bot configuration storage
  - HTTP API endpoints
  - Result persistence
  - Job cancellation

### 2. BarkBot Runner (Go)
- **Location:** `cmd/barkbot-runner/main.go`
- **Responsibilities:**
  - Execute single AI job in isolation
  - Call configured LLM provider (Anthropic Claude or OpenAI)
  - Enforce time limits (default 5 minutes)
  - Handle cancellation signals (SIGTERM)
  - Write results to JSON output
  - Clean workspace on exit

### 3. Bot Configuration
- **Storage:** PostgreSQL table `barkbot_bots`
- **Per-bot settings:**
  - `bot_id` - Unique identifier
  - `name` - Human-readable name
  - `provider` - "anthropic" or "openai"
  - `model` - e.g., "claude-3-5-sonnet-20241022" or "gpt-4"
  - `workspace_id` - Tenant isolation
  - `api_key_encrypted` - Provider credentials
  - `enabled` - Active/inactive flag

### 4. Job Schema
```elixir
%BarkbotJob{
  id: uuid,
  bot_id: string,
  status: "pending" | "running" | "completed" | "failed" | "cancelled",
  prompt: string,  # Task description
  system_prompt: string | nil,  # Optional system message
  max_tokens: integer,
  temperature: float,
  timeout_seconds: integer,
  
  # Execution tracking
  started_at: datetime | nil,
  completed_at: datetime | nil,
  cancelled_at: datetime | nil,
  
  # Results
  response: string | nil,
  error: string | nil,
  tokens_used: integer | nil,
  execution_time_ms: integer | nil,
  
  # Audit
  created_by: string,
  workspace_id: uuid
}
```

## Setup Workflow

### Option A: Provision New Instance
```bash
# 1. Provision via control plane (requires credentials)
bp cloud create my-barkbot --size CX23

# 2. Instance auto-provisions with BarkBot plugin enabled

# 3. Configure bot via UI or API
curl -X POST https://my-barkbot.barkpark.cloud/v1/plugins/barkbot/bots \
  -H "Authorization: Bearer <admin-token>" \
  -d '{
    "name": "My Assistant Bot",
    "provider": "anthropic",
    "model": "claude-3-5-sonnet-20241022",
    "api_key": "<anthropic-key>"
  }'
```

### Option B: Enroll Existing Instance
```bash
# 1. SSH to existing Barkpark instance (NOT done in this PR)
ssh user@existing-instance

# 2. Add plugin to config
echo "BARKPARK_PLUGINS=bulldocs,tasks,barkbot" >> /opt/barkpark/.env

# 3. Install runner binary (from release)
sudo wget -O /usr/local/bin/barkbot-runner \
  https://github.com/FRIKKern/barkpark/releases/download/v0.x.x/barkbot-runner
sudo chmod +x /usr/local/bin/barkbot-runner

# 4. Restart Barkpark
sudo systemctl restart barkpark

# 5. Configure bot via API (same as above)
```

## Usage

### Submit Job (API)
```bash
curl -X POST https://my-barkbot.barkpark.cloud/v1/plugins/barkbot/jobs \
  -H "Authorization: Bearer <token>" \
  -d '{
    "bot_id": "my-assistant-bot",
    "prompt": "Write a haiku about recursion",
    "max_tokens": 500,
    "timeout_seconds": 60
  }'

# Response:
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "pending",
  "created_at": "2026-11-08T15:46:00Z"
}
```

### Check Status
```bash
curl https://my-barkbot.barkpark.cloud/v1/plugins/barkbot/jobs/550e8400... \
  -H "Authorization: Bearer <token>"

# Response:
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "completed",
  "response": "Code calls itself,\nElegant loops within loops,\nStack overflow waits.",
  "tokens_used": 42,
  "execution_time_ms": 1234,
  "completed_at": "2026-11-08T15:46:03Z"
}
```

### Cancel Job
```bash
curl -X POST \
  https://my-barkbot.barkpark.cloud/v1/plugins/barkbot/jobs/550e8400.../cancel \
  -H "Authorization: Bearer <token>"
```

## Security

### Isolation
- **Workspace confinement:** Jobs scoped to workspace_id
- **Separate bot configs:** Each bot has own API keys, can't access others
- **Non-root execution:** Runner runs as `barkpark` user, not root
- **Time limits:** Default 5 min, configurable per job
- **Resource limits:** systemd unit has MemoryMax, CPUQuota

### Authentication
- **API endpoints:** Require bearer token with write permission
- **Bot creation:** Admin-only
- **Job submission:** Write permission in bot's workspace
- **Secrets:** API keys encrypted at rest, never in logs

### No Arbitrary Code Execution
- Runner only calls LLM APIs, doesn't exec user code
- No shell command injection surface
- Prompt is data, not code
- Bounded input/output

## Testing

### Unit Tests (Elixir)
```bash
mix test test/barkpark/plugins/barkbot_test.exs
```
- Job lifecycle FSM
- Workspace isolation
- Validation rules

### Integration Tests (Go)
```bash
go test ./cmd/barkbot-runner/...
```
- Mock LLM provider (no real API calls)
- Timeout enforcement
- Cancellation handling
- Result formatting

### Manual Harness
```bash
# Test runner with mock provider (no credentials needed)
go run ./cmd/barkbot-runner \
  --provider mock \
  --prompt "Test prompt" \
  --output /tmp/result.json
  
cat /tmp/result.json
# {"status":"completed","response":"Mock response","tokens_used":10}
```

### Real Provider Test (requires API key)
```bash
export ANTHROPIC_API_KEY=sk-...

go run ./cmd/barkbot-runner \
  --provider anthropic \
  --model claude-3-5-sonnet-20241022 \
  --prompt "Say hello in exactly 3 words" \
  --output /tmp/result.json
  
cat /tmp/result.json
# {"status":"completed","response":"Hello there friend","tokens_used":8,...}
```

## Rollout Plan

### Phase 1: Local Dev (This PR)
- ✅ Plugin implementation
- ✅ Runner implementation
- ✅ Unit tests
- ✅ Mock integration tests
- ✅ Documentation
- 🔲 Manual testing on local Barkpark instance

### Phase 2: Test Server Deployment (Requires User)
**Prerequisites:**
- User selects specific test server from Hetzner fleet
- User provides SSH access OR enrolls via control plane
- User provides Anthropic/OpenAI API key for testing

**Steps:**
1. User reviews this PR code
2. User merges to `main` (or test branch)
3. Deploy to ONE selected test instance
4. Configure one test bot
5. Submit test jobs, verify lifecycle
6. Test cancellation
7. Monitor resource usage

### Phase 3: Multi-Bot Production (Future)
- Dashboard UI in Studio for bot management
- Job history viewer
- Real-time streaming responses
- Webhook notifications on completion
- Advanced features:
  - Multi-turn conversations with memory
  - Tool use / function calling
  - File attachments
  - Browser/desktop automation (separate large effort)

## Out of Scope (This PR)

### Not Included
- ❌ Browser/desktop automation (too large, separate effort)
- ❌ Multi-turn conversations (add in Phase 3)
- ❌ Tool calling / function use (add in Phase 3)
- ❌ File upload/download (add in Phase 3)
- ❌ Streaming responses (add in Phase 3)
- ❌ Dashboard UI (basic API first, UI in Phase 3)
- ❌ Grok Bot connector (different from independent BarkBots)

### Why These Are Later
Each adds significant complexity:
- **Browser automation:** Requires headless Chrome, security sandboxing, VNC/screenshots
- **Conversations:** Needs message history, context management, memory pruning
- **Tools:** Requires function schema, safe execution, result parsing
- **Streaming:** Needs SSE infrastructure, partial response handling
- **UI:** Studio integration, React components, real-time updates

## File Changes Summary

### New Files
- `api/lib/barkpark/plugins/barkbot.ex` - Plugin definition
- `api/lib/barkpark/plugins/barkbot/` - Core logic modules
- `api/priv/repo/migrations/*_create_barkbot_tables.exs` - DB schema
- `api/priv/plugins/barkbot/plugin.json` - Manifest
- `cmd/barkbot-runner/main.go` - Runner binary
- `cmd/barkbot-runner/providers/` - LLM provider clients
- `internal/barkbot/` - Shared Go logic
- `api/test/barkpark/plugins/barkbot_test.exs` - Tests
- `cmd/barkbot-runner/*_test.go` - Runner tests
- `deploy/systemd/barkbot-worker.service` - Systemd unit

### Modified Files
- `.gitignore` - Add barkbot build artifacts
- `README.md` - Add BarkBot section
- (None required - plugin auto-discovered)

## Success Criteria

✅ **Runnable prototype**
- Plugin loads without errors
- Runner compiles and executes
- Mock tests pass

✅ **Job lifecycle works**
- Create job → pending
- Execute → running
- Complete → result stored
- Cancel → job stopped

✅ **Isolation proven**
- Workspace scoping enforced
- Time limits work
- Process cancellation works
- Multiple concurrent jobs don't interfere

✅ **Setup documented**
- Clear provisioning steps
- Enrollment instructions
- Configuration guide
- API usage examples

✅ **Gaps identified**
- What's tested vs not tested
- What's implemented vs TODO
- What needs manual verification
- What requires credentials

## Next Steps After PR Review

1. **User reviews code**
2. **User selects test server** (e.g., one of the warm-* instances)
3. **User provides:**
   - SSH access OR control plane credentials
   - Anthropic or OpenAI API key
4. **Deploy to test server**
5. **Manual verification:**
   - Create bot
   - Submit job
   - Verify completion
   - Test cancellation
   - Check logs
6. **Production rollout decision**
