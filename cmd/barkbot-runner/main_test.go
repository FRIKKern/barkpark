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

func TestRunnerMockProvider(t *testing.T) {
	tmpDir := t.TempDir()
	outputPath := filepath.Join(tmpDir, "result.json")

	// Build the binary
	binaryPath := filepath.Join(tmpDir, "barkbot-runner")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with mock provider
	cmd := exec.Command(binaryPath,
		"--provider", "mock",
		"--model", "mock-model",
		"--prompt", "Write a test haiku",
		"--output", outputPath,
		"--timeout", "10",
	)

	if err := cmd.Run(); err != nil {
		t.Fatalf("Runner failed: %v", err)
	}

	// Read result
	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("Failed to read output: %v", err)
	}

	var result Result
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	// Verify result
	if result.Status != "completed" {
		t.Errorf("Expected status 'completed', got %q", result.Status)
	}

	if result.Response == "" {
		t.Error("Expected non-empty response")
	}

	if result.TokensUsed == 0 {
		t.Error("Expected non-zero tokens")
	}

	if result.ExecutionTimeMs == 0 {
		t.Error("Expected non-zero execution time")
	}

	t.Logf("Result: %+v", result)
}

func TestRunnerCancellation(t *testing.T) {
	tmpDir := t.TempDir()
	outputPath := filepath.Join(tmpDir, "result.json")

	// Build the binary
	binaryPath := filepath.Join(tmpDir, "barkbot-runner")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with very short timeout so we can test SIGTERM
	cmd := exec.Command(binaryPath,
		"--provider", "mock",
		"--model", "mock-model",
		"--prompt", "This will be cancelled",
		"--output", outputPath,
		"--timeout", "10", // 10 seconds
	)

	// Start the process
	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start: %v", err)
	}

	// Wait for it to actually start executing
	time.Sleep(200 * time.Millisecond)
	
	// Send SIGTERM (what supervisor does on cancel)
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("Failed to send SIGTERM: %v", err)
	}

	// Wait for process to handle signal and exit
	_ = cmd.Wait()
	
	// Give it a moment to write the output file
	time.Sleep(100 * time.Millisecond)

	// Verify cancellation was recorded
	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("Failed to read output: %v", err)
	}

	var result Result
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	if result.Status != "cancelled" {
		t.Errorf("Expected status 'cancelled', got %q", result.Status)
	}

	t.Logf("Cancellation result: %+v", result)
}

func TestRunnerTimeout(t *testing.T) {
	tmpDir := t.TempDir()
	outputPath := filepath.Join(tmpDir, "result.json")

	// Build the binary
	binaryPath := filepath.Join(tmpDir, "barkbot-runner")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with very short timeout (mock takes 500ms)
	cmd := exec.Command(binaryPath,
		"--provider", "mock",
		"--model", "mock-model",
		"--prompt", "This will timeout",
		"--output", outputPath,
		"--timeout", "0", // Immediate timeout
	)

	_ = cmd.Run() // Will fail, that's expected

	// Verify timeout was recorded
	data, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("Failed to read output: %v", err)
	}

	var result Result
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatalf("Failed to parse result: %v", err)
	}

	if result.Status != "failed" {
		t.Errorf("Expected status 'failed', got %q", result.Status)
	}

	if result.Error == "" {
		t.Error("Expected error message for timeout")
	}

	t.Logf("Timeout result: %+v", result)
}

func TestRunnerMissingFlags(t *testing.T) {
	tmpDir := t.TempDir()

	binaryPath := filepath.Join(tmpDir, "barkbot-runner")
	buildCmd := exec.Command("go", "build", "-o", binaryPath, ".")
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with missing required flags
	cmd := exec.Command(binaryPath,
		"--provider", "mock",
		// Missing --model, --prompt, --output
	)

	err := cmd.Run()
	if err == nil {
		t.Error("Expected error for missing flags")
	}

	// Check exit code is 2 (usage error)
	if exitErr, ok := err.(*exec.ExitError); ok {
		if exitErr.ExitCode() != 2 {
			t.Errorf("Expected exit code 2, got %d", exitErr.ExitCode())
		}
	}
}
