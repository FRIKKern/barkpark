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
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultTimeout is the per-request HTTP timeout when Config.Timeout is zero.
// The legacy DataStore hardcoded 5s; the batch/CLI path can raise it via Config.
const DefaultTimeout = 5 * time.Second

// Doc represents a single document from the API.
//
// The flat string fields below mirror the Sanity-style document the query API
// emits at the top level. Two RawMessage fields carry the portable-doc block
// tree for paper documents WITHOUT disturbing that flat decode:
//
//   - Type holds the document's "_type" discriminator (e.g. "paper"), so the
//     TUI can detect a paper without a schema lookup.
//   - Blocks holds the paper's block tree. The live API returns "blocks" at the
//     TOP LEVEL of each document (verified against
//     /v1/data/query/<ds>/paper?perspective=raw), so it is decoded from "blocks".
//   - Content is a forward-compat slot for a nested "content" envelope
//     (content.blocks). The current API never populates it; PaperBlocks prefers
//     top-level Blocks and falls back to content.blocks if a future shape uses it.
//
// All four block-related additions use json.RawMessage / omitempty, so an
// ordinary document (no _type/blocks/content keys, or a non-paper type) decodes
// exactly as before — the string-flat path is untouched.
type Doc struct {
	ID        string            `json:"id"`
	Type      string            `json:"_type,omitempty"`
	Title     string            `json:"title"`
	Status    string            `json:"status"`
	Category  string            `json:"category,omitempty"`
	Author    string            `json:"author,omitempty"`
	UpdatedAt time.Time         `json:"updatedAt"`
	Values    map[string]string `json:"values,omitempty"`
	// Blocks is the paper block tree as emitted at the document top level.
	Blocks json.RawMessage `json:"blocks,omitempty"`
	// Content is the forward-compat nested envelope ({"blocks":[…]}). Unused by
	// the current API; PaperBlocks falls back to it when top-level Blocks is empty.
	Content json.RawMessage `json:"content,omitempty"`
	// Extra holds every top-level key of the decoded envelope, raw. The v1
	// envelope flattens a document's content fields to the top level (verified
	// against /v1/data/query — e.g. a task's "lifecycle_status" / "priority"
	// ride beside "_id"), and the typed fields above only capture a fixed
	// subset. list_preview rendering reads arbitrary schema-named fields via
	// ContentString. Never serialized back (json:"-"); nil for hand-built docs.
	Extra map[string]json.RawMessage `json:"-"`
}

// UnmarshalJSON decodes the typed fields exactly as before (alias type — no
// behaviour change), captures the raw top-level key set into Extra so
// schema-named content fields are reachable without a struct change per field,
// then normalizes the v1 flat envelope onto the legacy-shaped typed fields
// (ID / UpdatedAt / Values) the TUI consumes.
func (d *Doc) UnmarshalJSON(b []byte) error {
	type docAlias Doc
	var a docAlias
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*d = Doc(a)
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err == nil {
		d.Extra = raw
		d.normalizeEnvelope()
	}
	return nil
}

// envelopeMetaKeys are the v1 envelope's reserved/structural top-level keys.
// Everything else at the top level is a flattened content field (the envelope
// merges doc.content into the root — see Barkpark.Content.Envelope) and
// belongs in Values for the field editor.
var envelopeMetaKeys = map[string]bool{
	"_id": true, "_type": true, "_rev": true, "_draft": true,
	"_publishedId": true, "_createdAt": true, "_updatedAt": true,
	"title": true, "blocks": true, "content": true,
}

// normalizeEnvelope maps the v1 flat envelope onto the legacy-shaped typed
// fields. The legacy keys ("id", "updatedAt", "values") never appear on the
// live wire — the envelope emits "_id" / "_updatedAt" and flattens content to
// the top level (verified against /v1/data/query) — so the plain typed decode
// left ID empty, UpdatedAt zero and Values nil, latently breaking every
// consumer (saveDocument's patch target, Get-by-id, the editor's field
// values, timeAgo subtitles). Each fill is guarded so a legacy envelope that
// DOES carry the old keys still wins.
func (d *Doc) normalizeEnvelope() {
	if d.ID == "" {
		var id string
		if json.Unmarshal(d.Extra["_id"], &id) == nil {
			d.ID = id
		}
	}
	if d.UpdatedAt.IsZero() {
		var ts string
		if json.Unmarshal(d.Extra["_updatedAt"], &ts) == nil {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				d.UpdatedAt = t
			}
		}
	}
	if d.Status == "" {
		// The envelope carries publish state as the "_draft" boolean, not the
		// legacy "status" string the TUI's header/icons key off.
		var draft bool
		if json.Unmarshal(d.Extra["_draft"], &draft) == nil {
			if draft {
				d.Status = "draft"
			} else {
				d.Status = "published"
			}
		}
	}
	if len(d.Values) == 0 {
		values := make(map[string]string)
		for k, raw := range d.Extra {
			if envelopeMetaKeys[k] {
				continue
			}
			if v, ok := scalarString(raw); ok {
				values[k] = v
			}
		}
		if len(values) > 0 {
			d.Values = values
		}
	}
}

// scalarString renders a raw JSON scalar as the editor's string value:
// strings verbatim, numbers via their literal representation, booleans as
// "true"/"false" (the editor's boolean-toggle convention writes the same
// strings into dirtyValues). null, objects and arrays return ok=false — they
// have no flat-editor rendering.
func scalarString(raw json.RawMessage) (string, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s, true
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String(), true
	}
	var bv bool
	if err := json.Unmarshal(raw, &bv); err == nil {
		return strconv.FormatBool(bv), true
	}
	return "", false
}

// ContentString returns the scalar string rendering of a top-level envelope
// field: a JSON string verbatim, a JSON number via its literal representation
// ("1", "1.5"), and "" for anything else (missing, bool, null, object, array)
// — mirroring the Studio PaneBuilder's format_preview, where a misdeclared
// field degrades to "no badge", never a crash.
func (d Doc) ContentString(field string) string {
	raw, ok := d.Extra[field]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String()
	}
	return ""
}

// ClaimEpoch returns the fencing epoch of this task document's claim object
// (content.claim.epoch, flattened to the envelope top level as "claim") and
// whether a live claim is present. Epochs start at 1 on first claim, so 0
// never names a real claim — absent / unparseable / zero all report ok=false.
func (d Doc) ClaimEpoch() (int, bool) {
	raw, ok := d.Extra["claim"]
	if !ok {
		return 0, false
	}
	var c struct {
		Epoch int `json:"epoch"`
	}
	if err := json.Unmarshal(raw, &c); err != nil || c.Epoch <= 0 {
		return 0, false
	}
	return c.Epoch, true
}

// PaperBlocks returns the raw JSON for this document's portable-doc block tree,
// preferring the top-level "blocks" the live API emits and falling back to a
// nested "content":{"blocks":[…]} envelope if one is ever present. It returns
// nil when the document carries no block tree (every non-paper doc), so callers
// can branch on "is this a paper with renderable content?" off a single nil check.
func (d Doc) PaperBlocks() json.RawMessage {
	if len(d.Blocks) > 0 {
		return d.Blocks
	}
	if len(d.Content) > 0 {
		var env struct {
			Blocks json.RawMessage `json:"blocks"`
		}
		if err := json.Unmarshal(d.Content, &env); err == nil && len(env.Blocks) > 0 {
			return env.Blocks
		}
		// A bare content array (no envelope) is also acceptable.
		var arr []json.RawMessage
		if err := json.Unmarshal(d.Content, &arr); err == nil && len(arr) > 0 {
			return d.Content
		}
	}
	return nil
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
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("mutation error %d: %s", resp.StatusCode, string(respBody))
	}

	var out struct {
		Results []MutationResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, nil
	}
	return out.Results, nil
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
	endpoint := c.scopedURL("/v1/data/history/" + c.Dataset + "/" + typeName + "/" + docID)
	if limit > 0 {
		endpoint += "?limit=" + strconv.Itoa(limit)
	}

	resp, err := c.authGet(endpoint)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
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
	endpoint := c.scopedURL("/v1/data/revision/" + c.Dataset + "/" + id)

	resp, err := c.authGet(endpoint)
	if err != nil {
		return Doc{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
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
		body, _ := io.ReadAll(resp.Body)
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
	endpoint := c.scopedURL("/v1/data/doc/" + c.Dataset + "/" + typeName + "/" + id)

	resp, err := c.authGet(endpoint)
	if err != nil {
		return Doc{}, false
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Doc{}, false
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Doc{}, false
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

// ── Task quick-actions (flat /v1/tasks endpoints) ─────────────────────────────

// taskEnvelope is the {ok, reason, doc} shape every /v1/tasks endpoint returns
// — on success AND on failure. ok:false rides a 200 (no_ready), a 409
// (already_claimed / fenced_off), a 404 (not_found) or a 400; the reason
// string is the contract, not the HTTP status.
type taskEnvelope struct {
	OK     bool            `json:"ok"`
	Reason string          `json:"reason"`
	Doc    json.RawMessage `json:"doc"`
}

// taskPost POSTs a JSON payload to a FLAT /v1/tasks path. The task routes are
// plugin-mounted at the host's TOP-LEVEL /v1 scope (auth: :token_root in
// plugins/tasks.ex) — NOT under the /w/:workspace/p/:project prefix scopedURL
// builds; tenancy comes from the bearer token. An ok:false envelope surfaces
// the server's reason string VERBATIM as the error.
func (c *Client) taskPost(path string, payload map[string]interface{}) (*taskEnvelope, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", c.baseURL+path, bytes.NewReader(body))
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

	var env taskEnvelope
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		// Not the envelope (proxy error page, empty body) — fall back to the
		// HTTP status so the caller still sees something actionable.
		return nil, fmt.Errorf("task endpoint error %d", resp.StatusCode)
	}
	if !env.OK {
		reason := env.Reason
		if reason == "" {
			reason = fmt.Sprintf("task endpoint error %d", resp.StatusCode)
		}
		return nil, fmt.Errorf("%s", reason)
	}
	return &env, nil
}

// TaskClaim claims a task by doc id for workerID via the targeted
// POST /v1/tasks/:doc_id/claim ({"worker_id": …}). On success it returns the
// claim's fencing epoch (content.claim.epoch on the returned doc) — the token
// TaskClose must echo back as observed_epoch.
func (c *Client) TaskClaim(docID, workerID string) (int, error) {
	env, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/claim",
		map[string]interface{}{"worker_id": workerID})
	if err != nil {
		return 0, err
	}
	var doc struct {
		Claim struct {
			Epoch int `json:"epoch"`
		} `json:"claim"`
	}
	_ = json.Unmarshal(env.Doc, &doc)
	return doc.Claim.Epoch, nil
}

// TaskClose closes a claimed task via POST /v1/tasks/:doc_id/close. The server
// fences on observed_epoch (the epoch the worker saw at claim time — a
// mismatch returns reason "fenced_off"); lifecycle lands on "done" (the server
// default, sent explicitly).
func (c *Client) TaskClose(docID, workerID string, observedEpoch int) error {
	_, err := c.taskPost("/v1/tasks/"+url.PathEscape(docID)+"/close",
		map[string]interface{}{
			"worker_id":        workerID,
			"observed_epoch":   observedEpoch,
			"lifecycle_status": "done",
		})
	return err
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
