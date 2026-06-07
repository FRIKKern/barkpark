// Package apiclient is a framework-free HTTP client for the Barkpark Phoenix
// API. It has ZERO Bubble Tea dependency and is shared by the TUI today and the
// CLI later. Real-time change detection is surfaced through the OnChange
// callback rather than a tea.Program reference, so the same client drives both
// an interactive TUI and a one-shot CLI.
package apiclient

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// DefaultTimeout is the per-request HTTP timeout when Config.Timeout is zero.
// The legacy DataStore hardcoded 5s; the batch/CLI path can raise it via Config.
const DefaultTimeout = 5 * time.Second

// Doc represents a single document from the API.
type Doc struct {
	ID        string            `json:"id"`
	Title     string            `json:"title"`
	Status    string            `json:"status"`
	Category  string            `json:"category,omitempty"`
	Author    string            `json:"author,omitempty"`
	UpdatedAt time.Time         `json:"updatedAt"`
	Values    map[string]string `json:"values,omitempty"`
}

// WorkspaceInfo is one membership-scoped workspace from GET /api/workspaces.
type WorkspaceInfo struct {
	ID   string `json:"id"`
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// ProjectInfo is one project from GET /api/workspaces/:slug/projects.
type ProjectInfo struct {
	ID   string `json:"id"`
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// Config holds the connection + scope settings for a Client.
type Config struct {
	BaseURL   string
	Token     string
	Workspace string
	Project   string
	Dataset   string
	// Perspective selects which view of the dataset Query reads:
	// "published" (public default), "drafts" (Studio-style: drafts overlaid on
	// published), or "raw" (everything). An EMPTY string means "do not send a
	// perspective param" — the server then applies its own default (published).
	// The CLI's manifest-driven doc reads leave this empty so they keep the
	// published default; the TUI sets it to "drafts" so editing surfaces show
	// unpublished work. See ConfigFromEnv for the BARKPARK_PERSPECTIVE override.
	Perspective string
	// Timeout is the per-request HTTP timeout. Zero means DefaultTimeout.
	// (The SSE listener always uses an unbounded timeout, independent of this.)
	Timeout time.Duration
}

// ConfigFromEnv builds a Config from the BARKPARK_* environment variables,
// applying the same defaults the TUI's main() used inline.
func ConfigFromEnv() Config {
	baseURL := os.Getenv("BARKPARK_API_URL")
	if baseURL == "" {
		baseURL = os.Getenv("BARKPARK_SERVER")
	}
	if baseURL == "" {
		baseURL = "http://localhost:4000"
	}

	token := os.Getenv("BARKPARK_API_TOKEN")
	if token == "" {
		token = "barkpark-dev-token"
	}

	workspace := os.Getenv("BARKPARK_WORKSPACE")
	if workspace == "" {
		workspace = "default"
	}
	project := os.Getenv("BARKPARK_PROJECT")
	if project == "" {
		project = "default"
	}
	dataset := os.Getenv("BARKPARK_DATASET")
	if dataset == "" {
		dataset = "production"
	}

	return Config{
		BaseURL:     baseURL,
		Token:       token,
		Workspace:   workspace,
		Project:     project,
		Dataset:     dataset,
		Perspective: PerspectiveFromEnv(),
	}
}

// PerspectiveFromEnv resolves the dataset view for the interactive TUI: the
// BARKPARK_PERSPECTIVE env var when set to a recognised value (published|drafts|
// raw), else the TUI default "drafts" so editing surfaces show unpublished work.
// An unrecognised value falls back to the "drafts" default rather than passing
// junk to the server. This is the TUI/apiclient default ONLY — the CLI's
// manifest-driven reads never call this and keep the published default.
func PerspectiveFromEnv() string {
	switch os.Getenv("BARKPARK_PERSPECTIVE") {
	case "published", "drafts", "raw":
		return os.Getenv("BARKPARK_PERSPECTIVE")
	default:
		return "drafts"
	}
}

// Client is a framework-free HTTP client that talks to the Phoenix API.
type Client struct {
	baseURL string
	token   string
	// Workspace/Project/Dataset scope the /v1/ endpoints onto the
	// /w/:workspace_slug/p/:project_slug routing. Defaults: "default"/"default"/"production".
	Workspace string
	Project   string
	Dataset   string
	// Perspective is the dataset view Query reads ("published"/"drafts"/"raw").
	// Empty means "send no perspective param" — the server defaults to published.
	Perspective string
	client      *http.Client
	// OnChange, if set, is invoked when the SSE listener / poll fallback detects
	// that the dataset changed. It replaces the old tea.Program coupling: the TUI
	// sets it to program.Send(DataStoreRefreshMsg{}); a CLI may leave it nil.
	OnChange func()
	mu       sync.RWMutex
	lastHash string
}

// New constructs a Client from cfg, applying defaults for any empty scope field
// and a DefaultTimeout when Timeout is zero.
func New(cfg Config) *Client {
	if cfg.Workspace == "" {
		cfg.Workspace = "default"
	}
	if cfg.Project == "" {
		cfg.Project = "default"
	}
	if cfg.Dataset == "" {
		cfg.Dataset = "production"
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	return &Client{
		baseURL:     cfg.BaseURL,
		token:       cfg.Token,
		Workspace:   cfg.Workspace,
		Project:     cfg.Project,
		Dataset:     cfg.Dataset,
		Perspective: cfg.Perspective,
		client:      &http.Client{Timeout: timeout},
	}
}

// BaseURL returns the configured API base URL.
func (c *Client) BaseURL() string { return c.baseURL }

// Token returns the configured bearer token.
func (c *Client) Token() string { return c.token }

// SetToken sets the API token for authenticated requests.
func (c *Client) SetToken(token string) { c.token = token }

// scopedURL builds a workspace/project-scoped /v1/ endpoint of the form
//
//	<baseURL>/w/<Workspace>/p/<Project><suffix>
//
// where suffix is a leading-slash path segment (e.g. "/v1/data/mutate/<dataset>").
// This is the single place that knows the scoped URL scheme.
func (c *Client) scopedURL(suffix string) string {
	return fmt.Sprintf("%s/w/%s/p/%s%s", c.baseURL, c.Workspace, c.Project, suffix)
}

// authGet issues a GET to url with the Client's bearer token attached.
// Scoped /v1/ reads run ResolveWorkspace, which fails closed (403) for an
// anonymous caller — so every read must carry the token, exactly like
// Mutate/listenSSE do for their requests.
func (c *Client) authGet(url string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	return c.client.Do(req)
}

// ConditionalGetResult carries the outcome of GetConditional: the HTTP status,
// the response body (nil on 304), and the response ETag header (if any).
type ConditionalGetResult struct {
	StatusCode int
	Body       []byte
	ETag       string
}

// GetConditional issues an authenticated GET to an ABSOLUTE url, attaching
// If-None-Match when ifNoneMatch is non-empty so the server can answer 304 Not
// Modified. It returns the status, the body (read fully, nil on 304), and the
// response ETag. This is an additive, behaviour-preserving helper used by the
// manifest fetcher — it does not alter any existing method.
func (c *Client) GetConditional(url, ifNoneMatch string) (*ConditionalGetResult, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if ifNoneMatch != "" {
		req.Header.Set("If-None-Match", ifNoneMatch)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	res := &ConditionalGetResult{
		StatusCode: resp.StatusCode,
		ETag:       resp.Header.Get("ETag"),
	}
	if resp.StatusCode != http.StatusNotModified {
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		res.Body = body
	}
	return res, nil
}

// Mutate sends a mutation to the Phoenix API (Sanity format).
func (c *Client) Mutate(mutations []map[string]interface{}) error {
	endpoint := c.scopedURL("/v1/data/mutate/" + c.Dataset)
	body, err := json.Marshal(map[string]interface{}{"mutations": mutations})
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("mutation error %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// Query fetches documents from the API by type, with optional filter.
//
// When Client.Perspective is non-empty it is appended as ?perspective=<p>,
// combined with any filter via the right ?/& separator. An empty Perspective
// sends no param, so the server applies its own default (published) — that is
// the CLI/manifest contract; the TUI sets Perspective="drafts" to surface
// unpublished work.
func (c *Client) Query(typeName, filter string) []Doc {
	endpoint := c.scopedURL("/v1/data/query/" + c.Dataset + "/" + typeName)
	params := url.Values{}
	if filter != "" {
		params.Set("filter", filter)
	}
	if c.Perspective != "" {
		params.Set("perspective", c.Perspective)
	}
	if qs := params.Encode(); qs != "" {
		endpoint += "?" + qs
	}

	resp, err := c.authGet(endpoint)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	// The query controller wraps the page in {"result":{"documents":[...]}};
	// some/older endpoints put "documents" at the top level. Accept both so the
	// TUI's lists populate regardless of the envelope shape.
	var result struct {
		Result struct {
			Documents []Doc `json:"documents"`
		} `json:"result"`
		Documents []Doc `json:"documents"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	if len(result.Result.Documents) > 0 {
		return result.Result.Documents
	}
	return result.Documents
}

// Get fetches a single document by type and ID.
func (c *Client) Get(typeName, id string) (Doc, bool) {
	endpoint := c.scopedURL("/v1/data/doc/" + c.Dataset + "/" + typeName + "/" + id)

	resp, err := c.authGet(endpoint)
	if err != nil {
		return Doc{}, false
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Doc{}, false
	}

	var doc Doc
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return Doc{}, false
	}
	return doc, true
}

// Upsert creates or updates a document via the API.
//
// The scoped /v1/data API has no per-type document POST — upsert is expressed
// as a createOrReplace mutation routed through POST /v1/data/mutate/<dataset>.
func (c *Client) Upsert(typeName string, doc Doc) error {
	create := map[string]interface{}{
		"_type": typeName,
	}
	if doc.ID != "" {
		create["_id"] = doc.ID
	}
	if doc.Title != "" {
		create["title"] = doc.Title
	}
	if doc.Status != "" {
		create["status"] = doc.Status
	}
	if doc.Category != "" {
		create["category"] = doc.Category
	}
	if doc.Author != "" {
		create["author"] = doc.Author
	}
	for k, v := range doc.Values {
		create[k] = v
	}

	mutation := map[string]interface{}{"createOrReplace": create}
	return c.Mutate([]map[string]interface{}{mutation})
}

// Delete removes a document via the API.
//
// The scoped /v1/data API has no DELETE verb — deletion is expressed as a
// delete mutation routed through POST /v1/data/mutate/<dataset>.
func (c *Client) Delete(typeName, id string) bool {
	mutation := map[string]interface{}{
		"delete": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return c.Mutate([]map[string]interface{}{mutation}) == nil
}

// ListWorkspaces fetches the workspaces the bearer token is a member of via
// GET /api/workspaces. This is a token-gated, NOT path-scoped, endpoint — it
// lives under /api directly, not under /w/:ws/p/:project.
func (c *Client) ListWorkspaces() ([]WorkspaceInfo, error) {
	resp, err := c.authGet(c.baseURL + "/api/workspaces")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list workspaces: status %d", resp.StatusCode)
	}

	var result struct {
		Workspaces []WorkspaceInfo `json:"workspaces"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("parse workspaces: %w", err)
	}
	return result.Workspaces, nil
}

// ListProjects fetches the projects under a workspace via
// GET /api/workspaces/:workspace_slug/projects. A non-member (or unknown slug)
// returns 404, which surfaces here as an error.
func (c *Client) ListProjects(workspaceSlug string) ([]ProjectInfo, error) {
	resp, err := c.authGet(c.baseURL + "/api/workspaces/" + url.PathEscape(workspaceSlug) + "/projects")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list projects: status %d", resp.StatusCode)
	}

	var result struct {
		Workspace WorkspaceInfo `json:"workspace"`
		Projects  []ProjectInfo `json:"projects"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("parse projects: %w", err)
	}
	return result.Projects, nil
}

// StartSSE connects to the Phoenix SSE listener for real-time updates.
// Falls back to a single poll on reconnect, with exponential backoff. Change
// detection fires the OnChange callback (nil-safe). With OnChange unset the
// listener idles, so a CLI that never sets it never opens the stream.
func (c *Client) StartSSE(token string) {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		if c.OnChange == nil {
			time.Sleep(time.Second)
			continue
		}
		err := c.listenSSE(token)
		if err != nil {
			c.pollOnce()
			time.Sleep(backoff)
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		} else {
			backoff = time.Second
		}
	}
}

func (c *Client) listenSSE(token string) error {
	sseURL := c.scopedURL("/v1/data/listen/" + c.Dataset)
	req, err := http.NewRequest("GET", sseURL, nil)
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	sseClient := &http.Client{Timeout: 0}
	resp, err := sseClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("SSE status %d", resp.StatusCode)
	}

	// Use a line scanner instead of raw Read to handle SSE frames correctly
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: mutation") {
			c.notifyChange()
		}
	}
	return scanner.Err()
}

func (c *Client) pollOnce() {
	// Scoped change-detection fallback when the SSE listener drops. The legacy
	// flat document list has no scoped equivalent; the export endpoint streams
	// the dataset as NDJSON (one document envelope per line).
	//
	// Change detection hashes the DOCUMENT SET — the sorted set of
	// "_id:_rev" pairs — not the raw response body. The envelope's _rev bumps
	// on every mutation, so this hash changes iff a document is added, removed,
	// or revised. It deliberately ignores volatile / non-identity envelope
	// content and is order-independent, so a re-poll over the same docs (in any
	// order) yields the same hash and fires no spurious refresh.
	resp, err := c.authGet(c.scopedURL("/v1/data/export/" + c.Dataset))
	if err != nil {
		return
	}
	defer resp.Body.Close()

	hash := c.exportDocSetHash(resp.Body)

	c.mu.Lock()
	changed := hash != c.lastHash
	c.lastHash = hash
	c.mu.Unlock()

	if changed {
		c.notifyChange()
	}
}

// notifyChange invokes the OnChange callback if one is set. It is the single
// nil-safe seam where the framework-free client signals "the dataset changed".
func (c *Client) notifyChange() {
	if c.OnChange != nil {
		c.OnChange()
	}
}

// exportDocSetHash reads the NDJSON export stream and returns a stable hash of
// the document set: each line's "_id:_rev" pair, sorted and concatenated, then
// SHA-256'd. Unparseable lines are skipped so a single malformed record cannot
// poison the whole signature. The hash is identity-derived — independent of
// stream order and of any non-identity envelope fields.
func (c *Client) exportDocSetHash(r io.Reader) string {
	type docIdentity struct {
		ID  string `json:"_id"`
		Rev string `json:"_rev"`
	}

	pairs := make([]string, 0)
	scanner := bufio.NewScanner(r)
	// Export documents can be large; raise the line cap above bufio's 64KB
	// default so a big content blob doesn't truncate the _id/_rev decode.
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var d docIdentity
		if err := json.Unmarshal(line, &d); err != nil || d.ID == "" {
			continue
		}
		pairs = append(pairs, d.ID+":"+d.Rev)
	}

	sort.Strings(pairs)
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(pairs, "\n"))))
}
