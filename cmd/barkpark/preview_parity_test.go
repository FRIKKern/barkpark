package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/charmbracelet/x/ansi"
)

// Cross-surface preview-parity — the Go TUI leg (preview-contract W4, charter
// D20). The doc-list row's meta is resolved by the SAME `rowMeta` the real TUI
// calls (buildDocListPane), driven over the SHARED parity fixture — the ONE
// `Barkpark.Preview.project/3` manifest, mirrored byte-for-byte from the api
// generator (`mix barkpark.preview.gen_parity`). The row meta must equal the
// manifest description and survive to the rendered (ansi-stripped) row, so the
// TUI can never drift from the reader / envelope / web / Studio surfaces.
//
// DEGRADATION INVARIANT: the `core` variant (nil description) renders a valid
// row with NO meta suffix — byte-identical to a manifest-less doc, never a crash.

type parityManifest struct {
	Manifest struct {
		Description string `json:"description"`
	} `json:"manifest"`
}

type parityFixture struct {
	Rich parityManifest `json:"rich"`
	Core parityManifest `json:"core"`
}

// loadParityFixture reads the Go mirror AND captures each manifest's raw JSON
// (the exact bytes the v1 envelope hoists onto Extra["preview"]).
func loadParityFixture(t *testing.T) (rawRich, rawCore json.RawMessage, richDesc, coreDesc string) {
	t.Helper()
	b, err := os.ReadFile("testdata/preview-parity.json")
	if err != nil {
		t.Fatalf("read mirror: %v", err)
	}

	// Two decodes: one typed (for the description field), one raw (for the
	// exact manifest bytes the envelope would carry).
	var typed parityFixture
	if err := json.Unmarshal(b, &typed); err != nil {
		t.Fatalf("decode typed: %v", err)
	}

	var raw struct {
		Rich struct {
			Manifest json.RawMessage `json:"manifest"`
		} `json:"rich"`
		Core struct {
			Manifest json.RawMessage `json:"manifest"`
		} `json:"core"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatalf("decode raw: %v", err)
	}
	return raw.Rich.Manifest, raw.Core.Manifest, typed.Rich.Manifest.Description, typed.Core.Manifest.Description
}

// docWithManifest builds the Doc the envelope produces: the manifest rides on
// Extra["preview"] exactly as the hoisted top-level key.
func docWithManifest(manifest json.RawMessage) Doc {
	return Doc{Extra: map[string]json.RawMessage{"preview": manifest}}
}

func TestPreviewParityRowMetaMatchesManifestDescription(t *testing.T) {
	rawRich, _, richDesc, _ := loadParityFixture(t)

	if richDesc == "" {
		t.Fatal("fixture rich manifest has no description — regenerate the mirror")
	}

	// The REAL resolution path (buildDocListPane → rowMeta): a block doc with no
	// list_preview spec falls back to the manifest's OG description.
	got := rowMeta(docWithManifest(rawRich), apiclient.ListPreview{})
	if got != richDesc {
		t.Errorf("rowMeta = %q, want the manifest description %q", got, richDesc)
	}
}

func TestPreviewParityRowRendersManifestDescription(t *testing.T) {
	rawRich, _, richDesc, _ := loadParityFixture(t)

	m := model{}
	meta := rowMeta(docWithManifest(rawRich), apiclient.ListPreview{})
	item := PaneItem{
		ID: "rich", Title: "Theme System", Icon: "○", Status: "draft",
		Subtitle: "2d ago", Meta: meta,
	}

	lines := m.renderPaneItem(item, 80, false, false, true)
	if len(lines) != 2 {
		t.Fatalf("want 2 row lines, got %d: %q", len(lines), lines)
	}

	// The description must survive to the rendered (ansi-stripped) subtitle row.
	sub := ansi.Strip(lines[1])
	if !strings.Contains(sub, richDesc) {
		t.Errorf("rendered subtitle row %q missing manifest description %q", sub, richDesc)
	}
}

func TestPreviewParityDegradationCoreRowHasNoMeta(t *testing.T) {
	_, rawCore, _, coreDesc := loadParityFixture(t)

	if coreDesc != "" {
		t.Fatalf("fixture core manifest should have a nil/blank description, got %q", coreDesc)
	}

	// Core-only manifest (no description) → rowMeta degrades to "".
	meta := rowMeta(docWithManifest(rawCore), apiclient.ListPreview{})
	if meta != "" {
		t.Errorf("core rowMeta = %q, want empty (degraded)", meta)
	}

	// The rendered row carries no meta suffix — no dangling " · ".
	m := model{}
	item := PaneItem{
		ID: "core", Title: "Release Checklist", Icon: "○", Status: "draft",
		Subtitle: "2d ago", Meta: meta,
	}
	lines := m.renderPaneItem(item, 80, false, false, true)
	sub := ansi.Strip(lines[1])
	if strings.Contains(sub, "·") {
		t.Errorf("degraded core row must carry no meta separator, got %q", sub)
	}
}
