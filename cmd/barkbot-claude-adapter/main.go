// Command barkbot-claude-adapter executes AI tasks via Claude Code CLI.
//
// It wraps the official `claude` CLI (https://code.claude.com) running in
// programmatic mode (-p) with the user's authenticated subscription.
//
// Requirements:
// - Claude Code installed (https://code.claude.com/docs/en/setup)
// - User authenticated via `claude setup-token` (stores CLAUDE_CODE_OAUTH_TOKEN)
// - Workspace directory exists and is writable
//
// Usage:
//
//	barkbot-claude-adapter \
//	  --prompt "Help me debug this code" \
//	  --workspace /barkpark/workspaces/my-bot \
//	  --output /tmp/result.json \
//	  [--session-id session-abc123] \
//	  [--timeout 300] \
//	  [--claude-bin /usr/local/bin/claude]
//
// Authentication:
// - Never pass tokens via CLI
// - Assumes `claude` binary is authenticated (via setup-token)
// - Fails explicitly if not authenticated
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Result is the output structure written to the output file.
type Result struct {
	Status          string `json:"status"` // "completed"|"failed"|"auth_failed"|"timeout"|"cancelled"
	Response        string `json:"response,omitempty"`
	Error           string `json:"error,omitempty"`
	ExecutionTimeMs int64  `json:"execution_time_ms,omitempty"`
	SessionID       string `json:"session_id,omitempty"`
}

func main() {
	os.Exit(run())
}

func run() int {
	var (
		prompt     = flag.String("prompt", "", "User prompt (required)")
		workspace  = flag.String("workspace", "", "Workspace directory (required)")
		output     = flag.String("output", "", "Output JSON file path (required)")
		sessionID  = flag.String("session-id", "", "Session ID for resume (optional)")
		timeoutSec = flag.Int("timeout", 300, "Timeout in seconds")
		claudeBin  = flag.String("claude-bin", "claude", "Path to claude binary")
	)
	flag.Parse()

	// Validate required flags
	if *prompt == "" || *workspace == "" || *output == "" {
		fmt.Fprintln(os.Stderr, "Error: --prompt, --workspace, and --output are required")
		flag.Usage()
		return 2
	}

	// Verify workspace exists and is accessible
	if stat, err := os.Stat(*workspace); err != nil || !stat.IsDir() {
		writeResult(*output, Result{
			Status: "failed",
			Error:  fmt.Sprintf("Workspace not accessible: %s", *workspace),
		})
		return 1
	}

	// Build claude command
	// Format: claude -p --cwd <workspace> [-s <session-id>] -m <prompt>
	args := []string{
		"-p",           // Programmatic mode (streaming, uses OAuth token)
		"--cwd", *workspace, // Isolated workspace
	}

	if *sessionID != "" {
		args = append(args, "-s", *sessionID) // Resume session
	}

	args = append(args, "-m", *prompt)

	// Set up cancellation on SIGTERM
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

	// Execute claude CLI with process group for proper cancellation
	start := time.Now()
	cmd := exec.CommandContext(ctx, *claudeBin, args...)
	cmd.Dir = *workspace
	
	// Set process group ID so we can kill entire tree
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	
	// Handle graceful shutdown with escalation
	go func() {
		<-ctx.Done()
		if cmd.Process != nil {
			// Get process group ID
			pgid, err := syscall.Getpgid(cmd.Process.Pid)
			if err == nil {
				// Kill entire process group (negative PID)
				fmt.Fprintf(os.Stderr, "Sending SIGTERM to process group %d\n", pgid)
				syscall.Kill(-pgid, syscall.SIGTERM)
				
				// Escalate to SIGKILL after 5 seconds
				time.Sleep(5 * time.Second)
				if cmd.ProcessState == nil || !cmd.ProcessState.Exited() {
					fmt.Fprintf(os.Stderr, "Escalating to SIGKILL for process group %d\n", pgid)
					syscall.Kill(-pgid, syscall.SIGKILL)
				}
			}
		}
	}()

	outputBytes, err := cmd.CombinedOutput()
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
			// Check if authentication error
			outputStr := string(outputBytes)
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
			Response:        string(outputBytes),
			ExecutionTimeMs: executionMs,
			SessionID:       extractSessionID(outputBytes),
		}
	}

	// Write result to output file
	if err := writeResult(*output, result); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write output: %v\n", err)
		return 1
	}

	if result.Status == "completed" {
		return 0
	}
	return 1
}

func isAuthError(output string) bool {
	// Claude Code typical auth error patterns (based on docs)
	lowerOutput := strings.ToLower(output)
	patterns := []string{
		"not authenticated",
		"authentication required",
		"claude_code_oauth_token",
		"setup-token",
		"auth failed",
		"unauthenticated",
	}

	for _, pattern := range patterns {
		if strings.Contains(lowerOutput, pattern) {
			return true
		}
	}
	return false
}

func extractSessionID(output []byte) string {
	// Parse session ID from claude -p output
	// Format: TBD based on actual CLI behavior
	// For now, return empty (will be filled in after testing real CLI)
	
	// Expected format (hypothetical): session-abc123 or similar
	outputStr := string(output)
	lines := strings.Split(outputStr, "\n")
	
	for _, line := range lines {
		if strings.HasPrefix(line, "session:") || strings.HasPrefix(line, "Session ID:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				return parts[1]
			}
		}
	}
	
	return ""
}

func writeResult(path string, result Result) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal result: %w", err)
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("write file: %w", err)
	}

	return nil
}
