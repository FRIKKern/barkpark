// Command barkbot-runner executes AI tasks by calling LLM provider APIs.
//
// It is a standalone binary that:
// - Calls Anthropic Claude or OpenAI GPT APIs
// - Enforces time limits
// - Handles cancellation via SIGTERM
// - Returns structured JSON results
// - Supports mock provider for testing
//
// Usage:
//
//	barkbot-runner \
//	  --provider anthropic \
//	  --model claude-3-5-sonnet-20241022 \
//	  --prompt "Write a haiku" \
//	  --output /tmp/result.json \
//	  [--api-key sk-...] \
//	  [--system "You are a helpful assistant"] \
//	  [--max-tokens 500] \
//	  [--temperature 1.0]
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/FRIKKern/barkpark/cmd/barkbot-runner/providers"
)

// Result is the output structure written to the output file.
type Result struct {
	Status          string `json:"status"`            // "completed" | "failed" | "cancelled"
	Response        string `json:"response,omitempty"`
	Error           string `json:"error,omitempty"`
	TokensUsed      int    `json:"tokens_used,omitempty"`
	ExecutionTimeMs int64  `json:"execution_time_ms,omitempty"`
}

func main() {
	os.Exit(run())
}

func run() int {
	var (
		provider    = flag.String("provider", "", "LLM provider: anthropic|openai|mock (required)")
		model       = flag.String("model", "", "Model name (required)")
		prompt      = flag.String("prompt", "", "User prompt (required)")
		output      = flag.String("output", "", "Output JSON file path (required)")
		apiKey      = flag.String("api-key", "", "API key (optional, can use env vars)")
		systemPrompt = flag.String("system", "", "System prompt (optional)")
		maxTokens   = flag.Int("max-tokens", 4096, "Maximum tokens to generate")
		temperature = flag.Float64("temperature", 1.0, "Temperature (0.0 to 2.0)")
		timeoutSec  = flag.Int("timeout", 300, "Timeout in seconds")
	)
	flag.Parse()

	// Validate required flags
	if *provider == "" || *model == "" || *prompt == "" || *output == "" {
		fmt.Fprintln(os.Stderr, "Error: --provider, --model, --prompt, and --output are required")
		flag.Usage()
		return 2
	}

	// Create provider client
	client, err := providers.NewProvider(*provider, *model, *apiKey)
	if err != nil {
		writeResult(*output, Result{
			Status: "failed",
			Error:  fmt.Sprintf("Failed to create provider: %v", err),
		})
		return 1
	}

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

	// Execute request
	start := time.Now()
	
	req := providers.Request{
		Prompt:       *prompt,
		SystemPrompt: *systemPrompt,
		MaxTokens:    *maxTokens,
		Temperature:  *temperature,
	}

	resp, err := client.Generate(ctx, req)
	executionMs := time.Since(start).Milliseconds()

	// Handle result
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
				Status:          "failed",
				Error:           "Job timed out",
				ExecutionTimeMs: executionMs,
			}
		} else {
			result = Result{
				Status:          "failed",
				Error:           err.Error(),
				ExecutionTimeMs: executionMs,
			}
		}
	} else {
		result = Result{
			Status:          "completed",
			Response:        resp.Content,
			TokensUsed:      resp.TokensUsed,
			ExecutionTimeMs: executionMs,
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
