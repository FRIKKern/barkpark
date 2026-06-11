package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/textinput"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Image-field pins (TUI↔Studio parity, 2026-06-11): the field is value-aware
// (shows the stored URL + asset linkage, or a quiet hint), enter edits the URL
// part of the value, and a commit preserves the JSON assetId envelope when the
// URL is unchanged but downgrades to a bare URL when hand-edited.

func TestParseImageValue(t *testing.T) {
	cases := []struct {
		in, url, asset string
	}{
		{"", "", ""},
		{"/media/files/x.png", "/media/files/x.png", ""},
		{`{"url":"/media/files/x.png","assetId":"a1"}`, "/media/files/x.png", "a1"},
		{`{"url":"/media/files/x.png","id":"a2"}`, "/media/files/x.png", "a2"},
		{"{not json", "{not json", ""}, // degrade to URL, never error
	}
	for _, c := range cases {
		url, asset := parseImageValue(c.in)
		if url != c.url || asset != c.asset {
			t.Errorf("parseImageValue(%q) = (%q, %q), want (%q, %q)", c.in, url, asset, c.url, c.asset)
		}
	}
}

func imageFieldModel(value string) model {
	return model{
		selectedDoc: &Doc{
			ID:     "drafts.p1",
			Title:  "Doc",
			Values: map[string]string{"cover": value},
		},
		editorSchema: &apiclient.Schema{
			Name: "post",
			Fields: []Field{
				{Name: "cover", Title: "Cover", Type: FieldImage},
			},
		},
		width:  100,
		height: 40,
	}
}

func TestImageFieldRenderShowsValueState(t *testing.T) {
	// Unset → quiet hint, never the dead "Drop image or browse" card.
	m := imageFieldModel("")
	out := strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "No image") {
		t.Errorf("empty image field should hint, got:\n%s", out)
	}
	if strings.Contains(out, "Drop image") {
		t.Errorf("dead drop affordance must be gone, got:\n%s", out)
	}

	// JSON envelope → URL + asset linkage both visible.
	m = imageFieldModel(`{"url":"/media/files/cat.png","assetId":"asset-9"}`)
	out = strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "/media/files/cat.png") || !strings.Contains(out, "asset-9") {
		t.Errorf("set image field should show url + asset id, got:\n%s", out)
	}

	// Bare URL → shown as-is.
	m = imageFieldModel("/media/files/dog.png")
	out = strings.Join(m.renderField(m.editorSchema.Fields[0], 60, false, false), "\n")
	if !strings.Contains(out, "/media/files/dog.png") {
		t.Errorf("bare-url image field should show the url, got:\n%s", out)
	}
}

func TestImageFieldEditPrefillsURLNotJSON(t *testing.T) {
	m := imageFieldModel(`{"url":"/media/files/cat.png","assetId":"asset-9"}`)
	m.startFieldEdit()
	if !m.editing {
		t.Fatal("image field should be text-editable")
	}
	if got := m.textInput.Value(); got != "/media/files/cat.png" {
		t.Errorf("edit prefill = %q, want the URL part", got)
	}
}

func TestImageFieldCommitSemantics(t *testing.T) {
	orig := `{"url":"/media/files/cat.png","assetId":"asset-9"}`

	// Unchanged URL → the original JSON (asset linkage preserved).
	m := imageFieldModel(orig)
	m.textInput = textinput.New()
	m.textInput.SetValue("/media/files/cat.png")
	m.commitFieldEdit()
	if got := m.dirtyValues["cover"]; got != orig {
		t.Errorf("unchanged URL commit = %q, want original envelope", got)
	}

	// Edited URL → bare string, the stale assetId is dropped.
	m = imageFieldModel(orig)
	m.textInput = textinput.New()
	m.textInput.SetValue("https://example.com/new.png")
	m.commitFieldEdit()
	if got := m.dirtyValues["cover"]; got != "https://example.com/new.png" {
		t.Errorf("edited URL commit = %q, want bare URL", got)
	}

	// Cleared → empty string (the server's clear-on-empty drops the key).
	m = imageFieldModel(orig)
	m.textInput = textinput.New()
	m.textInput.SetValue("")
	m.commitFieldEdit()
	if got := m.dirtyValues["cover"]; got != "" {
		t.Errorf("cleared commit = %q, want empty", got)
	}
}
