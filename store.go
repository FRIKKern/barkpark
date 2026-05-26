package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

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

// DataStoreRefreshMsg is sent to the TUI when the API data changes.
type DataStoreRefreshMsg struct{}

// DataStore is an HTTP client that talks to the Phoenix API.
type DataStore struct {
	baseURL string
	token   string
	// Workspace/Project/Dataset scope the /v1/ endpoints onto the new
	// /w/:workspace_slug/p/:project_slug routing. Defaults: "default"/"default"/"production".
	Workspace string
	Project   string
	Dataset   string
	client    *http.Client
	program   *tea.Program
	mu        sync.RWMutex
	lastHash  string
}

// NewDataStore creates an API-backed DataStore with default scope.
func NewDataStore(baseURL string) *DataStore {
	return &DataStore{
		baseURL:   baseURL,
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
		client:    &http.Client{Timeout: 5 * time.Second},
	}
}

// scopedURL builds a workspace/project-scoped /v1/ endpoint of the form
//
//	<baseURL>/w/<Workspace>/p/<Project><suffix>
//
// where suffix is a leading-slash path segment (e.g. "/v1/data/mutate/<dataset>").
// This is the single place that knows the scoped URL scheme.
func (ds *DataStore) scopedURL(suffix string) string {
	return fmt.Sprintf("%s/w/%s/p/%s%s", ds.baseURL, ds.Workspace, ds.Project, suffix)
}

// SetToken sets the API token for authenticated requests.
func (ds *DataStore) SetToken(token string) {
	ds.token = token
}

// SetProgram sets the tea.Program reference for sending refresh messages.
func (ds *DataStore) SetProgram(p *tea.Program) {
	ds.program = p
}

// authGet issues a GET to url with the DataStore's bearer token attached.
// Scoped /v1/ reads run ResolveWorkspace, which fails closed (403) for an
// anonymous caller — so every read must carry the token, exactly like
// Mutate/listenSSE do for their requests.
func (ds *DataStore) authGet(url string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	if ds.token != "" {
		req.Header.Set("Authorization", "Bearer "+ds.token)
	}
	return ds.client.Do(req)
}

// Mutate sends a mutation to the Phoenix API (Sanity format).
func (ds *DataStore) Mutate(mutations []map[string]interface{}) error {
	endpoint := ds.scopedURL("/v1/data/mutate/" + ds.Dataset)
	body, err := json.Marshal(map[string]interface{}{"mutations": mutations})
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if ds.token != "" {
		req.Header.Set("Authorization", "Bearer "+ds.token)
	}

	resp, err := ds.client.Do(req)
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
func (ds *DataStore) Query(typeName, filter string) []Doc {
	endpoint := ds.scopedURL("/v1/data/query/" + ds.Dataset + "/" + typeName)
	if filter != "" {
		endpoint += "?filter=" + url.QueryEscape(filter)
	}

	resp, err := ds.authGet(endpoint)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var result struct {
		Documents []Doc `json:"documents"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	return result.Documents
}

// Get fetches a single document by type and ID.
func (ds *DataStore) Get(typeName, id string) (Doc, bool) {
	endpoint := ds.scopedURL("/v1/data/doc/" + ds.Dataset + "/" + typeName + "/" + id)

	resp, err := ds.authGet(endpoint)
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
func (ds *DataStore) Upsert(typeName string, doc Doc) error {
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
	return ds.Mutate([]map[string]interface{}{mutation})
}

// Delete removes a document via the API.
//
// The scoped /v1/data API has no DELETE verb — deletion is expressed as a
// delete mutation routed through POST /v1/data/mutate/<dataset>.
func (ds *DataStore) Delete(typeName, id string) bool {
	mutation := map[string]interface{}{
		"delete": map[string]interface{}{
			"id":   id,
			"type": typeName,
		},
	}
	return ds.Mutate([]map[string]interface{}{mutation}) == nil
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

// ListWorkspaces fetches the workspaces the bearer token is a member of via
// GET /api/workspaces. This is a token-gated, NOT path-scoped, endpoint — it
// lives under /api directly, not under /w/:ws/p/:project.
func (ds *DataStore) ListWorkspaces() ([]WorkspaceInfo, error) {
	resp, err := ds.authGet(ds.baseURL + "/api/workspaces")
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
func (ds *DataStore) ListProjects(workspaceSlug string) ([]ProjectInfo, error) {
	resp, err := ds.authGet(ds.baseURL + "/api/workspaces/" + url.PathEscape(workspaceSlug) + "/projects")
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
// Falls back to a single poll on reconnect, with exponential backoff.
func (ds *DataStore) StartSSE(token string) {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		if ds.program == nil {
			time.Sleep(time.Second)
			continue
		}
		err := ds.listenSSE(token)
		if err != nil {
			ds.pollOnce()
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

func (ds *DataStore) listenSSE(token string) error {
	sseURL := ds.scopedURL("/v1/data/listen/" + ds.Dataset)
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
			ds.program.Send(DataStoreRefreshMsg{})
		}
	}
	return scanner.Err()
}

func (ds *DataStore) pollOnce() {
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
	resp, err := ds.authGet(ds.scopedURL("/v1/data/export/" + ds.Dataset))
	if err != nil {
		return
	}
	defer resp.Body.Close()

	hash := ds.exportDocSetHash(resp.Body)

	ds.mu.Lock()
	changed := hash != ds.lastHash
	ds.lastHash = hash
	ds.mu.Unlock()

	if changed && ds.program != nil {
		ds.program.Send(DataStoreRefreshMsg{})
	}
}

// exportDocSetHash reads the NDJSON export stream and returns a stable hash of
// the document set: each line's "_id:_rev" pair, sorted and concatenated, then
// SHA-256'd. Unparseable lines are skipped so a single malformed record cannot
// poison the whole signature. The hash is identity-derived — independent of
// stream order and of any non-identity envelope fields.
func (ds *DataStore) exportDocSetHash(r io.Reader) string {
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

// ── Helpers ──────────────────────────────────────────────────────────────────

func timeAgo(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := time.Since(t)
	if d.Minutes() < 60 {
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	}
	if d.Hours() < 24 {
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

func statusIcon(status string) string {
	switch status {
	case "published":
		return "●"
	case "draft":
		return "○"
	case "active":
		return "◆"
	case "planning":
		return "◇"
	case "completed":
		return "✓"
	default:
		return "·"
	}
}
