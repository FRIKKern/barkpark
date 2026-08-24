// Package apiclient is a framework-free HTTP client for the Barkpark Phoenix
// API. It has ZERO Bubble Tea dependency and is shared by the TUI today and the
// CLI later. Real-time change detection is surfaced through the OnChange
// callback rather than a tea.Program reference, so the same client drives both
// an interactive TUI and a one-shot CLI.
package apiclient

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/httpx"
)

// DefaultTimeout is the per-request HTTP timeout when Config.Timeout is zero.
// The legacy DataStore hardcoded 5s; the batch/CLI path can raise it via Config.
const DefaultTimeout = 5 * time.Second

// maxManifestBytes caps the /v1/capabilities body read — real manifests are
// tens-to-hundreds of KB, so 8MB is generous headroom that still refuses an
// unbounded stream from a misconfigured/hostile base_url.
const maxManifestBytes = 8 << 20

// maxDocBytes caps the per-document body buffered by Get. 64MB is generous for a
// single document while still refusing an unbounded/hostile stream.
const maxDocBytes = 64 << 20

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
	// OnChange, if set, is invoked when a real SSE mutation frame reports that
	// the dataset changed. It replaces the old tea.Program coupling: the TUI sets
	// it to program.Send(DataStoreRefreshMsg{}); a CLI may leave it nil. The
	// NDJSON poll fallback fires OnChangeFallback (below) instead, when that is
	// set — so a caller can tell a live event from a poll-driven refresh.
	OnChange func()
	// OnChangeFallback, if set, is invoked INSTEAD of OnChange when a change is
	// detected by the NDJSON poll fallback (pollOnce) rather than a live SSE
	// frame. It lets a caller render an honest connection state: a client stuck
	// reconnecting, refreshing purely off the poll, must not read as ● live.
	// Unset (the desk TUI, which only wires OnChange) → poll-detected changes
	// fall through to OnChange, so that caller is behaviourally unchanged.
	OnChangeFallback func()
	// OnLivePulse, if set, is invoked whenever the SSE stream proves itself
	// alive: the server's `event: welcome` frame on subscribe, the `: keepalive`
	// comment it emits every 30s of quiet, and every mutation frame. Unlike
	// OnChange it carries NO "data changed" meaning — it only says "the live
	// stream is genuinely connected right now", which is what lets a caller
	// render an honest ● live over a QUIET dataset (mutation frames alone would
	// read as ◐ polling whenever nothing happens to change). Nil-safe; the desk
	// TUI leaves it unset.
	OnLivePulse func()
	mu          sync.RWMutex
	lastHash    string
	// listenBackoffFloor overrides Listen's reconnect backoff floor. Zero means
	// the 1s default; tests set a tiny value so the capped 5xx-retry path runs
	// in milliseconds instead of tens of seconds.
	listenBackoffFloor time.Duration
	// retry is the GET-only transient-500 retry installed by New. It is held
	// here (not just inside client.Transport) so Retries can report the count —
	// a retry nobody can count is a retry that hides a sick server. See retry.go.
	retry *retryTransport
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
	// Every Client gets the narrow transient-500 retry (retry.go): GET only,
	// HTTP 500 only, error.code "internal_error" only, announced on stderr.
	// Installed here rather than at ~20 call sites so there is ONE owner of the
	// policy and no read path can be forgotten.
	rt := &retryTransport{onRetry: stderrRetryNotifier}
	return &Client{
		baseURL:     cfg.BaseURL,
		token:       cfg.Token,
		Workspace:   cfg.Workspace,
		Project:     cfg.Project,
		Dataset:     cfg.Dataset,
		Perspective: cfg.Perspective,
		// httpx.CheckRedirect for the same reason the retry lives here: ONE owner.
		// Go's default policy rewrites a redirected POST into a bodyless GET, so
		// every typed write on this client could silently become a read that
		// reported the redirect target's 200 as success.
		client: &http.Client{Timeout: timeout, Transport: rt, CheckRedirect: httpx.CheckRedirect},
		retry:  rt,
	}
}

// BaseURL returns the configured API base URL.
func (c *Client) BaseURL() string { return c.baseURL }

// Token returns the configured bearer token.
func (c *Client) Token() string { return c.token }

// SetToken sets the API token for authenticated requests.
func (c *Client) SetToken(token string) { c.token = token }

// ScopedURL builds a workspace/project-scoped /v1/ endpoint of the form
//
//	<base>/w/<workspace>/p/<project><suffix>
//
// where suffix is a leading-slash path segment (e.g. "/v1/data/mutate/<dataset>").
// This is the single place that knows the scoped URL scheme — Client.scopedURL
// and the CLI's migrateEndpoint.scopedURL both delegate here so the scheme has
// exactly one owner.
//
// base is normalized with base so a base carrying a
// trailing slash (e.g. "https://api.example.com/") does not splice a doubled
// "//w/". The workspace/project slugs are PathEscaped — parity with the escaped
// dataset/type/id segments in the suffix (and with the JS SDK's scope builder). A
// slug carrying a space, '/', '#', '?', or non-ASCII would otherwise splice a
// broken/ambiguous path. suffix is already-built (its dynamic segments are
// PathEscaped at the call site), so it's passed through untouched.
// @canonical capability:url-scoped-build aka:scopedURL,scoped_url doc:docs/cards/cli.md
func ScopedURL(base, workspace, project, suffix string) string {
	return fmt.Sprintf("%s/w/%s/p/%s%s", strings.TrimRight(base, "/"), url.PathEscape(workspace), url.PathEscape(project), suffix)
}

// scopedURL delegates to the package-level ScopedURL with the Client's configured
// base URL and workspace/project scope.
func (c *Client) scopedURL(suffix string) string {
	return ScopedURL(c.baseURL, c.Workspace, c.Project, suffix)
}

// flatURL builds a NOT-scoped endpoint (no /w/<ws>/p/<proj> prefix) of the
// form <base><path>, normalizing a trailing slash on the base the same way
// ScopedURL does — a bare c.baseURL+path splice would otherwise produce
// "//v1/..." when BARKPARK_API_URL/-s carries a trailing slash, which Phoenix
// 404s. path is already-built (its dynamic segments PathEscaped at the call
// site) and is passed through untouched.
func (c *Client) flatURL(path string) string {
	return strings.TrimRight(c.baseURL, "/") + path
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
// response ETag. The body read is bounded at maxManifestBytes — the right cap
// for the manifest/capabilities-sized payloads this helper was written for.
// Callers whose responses legitimately grow past that (the task board's corpus
// fetch crossed it at 9.1 MB) use GetConditionalBounded with their own cap.
func (c *Client) GetConditional(url, ifNoneMatch string) (*ConditionalGetResult, error) {
	return c.getConditionalBounded(url, ifNoneMatch, maxManifestBytes, "capabilities manifest response")
}

// GetConditionalBounded is GetConditional with a caller-owned body cap. It
// exists for authenticated APIs whose valid payloads are larger than the
// capabilities manifest while still requiring a hard memory-safety ceiling. A
// response larger than maxBytes errors instead of being silently truncated — a
// truncated JSON body would parse as garbage or, worse, as a plausible prefix.
// The cap is a refusal, never a trim; callers must choose a positive,
// contract-specific maxBytes, and the manifest's established 8 MiB limit is
// unchanged.
func (c *Client) GetConditionalBounded(url, ifNoneMatch string, maxBytes int64) (*ConditionalGetResult, error) {
	return c.getConditionalBounded(url, ifNoneMatch, maxBytes, "response")
}

func (c *Client) getConditionalBounded(url, ifNoneMatch string, maxBytes int64, subject string) (*ConditionalGetResult, error) {
	if maxBytes <= 0 {
		return nil, fmt.Errorf("%s limit must be positive", subject)
	}
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
		body, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
		if err != nil {
			return nil, err
		}
		if int64(len(body)) > maxBytes {
			return nil, fmt.Errorf("%s exceeds %d bytes — refusing to parse a truncated body", subject, maxBytes)
		}
		res.Body = body
	}
	return res, nil
}

// MutationResult is one entry of the mutate endpoint's "results" array: the
// (possibly server-assigned) document id, the applied operation, and the
// resulting document envelope. The mutate controller responds with
// {"transactionId": …, "results": [{"id": …, "operation": …, "document": …}]}.
type MutationResult struct {
	ID        string          `json:"id"`
	Operation string          `json:"operation"`
	Document  json.RawMessage `json:"document"`
}

// Mutate sends a mutation to the Phoenix API (Sanity format).
func (c *Client) Mutate(mutations []map[string]interface{}) error {
	_, err := c.MutateResults(mutations)
	return err
}

// MutateResults sends a mutation batch and returns the per-mutation results.
// Callers that need the server's outcome (e.g. Create, which needs the
// generated drafts.<type>-<n> id back) use this; Mutate keeps the legacy
// error-only signature. A success response whose body fails to decode returns
// nil results, not an error — the mutation itself committed.
func (c *Client) MutateResults(mutations []map[string]interface{}) ([]MutationResult, error) {
	endpoint := c.scopedURL("/v1/data/mutate/" + c.Dataset)
	body, err := json.Marshal(map[string]interface{}{"mutations": mutations})
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return nil, humanAPIError(resp.StatusCode, respBody)
	}

	var out struct {
		Results []MutationResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, nil
	}
	return out.Results, nil
}

// humanAPIError turns the server's error envelope into a one-line human
// message — the TUI status bar gets "validation_failed: priority must be an
// integer 0..4" instead of a raw JSON blob. Unknown shapes fall back to the
// body verbatim (clamped) so nothing is ever swallowed.
func humanAPIError(status int, body []byte) error {
	var env struct {
		Error struct {
			Code    string              `json:"code"`
			Message string              `json:"message"`
			Details map[string][]string `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &env) == nil && (env.Error.Code != "" || env.Error.Message != "") {
		msg := env.Error.Message
		if msg == "" {
			msg = env.Error.Code
		}
		var parts []string
		for field, reasons := range env.Error.Details {
			parts = append(parts, field+": "+strings.Join(reasons, "; "))
		}
		sort.Strings(parts) // deterministic over the map
		if len(parts) > 0 {
			msg += " — " + strings.Join(parts, " · ")
		}
		return fmt.Errorf("%s", msg)
	}
	raw := strings.TrimSpace(string(body))
	if r := []rune(raw); len(r) > 200 {
		raw = string(r[:200]) + "…"
	}
	return fmt.Errorf("error %d: %s", status, raw)
}

// Publish promotes a document's draft to published via the publish mutation.
// id is the BARE published id (no "drafts." prefix), matching the documented
// mutate contract ({"publish":{"id":"x","type":"post"}}); the server's
// Content.publish_document derives the drafts. twin itself.
func (c *Client) Publish(typeName, id string) error {
	mutation := map[string]interface{}{
		"publish": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return c.Mutate([]map[string]interface{}{mutation})
}

// Unpublish demotes a published document back to a draft via the unpublish
// mutation. id is the BARE published id, exactly like Publish; the server's
// Content.unpublish_document moves the row to its drafts. twin.
func (c *Client) Unpublish(typeName, id string) error {
	mutation := map[string]interface{}{
		"unpublish": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return c.Mutate([]map[string]interface{}{mutation})
}

// DiscardDraft drops a document's draft, reverting to the published version,
// via the discardDraft mutation. id is the BARE published id (the server
// derives the drafts. twin itself, mirroring Content.discard_draft). The
// SERVER does not twin-guard — discarding the only draft deletes the document
// outright — so callers gate on a published twin existing (Studio's
// is_draft && has_published guard; the TUI probes Get(type, bareId)).
func (c *Client) DiscardDraft(typeName, id string) error {
	mutation := map[string]interface{}{
		"discardDraft": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return c.Mutate([]map[string]interface{}{mutation})
}

// Create creates a NEW draft document with a server-assigned id: a create
// mutation carrying no _id makes Content.create_document generate
// "<type>-<n>" and prefix "drafts.". The assigned draft id is returned from
// the mutate results so the caller can select the new document.
func (c *Client) Create(typeName, title string) (string, error) {
	mutation := map[string]interface{}{
		"create": map[string]interface{}{
			"_type": typeName,
			"title": title,
		},
	}
	results, err := c.MutateResults([]map[string]interface{}{mutation})
	if err != nil {
		return "", err
	}
	if len(results) == 0 || results[0].ID == "" {
		return "", fmt.Errorf("create: server returned no document id")
	}
	return results[0].ID, nil
}

// duplicateSkipKeys are the legacy-envelope top-level keys that are document
// METADATA, not content — they must not be copied into a duplicate's create
// payload. ("status" is server-assigned: a create is always a fresh draft,
// exactly like Studio's clone_document forcing status "draft".)
var duplicateSkipKeys = map[string]bool{
	"id": true, "status": true, "updatedAt": true, "createdAt": true, "values": true,
}

// Duplicate clones a document into a fresh draft with a server-assigned id,
// matching Studio's duplicate-doc action (Content.clone_document): the title
// gets a " (copy)" suffix and every content field is copied VERBATIM as raw
// JSON — not the editor's scalar projection — so nested objects and arrays
// survive the round-trip. The create mutation carries no _id, so the server
// generates "<type>-<n>" and the assigned "drafts.<id>" comes back like
// Create's. Papers are refused up front: a block tree cannot ride the generic
// mutate path (the paper schema has no blocks field — paper writes go through
// the paper-ingest API), and cloning one without its blocks would be silent
// data loss.
func (c *Client) Duplicate(typeName, id string) (string, error) {
	doc, ok := c.Get(typeName, id)
	if !ok {
		return "", fmt.Errorf("duplicate: source document %s not found", id)
	}
	if blocks := bytes.TrimSpace(doc.Blocks); len(blocks) > 0 && string(blocks) != "null" {
		return "", fmt.Errorf("papers cannot be duplicated here — use Studio")
	}

	title := doc.Title
	if title == "" {
		title = "Untitled"
	}
	create := map[string]interface{}{
		"_type": typeName,
		"title": title + " (copy)",
	}
	for k, raw := range doc.Extra {
		if envelopeMetaKeys[k] || duplicateSkipKeys[k] {
			continue
		}
		create[k] = raw
	}

	results, err := c.MutateResults([]map[string]interface{}{{"create": create}})
	if err != nil {
		return "", err
	}
	if len(results) == 0 || results[0].ID == "" {
		return "", fmt.Errorf("duplicate: server returned no document id")
	}
	return results[0].ID, nil
}

// Query fetches documents from the API by type, with optional filter.
//
// When Client.Perspective is non-empty it is appended as ?perspective=<p>,
// combined with any filter via the right ?/& separator. An empty Perspective
// sends no param, so the server applies its own default (published) — that is
// the CLI/manifest contract; the TUI sets Perspective="drafts" to surface
// unpublished work.
func (c *Client) Query(typeName, filter string) []Doc {
	endpoint := c.scopedURL("/v1/data/query/" + c.Dataset + "/" + url.PathEscape(typeName))
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
		_, _ = io.ReadAll(io.LimitReader(resp.Body, 64*1024))
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

// Search runs the scoped full-text search endpoint
//
//	GET /w/<ws>/p/<proj>/v1/data/search/<dataset>?q=…[&limit=…][&perspective=…]
//
// (SearchController.search). q is required server-side; limit > 0 caps the
// page (server default 50); the Client's Perspective rides along exactly as
// in Query. The engine param is deliberately NOT sent — the server default
// ("postgres") applies. The response carries the matching document envelopes
// at top-level "documents" ({"documents":[…],"count":…,"query":…,…}), which
// decode through the same envelope normalization Query's docs use.
// Revision is one row of a document's revision history
// (GET /v1/data/history/:dataset/:type/:doc_id — newest first).
type Revision struct {
	ID        string    `json:"id"`
	Action    string    `json:"action"`
	Title     string    `json:"title"`
	Status    string    `json:"status"`
	Timestamp time.Time `json:"timestamp"`
}

// History lists a document's revisions, newest first. docID is the BARE
// published id — the server tracks the draft+published family under it.
func (c *Client) History(typeName, docID string, limit int) ([]Revision, error) {
	endpoint := c.scopedURL("/v1/data/history/" + c.Dataset + "/" + url.PathEscape(typeName) + "/" + url.PathEscape(docID))
	if limit > 0 {
		endpoint += "?limit=" + strconv.Itoa(limit)
	}

	resp, err := c.authGet(endpoint)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return nil, fmt.Errorf("history error %d: %s", resp.StatusCode, string(body))
	}

	var out struct {
		Revisions []Revision `json:"revisions"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("parse history response: %w", err)
	}
	return out.Revisions, nil
}

// RevisionDoc fetches one revision (GET /v1/data/revision/:dataset/:id) and
// shapes it as a Doc — title/status typed, content scalars flattened into
// Values exactly like a live envelope — so revision content can ride every
// Doc consumer (e.g. the diff view) unchanged.
func (c *Client) RevisionDoc(id string) (Doc, error) {
	endpoint := c.scopedURL("/v1/data/revision/" + c.Dataset + "/" + url.PathEscape(id))

	resp, err := c.authGet(endpoint)
	if err != nil {
		return Doc{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return Doc{}, fmt.Errorf("revision error %d: %s", resp.StatusCode, string(body))
	}

	var out struct {
		Revision struct {
			DocID   string                     `json:"doc_id"`
			Title   string                     `json:"title"`
			Status  string                     `json:"status"`
			Content map[string]json.RawMessage `json:"content"`
		} `json:"revision"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return Doc{}, fmt.Errorf("parse revision response: %w", err)
	}

	values := make(map[string]string)
	for k, raw := range out.Revision.Content {
		if v, ok := scalarString(raw); ok {
			values[k] = v
		}
	}
	return Doc{
		ID:     out.Revision.DocID,
		Title:  out.Revision.Title,
		Status: out.Revision.Status,
		Values: values,
	}, nil
}

func (c *Client) Search(query string, limit int) ([]Doc, error) {
	endpoint := c.scopedURL("/v1/data/search/" + c.Dataset)
	params := url.Values{}
	params.Set("q", query)
	if limit > 0 {
		params.Set("limit", strconv.Itoa(limit))
	}
	if c.Perspective != "" {
		params.Set("perspective", c.Perspective)
	}
	endpoint += "?" + params.Encode()

	resp, err := c.authGet(endpoint)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return nil, fmt.Errorf("search error %d: %s", resp.StatusCode, string(body))
	}

	var out struct {
		Documents []Doc `json:"documents"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("parse search response: %w", err)
	}
	return out.Documents, nil
}

// Get fetches a single document by type and ID.
//
// The doc-show endpoint wraps the document in the v1 response envelope —
// {"result":{…doc…},"schemaHash":…,"etag":…} (QueryController.show via
// respond_json; verified live) — so the doc must be decoded from "result".
// Decoding the WHOLE body as a Doc silently produced an empty document
// (Title "", Extra = the envelope's own keys) because the response is valid
// JSON either way: 200-with-wrong-data, no error anywhere. A body with no
// "result" object (legacy/flat shape) still decodes directly.
func (c *Client) Get(typeName, id string) (Doc, bool) {
	return c.GetPerspective(typeName, id, "")
}

// GetPerspective is Get with an explicit dataset view: a non-empty perspective
// ("drafts"/"raw") is appended as ?perspective=<p> so a caller can read
// unpublished edits; an empty perspective leaves the server default (published),
// which is exactly what Get delegates. The cmux hook's acceptance gate reads
// "drafts" so an agent's just-recorded `met=true` (which lands as a draft
// overlay on a published task) is visible before the auto-close decision. Same
// {"result":{…}} envelope peel + fail-closed (Doc,false)-on-any-error contract
// as Get.
func (c *Client) GetPerspective(typeName, id, perspective string) (Doc, bool) {
	doc, outcome := c.GetPerspectiveResult(typeName, id, perspective)
	return doc, outcome == DocReadOK
}

// DocReadOutcome classifies WHY a single-document read succeeded or failed, so a
// caller (e.g. `bp cmux status`) can tell "no such document" (404) apart from
// "the server is unreachable" (transport error / 5xx / unreadable body) —
// GetPerspective's plain bool collapses both into false.
type DocReadOutcome int

const (
	DocReadOK          DocReadOutcome = iota // 200 with a decodable document
	DocReadNotFound                          // 404 — the id names no document
	DocReadUnreachable                       // transport error, non-200/404, or an unreadable/undecodable body
)

// GetPerspectiveResult is GetPerspective that additionally reports the read
// outcome. Same URL, auth, {"result":{…}} envelope-peel and fail-closed
// contract; the only addition is the DocReadOutcome discriminator (every
// non-OK outcome still maps to GetPerspective's false, so existing callers are
// behaviour-identical). 404 → DocReadNotFound; a transport error, any other
// non-200, an oversized body, or an undecodable body → DocReadUnreachable.
func (c *Client) GetPerspectiveResult(typeName, id, perspective string) (Doc, DocReadOutcome) {
	endpoint := c.scopedURL("/v1/data/doc/" + c.Dataset + "/" + url.PathEscape(typeName) + "/" + url.PathEscape(id))
	if perspective != "" {
		params := url.Values{}
		params.Set("perspective", perspective)
		endpoint += "?" + params.Encode()
	}

	resp, err := c.authGet(endpoint)
	if err != nil {
		return Doc{}, DocReadUnreachable
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		_, _ = io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return Doc{}, DocReadNotFound
	}
	if resp.StatusCode != http.StatusOK {
		_, _ = io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return Doc{}, DocReadUnreachable
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDocBytes+1))
	if err != nil || int64(len(body)) > maxDocBytes {
		return Doc{}, DocReadUnreachable
	}

	var wrapped struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(body, &wrapped) == nil && len(bytes.TrimSpace(wrapped.Result)) > 0 &&
		bytes.HasPrefix(bytes.TrimSpace(wrapped.Result), []byte("{")) {
		body = wrapped.Result
	}

	var doc Doc
	if err := json.Unmarshal(body, &doc); err != nil {
		return Doc{}, DocReadUnreachable
	}
	return doc, DocReadOK
}

// PaperDoc fetches ONE paper document by slug and returns the raw JSON of the
// response envelope's "result" object — the paper itself (title, blocks,
// body_html, _rev, …), ready for the caller to decode.
//
// It reuses Get's scopedURL + authGet path and the same {"result":{…}} unwrap:
// the doc-show endpoint (QueryController.show) wraps every document in the v1
// envelope, so the bare document is peeled out of "result" here (a flat/legacy
// body with no "result" object is returned verbatim). A non-empty perspective
// is appended as ?perspective=<p> so a caller can read drafts/raw; an empty
// perspective leaves the server default (published). This is the charter-D13e
// direct read — never paper_cmd.go's fetch-all-then-match.
//
// GET /v1/data/doc/:dataset/paper/:slug
func (c *Client) PaperDoc(dataset, slug, perspective string) ([]byte, error) {
	endpoint := c.scopedURL("/v1/data/doc/" + url.PathEscape(dataset) + "/paper/" + url.PathEscape(slug))
	params := url.Values{}
	params.Set("resolve", "tasks")
	if perspective != "" {
		params.Set("perspective", perspective)
	}
	endpoint += "?" + params.Encode()

	resp, err := c.authGet(endpoint)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return nil, fmt.Errorf("paper %s: status %d: %s", slug, resp.StatusCode, bodyPreview(body))
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDocBytes+1))
	if err != nil {
		return nil, fmt.Errorf("paper %s: read body: %w", slug, err)
	}
	if int64(len(body)) > maxDocBytes {
		return nil, fmt.Errorf("paper %s: body exceeds %d bytes", slug, maxDocBytes)
	}

	var wrapped struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(body, &wrapped) == nil {
		if r := bytes.TrimSpace(wrapped.Result); len(r) > 0 && bytes.HasPrefix(r, []byte("{")) {
			return wrapped.Result, nil
		}
	}
	// No "result" wrapper (a flat/legacy document body) — hand it back verbatim.
	return body, nil
}

// PaperSource is the fail-closed reader projection returned by the canonical
// Paper source endpoint. Exactly one source arm is populated: Blocks for
// kind=blocks or HTML for kind=html. Broad document fields and derived caches
// never cross this boundary.
type PaperSource struct {
	ID     string
	Title  string
	Rev    string
	Kind   string
	Blocks json.RawMessage
	HTML   string
}

// PaperSource fetches the canonical reader projection for one Paper. The
// dataset is part of the path so a staging reader cannot silently fall back to
// production. Authenticated/non-default callers use the membership-gated
// workspace/project route; a tokenless Default-scope caller uses the public
// flat route, preserving `bp paper view` for ordinary published Papers.
//
// GET /w/:workspace/p/:project/d/:dataset/papers/:slug/source
// GET /d/:dataset/papers/:slug/source (public Default scope)
func (c *Client) PaperSource(dataset, slug, perspective string) (PaperSource, error) {
	path := "/d/" + url.PathEscape(dataset) + "/papers/" + url.PathEscape(slug) + "/source"
	endpoint := c.scopedURL(path)
	if c.token == "" && c.Workspace == "default" && c.Project == "default" {
		endpoint = c.flatURL(path)
	}
	if perspective != "" {
		params := url.Values{}
		params.Set("perspective", perspective)
		endpoint += "?" + params.Encode()
	}

	resp, err := c.authGet(endpoint)
	if err != nil {
		return PaperSource{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return PaperSource{}, fmt.Errorf("paper %s source: status %d: %s", slug, resp.StatusCode, bodyPreview(body))
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDocBytes+1))
	if err != nil {
		return PaperSource{}, fmt.Errorf("paper %s source: read body: %w", slug, err)
	}
	if int64(len(body)) > maxDocBytes {
		return PaperSource{}, fmt.Errorf("paper %s source: body exceeds %d bytes", slug, maxDocBytes)
	}

	var payload struct {
		ID     string `json:"id"`
		Title  string `json:"title"`
		Rev    string `json:"_rev"`
		Source struct {
			Kind   string          `json:"kind"`
			Blocks json.RawMessage `json:"blocks"`
			HTML   string          `json:"html"`
		} `json:"source"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return PaperSource{}, fmt.Errorf("paper %s source: decode: %w", slug, err)
	}

	source := PaperSource{
		ID: payload.ID, Title: payload.Title, Rev: payload.Rev,
		Kind: payload.Source.Kind, Blocks: payload.Source.Blocks, HTML: payload.Source.HTML,
	}
	switch source.Kind {
	case "blocks":
		if len(bytes.TrimSpace(source.Blocks)) == 0 || !json.Valid(source.Blocks) {
			return PaperSource{}, fmt.Errorf("paper %s source: invalid blocks", slug)
		}
	case "html":
		// The server owns semantic-empty validation and sanitization. An empty
		// string in a nominal html arm is nevertheless an invalid wire shape.
		if strings.TrimSpace(source.HTML) == "" {
			return PaperSource{}, fmt.Errorf("paper %s source: empty html", slug)
		}
	default:
		return PaperSource{}, fmt.Errorf("paper %s source: unknown kind %q", slug, source.Kind)
	}
	return source, nil
}

// DocumentJSON adapts the narrow reader projection to the established minimal
// Paper document shape consumed by pdrender and `bp paper view -o json`.
func (s PaperSource) DocumentJSON(fallbackID string) ([]byte, error) {
	id := s.ID
	if id == "" {
		id = fallbackID
	}
	doc := map[string]any{
		"_id": id, "_type": "paper", "title": s.Title,
	}
	if s.Rev != "" {
		doc["_rev"] = s.Rev
	}
	switch s.Kind {
	case "blocks":
		var blocks any
		if err := json.Unmarshal(s.Blocks, &blocks); err != nil {
			return nil, err
		}
		doc["blocks"] = blocks
	case "html":
		doc["body_html"] = s.HTML
	default:
		return nil, fmt.Errorf("unknown Paper source kind %q", s.Kind)
	}
	return json.Marshal(doc)
}

// bodyPreview trims an error-body to a short single-line preview so a non-2xx
// status surfaces the server's reason without dumping a whole HTML error page.
func bodyPreview(body []byte) string {
	s := strings.TrimSpace(string(body))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
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
func (c *Client) Delete(typeName, id string) error {
	mutation := map[string]interface{}{
		"delete": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return c.Mutate([]map[string]interface{}{mutation})
}

// ── Task quick-actions (flat /v1/tasks endpoints) ─────────────────────────────

// taskEnvelope is the {ok, reason, doc} shape every /v1/tasks endpoint returns
// — on success AND on failure. ok:false rides a 200 (no_ready), a 409
// (already_claimed / fenced_off), a 404 (not_found) or a 400; the reason
// string is the contract, not the HTTP status.
type taskEnvelope struct {
	OK      bool            `json:"ok"`
	Reason  string          `json:"reason"`
	Doc     json.RawMessage `json:"doc"`
	Notices []TaskNotice    `json:"notices"`
	// Help is the top-level {"help":[…]} array a claim/close (also stamp/pulse/
	// release) 2xx envelope carries — 1–3 concrete next-command templates the
	// server authors beside its mutation emitters (AXI R5, mutation_help/3) with
	// REAL ids/epochs. Advisory only, omitted when empty. Every typed helper below
	// surfaces it so the frontier/cmux/board/desk-TUI claim paths reach the same
	// next-step parity `runCommand` gives the manifest path (charter D18) — it was
	// silently dropped before, decoded nowhere.
	Help []string `json:"help"`
	// Conflicts rides a 409 resource_conflict envelope: the tasks/workers that
	// already hold one or more of the file resources this claim declared. The
	// server's check_resources_free fence populates it; a frontier claimer names
	// the holder on skip so a builder learns who owns the seam BEFORE merge (it
	// was silently dropped before df-next-frontier). Empty on every other reason.
	Conflicts []TaskConflict `json:"conflicts"`
}

// TaskConflict is one holder in a resource_conflict envelope: the task + worker
// currently holding some of the file resources a resources-declaring claim
// requested, and which of them overlap. Surfaced verbatim on skip.
type TaskConflict struct {
	Task      string   `json:"task"`
	Worker    string   `json:"worker"`
	Resources []string `json:"resources"`
}

// TaskNotice is one advisory rail-awareness notice a claim/close 2xx envelope
// may carry (top-level "notices":[…], omitted when empty). Two shapes ride the
// one struct — blocked_while_claimed ({type, task_id, blockers}) fires when a
// blocker lands on a task you hold; rail_changed ({type, parent_id, rail_rev})
// fires when the parent rail you observed moved. Advisory only: they never fail
// the request, and a consumer that ignores them loses nothing but the heads-up.
type TaskNotice struct {
	// omitempty matters on the MARSHAL side: the frontier claim's machine JSON
	// re-serializes notices (axi-b1), and a rail_changed notice must not ship
	// `"task_id":"","blockers":null` noise — the AXI nil-key-omission law.
	// Decoding is unaffected.
	Type     string   `json:"type"`
	TaskID   string   `json:"task_id,omitempty"`
	Blockers []string `json:"blockers,omitempty"`
	ParentID string   `json:"parent_id,omitempty"`
	RailRev  string   `json:"rail_rev,omitempty"`
}

// taskPost POSTs a JSON payload to a FLAT /v1/tasks path. The task routes are
// plugin-mounted at the host's TOP-LEVEL /v1 scope (auth: :token_root in
// plugins/tasks.ex) — NOT under the /w/:workspace/p/:project prefix scopedURL
// builds; tenancy comes from the bearer token. An ok:false envelope surfaces
// the server's reason string VERBATIM as the error.
func (c *Client) taskPost(path string, payload map[string]interface{}) (*taskEnvelope, error) {
	env, status, err := c.taskPostRaw(path, payload)
	if err != nil {
		return nil, err
	}
	if !env.OK {
		reason := env.Reason
		if reason == "" {
			reason = fmt.Sprintf("task endpoint error %d", status)
		}
		return nil, fmt.Errorf("%s", reason)
	}
	return env, nil
}

// taskPostRaw is taskPost's transport core: it POSTs the payload and decodes the
// envelope REGARDLESS of ok, returning the HTTP status alongside so a caller that
// needs the ok:false detail (reason + conflicts on a 409) can inspect it instead
// of collapsing it into an opaque error string. A non-nil error signals a
// transport/decode failure ONLY — a business rejection (ok:false) rides the
// returned envelope, never the error. taskPost wraps this for the common
// reason-as-error contract every other /v1/tasks caller relies on.
func (c *Client) taskPostRaw(path string, payload map[string]interface{}) (*taskEnvelope, int, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, 0, err
	}

	req, err := http.NewRequest("POST", c.flatURL(path), bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	var env taskEnvelope
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		// Not the envelope (proxy error page, empty body) — fall back to the
		// HTTP status so the caller still sees something actionable.
		return nil, resp.StatusCode, fmt.Errorf("task endpoint error %d", resp.StatusCode)
	}
	return &env, resp.StatusCode, nil
}

// TaskClaim claims a task by doc id for workerID via the targeted
// POST /v1/tasks/:doc_id/claim ({"worker_id": …}). On success it returns the
// claim's fencing epoch (content.claim.epoch on the returned doc) — the token
// TaskClose must echo back as observed_epoch.
func (c *Client) TaskClaim(docID, workerID string) (int, error) {
	epoch, _, _, err := c.TaskClaimN(docID, workerID)
	return epoch, err
}

// TaskClaimN is TaskClaim plus the envelope's advisory rail-awareness notices
// (blocked_while_claimed / rail_changed, nil when the server sent none) AND the
// server's help[] next-command templates (charter D18, nil when the server sent
// none). Callers that want to surface the heads-up (the task board's status
// strip, the desk TUI, the cmux hook) use this; TaskClaim stays the epoch-only
// convenience for callers that don't.
func (c *Client) TaskClaimN(docID, workerID string) (int, []TaskNotice, []string, error) {
	env, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/claim",
		map[string]interface{}{"worker_id": workerID})
	if err != nil {
		return 0, nil, nil, err
	}
	var doc struct {
		Claim struct {
			Epoch int `json:"epoch"`
		} `json:"claim"`
	}
	if err := json.Unmarshal(env.Doc, &doc); err != nil || doc.Claim.Epoch <= 0 {
		return 0, nil, nil, fmt.Errorf("claim %s: server returned no fencing epoch", docID)
	}
	return doc.Claim.Epoch, env.Notices, env.Help, nil
}

// TaskClaimOutcome is the full result of a resources-declaring claim: on a
// WON claim OK is true and Epoch carries the fencing token; on a LOST race or a
// file fence OK is false and Reason names why ("not_ready" / "already_claimed" /
// "resource_conflict"), with Conflicts naming the holder(s) on a resource
// conflict. It lets the frontier loop branch on the reason and skip-and-retry
// instead of aborting on the first opaque error.
type TaskClaimOutcome struct {
	OK        bool
	Reason    string
	Epoch     int
	Notices   []TaskNotice
	Help      []string
	Conflicts []TaskConflict
}

// TaskClaimResources claims docID for workerID and DECLARES the file resources
// the task will touch, so the server's check_resources_free fence can reject a
// claim whose files are already held by another worker (409 resource_conflict +
// holders). resources is the task's sorted file-scope key set. Unlike TaskClaim/
// TaskClaimN it does NOT collapse a business rejection into an error: a lost race
// or a file fence rides the returned outcome (OK=false + Reason + Conflicts) so
// the frontier claim loop can skip to the next non-colliding pick. A non-nil
// error means a transport/decode failure OR — matching TaskClaimN's fencing
// discipline — a WON claim (ok:true) that carried no positive epoch, which stays
// a HARD failure because proceeding with epoch 0 defeats the CAS fencing. An
// empty resources slice sends no resources key (byte-identical to a bare claim),
// so the server fence is a no-op — the caller opts into the fence by declaring.
func (c *Client) TaskClaimResources(docID, workerID string, resources []string) (TaskClaimOutcome, error) {
	payload := map[string]interface{}{"worker_id": workerID}
	if len(resources) > 0 {
		payload["resources"] = resources
	}
	env, _, err := c.taskPostRaw("/v1/tasks/"+url.PathEscape(docID)+"/claim", payload)
	if err != nil {
		return TaskClaimOutcome{}, err
	}
	if !env.OK {
		reason := env.Reason
		if reason == "" {
			reason = "claim_rejected"
		}
		return TaskClaimOutcome{OK: false, Reason: reason, Conflicts: env.Conflicts, Notices: env.Notices, Help: env.Help}, nil
	}
	var doc struct {
		Claim struct {
			Epoch int `json:"epoch"`
		} `json:"claim"`
	}
	if err := json.Unmarshal(env.Doc, &doc); err != nil || doc.Claim.Epoch <= 0 {
		return TaskClaimOutcome{}, fmt.Errorf("claim %s: server returned no fencing epoch", docID)
	}
	return TaskClaimOutcome{OK: true, Epoch: doc.Claim.Epoch, Notices: env.Notices, Help: env.Help}, nil
}

// TaskClose closes a claimed task via POST /v1/tasks/:doc_id/close. The server
// fences on observed_epoch (the epoch the worker saw at claim time — a
// mismatch returns reason "fenced_off"); lifecycle lands on "done" (the server
// default, sent explicitly).
func (c *Client) TaskClose(docID, workerID string, observedEpoch int) error {
	_, _, err := c.TaskCloseN(docID, workerID, observedEpoch)
	return err
}

// TaskCloseN is TaskClose plus the envelope's advisory rail-awareness notices
// AND the server's help[] next-command templates (both nil when the server sent
// none) — the advisory-aware twin the board/desk-TUI use so a clean close can
// still flag a blocker that landed on a sibling and point at the next task. On a
// fenced 409 the reason rides the error (fenced_off / doc_changed_since_claim);
// notices and help only accompany a 2xx.
// TaskCloseRevN is TaskCloseN plus an observed_rev strict-CAS guard. When a
// task's brief legitimately changed since claim — e.g. the worker marked its
// own acceptance criteria met — the server's work-digest fence
// (doc_changed_since_claim) rejects a plain close; passing the freshly-observed
// rev is the sanctioned bypass (Tasks.close/3 :observed_rev). The worker match
// still prevents theft.
func (c *Client) TaskCloseRevN(docID, workerID string, observedEpoch int, observedRev string) ([]TaskNotice, []string, error) {
	env, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/close",
		map[string]interface{}{
			"worker_id":        workerID,
			"observed_epoch":   observedEpoch,
			"observed_rev":     observedRev,
			"lifecycle_status": "done",
		})
	if err != nil {
		return nil, nil, err
	}
	return env.Notices, env.Help, nil
}

func (c *Client) TaskCloseN(docID, workerID string, observedEpoch int) ([]TaskNotice, []string, error) {
	env, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/close",
		map[string]interface{}{
			"worker_id":        workerID,
			"observed_epoch":   observedEpoch,
			"lifecycle_status": "done",
		})
	if err != nil {
		return nil, nil, err
	}
	return env.Notices, env.Help, nil
}

// TaskRelabel adds and/or removes content.labels on a task via
// POST /v1/tasks/:doc_id/labels ({"add": […], "remove": […]}). The server
// (tasks_controller.relabel → Tasks.relabel_by_id) is advisory-locked +
// CAS-on-rev; a lost race comes back as an ok:false envelope whose reason
// string taskPost surfaces VERBATIM as the error (409 conflict). Either list
// may be empty/nil — a nil marshals to null, which the server's
// Params.string_list normalises to []. Used by the board's `t` verb to apply
// a derived tag suggestion.
func (c *Client) TaskRelabel(docID string, add, remove []string) error {
	_, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/labels",
		map[string]interface{}{
			"add":    add,
			"remove": remove,
		})
	return err
}

// TaskReadback is what the store handed back on a second read: the task's
// content, plus the two fields that say WHICH ROW answered.
//
// Status and DocID are not decoration. GET /v1/tasks/:doc_id falls back to the
// `drafts.` twin when no published row exists for the id
// (tasks_controller.ex find_task_by_doc_id), so an id the caller believes names
// a board row can be answered by a draft the board never shows. The server has
// always sent both fields (Params.render_doc emits `doc_id` and `status`); the
// CLI simply threw them away, which made the read-back unable to name the row
// it read.
type TaskReadback struct {
	// Content is `doc.content` VERBATIM. It is returned raw rather than decoded
	// here because the criteria decode (with the server's exact tolerance
	// contract) belongs to internal/taskboard, which owns that shape.
	Content json.RawMessage
	// Status is the document's publish state — "published" for a board row.
	Status string
	// DocID is the id the SERVER matched, which is NOT necessarily the id that
	// was asked for: a draft-only row answers as "drafts.<id>".
	DocID string
	// LifecycleStatus is `doc.lifecycle_status` — the SEAL. `bp task close`
	// writes it, so a close receipt that does not read it is asserting the seal
	// it asked for rather than the one the store took.
	LifecycleStatus string
	// Claim is `doc.claim` VERBATIM. It is a SEPARATE field rather than part of
	// Content because the server moves it out: render_doc emits
	// `content: Map.delete(content, "claim")` and surfaces the claim at the top
	// level, so anything reading content for a claim (a pulse's now-line, for
	// one) finds nothing there. Raw, because the claim/pulse decode with its
	// tolerance contract belongs to internal/taskboard.
	Claim json.RawMessage
}

// IsDraft reports whether the row that answered is a draft rather than a
// published board row. Both signals are honoured because either one alone is
// enough to mean "the board will not show this": the `drafts.` doc_id prefix
// and a status that is not "published". An EMPTY status is not treated as a
// draft — an absent field is unknown, not a verdict.
func (r TaskReadback) IsDraft() bool {
	if strings.HasPrefix(r.DocID, "drafts.") {
		return true
	}
	return r.Status != "" && r.Status != "published"
}

// TaskGetContent RE-READS one task via GET /v1/tasks/:doc_id and returns its
// `doc.content` object plus the identity of the row that answered (the flat,
// token-scoped task route — tenancy rides the bearer token, exactly like the
// claim/close/stamp POSTs above).
//
// It exists for the PDS success-claim law (charter PDS-D359/D361): a ledger
// writer may not report a write it never read back. `bp task stamp` POSTs and
// then calls this to ask the STORE what it now holds, so a write dropped by a
// transport ceiling, a second door, or a bad minute on the box cannot be
// reported as a success.
//
// An ok:false envelope surfaces the server's reason string VERBATIM as the
// error; a non-200 carries the status. Both are honest read failures — the
// caller must NOT read them as "the write landed".
func (c *Client) TaskGetContent(docID string) (TaskReadback, error) {
	resp, err := c.authGet(c.flatURL("/v1/tasks/" + url.PathEscape(docID)))
	if err != nil {
		return TaskReadback{}, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return TaskReadback{}, fmt.Errorf("task read-back %s: %w", docID, err)
	}
	if resp.StatusCode != http.StatusOK {
		return TaskReadback{}, fmt.Errorf("task read-back %s: status %d", docID, resp.StatusCode)
	}
	var env struct {
		OK     bool   `json:"ok"`
		Reason string `json:"reason"`
		Doc    struct {
			Content         json.RawMessage `json:"content"`
			Status          string          `json:"status"`
			DocID           string          `json:"doc_id"`
			LifecycleStatus string          `json:"lifecycle_status"`
			Claim           json.RawMessage `json:"claim"`
		} `json:"doc"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return TaskReadback{}, fmt.Errorf("task read-back %s: %w", docID, err)
	}
	if !env.OK {
		reason := env.Reason
		if reason == "" {
			reason = "task read-back returned ok:false with no reason"
		}
		return TaskReadback{}, fmt.Errorf("%s", reason)
	}
	if len(bytes.TrimSpace(env.Doc.Content)) == 0 {
		return TaskReadback{}, fmt.Errorf("task read-back %s: envelope carried no doc.content", docID)
	}
	return TaskReadback{
		Content:         env.Doc.Content,
		Status:          env.Doc.Status,
		DocID:           env.Doc.DocID,
		LifecycleStatus: env.Doc.LifecycleStatus,
		Claim:           env.Doc.Claim,
	}, nil
}

// GraphNode is one node of a GET /v1/graph/:id response — the id ↔ doc_id join
// the edge endpoints need. In the published path `id` is a UUID and `doc_id`
// the slug; in the drafts path both are the slug. Only the two fields the
// frontier fold reads are decoded.
type GraphNode struct {
	ID    string `json:"id"`
	DocID string `json:"doc_id"`
}

// GraphEdgeWire is one edge of a GET /v1/graph/:id response. `from_id`/`to_id`
// are in the node id-space (UUIDs on the published path, slugs on drafts); the
// caller resolves them to doc_ids via the node list.
type GraphEdgeWire struct {
	FromID string `json:"from_id"`
	ToID   string `json:"to_id"`
	Kind   string `json:"kind"`
}

// GraphResult is the decoded subset of a GET /v1/graph/:id envelope.
type GraphResult struct {
	OK    bool            `json:"ok"`
	Root  string          `json:"root"`
	Nodes []GraphNode     `json:"nodes"`
	Edges []GraphEdgeWire `json:"edges"`
}

// GraphShow fetches the content graph rooted at id via GET /v1/graph/:id — a
// token-gated, NOT path-scoped endpoint (it lives under /v1 directly, its scope
// derived from the token + the dataset query param, like ListWorkspaces). It
// requests the `drafts` perspective (tasks live as drafts, the same view the
// board reads), `direction=both`, and `kinds=blocks` so only dependency edges
// come back. Used by `bp task frontier` to enrich the dispatch frontier with
// REAL cross-root block edges (df-graph-crossdep) — the fetch happens here,
// OUTSIDE the pure taskboard.Frontier model.
func (c *Client) GraphShow(id string) (*GraphResult, error) {
	path := "/v1/graph/" + url.PathEscape(id) +
		"?drafts=true&direction=both&kinds=blocks"
	if c.Dataset != "" {
		path += "&dataset=" + url.QueryEscape(c.Dataset)
	}
	u := c.flatURL(path)
	resp, err := c.authGet(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return nil, fmt.Errorf("graph.show %s error %d: %s", id, resp.StatusCode, string(raw))
	}
	var out GraphResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListWorkspaces fetches the workspaces the bearer token is a member of via
// GET /api/workspaces. This is a token-gated, NOT path-scoped, endpoint — it
// lives under /api directly, not under /w/:ws/p/:project.
// tenancyPost POSTs {"name": …} to a flat /api tenancy path and decodes the
// 201 body into out. The server derives the slug from the name and seeds the
// child defaults itself (workspace → Default project + production dataset;
// project → production dataset). Non-201 surfaces the body verbatim — the
// 422 changeset reason (duplicate/invalid slug) is the useful part.
func (c *Client) tenancyPost(path, name string, out interface{}) error {
	body, err := json.Marshal(map[string]string{"name": name})
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", c.flatURL(path), bytes.NewReader(body))
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

	if resp.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return fmt.Errorf("create error %d: %s", resp.StatusCode, string(raw))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// CreateWorkspace creates a workspace from a display name
// (POST /api/workspaces). The caller's token becomes its owner-member.
func (c *Client) CreateWorkspace(name string) (WorkspaceInfo, error) {
	var out struct {
		Workspace WorkspaceInfo `json:"workspace"`
	}
	err := c.tenancyPost("/api/workspaces", name, &out)
	return out.Workspace, err
}

// CreateProject creates a project under a workspace the caller is a member of
// (POST /api/workspaces/:slug/projects).
func (c *Client) CreateProject(workspaceSlug, name string) (ProjectInfo, error) {
	var out struct {
		Project ProjectInfo `json:"project"`
	}
	err := c.tenancyPost("/api/workspaces/"+url.PathEscape(workspaceSlug)+"/projects", name, &out)
	return out.Project, err
}

func (c *Client) ListWorkspaces() ([]WorkspaceInfo, error) {
	resp, err := c.authGet(c.flatURL("/api/workspaces"))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("list workspaces: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, humanAPIError(resp.StatusCode, body)
	}

	var result struct {
		Workspaces []WorkspaceInfo `json:"workspaces"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse workspaces: %w", err)
	}
	return result.Workspaces, nil
}

// ListProjects fetches the projects under a workspace via
// GET /api/workspaces/:workspace_slug/projects. A non-member (or unknown slug)
// returns 404, which surfaces here as an error.
func (c *Client) ListProjects(workspaceSlug string) ([]ProjectInfo, error) {
	resp, err := c.authGet(c.flatURL("/api/workspaces/" + url.PathEscape(workspaceSlug) + "/projects"))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("list projects: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, humanAPIError(resp.StatusCode, body)
	}

	var result struct {
		Workspace WorkspaceInfo `json:"workspace"`
		Projects  []ProjectInfo `json:"projects"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse projects: %w", err)
	}
	return result.Projects, nil
}
