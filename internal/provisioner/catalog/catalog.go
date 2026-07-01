// Package catalog is the provisioner's embedded template catalog: the deploy
// templates (`place-directory`, `website-starter`, `blog-starter`) baked into
// the barkpark-provisioner binary so the post-provision bootstrap step (dwb-4)
// can stand up a fresh instance's content with NO checkout on the worker host.
//
// go:embed cannot reach files OUTSIDE a package directory, so the canonical
// templates live at the repo root (`templates/<name>/` — referenced by
// templates/DEPLOYING.md + MANIFEST.md) and a byte-identical COPY is synced into
// `internal/provisioner/catalog/templates/` for embedding. `make
// provisioner-catalog-sync` re-copies them; TestEmbeddedCatalogMatchesRepoRoot
// fails the build on any drift. This mirrors the assets.go precedent
// (internal/cli/setup/assets) for the repo-root deploy.sh.
//
// Each catalog Entry is a parsed + validated `internal/template` manifest plus
// access to its referenced schema/seed bytes (resolved against the manifest's
// directory in the embedded FS). Entries are keyed by manifest `name`.
package catalog

import (
	"embed"
	"fmt"
	"io/fs"
	"path"
	"sort"

	"github.com/FRIKKern/barkpark/internal/template"
)

//go:embed templates
var templatesFS embed.FS

// Entry is one catalog template: its parsed manifest and the embedded directory
// its relative schema/seed paths resolve against.
type Entry struct {
	Manifest *template.Template
	dir      string // embedded dir, e.g. "templates/place-directory"
}

// SchemaBytes returns the raw bytes of every schema file the manifest lists, in
// manifest order.
func (e *Entry) SchemaBytes() ([][]byte, error) {
	out := make([][]byte, 0, len(e.Manifest.Schemas))
	for _, rel := range e.Manifest.Schemas {
		b, err := fs.ReadFile(templatesFS, path.Join(e.dir, rel))
		if err != nil {
			return nil, fmt.Errorf("read schema %q for template %q: %w", rel, e.Manifest.Name, err)
		}
		out = append(out, b)
	}
	return out, nil
}

// SeedBytes returns the raw bytes of the manifest's seed file, or (nil,nil) when
// the template ships no seed.
func (e *Entry) SeedBytes() ([]byte, error) {
	if e.Manifest.Seed == nil {
		return nil, nil
	}
	b, err := fs.ReadFile(templatesFS, path.Join(e.dir, e.Manifest.Seed.Path))
	if err != nil {
		return nil, fmt.Errorf("read seed %q for template %q: %w", e.Manifest.Seed.Path, e.Manifest.Name, err)
	}
	return b, nil
}

// catalog is the parsed+validated set, keyed by manifest name. Built once at
// package init from the embedded FS; a malformed embedded template panics at
// startup (a build/embed error, not a runtime input error) so a broken bundle
// never ships silently.
var catalog = mustLoad()

// Get returns the catalog entry for a template slug, or (nil,false) when the
// slug is unknown. The control plane validates the slug at launch, but the
// worker re-checks here (defence in depth: an unknown slug is a bootstrap
// no-op-with-error, never a nil-deref).
func Get(name string) (*Entry, bool) {
	e, ok := catalog[name]
	return e, ok
}

// Names lists every known template slug, sorted — the source of truth the
// control-plane allowlist mirrors.
func Names() []string {
	names := make([]string, 0, len(catalog))
	for n := range catalog {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// mustLoad parses every embedded manifest. It panics on a malformed/duplicate
// template because that is a build-time defect in the baked bundle, not a
// recoverable runtime condition.
func mustLoad() map[string]*Entry {
	m, err := load()
	if err != nil {
		panic("provisioner/catalog: " + err.Error())
	}
	return m
}

func load() (map[string]*Entry, error) {
	dirs, err := fs.ReadDir(templatesFS, "templates")
	if err != nil {
		return nil, fmt.Errorf("read embedded templates dir: %w", err)
	}
	out := map[string]*Entry{}
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		dir := path.Join("templates", d.Name())
		manifestPath := path.Join(dir, "barkpark.template.json")
		body, err := fs.ReadFile(templatesFS, manifestPath)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", manifestPath, err)
		}
		tpl, err := template.Load(body)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", manifestPath, err)
		}
		if err := tpl.Validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", manifestPath, err)
		}
		if _, dup := out[tpl.Name]; dup {
			return nil, fmt.Errorf("duplicate template name %q", tpl.Name)
		}
		out[tpl.Name] = &Entry{Manifest: tpl, dir: dir}
	}
	return out, nil
}
