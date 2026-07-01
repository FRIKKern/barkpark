package catalog

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestCatalogCarriesTheThreeTemplates locks the catalog contents: the three
// deploy templates are present, parsed, and validated — and Names() is the
// sorted slug list the control-plane allowlist mirrors.
func TestCatalogCarriesTheThreeTemplates(t *testing.T) {
	want := []string{"blog-starter", "place-directory", "website-starter"}
	if got := Names(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Names() = %v, want %v (update the Elixir @known_templates allowlist if this changes)", got, want)
	}
	for _, name := range want {
		e, ok := Get(name)
		if !ok {
			t.Fatalf("Get(%q) missing", name)
		}
		if e.Manifest.Name != name {
			t.Errorf("Get(%q).Manifest.Name = %q", name, e.Manifest.Name)
		}
		schemas, err := e.SchemaBytes()
		if err != nil {
			t.Fatalf("SchemaBytes(%q): %v", name, err)
		}
		if len(schemas) == 0 || len(schemas[0]) == 0 {
			t.Errorf("template %q has no schema bytes", name)
		}
		seed, err := e.SeedBytes()
		if err != nil {
			t.Fatalf("SeedBytes(%q): %v", name, err)
		}
		if e.Manifest.Seed != nil && len(seed) == 0 {
			t.Errorf("template %q declares a seed but SeedBytes is empty", name)
		}
	}
}

// TestGetUnknownTemplate proves an unknown slug is a clean (nil,false) — the
// worker-side defence the bootstrap errors on instead of nil-dereferencing.
func TestGetUnknownTemplate(t *testing.T) {
	if e, ok := Get("no-such-template"); ok || e != nil {
		t.Fatalf("Get(no-such-template) = (%v,%v), want (nil,false)", e, ok)
	}
}

// TestEmbeddedCatalogMatchesRepoRoot is the DRIFT TRIPWIRE: every file embedded
// under internal/provisioner/catalog/templates/ must be byte-identical to its
// canonical sibling at the repo root templates/ (go:embed cannot reach outside
// the package dir, so a synced copy exists — this test fails the build the
// moment someone edits one side only). Mirrors the assets.go deploy.sh
// precedent.
func TestEmbeddedCatalogMatchesRepoRoot(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "templates")

	err := fs.WalkDir(templatesFS, "templates", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		embedded, err := fs.ReadFile(templatesFS, p)
		if err != nil {
			return err
		}
		// p is "templates/<name>/<rel...>" — map onto the repo root copy.
		rel, rerr := filepath.Rel("templates", filepath.FromSlash(p))
		if rerr != nil {
			return rerr
		}
		canonical, rerr := os.ReadFile(filepath.Join(repoRoot, rel))
		if rerr != nil {
			t.Errorf("embedded %s has no repo-root canonical counterpart: %v", p, rerr)
			return nil
		}
		if !bytes.Equal(embedded, canonical) {
			t.Errorf("embedded %s has DRIFTED from templates/%s — re-sync the copy (edit the repo-root file, then cp into internal/provisioner/catalog/templates/)", p, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk embedded templates: %v", err)
	}

	// And the reverse: every repo-root template with a manifest is embedded, so a
	// NEW template cannot silently miss the catalog.
	entries, err := os.ReadDir(repoRoot)
	if err != nil {
		t.Fatalf("read repo templates dir: %v", err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(repoRoot, e.Name(), "barkpark.template.json")); err != nil {
			continue // not a template dir
		}
		if _, ok := Get(e.Name()); !ok {
			t.Errorf("repo template %q is not in the embedded catalog — sync it into internal/provisioner/catalog/templates/", e.Name())
		}
	}
}
