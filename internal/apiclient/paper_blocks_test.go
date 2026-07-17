package apiclient

import (
	"encoding/json"
	"strings"
	"testing"
)

// PaperBlocks must resolve the block tree across every live paper shape:
// top-level "blocks", a nested "content":{"blocks":…}, and a nested
// "body":{"blocks":…} (the shape enterprise-ready-auth-wave-2026-07-11 uses).
// A body_html-only paper carries no block tree and must return nil so callers
// fall through to the BodyHTML render path.
func TestPaperBlocksResolvesEveryShape(t *testing.T) {
	cases := []struct {
		name     string
		doc      string
		wantNil  bool
		wantHead string // substring the returned blocks JSON must contain
	}{
		{
			name:     "canonical empty blocks stay authoritative",
			doc:      `{"_id":"p","blocks":[],"body":{"blocks":[{"type":"heading","text":"stale"}]},"body_html":"<h1>stale</h1>"}`,
			wantHead: `[]`,
		},
		{
			name:     "top-level blocks",
			doc:      `{"_id":"p","blocks":[{"type":"heading","text":"Top"}]}`,
			wantHead: `"Top"`,
		},
		{
			name:     "content envelope",
			doc:      `{"_id":"p","content":{"blocks":[{"type":"heading","text":"InContent"}]}}`,
			wantHead: `"InContent"`,
		},
		{
			name:     "body envelope",
			doc:      `{"_id":"p","body":{"blocks":[{"type":"heading","text":"InBody"}]}}`,
			wantHead: `"InBody"`,
		},
		{
			name:     "bare body array",
			doc:      `{"_id":"p","body":[{"type":"heading","text":"BareBody"}]}`,
			wantHead: `"BareBody"`,
		},
		{
			name:    "body_html only — no block tree",
			doc:     `{"_id":"p","body_html":"<h1>HTML</h1>"}`,
			wantNil: true,
		},
		{
			name:     "empty body envelope is an intentional empty source",
			doc:      `{"_id":"p","body":{"blocks":[]}}`,
			wantHead: `[]`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var d Doc
			if err := json.Unmarshal([]byte(tc.doc), &d); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			got := d.PaperBlocks()
			if tc.wantNil {
				if got != nil {
					t.Fatalf("PaperBlocks = %s, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("PaperBlocks = nil, want blocks containing %s", tc.wantHead)
			}
			if !strings.Contains(string(got), tc.wantHead) {
				t.Errorf("PaperBlocks = %s, want it to contain %s", got, tc.wantHead)
			}
		})
	}
}

// body_html must decode into the typed BodyHTML field AND must NOT leak into
// Values (it is envelope-meta, not a flat editor field). Same for the "body"
// envelope, which scalarString already rejects but which we exclude explicitly.
func TestBodyHTMLDecodesAndDoesNotLeakIntoValues(t *testing.T) {
	var d Doc
	if err := json.Unmarshal([]byte(`{"_id":"p","title":"T","body_html":"<h1>Hi</h1>","event_type":"published"}`), &d); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if d.BodyHTML != "<h1>Hi</h1>" {
		t.Errorf("BodyHTML = %q, want the raw HTML", d.BodyHTML)
	}
	if _, ok := d.Values["body_html"]; ok {
		t.Errorf("body_html leaked into Values: %v", d.Values)
	}
	// A genuine flat content field still lands in Values.
	if d.Values["event_type"] != "published" {
		t.Errorf("event_type = %q, want it in Values", d.Values["event_type"])
	}
}
