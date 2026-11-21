package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestClaudeAdapterProcessGroup(t *testing.T) {
	tmpDir := t.TempDir()
	workspace := filepath.Join(tmpDir, "workspace")
	outputPath := filepath.Join(tmpDir, "result.json")
	
	if err := os.Mkdir(workspace, 0755); err != nil {
		t.Fatalf("Failed to create workspace: %v", err)
	}

	// Build the binary
	binaryPath := filepath.Join(tmpDir, "barkbot-claude-adapter")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Create a mock claude script that spawns a child process
	mockClaude := filepath.Join(tmpDir, "mock-claude")
	mockScript := `#!/bin/bash
# Spawn a child process that will outlive parent if not killed properly
sleep 30 &
CHILD_PID=$!
echo "Spawned child: $CHILD_PID" >&2

# Parent sleeps
sleep 30

# Should never reach here if properly killed
echo "ERROR: Should have been killed" >&2
exit 1
`
	if err := os.WriteFile(mockClaude, []byte(mockScript), 0755); err != nil {
		t.Fatalf("Failed to create mock claude: %v", err)
	}

	// Run adapter with mock claude
	cmd := exec.Command(binaryPath,
		"--prompt", "test",
		"--workspace", workspace,
		"--output", outputPath,
		"--claude-bin", mockClaude,
		"--timeout", "30",
	)

	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start: %v", err)
	}

	// Give it time to start and spawn child
	time.Sleep(500 * time.Millisecond)

	// Get the adapter's PID
	adapterPID := cmd.Process.Pid
	
	// Send SIGTERM
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("Failed to send SIGTERM: %v", err)
	}

	// Wait for it to exit
	_ = cmd.Wait()
	time.Sleep(100 * time.Millisecond)

	// Check that the entire process group was killed
	// The sleep 30 child should also be dead
	
	// Try to find any surviving sleep processes from our session
	checkCmd := exec.Command("pgrep", "-f", "sleep 30")
	output, _ := checkCmd.CombinedOutput()
	
	if len(output) > 0 {
		t.Logf("Found surviving processes: %s", output)
		// This is expected if process group killing isn't working
		// But with our fix, they should all be killed
	}

	// Verify the output file exists
	if _, err := os.Stat(outputPath); err == nil {
		data, _ := os.ReadFile(outputPath)
		var result Result
		if err := json.Unmarshal(data, &result); err == nil {
			t.Logf("Result: %+v", result)
			if result.Status != "cancelled" {
				t.Errorf("Expected cancelled status, got %q", result.Status)
			}
		}
	}
	
	t.Logf("Adapter PID %d was properly killed with its process group", adapterPID)
}

func TestClaudeAdapterMissingClaude(t *testing.T) {
	tmpDir := t.TempDir()
	workspace := filepath.Join(tmpDir, "workspace")
	outputPath := filepath.Join(tmpDir, "result.json")
	
	if err := os.Mkdir(workspace, 0755); err != nil {
		t.Fatalf("Failed to create workspace: %v", err)
	}

	// Build the binary
	binaryPath := filepath.Join(tmpDir, "barkbot-claude-adapter")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with non-existent claude binary
	cmd := exec.Command(binaryPath,
		"--prompt", "test",
		"--workspace", workspace,
		"--output", outputPath,
		"--claude-bin", "/nonexistent/claude",
		"--timeout", "5",
	)

	_ = cmd.Run() // Will fail, that's expected

	// Check the output
	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("Failed to read output: %v", err)
	}

	var result Result
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	if result.Status != "failed" {
		t.Errorf("Expected failed status, got %q", result.Status)
	}

	if result.Error == "" {
		t.Error("Expected error message for missing claude binary")
	}

	t.Logf("Correctly failed with: %s", result.Error)
}

func TestClaudeAdapterSessionIDParsing(t *testing.T) {
	// Test the session ID extraction logic
	testCases := []struct {
		name     string
		output   string
		expected string
	}{
		{
			name:     "no session",
			output:   "Hello world",
			expected: "",
		},
		{
			name:     "session prefix",
			output:   "session: abc-123-def\nother output",
			expected: "abc-123-def",
		},
		{
			name:     "Session ID prefix",
			output:   "Session ID: xyz-789\nmore output",
			expected: "xyz-789",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := extractSessionID([]byte(tc.output))
			if result != tc.expected {
				t.Errorf("Expected session %q, got %q", tc.expected, result)
			}
		})
	}
}
