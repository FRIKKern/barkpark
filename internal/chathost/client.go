package chathost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var ErrRevoked = errors.New("chat host credential revoked")

// StatusError is a non-2xx answer from the chat host API other than the 401
// that means ErrRevoked.
type StatusError struct {
	Code   int
	Status string
	Body   string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("chat host API %s: %s", e.Status, e.Body)
}

// configError marks a failure of the host's own configuration (server URL,
// credential) that no retry can heal.
type configError struct{ err error }

func (e *configError) Error() string { return e.err.Error() }
func (e *configError) Unwrap() error { return e.err }

// Transient reports whether retrying the same call later can succeed: network
// errors, timeouts, 5xx, 408 and 429. Revocation, any other 4xx and a bad
// local configuration are not transient.
func Transient(err error) bool {
	if err == nil || errors.Is(err, ErrRevoked) {
		return false
	}
	var config *configError
	if errors.As(err, &config) {
		return false
	}
	var refused *AttachmentError
	if errors.As(err, &refused) {
		return false
	}
	var status *StatusError
	if errors.As(err, &status) {
		return status.Code >= 500 || status.Code == http.StatusRequestTimeout || status.Code == http.StatusTooManyRequests
	}
	return true
}

type Client struct {
	BaseURL               string
	Credential            string
	HTTPClient            *http.Client
	AllowInsecureLoopback bool
}

type HostInfo struct {
	ID              string         `json:"id"`
	WorkspaceID     string         `json:"workspace_id"`
	Name            string         `json:"name"`
	ApprovedRoots   []string       `json:"approved_roots"`
	ProtocolVersion int            `json:"protocol_version"`
	Capabilities    map[string]any `json:"capabilities"`
}

type EnrollmentResult struct {
	Host       HostInfo `json:"host"`
	Credential string   `json:"credential"`
}

type RemoteCommand struct {
	LeaseID    string         `json:"lease_id"`
	Epoch      uint64         `json:"epoch"`
	LastCursor uint64         `json:"last_cursor"`
	Command    map[string]any `json:"command"`
}

func (c *Client) Enroll(ctx context.Context, token string, roots []string, capabilities map[string]any) (EnrollmentResult, error) {
	var result EnrollmentResult
	err := c.do(ctx, http.MethodPost, "/v1/chat-host/enroll", false, map[string]any{
		"enrollment_token": token,
		"approved_roots":   roots,
		"protocol_version": 1,
		"capabilities":     capabilities,
	}, &result)
	return result, err
}

func (c *Client) Heartbeat(ctx context.Context, capabilities map[string]any) error {
	return c.do(ctx, http.MethodPost, "/v1/chat-host/heartbeat", true, map[string]any{
		"protocol_version": 1,
		"capabilities":     capabilities,
	}, nil)
}

func (c *Client) Commands(ctx context.Context) ([]RemoteCommand, error) {
	var response struct {
		Commands []RemoteCommand `json:"commands"`
	}
	err := c.do(ctx, http.MethodGet, "/v1/chat-host/commands", true, nil, &response)
	return response.Commands, err
}

func (c *Client) Publish(ctx context.Context, command RemoteCommand, cursor uint64, key string, event map[string]any) error {
	return c.do(ctx, http.MethodPost, "/v1/chat-host/events", true, map[string]any{
		"lease_id":        command.LeaseID,
		"epoch":           command.Epoch,
		"cursor":          cursor,
		"idempotency_key": key,
		"event":           event,
	}, nil)
}

func (c *Client) do(ctx context.Context, method, path string, authenticate bool, payload any, response any) error {
	resp, err := c.send(ctx, method, path, authenticate, payload)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if response == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(response)
}

// send makes one request and returns a 2xx response with its body unread; the
// caller closes it. Any other answer is closed here and returned as an error.
func (c *Client) send(ctx context.Context, method, path string, authenticate bool, payload any) (*http.Response, error) {
	base, err := url.Parse(c.BaseURL)
	if err != nil {
		return nil, &configError{fmt.Errorf("parse server URL: %w", err)}
	}
	if err := validateServerURL(base, c.AllowInsecureLoopback); err != nil {
		return nil, &configError{err}
	}
	base.Path = strings.TrimRight(base.Path, "/") + path

	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, base.String(), body)
	if err != nil {
		return nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if authenticate {
		if c.Credential == "" {
			return nil, &configError{errors.New("missing chat host credential")}
		}
		req.Header.Set("Authorization", "Host "+c.Credential)
	}

	httpClient := c.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	if err := validateServerURL(resp.Request.URL, c.AllowInsecureLoopback); err != nil {
		resp.Body.Close()
		return nil, &configError{fmt.Errorf("unsafe redirect: %w", err)}
	}
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		return nil, ErrRevoked
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		limited, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		return nil, &StatusError{Code: resp.StatusCode, Status: resp.Status, Body: strings.TrimSpace(string(limited))}
	}
	return resp, nil
}

func validateServerURL(value *url.URL, allowInsecureLoopback bool) error {
	if value.Scheme == "https" && value.Hostname() != "" {
		return nil
	}
	if value.Scheme == "http" && allowInsecureLoopback {
		host := value.Hostname()
		if host == "localhost" || host == "127.0.0.1" || host == "::1" {
			return nil
		}
	}
	return fmt.Errorf("chat host server URL must use https (http loopback requires explicit opt-in)")
}
