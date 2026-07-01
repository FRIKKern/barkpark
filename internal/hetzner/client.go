// Package hetzner is the native, SDK-backed Hetzner client — the drop-in
// replacement for the argv-shelling cloud.HcloudProvider in internal/cli/cloud.
// It wraps github.com/hetznercloud/hcloud-go/v2 so the provisioner (and the
// future `bp cloud hetzner …` surface) talks to api.hetzner.cloud directly
// instead of exec'ing the `hcloud` CLI: no binary on PATH, structured errors,
// real action polling instead of scraping stdout.
//
// The package mirrors the cloud package's seams 1:1 — APIProvider implements
// cloud.CloudProvider (+ ServerLabeler + LabelLister), DNS implements
// cloud.DNSProvider — with the SAME label keys and the SAME error-tolerance
// contract, so swapping one for the other changes transport, not behavior.
package hetzner

import (
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// Client wraps *hcloud.Client. The underlying SDK client is exported via
// HCloud() so callers that outgrow the seam (future `bp cloud hetzner …`
// subcommands) can reach the full API without this package re-wrapping every
// resource.
type Client struct {
	hc *hcloud.Client
}

// Option configures NewClient. Options exist so tests can point the client at
// an httptest fake (WithEndpoint) and poll fast (WithPollBackoff) — production
// callers usually pass none.
type Option func(*options)

type options struct {
	endpoint    string
	httpClient  *http.Client
	pollBackoff time.Duration
}

// WithEndpoint overrides the API root (default https://api.hetzner.cloud/v1).
// Tests set it to an httptest.Server URL so no request ever leaves the process.
func WithEndpoint(endpoint string) Option {
	return func(o *options) { o.endpoint = endpoint }
}

// WithHTTPClient overrides the *http.Client the SDK dispatches through.
func WithHTTPClient(c *http.Client) Option {
	return func(o *options) { o.httpClient = c }
}

// WithPollBackoff sets a CONSTANT action-poll interval (default: the SDK's
// exponential backoff starting at 1s). Tests set ~1ms so waiting on a fake
// action completes instantly.
func WithPollBackoff(d time.Duration) Option {
	return func(o *options) { o.pollBackoff = d }
}

// NewClient returns a Client authenticated with token. The token comes from
// ResolveToken (HCLOUD_TOKEN) in production wiring; tests pass any non-empty
// string plus WithEndpoint.
func NewClient(token string, opts ...Option) *Client {
	var o options
	for _, opt := range opts {
		opt(&o)
	}
	hcOpts := []hcloud.ClientOption{hcloud.WithToken(token)}
	if o.endpoint != "" {
		hcOpts = append(hcOpts, hcloud.WithEndpoint(o.endpoint))
	}
	if o.httpClient != nil {
		hcOpts = append(hcOpts, hcloud.WithHTTPClient(o.httpClient))
	}
	if o.pollBackoff > 0 {
		hcOpts = append(hcOpts, hcloud.WithPollOpts(hcloud.PollOpts{
			BackoffFunc: hcloud.ConstantBackoff(o.pollBackoff),
		}))
	}
	return &Client{hc: hcloud.NewClient(hcOpts...)}
}

// HCloud exposes the underlying SDK client for callers that need resources
// this package doesn't wrap.
func (c *Client) HCloud() *hcloud.Client {
	return c.hc
}

// ResolveToken reads the Hetzner Cloud API token from HCLOUD_TOKEN — the same
// env var the `hcloud` CLI (and thus the argv provider) authenticates with, so
// flipping to the native provider needs no new credential. An empty/unset var
// is an error: failing early beats a cryptic 401 later.
func ResolveToken() (string, error) {
	if tok := strings.TrimSpace(os.Getenv("HCLOUD_TOKEN")); tok != "" {
		return tok, nil
	}
	return "", fmt.Errorf("hetzner: HCLOUD_TOKEN is not set (the native provider reads the API token from the environment; `hcloud context` files are CLI-only)")
}
