package providers

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// MockProvider is a fake LLM provider for testing (no API calls, no credentials needed).
type MockProvider struct {
	model string
}

// NewMockProvider creates a mock provider.
func NewMockProvider(model string) *MockProvider {
	return &MockProvider{model: model}
}

// Generate returns a canned response for testing.
func (m *MockProvider) Generate(ctx context.Context, req Request) (Response, error) {
	// Simulate some processing time
	select {
	case <-time.After(500 * time.Millisecond):
	case <-ctx.Done():
		return Response{}, ctx.Err()
	}

	// Generate mock response based on prompt
	response := generateMockResponse(req.Prompt, m.model)

	return Response{
		Content:    response,
		TokensUsed: len(strings.Fields(response)), // Rough approximation
	}, nil
}

func generateMockResponse(prompt, model string) string {
	prompt = strings.ToLower(prompt)

	// Pattern-based responses for common test cases
	if strings.Contains(prompt, "haiku") {
		return "Mock haiku here,\nThree lines of syllables count,\nFive, seven, then five."
	}

	if strings.Contains(prompt, "hello") {
		return "Hello! I'm a mock BarkBot running on the " + model + " model. How can I help you today?"
	}

	if strings.Contains(prompt, "test") || strings.Contains(prompt, "testing") {
		return "This is a mock response from BarkBot. I'm simulating an AI assistant for testing purposes. The runner is working correctly!"
	}

	// Default response
	return fmt.Sprintf("Mock response from %s: I received your prompt about %q. This is a test response generated without calling a real LLM API. In production, I would use the actual provider to generate a real response.", model, truncate(prompt, 50))
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
