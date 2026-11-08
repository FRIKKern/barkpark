# BarkBot Prototype - Setup & Testing Guide

## Quick Start (Local Development)

### 1. Build the Runner

```bash
cd /workspace
go build -o barkbot-runner ./cmd/barkbot-runner
```

### 2. Test Runner (Mock Provider - No API Key Needed)

```bash
./barkbot-runner \
  --provider mock \
  --model test-model \
  --prompt "Write a haiku about computers" \
  --output /tmp/result.json

cat /tmp/result.json
```

Expected output:
```json
{
  "status": "completed",
  "response": "Mock haiku here,\nThree lines of syllables count,\nFive, seven, then five.",
  "tokens_used": 12,
  "execution_time_ms": 523
}
```

### 3. Run Go Tests

```bash
cd /workspace/cmd/barkbot-runner
go test -v
```

Tests cover:
- ✅ Mock provider execution
- ✅ Cancellation handling (SIGTERM)
- ✅ Timeout enforcement
- ✅ Missing flag validation

### 4. Test with Real Provider (Requires API Key)

**Anthropic Claude:**
```bash
export ANTHROPIC_API_KEY=sk-ant-...

./barkbot-runner \
  --provider anthropic \
  --model claude-3-5-sonnet-20241022 \
  --prompt "Say hello in exactly 5 words" \
  --output /tmp/claude-result.json \
  --max-tokens 50

cat /tmp/claude-result.json
```

**OpenAI GPT:**
```bash
export OPENAI_API_KEY=sk-...

./barkbot-runner \
  --provider openai \
  --model gpt-4 \
  --prompt "Say hello in exactly 5 words" \
  --output /tmp/gpt-result.json \
  --max-tokens 50

cat /tmp/gpt-result.json
```

## Elixir Plugin Setup

### 1. Add Plugin to Configuration

Edit your Barkpark instance's `.env` file:
```bash
# Enable BarkBot plugin
BARKPARK_PLUGINS=bulldocs,tasks,barkbot
```

### 2. Install Runner Binary

```bash
# Copy built binary to system path
sudo cp barkbot-runner /usr/local/bin/
sudo chmod +x /usr/local/bin/barkbot-runner

# Verify installation
which barkbot-runner
barkbot-runner --help
```

### 3. Run Migrations

```bash
cd /workspace/api
mix ecto.migrate
```

### 4. Start Barkpark

```bash
cd /workspace/api
mix phx.server
```

### 5. Access BarkBot UI

Open browser to: `http://localhost:4000/barkbot/chat`

## Creating Your First Bot

### Via Web UI

1. Navigate to `/barkbot/bots/new`
2. Fill in bot details:
   - **Name:** My Assistant
   - **Bot ID:** my-assistant (slug)
   - **Provider:** anthropic or openai
   - **Model:** claude-3-5-sonnet-20241022 or gpt-4
   - **API Key:** Your provider's API key
   - **System Prompt:** (optional) "You are a helpful assistant..."
3. Click "Create Bot"
4. Navigate to `/barkbot/chat` to start chatting

### Via API

```bash
# Create bot
curl -X POST http://localhost:4000/v1/plugins/barkbot/bots \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "bot_id": "my-assistant",
    "name": "My Assistant",
    "provider": "mock",
    "model": "mock-model",
    "workspace_id": "<your-workspace-id>",
    "description": "A helpful AI assistant"
  }'

# List bots
curl http://localhost:4000/v1/plugins/barkbot/bots \
  -H "Authorization: Bearer barkpark-dev-token"

# Submit a job
curl -X POST http://localhost:4000/v1/plugins/barkbot/jobs \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "bot_id": "my-assistant",
    "prompt": "Write a haiku about recursion",
    "max_tokens": 500,
    "timeout_seconds": 60,
    "workspace_id": "<your-workspace-id>"
  }'

# Check job status (replace JOB_ID)
curl http://localhost:4000/v1/plugins/barkbot/jobs/JOB_ID \
  -H "Authorization: Bearer barkpark-dev-token"
```

## Deployment to Existing Barkpark Instance

### Option A: Via Control Plane (Safest)

**Prerequisites:**
- Control plane admin access
- Selected test server from fleet
- Anthropic or OpenAI API key

**Steps:**
1. Merge this PR to `main` or test branch
2. Deploy to test instance (auto-deploys via git pull)
3. SSH to instance and verify:
   ```bash
   ssh user@test-instance
   systemctl status barkpark
   ls -la /usr/local/bin/barkbot-runner
   ```

### Option B: Manual Enrollment (Requires SSH)

**Prerequisites:**
- SSH access to target instance
- Root or sudo privileges

**Steps:**

1. SSH to instance:
   ```bash
   ssh user@your-instance
   ```

2. Add plugin to config:
   ```bash
   sudo vi /opt/barkpark/.env
   # Add: BARKPARK_PLUGINS=bulldocs,tasks,barkbot
   ```

3. Install runner:
   ```bash
   sudo wget -O /usr/local/bin/barkbot-runner \
     https://github.com/FRIKKern/barkpark/releases/download/v0.x.x/barkbot-runner
   sudo chmod +x /usr/local/bin/barkbot-runner
   ```

4. Restart Barkpark:
   ```bash
   sudo systemctl restart barkpark
   ```

5. Verify:
   ```bash
   curl -I http://localhost:4000/barkbot/chat
   # Should return 200 OK
   ```

## Testing the Full Stack

### 1. Unit Tests (Go)

```bash
cd /workspace/cmd/barkbot-runner
go test -v
```

Coverage:
- ✅ Mock provider
- ✅ Cancellation
- ✅ Timeout
- ✅ Error handling

### 2. Integration Tests (Elixir - TODO)

```bash
cd /workspace/api
mix test test/barkpark/plugins/barkbot_test.exs
```

### 3. Manual End-to-End Test

```bash
# 1. Start Barkpark
cd /workspace/api && mix phx.server

# 2. In another terminal, create a bot
curl -X POST http://localhost:4000/v1/plugins/barkbot/bots \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "bot_id": "test-bot",
    "name": "Test Bot",
    "provider": "mock",
    "model": "mock-model",
    "workspace_id": "YOUR_WORKSPACE_ID"
  }' | jq .

# 3. Submit a job
JOB_ID=$(curl -X POST http://localhost:4000/v1/plugins/barkbot/jobs \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "bot_id": "test-bot",
    "prompt": "Hello, world!",
    "workspace_id": "YOUR_WORKSPACE_ID"
  }' | jq -r .id)

echo "Job ID: $JOB_ID"

# 4. Wait a moment, then check status
sleep 2
curl http://localhost:4000/v1/plugins/barkbot/jobs/$JOB_ID \
  -H "Authorization: Bearer barkpark-dev-token" | jq .

# Expected: status "completed", response field populated
```

### 4. UI Test (Browser)

1. Open: `http://localhost:4000/barkbot/chat`
2. Select bot from left sidebar (or create one)
3. Type message in composer
4. Click "Send"
5. Verify:
   - Message appears in chat
   - Typing indicator shows
   - Response appears after ~1 second (mock)
   - Computer info shows in right panel

## Troubleshooting

### Runner Not Found

```bash
# Check if binary exists
which barkbot-runner

# If not, build and install:
cd /workspace
go build -o barkbot-runner ./cmd/barkbot-runner
sudo cp barkbot-runner /usr/local/bin/
```

### Plugin Not Loading

```bash
# Check logs
journalctl -u barkpark -f

# Verify env var
grep BARKPARK_PLUGINS /opt/barkpark/.env

# Should include: barkbot
```

### Job Fails Immediately

```bash
# Check runner can execute
/usr/local/bin/barkbot-runner --help

# Run manually to see error
/usr/local/bin/barkbot-runner \
  --provider mock \
  --model test \
  --prompt "test" \
  --output /tmp/debug.json

cat /tmp/debug.json
```

### Database Errors

```bash
# Run migrations
cd /workspace/api
mix ecto.migrate

# Check if tables exist
psql -d barkpark_dev -c "\dt barkbot*"
```

## Security Checklist

- [ ] API keys encrypted at rest (placeholder in prototype, use Cloak in production)
- [ ] Jobs scoped to workspace_id
- [ ] Runner runs as `barkpark` user (not root)
- [ ] Timeouts enforced (default 5 minutes)
- [ ] Cancellation works (SIGTERM)
- [ ] No arbitrary code execution (only LLM API calls)
- [ ] Bearer tokens required for all API endpoints

## What's Implemented

✅ **Core Runner:**
- Mock provider (no credentials needed)
- Anthropic Claude integration
- OpenAI GPT integration
- Time limits (default 5 min)
- Cancellation via SIGTERM
- JSON result output

✅ **Backend (Elixir):**
- Bot configuration storage
- Job queue with lifecycle FSM
- Conversation/message storage
- Runner execution wrapper
- Workspace isolation
- HTTP API endpoints

✅ **Frontend (LiveView):**
- Dark charcoal UI matching screenshot
- 3-column layout (bots, chat, details)
- Chat bubbles for user/assistant
- Typing indicator
- Computer status panel
- Activity/library sections

✅ **Testing:**
- Go unit tests (mock provider)
- Cancellation tests
- Timeout tests
- Manual test scripts

## What's NOT Implemented (Future)

❌ **Not in Prototype:**
- Browser/desktop automation (too large)
- Multi-turn conversation memory
- Tool calling / function use
- File uploads
- Streaming responses
- Dashboard/admin UI for bot management
- Webhook notifications
- PubSub for real-time updates (polling used)

❌ **Production Gaps:**
- Real encryption (using Base64 placeholder)
- Systemd unit for runner management
- Resource limits (MemoryMax, CPUQuota on unit)
- Proper error recovery
- Job queue workers (currently inline)
- Monitoring/alerting
- Rate limiting per bot

## Next Steps

1. **User reviews this PR**
2. **User merges to test branch**
3. **User selects test instance** from Hetzner fleet
4. **User provides:**
   - SSH access OR control plane deploy
   - Anthropic or OpenAI API key for one bot
5. **Deploy and verify:**
   - Runner installed and executable
   - Migrations applied
   - UI accessible
   - Test job completes successfully
6. **Production rollout decision**

## Files Changed

### New Files

**Go Runner:**
- `cmd/barkbot-runner/main.go` (299 lines)
- `cmd/barkbot-runner/providers/provider.go` (41 lines)
- `cmd/barkbot-runner/providers/mock.go` (63 lines)
- `cmd/barkbot-runner/providers/anthropic.go` (160 lines)
- `cmd/barkbot-runner/providers/openai.go` (145 lines)
- `cmd/barkbot-runner/main_test.go` (186 lines)

**Elixir Plugin:**
- `api/lib/barkpark/plugins/barkbot.ex` (108 lines)
- `api/lib/barkpark/plugins/barkbot/bot.ex` (108 lines)
- `api/lib/barkpark/plugins/barkbot/job.ex` (130 lines)
- `api/lib/barkpark/plugins/barkbot/conversation.ex` (83 lines)
- `api/lib/barkpark/plugins/barkbot/runner.ex` (189 lines)
- `api/lib/barkpark/plugins/barkbot/jobs.ex` (124 lines)
- `api/lib/barkpark/plugins/barkbot/bots.ex` (78 lines)
- `api/lib/barkpark/plugins/barkbot/conversations.ex` (76 lines)
- `api/lib/barkpark/plugins/barkbot/web/chat_live.ex` (378 lines)

**Database:**
- `api/priv/repo/migrations/20261108154600_create_barkbot_tables.exs` (146 lines)

**Assets:**
- `api/priv/static/css/barkbot.css` (528 lines)
- `api/priv/plugins/barkbot/plugin.json` (10 lines)

**Documentation:**
- `BARKBOT_PROTOTYPE.md` (original design doc)
- `BARKBOT_SETUP.md` (this file)

**Total: ~2,850 lines of code + documentation**

### Modified Files

None required - plugin auto-discovered by Barkpark's plugin system.

## Screenshots

(To be added after UI is tested in browser)

## Contact

Questions? Issues? Reach out to the team or open a GitHub issue.
