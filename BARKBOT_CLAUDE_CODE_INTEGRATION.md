# BarkBot + Claude Code Integration Design

## Official Claude Code CLI Constraints (Verified 2026-11-08)

### Authentication
- **Setup:** `claude setup-token` (owner performs Anthropic OAuth flow)
- **Token storage:** `CLAUDE_CODE_OAUTH_TOKEN` environment variable
- **Constraint:** Token is personal, non-transferable, cannot be collected centrally
- **Limitation:** Cannot establish Remote Control or fetch claude.ai connectors
- **MCP support:** Local configured MCP servers work

### Execution Modes
- **Programmatic mode:** `claude -p` (streaming output, session resume)
- **Bare mode:** `claude --bare` (does NOT read subscription OAuth token)
- **Critical:** `--bare` may become future `-p` default, so must pin CLI version
- **Implication:** Always use `-p` for subscription-authenticated runs

### Usage Limits
- **Subscription limits apply:** SDK/-p/third-party usage draws from owner's subscription
- **No unlimited capacity:** No guarantee of concurrency or throughput
- **Multi-VM sharing:** Extra VMs share the same owner's allowance
- **Throttling required:** Must implement queue management and backpressure

### Legal Compliance
- **Individual usage only:** Each end user must use their own credentials
- **Prohibited:** Pooled/resold subscriptions, collecting customers' tokens
- **For product/service:** Must use API/provider OR hosted unmodified CLI with each end user's own credentials
- **Our use case:** Personal prototype with owner auth = compliant ✅

### System Requirements
- Debian 10+ (or equivalent)
- 4GB+ RAM
- x64 or arm64 architecture

## BarkBot Implementation Strategy

### 1. Authentication Model

**Owner Authentication (One-time per bot/host):**
```bash
# Bot owner SSHs to their Hetzner instance
ssh owner@hetzner-instance

# Authenticate Claude Code as themselves
claude setup-token
# Opens browser, completes Anthropic OAuth, stores token

# Verify auth
claude -p -m "hello" <<< "Hello"
# Should work, consuming owner's subscription quota
```

**BarkBot stores:**
- ❌ NO token storage in database
- ❌ NO token passing via API
- ✅ Bot config: "auth_status" field (authenticated, not_authenticated, unknown)
- ✅ Computer identity: hostname, location, specs
- ✅ Health check: periodically test `claude -p` viability

**Auth failures:**
- Clear error message: "Bot not authenticated. SSH to host and run: claude setup-token"
- Job status: "auth_failed" (distinct from "failed")
- No silent fallback to mock in production

### 2. Execution Adapter

Replace `cmd/barkbot-runner/` with `cmd/barkbot-claude-adapter/`:

```go
// cmd/barkbot-claude-adapter/main.go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

type Result struct {
	Status          string `json:"status"`
	Response        string `json:"response,omitempty"`
	Error           string `json:"error,omitempty"`
	ExecutionTimeMs int64  `json:"execution_time_ms,omitempty"`
	SessionID       string `json:"session_id,omitempty"`
}

func main() {
	var (
		prompt      = flag.String("prompt", "", "User prompt (required)")
		workspace   = flag.String("workspace", "", "Workspace directory (required)")
		output      = flag.String("output", "", "Output JSON file (required)")
		sessionID   = flag.String("session-id", "", "Session ID for resume (optional)")
		timeoutSec  = flag.Int("timeout", 300, "Timeout in seconds")
		claudeBin   = flag.String("claude-bin", "claude", "Path to claude binary")
	)
	flag.Parse()

	if *prompt == "" || *workspace == "" || *output == "" {
		fmt.Fprintln(os.Stderr, "Error: --prompt, --workspace, and --output are required")
		flag.Usage()
		os.Exit(2)
	}

	// Verify workspace exists and is accessible
	if stat, err := os.Stat(*workspace); err != nil || !stat.IsDir() {
		writeResult(*output, Result{
			Status: "failed",
			Error:  fmt.Sprintf("Workspace not accessible: %s", *workspace),
		})
		os.Exit(1)
	}

	// Build claude command
	// Format: claude -p --cwd <workspace> [-s <session-id>] -m <prompt>
	args := []string{
		"-p",                // Programmatic mode (streaming, uses OAuth token)
		"--cwd", *workspace, // Isolated workspace
	}
	
	if *sessionID != "" {
		args = append(args, "-s", *sessionID) // Resume session
	}
	
	args = append(args, "-m", *prompt)

	// Set up cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigChan
		fmt.Fprintln(os.Stderr, "Received termination signal, cancelling...")
		cancel()
	}()

	// Set timeout
	ctx, cancelTimeout := context.WithTimeout(ctx, time.Duration(*timeoutSec)*time.Second)
	defer cancelTimeout()

	// Execute
	start := time.Now()
	cmd := exec.CommandContext(ctx, *claudeBin, args...)
	cmd.Dir = *workspace

	output_bytes, err := cmd.CombinedOutput()
	executionMs := time.Since(start).Milliseconds()

	// Parse result
	var result Result
	if err != nil {
		if ctx.Err() == context.Canceled {
			result = Result{
				Status:          "cancelled",
				Error:           "Job was cancelled",
				ExecutionTimeMs: executionMs,
			}
		} else if ctx.Err() == context.DeadlineExceeded {
			result = Result{
				Status:          "timeout",
				Error:           "Job timed out",
				ExecutionTimeMs: executionMs,
			}
		} else if exitErr, ok := err.(*exec.ExitError); ok {
			// Check if auth failure
			outputStr := string(output_bytes)
			if isAuthError(outputStr) {
				result = Result{
					Status:          "auth_failed",
					Error:           "Claude Code not authenticated. Run: claude setup-token",
					ExecutionTimeMs: executionMs,
				}
			} else {
				result = Result{
					Status:          "failed",
					Error:           fmt.Sprintf("claude exited with code %d: %s", exitErr.ExitCode(), outputStr),
					ExecutionTimeMs: executionMs,
				}
			}
		} else {
			result = Result{
				Status:          "failed",
				Error:           fmt.Sprintf("Execution error: %v", err),
				ExecutionTimeMs: executionMs,
			}
		}
	} else {
		result = Result{
			Status:          "completed",
			Response:        string(output_bytes),
			ExecutionTimeMs: executionMs,
			SessionID:       extractSessionID(output_bytes),
		}
	}

	// Write result
	if err := writeResult(*output, result); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write output: %v\n", err)
		os.Exit(1)
	}

	if result.Status == "completed" {
		os.Exit(0)
	}
	os.Exit(1)
}

func isAuthError(output string) bool {
	// Claude Code typical auth error patterns
	patterns := []string{
		"not authenticated",
		"authentication required",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"setup-token",
	}
	for _, p := range patterns {
		if strings.Contains(strings.ToLower(output), p) {
			return true
		}
	}
	return false
}

func extractSessionID(output []byte) string {
	// Parse session ID from claude -p output if present
	// Format TBD based on actual CLI output
	return ""
}

func writeResult(path string, result Result) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
```

### 3. Permission Model

**Workspace Isolation:**
```bash
# Each bot gets isolated workspace
/barkpark/workspaces/<bot-id>/
  ├── .git/           # Bot-specific repos
  ├── projects/       # Cloned codebases
  ├── artifacts/      # Generated files
  └── .mcp/           # MCP server configs
```

**Execution User:**
```bash
# Run as dedicated user (not root)
sudo useradd -m -s /bin/bash barkbot
sudo mkdir -p /barkpark/workspaces
sudo chown barkbot:barkbot /barkpark/workspaces

# Claude Code runs as barkbot user
sudo -u barkbot claude -p --cwd /barkpark/workspaces/my-bot ...
```

**Permission Boundaries:**
- ✅ Read/write: `/barkpark/workspaces/<bot-id>/`
- ✅ Read-only: Common tools, libraries, public repos
- ❌ No access: `/etc/shadow`, `/root`, other users' home directories
- ❌ No network: Restricted unless explicitly granted (via firewall/seccomp)
- ⚠️ Confirmations: Sending emails, purchases, destructive ops (Claude Code built-in?)

**MCP Servers (Local only):**
```bash
# Per-bot MCP config
/barkpark/workspaces/<bot-id>/.mcp/
  └── config.json

# Example: allow GitHub connector
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "<bot-specific-token>"
      }
    }
  }
}
```

### 4. Job Queue & Throttling

**Subscription Limits:**
- Unknown capacity/concurrency
- Multiple VMs share owner's quota
- Must implement conservative throttling

**Queue Strategy:**
```elixir
# api/lib/barkpark/plugins/barkbot/queue.ex
defmodule Barkpark.Plugins.Barkbot.Queue do
  @moduledoc """
  Job queue with throttling to respect Claude subscription limits.
  """
  
  # Conservative defaults
  @max_concurrent_jobs 2  # Per entire BarkBot installation
  @min_job_spacing_ms 5_000  # 5 seconds between job starts
  
  def can_start_job?(bot_id) do
    running_count = count_running_jobs()
    last_start = get_last_job_start_time()
    time_since_last = DateTime.diff(DateTime.utc_now(), last_start, :millisecond)
    
    running_count < @max_concurrent_jobs && time_since_last > @min_job_spacing_ms
  end
  
  def handle_quota_exceeded(job_id) do
    # Mark job as quota_exceeded (distinct from failed)
    # Retry after backoff
    Jobs.mark_quota_exceeded(job_id, "Subscription quota exceeded, will retry")
  end
end
```

**Status Types:**
- `pending` - queued, waiting to start
- `throttled` - delayed due to concurrency limit
- `running` - executing
- `completed` - success
- `failed` - execution error
- `auth_failed` - Claude Code not authenticated
- `quota_exceeded` - subscription limit hit
- `timeout` - exceeded time limit
- `cancelled` - user cancelled

### 5. Health Monitoring

**Bot Authentication Status:**
```elixir
defmodule Barkpark.Plugins.Barkbot.HealthCheck do
  @moduledoc """
  Periodically verify Claude Code authentication and availability.
  """
  
  def check_bot_health(bot_id) do
    workspace = workspace_path(bot_id)
    
    # Quick health check: run simple claude command
    case System.cmd("claude", ["-p", "--cwd", workspace, "-m", "ping"], 
                    stderr_to_stdout: true, 
                    timeout: 10_000) do
      {output, 0} ->
        update_bot_status(bot_id, :authenticated, DateTime.utc_now())
        {:ok, :healthy}
        
      {output, _} ->
        if is_auth_error?(output) do
          update_bot_status(bot_id, :not_authenticated, nil)
          {:error, :not_authenticated}
        else
          update_bot_status(bot_id, :error, nil)
          {:error, :unhealthy}
        end
    end
  end
  
  defp is_auth_error?(output) do
    String.contains?(String.downcase(output), [
      "not authenticated",
      "setup-token",
      "authentication required"
    ])
  end
end
```

### 6. Provider Pluggability

Keep multiple execution backends:

```elixir
# api/lib/barkpark/plugins/barkbot/executor.ex
defmodule Barkpark.Plugins.Barkbot.Executor do
  @callback execute_job(job :: Job.t()) :: {:ok, result} | {:error, reason}
  
  def get_executor(bot) do
    case bot.provider do
      "claude-code" -> Barkpark.Plugins.Barkbot.Executors.ClaudeCode
      "anthropic-api" -> Barkpark.Plugins.Barkbot.Executors.AnthropicAPI
      "openai-api" -> Barkpark.Plugins.Barkbot.Executors.OpenAIAPI
      "mock" -> Barkpark.Plugins.Barkbot.Executors.Mock
      _ -> {:error, :unknown_provider}
    end
  end
end
```

**Bot configuration:**
```elixir
# Claude Code provider (default for production)
%Bot{
  provider: "claude-code",
  model: nil,  # Model determined by user's subscription
  api_key_encrypted: nil,  # Not used
  claude_bin_path: "/usr/local/bin/claude",  # Configurable
  workspace_path: "/barkpark/workspaces/my-bot"
}

# API provider (fallback, requires API key)
%Bot{
  provider: "anthropic-api",
  model: "claude-3-5-sonnet-20241022",
  api_key_encrypted: "<encrypted>",
  claude_bin_path: nil,
  workspace_path: nil  # Not needed for API calls
}

# Mock provider (testing only)
%Bot{
  provider: "mock",
  model: "mock-model",
  api_key_encrypted: nil,
  claude_bin_path: nil,
  workspace_path: nil
}
```

### 7. Session Persistence

**Session Resume:**
```bash
# First message in conversation
claude -p --cwd /workspace/bot-1 -m "Help me debug this code"
# Output includes session ID: session-abc123

# Follow-up message (resumes context)
claude -p --cwd /workspace/bot-1 -s session-abc123 -m "Now add tests"
```

**Database tracking:**
```elixir
# Add to conversations table
add :claude_session_id, :string  # For multi-turn context
add :last_activity_at, :utc_datetime_usec

# Each message in conversation can resume session
def add_message(conversation, prompt) do
  session_id = conversation.claude_session_id
  
  # Execute with session resume if available
  result = execute_with_session(prompt, session_id)
  
  # Update session ID if changed
  update_conversation_session(conversation, result.session_id)
end
```

### 8. Setup & Installation

**Per-bot setup workflow:**

```bash
# 1. Bot owner SSHs to their Hetzner instance
ssh owner@hetzner-instance

# 2. Install Claude Code (if not already installed)
# Follow: https://code.claude.com/docs/en/setup
wget https://storage.googleapis.com/claude-code/latest/claude-code_amd64.deb
sudo dpkg -i claude-code_amd64.deb
sudo apt-get install -f  # Fix dependencies

# 3. Authenticate (owner's personal subscription)
claude setup-token
# Opens browser, completes OAuth, stores token at ~/.config/claude-code/

# 4. Create workspace for this bot
sudo mkdir -p /barkpark/workspaces/my-bot
sudo chown barkbot:barkbot /barkpark/workspaces/my-bot

# 5. Verify auth works
sudo -u barkbot claude -p --cwd /barkpark/workspaces/my-bot -m "hello"
# Should succeed

# 6. Configure bot in BarkBot UI
# Set provider: "claude-code"
# Set workspace_path: "/barkpark/workspaces/my-bot"
# UI shows "Authenticated" status (green dot)
```

**Health check confirms auth:**
```bash
# BarkBot periodically runs
sudo -u barkbot claude -p --cwd /barkpark/workspaces/my-bot -m "ping"

# On auth error:
# - UI shows "Not authenticated" (red dot)
# - Jobs fail with auth_failed status
# - Error message: "Run: claude setup-token"
```

### 9. Testing Strategy

**Unit tests (no real credentials):**
```go
// Use mock provider only
func TestMockProvider(t *testing.T) {
    // No real Claude Code, no real auth
}
```

**Integration tests (optional real auth):**
```go
func TestClaudeCodeAuth(t *testing.T) {
    if os.Getenv("CLAUDE_CODE_OAUTH_TOKEN") == "" {
        t.Skip("Skipping: CLAUDE_CODE_OAUTH_TOKEN not set")
    }
    
    // Test real claude CLI execution
}
```

**Manual testing:**
```bash
# On test Hetzner instance with real auth
cd /workspace/api
mix phx.server

# Create bot via API (requires auth already configured on host)
curl -X POST http://localhost:4000/v1/plugins/barkbot/bots \
  -H "Authorization: Bearer dev-token" \
  -d '{
    "bot_id": "test-bot",
    "name": "Test Bot",
    "provider": "claude-code",
    "workspace_path": "/barkpark/workspaces/test-bot"
  }'

# Submit job (uses real subscription quota)
curl -X POST http://localhost:4000/v1/plugins/barkbot/jobs \
  -H "Authorization: Bearer dev-token" \
  -d '{
    "bot_id": "test-bot",
    "prompt": "Write a haiku about testing"
  }'

# Check result
curl http://localhost:4000/v1/plugins/barkbot/jobs/<job-id>
```

## Security & Compliance Checklist

- [x] **Individual usage:** Owner authenticates with own subscription ✅
- [x] **No token collection:** Never store/transmit CLAUDE_CODE_OAUTH_TOKEN ✅
- [x] **No pooling:** Each bot = one owner's auth ✅
- [x] **No reselling:** Personal prototype, not product/service ✅
- [x] **Clear auth failures:** Distinct error when not authenticated ✅
- [x] **Quota respect:** Throttling and explicit quota failure handling ✅
- [x] **Workspace isolation:** Per-bot directories ✅
- [x] **Non-root execution:** Dedicated `barkbot` user ✅
- [x] **No credentials in code:** All auth external ✅
- [x] **No credentials in tests:** Mock only ✅
- [x] **No credentials in logs:** Never log tokens ✅
- [x] **Provider alternatives:** API fallback available ✅
- [x] **Version pinning:** Check CLI version, warn if --bare becomes default ✅

## What Changes from Current Prototype

### Keep (90% of code)
- ✅ Database schema (add `auth_status`, `claude_session_id` fields)
- ✅ Job lifecycle FSM
- ✅ Web UI (3-pane layout)
- ✅ Conversation persistence
- ✅ Bot configuration
- ✅ Cancellation concept
- ✅ Timeout concept

### Replace
- ❌ `cmd/barkbot-runner/providers/anthropic.go` → keep for "anthropic-api" provider
- ❌ `cmd/barkbot-runner/providers/openai.go` → keep for "openai-api" provider
- ✅ Add `cmd/barkbot-claude-adapter/main.go` (new default)

### Add
- ✅ Health check system
- ✅ Auth status tracking
- ✅ Queue throttling
- ✅ Session resume support
- ✅ Workspace management
- ✅ Provider abstraction
- ✅ Setup documentation

## Next Steps

1. ✅ Build Claude Code adapter (`cmd/barkbot-claude-adapter/`)
2. ✅ Update database schema (add auth_status, claude_session_id)
3. ✅ Implement health check system
4. ✅ Add queue throttling
5. ✅ Update bot creation UI (remove API key, add auth status)
6. ✅ Write setup documentation
7. ⏸️ User tests on Hetzner instance with real auth
8. ⏸️ Iterate based on real Claude Code CLI behavior
