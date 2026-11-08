package providers

import (
	"context"
	"fmt"
	"os"
)

// Request is the input to a provider.
type Request struct {
	Prompt       string
	SystemPrompt string
	MaxTokens    int
	Temperature  float64
}

// Response is the output from a provider.
type Response struct {
	Content    string
	TokensUsed int
}

// Provider is the interface all LLM providers must implement.
type Provider interface {
	Generate(ctx context.Context, req Request) (Response, error)
}

// NewProvider creates a provider client based on the provider name.
func NewProvider(name, model, apiKey string) (Provider, error) {
	switch name {
	case "mock":
		return NewMockProvider(model), nil
	case "anthropic":
		if apiKey == "" {
			apiKey = getEnvOrEmpty("ANTHROPIC_API_KEY")
		}
		if apiKey == "" {
			return nil, fmt.Errorf("anthropic provider requires API key (--api-key or ANTHROPIC_API_KEY env)")
		}
		return NewAnthropicProvider(model, apiKey), nil
	case "openai":
		if apiKey == "" {
			apiKey = getEnvOrEmpty("OPENAI_API_KEY")
		}
		if apiKey == "" {
			return nil, fmt.Errorf("openai provider requires API key (--api-key or OPENAI_API_KEY env)")
		}
		return NewOpenAIProvider(model, apiKey), nil
	default:
		return nil, fmt.Errorf("unknown provider: %s (supported: mock, anthropic, openai)", name)
	}
}

func getEnvOrEmpty(key string) string {
	return os.Getenv(key)
}
