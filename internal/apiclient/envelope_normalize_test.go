package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// liveEnvelope is the REAL v1 envelope shape captured from prod
// (/w/default/p/default/v1/data/query/production/post?perspective=drafts):
// "_id"/"_updatedAt" with content fields flattened to the top level — none of
// the legacy "id"/"updatedAt"/"values" keys the typed Doc decode expects.
const liveEnvelope = `{
	"_createdAt": "2026-06-05T10:19:18.901132Z",
	"_draft": true,
	"_id": "drafts.playground-unpublish-1",
	"_publishedId": "playground-unpublish-1",
	"_rev": "a49ab6f8b38b957cfa3d3a165aabce0f",
	"_type": "post",
	"_updatedAt": "2026-06-05T10:19:18.901132Z",
	"title": "Unpublish me",
	"status": "draft",
	"category": "Tech",
	"author": "Knut",
	"featured": true,
	"priority": 2,
	"tags": ["a", "b"],
	"meta": {"x": 1}
}`

// Decoding the live envelope must land ID, UpdatedAt and Values — the fields
// saveDocument (patch target), Get-by-id, timeAgo and the field editor consume.
func TestDocNormalizesLiveV1Envelope(t *testing.T) {
	var d Doc
	if err := json.Unmarshal([]byte(liveEnvelope), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if d.ID != "drafts.playground-unpublish-1" {
		t.Errorf("ID = %q, want the envelope _id", d.ID)
	}
	want := time.Date(2026, 6, 5, 10, 19, 18, 901132000, time.UTC)
	if !d.UpdatedAt.Equal(want) {
		t.Errorf("UpdatedAt = %v, want %v (parsed from _updatedAt)", d.UpdatedAt, want)
	}
	if d.Title != "Unpublish me" || d.Type != "post" || d.Status != "draft" {
		t.Errorf("typed fields wrong: title=%q type=%q status=%q", d.Title, d.Type, d.Status)
	}

	// Values: flattened scalar content fields, stringified; meta keys and
	// structured values excluded.
	wantValues := map[string]string{
		"status":   "draft",
		"category": "Tech",
		"author":   "Knut",
		"featured": "true",
		"priority": "2",
	}
	for k, v := range wantValues {
		if got := d.Values[k]; got != v {
			t.Errorf("Values[%q] = %q, want %q", k, got, v)
		}
	}
	for _, k := range []string{"_id", "_type", "_rev", "_draft", "_publishedId",
		"_createdAt", "_updatedAt", "title", "tags", "meta"} {
		if _, ok := d.Values[k]; ok {
			t.Errorf("Values must not contain %q", k)
		}
	}
}

// A legacy envelope that carries the old keys ("id", "updatedAt", "values")
// keeps them — normalization only fills gaps, never overrides.
func TestLegacyEnvelopeKeysWin(t *testing.T) {
	raw := `{
		"id": "legacy-id",
		"_id": "envelope-id",
		"updatedAt": "2025-01-02T03:04:05Z",
		"_updatedAt": "2026-06-05T10:19:18.901132Z",
		"values": {"a": "b"},
		"category": "Tech",
		"title": "T"
	}`
	var d Doc
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if d.ID != "legacy-id" {
		t.Errorf("ID = %q, legacy id must win", d.ID)
	}
	if want := time.Date(2025, 1, 2, 3, 4, 5, 0, time.UTC); !d.UpdatedAt.Equal(want) {
		t.Errorf("UpdatedAt = %v, legacy updatedAt must win", d.UpdatedAt)
	}
	if len(d.Values) != 1 || d.Values["a"] != "b" {
		t.Errorf("Values = %v, legacy values must win (no synthesis)", d.Values)
	}
}

// Round-trip: a doc decoded from the live envelope, sent back through Upsert,
// must carry the real _id in the createOrReplace mutation body.
func TestUpsertRoundTripsEnvelopeID(t *testing.T) {
	var captured []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	var d Doc
	if err := json.Unmarshal([]byte(liveEnvelope), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	if err := c.Upsert("post", d); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	var body struct {
		Mutations []struct {
			CreateOrReplace map[string]any `json:"createOrReplace"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	cr := body.Mutations[0].CreateOrReplace
	if cr["_id"] != "drafts.playground-unpublish-1" {
		t.Errorf("createOrReplace _id = %v, want the envelope _id", cr["_id"])
	}
	if cr["category"] != "Tech" {
		t.Errorf("createOrReplace must carry Values fields, got category=%v", cr["category"])
	}
}

// Status gap-fill: the envelope carries publish state as the "_draft" boolean;
// the legacy "status" string wins when present (liveEnvelope above carries
// both — pinned in TestDocNormalizesLiveV1Envelope's sibling here).
func TestDocStatusFromDraftFlag(t *testing.T) {
	var d Doc
	if err := json.Unmarshal([]byte(`{"_id":"x","_draft":false,"title":"t"}`), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if d.Status != "published" {
		t.Fatalf("Status = %q, want published (from _draft:false)", d.Status)
	}

	var d2 Doc
	if err := json.Unmarshal([]byte(`{"_id":"y","_draft":true,"title":"t"}`), &d2); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if d2.Status != "draft" {
		t.Fatalf("Status = %q, want draft (from _draft:true)", d2.Status)
	}

	var d3 Doc
	if err := json.Unmarshal([]byte(`{"_id":"z","_draft":true,"status":"archived"}`), &d3); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if d3.Status != "archived" {
		t.Fatalf("Status = %q, want archived (explicit status wins)", d3.Status)
	}
}
