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

const openaiAPIURL = "https://api.openai.com/v1/chat/completions"

// OpenAIProvider calls the OpenAI GPT API.
type OpenAIProvider struct {
	model  string
	apiKey string
	client *http.Client
}

// NewOpenAIProvider creates an OpenAI provider.
func NewOpenAIProvider(model, apiKey string) *OpenAIProvider {
	return &OpenAIProvider{
		model:  model,
		apiKey: apiKey,
		client: &http.Client{Timeout: 120 * time.Second},
	}
}

type openaiRequest struct {
	Model       string           `json:"model"`
	Messages    []openaiMessage  `json:"messages"`
	MaxTokens   int              `json:"max_tokens,omitempty"`
	Temperature float64          `json:"temperature,omitempty"`
}

type openaiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openaiResponse struct {
	ID      string         `json:"id"`
	Object  string         `json:"object"`
	Choices []openaiChoice `json:"choices"`
	Usage   openaiUsage    `json:"usage"`
}

type openaiChoice struct {
	Index        int           `json:"index"`
	Message      openaiMessage `json:"message"`
	FinishReason string        `json:"finish_reason"`
}

type openaiUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type openaiError struct {
	Error openaiErrorDetails `json:"error"`
}

type openaiErrorDetails struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    string `json:"code"`
}

// Generate calls the OpenAI API.
func (o *OpenAIProvider) Generate(ctx context.Context, req Request) (Response, error) {
	messages := []openaiMessage{}
	
	if req.SystemPrompt != "" {
		messages = append(messages, openaiMessage{
			Role:    "system",
			Content: req.SystemPrompt,
		})
	}
	
	messages = append(messages, openaiMessage{
		Role:    "user",
		Content: req.Prompt,
	})

	payload := openaiRequest{
		Model:       o.model,
		Messages:    messages,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return Response{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", openaiAPIURL, bytes.NewReader(body))
	if err != nil {
		return Response{}, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+o.apiKey)

	resp, err := o.client.Do(httpReq)
	if err != nil {
		return Response{}, fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var apiErr openaiError
		if err := json.Unmarshal(respBody, &apiErr); err == nil && apiErr.Error.Message != "" {
			return Response{}, fmt.Errorf("openai API error: %s", apiErr.Error.Message)
		}
		return Response{}, fmt.Errorf("openai API error: %s (status %d)", string(respBody), resp.StatusCode)
	}

	var apiResp openaiResponse
	if err := json.Unmarshal(respBody, &apiResp); err != nil {
		return Response{}, fmt.Errorf("unmarshal response: %w", err)
	}

	if len(apiResp.Choices) == 0 {
		return Response{}, fmt.Errorf("no choices in response")
	}

	return Response{
		Content:    apiResp.Choices[0].Message.Content,
		TokensUsed: apiResp.Usage.TotalTokens,
	}, nil
}
