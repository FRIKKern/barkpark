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
	"strconv"
	"strings"
	"time"
)

// ErrRevoked is a 401 on an authenticated call: the server no longer takes
// this machine's credential (revoked by the owner, or past its 30 days).
var ErrRevoked = errors.New("chat host credential revoked or expired: ask the workspace owner to register this machine again (Studio > Chat hosts), then run barkpark-chat-host enroll")

// StatusError is a non-2xx answer from the chat host API other than the 401
// that means ErrRevoked.
type StatusError struct {
	Code   int
	Status string
	Body   string
	// RetryAfter is the server's Retry-After in whole seconds; zero when absent.
	RetryAfter time.Duration
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
	var enrollRefused *EnrollRefusedError
	if errors.As(err, &enrollRefused) {
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

// MaxHeldLeases is the most lease ids a heartbeat's held_leases may list: the
// server refuses a longer list with 422 (task-bbb32ae64e56c1e0).
const MaxHeldLeases = 1000

// Heartbeat says the host is up and lists the leases it still holds: the
// server renews only those of its running leases, so one this process gave up
// on is closed by the server's expiry sweep (task-e8a91dd731695004). An empty
// list is sent as [], meaning none; a server older than the key ignores it.
//
// Past MaxHeldLeases the list is left out, not cut: the server then renews
// every live lease, as for a host that sends no list, where a cut list would
// let leases this process still runs expire. A host running that many turns
// is not one we expect.
func (c *Client) Heartbeat(ctx context.Context, capabilities map[string]any, held []string) error {
	if held == nil {
		held = []string{}
	}
	body := map[string]any{
		"protocol_version": 1,
		"capabilities":     capabilities,
		"held_leases":      held,
	}
	if len(held) > MaxHeldLeases {
		delete(body, "held_leases")
	}
	return c.do(ctx, http.MethodPost, "/v1/chat-host/heartbeat", true, body, nil)
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

// PostStatus sends a turn's status label out of the event sequence: no cursor,
// no idempotency key, fenced by the lease and its epoch like an event
// (task-768e7dc4449cc7b9). An old server answers 404.
func (c *Client) PostStatus(ctx context.Context, command RemoteCommand, label string) error {
	return c.do(ctx, http.MethodPost, "/v1/chat-host/leases/"+url.PathEscape(command.LeaseID)+"/status", true, map[string]any{
		"epoch": command.Epoch,
		"label": label,
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
		// Only enroll is unauthenticated, and its 401 is about the one-time
		// code, not a credential: the server says why and what to do.
		if !authenticate {
			limited, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			return nil, enrollRefusal(limited)
		}
		resp.Body.Close()
		return nil, ErrRevoked
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		limited, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		statusErr := &StatusError{Code: resp.StatusCode, Status: resp.Status, Body: strings.TrimSpace(string(limited))}
		if seconds, err := strconv.Atoi(strings.TrimSpace(resp.Header.Get("Retry-After"))); err == nil && seconds > 0 {
			statusErr.RetryAfter = time.Duration(seconds) * time.Second
		}
		return nil, statusErr
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
