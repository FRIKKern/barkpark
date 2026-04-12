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

// StartPolling checks for data changes every 2 seconds and notifies the TUI.
func (ds *DataStore) StartPolling() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		if ds.program == nil {
			continue
		}
		if ds.hasChanged() {
			ds.program.Send(DataStoreRefreshMsg{})
		}
	}
}

// hasChanged does a lightweight check to see if data has changed since last poll.
func (ds *DataStore) hasChanged() bool {
	resp, err := ds.client.Get(ds.baseURL + "/api/documents/")
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return false
	}

	hash := fmt.Sprintf("%x", body)

	ds.mu.Lock()
	defer ds.mu.Unlock()

	if hash != ds.lastHash {
		ds.lastHash = hash
		return ds.lastHash != "" // don't trigger on first poll
	}
	return false
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
