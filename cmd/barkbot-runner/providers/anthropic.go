package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const anthropicAPIURL = "https://api.anthropic.com/v1/messages"

// AnthropicProvider calls the Anthropic Claude API.
type AnthropicProvider struct {
	model  string
	apiKey string
	client *http.Client
}

// NewAnthropicProvider creates an Anthropic provider.
func NewAnthropicProvider(model, apiKey string) *AnthropicProvider {
	return &AnthropicProvider{
		model:  model,
		apiKey: apiKey,
		client: &http.Client{Timeout: 120 * time.Second},
	}
}

type anthropicRequest struct {
	Model       string              `json:"model"`
	MaxTokens   int                 `json:"max_tokens"`
	Temperature float64             `json:"temperature,omitempty"`
	System      string              `json:"system,omitempty"`
	Messages    []anthropicMessage  `json:"messages"`
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type anthropicResponse struct {
	ID      string             `json:"id"`
	Type    string             `json:"type"`
	Role    string             `json:"role"`
	Content []anthropicContent `json:"content"`
	Usage   anthropicUsage     `json:"usage"`
}

type anthropicContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type anthropicUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

type anthropicError struct {
	Type    string                 `json:"type"`
	Message string                 `json:"message"`
	Error   anthropicErrorDetails  `json:"error"`
}

type anthropicErrorDetails struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// Generate calls the Anthropic API.
func (a *AnthropicProvider) Generate(ctx context.Context, req Request) (Response, error) {
	payload := anthropicRequest{
		Model:       a.model,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
		System:      req.SystemPrompt,
		Messages: []anthropicMessage{
			{
				Role:    "user",
				Content: req.Prompt,
			},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return Response{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", anthropicAPIURL, bytes.NewReader(body))
	if err != nil {
		return Response{}, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", a.apiKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return Response{}, fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var apiErr anthropicError
		if err := json.Unmarshal(respBody, &apiErr); err == nil && apiErr.Error.Message != "" {
			return Response{}, fmt.Errorf("anthropic API error: %s", apiErr.Error.Message)
		}
		return Response{}, fmt.Errorf("anthropic API error: %s (status %d)", string(respBody), resp.StatusCode)
	}

	var apiResp anthropicResponse
	if err := json.Unmarshal(respBody, &apiResp); err != nil {
		return Response{}, fmt.Errorf("unmarshal response: %w", err)
	}

	// Extract text content
	var content string
	for _, c := range apiResp.Content {
		if c.Type == "text" {
			content += c.Text
		}
	}

	return Response{
		Content:    content,
		TokensUsed: apiResp.Usage.InputTokens + apiResp.Usage.OutputTokens,
	}, nil
}
