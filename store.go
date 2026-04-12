package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
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
	baseURL  string
	token    string
	client   *http.Client
	program  *tea.Program
	mu       sync.RWMutex
	lastHash string // hash of last response to detect changes
}

// NewDataStore creates an API-backed DataStore.
func NewDataStore(baseURL string) *DataStore {
	return &DataStore{
		baseURL: baseURL,
		client:  &http.Client{Timeout: 5 * time.Second},
	}
}

// SetToken sets the API token for authenticated requests.
func (ds *DataStore) SetToken(token string) {
	ds.token = token
}

// Mutate sends a mutation to the Phoenix API (Sanity format).
func (ds *DataStore) Mutate(mutations []map[string]interface{}) error {
	endpoint := fmt.Sprintf("%s/v1/data/mutate/production", ds.baseURL)
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

// SetProgram sets the tea.Program reference for sending refresh messages.
func (ds *DataStore) SetProgram(p *tea.Program) {
	ds.program = p
}

// Load is a no-op for the API client (data lives in Phoenix/Postgres).
func (ds *DataStore) Load() error {
	return nil
}

// Query fetches documents from the API by type, with optional filter.
func (ds *DataStore) Query(typeName, filter string) []Doc {
	endpoint := fmt.Sprintf("%s/api/documents/%s", ds.baseURL, typeName)
	if filter != "" {
		endpoint += "?filter=" + url.QueryEscape(filter)
	}

	resp, err := ds.client.Get(endpoint)
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
	endpoint := fmt.Sprintf("%s/api/documents/%s/%s", ds.baseURL, typeName, id)

	resp, err := ds.client.Get(endpoint)
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
func (ds *DataStore) Upsert(typeName string, doc Doc) error {
	endpoint := fmt.Sprintf("%s/api/documents/%s", ds.baseURL, typeName)

	body, err := json.Marshal(doc)
	if err != nil {
		return err
	}

	resp, err := ds.client.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API error %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// Delete removes a document via the API.
func (ds *DataStore) Delete(typeName, id string) bool {
	endpoint := fmt.Sprintf("%s/api/documents/%s/%s", ds.baseURL, typeName, id)

	req, err := http.NewRequest(http.MethodDelete, endpoint, nil)
	if err != nil {
		return false
	}

	resp, err := ds.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK
}

// StartSSE connects to the Phoenix SSE listener for real-time updates.
// Falls back to polling if SSE connection fails.
func (ds *DataStore) StartSSE(token string) {
	for {
		if ds.program == nil {
			time.Sleep(time.Second)
			continue
		}
		err := ds.listenSSE(token)
		if err != nil {
			// SSE failed, fall back to polling briefly then retry
			ds.pollOnce()
			time.Sleep(3 * time.Second)
		}
	}
}

func (ds *DataStore) listenSSE(token string) error {
	sseURL := ds.baseURL + "/v1/data/listen/production"
	req, err := http.NewRequest("GET", sseURL, nil)
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	// Use a client without timeout for long-lived SSE
	sseClient := &http.Client{Timeout: 0}
	resp, err := sseClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("SSE status %d", resp.StatusCode)
	}

	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			line := string(buf[:n])
			// Any "event: mutation" line means data changed
			if contains(line, "event: mutation") {
				ds.program.Send(DataStoreRefreshMsg{})
			}
		}
		if err != nil {
			return err
		}
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func (ds *DataStore) pollOnce() {
	resp, err := ds.client.Get(ds.baseURL + "/api/documents/")
	if err != nil {
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return
	}

	hash := fmt.Sprintf("%x", body)

	ds.mu.Lock()
	changed := hash != ds.lastHash && ds.lastHash != ""
	ds.lastHash = hash
	ds.mu.Unlock()

	if changed && ds.program != nil {
		ds.program.Send(DataStoreRefreshMsg{})
	}
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
