package template

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// validManifest is a minimal-but-complete document every field-level test mutates.
const validManifest = `{
  "manifestVersion": "1",
  "name": "place-directory",
  "title": "Place Directory",
  "description": "A map-backed listing site.",
  "framework": "nextjs",
  "dataset": "production",
  "demoContent": true,
  "schemas": ["schemas/place.json"],
  "seed": { "path": "seed-places.json", "publish": true, "publishType": "place" },
  "env": [
    { "key": "BARKPARK_API_URL", "role": "server", "source": "api_url" },
    { "key": "BARKPARK_TOKEN", "role": "server", "source": "read_token" }
  ]
}`

func TestLoadValid(t *testing.T) {
	tpl, err := Load([]byte(validManifest))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := tpl.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if tpl.Dataset() != "production" {
		t.Errorf("Dataset() = %q", tpl.Dataset())
	}
	if tpl.Seed.Format() != SeedFormatMutations {
		t.Errorf("default Seed.Format() = %q, want mutations", tpl.Seed.Format())
	}
}

func TestDatasetDefault(t *testing.T) {
	tpl, err := Load([]byte(`{
  "manifestVersion": "1", "name": "x", "title": "X", "description": "d",
  "framework": "nextjs", "schemas": ["s.json"]
}`))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if tpl.Dataset() != DefaultDataset {
		t.Errorf("Dataset() = %q, want %q", tpl.Dataset(), DefaultDataset)
	}
}

func TestLoadRejectsUnknownField(t *testing.T) {
	_, err := Load([]byte(`{"manifestVersion":"1","name":"x","framework":"nextjs","bogus":true}`))
	if err == nil {
		t.Fatal("expected Load to reject an unknown field")
	}
}

func TestLoadRejectsTrailingData(t *testing.T) {
	_, err := Load([]byte(`{"manifestVersion":"1"} {"manifestVersion":"1"}`))
	if err == nil {
		t.Fatal("expected Load to reject trailing data after the document")
	}
}

// TestValidateRejects proves Validate is NOT vacuous: each mutation of the good
// manifest must fail for the stated reason.
func TestValidateRejects(t *testing.T) {
	cases := []struct {
		name string
		json string
		want string // substring the error must contain
	}{
		{"missing version", `{"name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"]}`, "manifestVersion is required"},
		{"bad version", `{"manifestVersion":"2","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"]}`, "unsupported manifestVersion"},
		{"missing name", `{"manifestVersion":"1","title":"X","description":"d","framework":"nextjs","schemas":["s.json"]}`, "name is required"},
		{"bad name slug", `{"manifestVersion":"1","name":"Place Directory","title":"X","description":"d","framework":"nextjs","schemas":["s.json"]}`, "kebab slug"},
		{"missing title", `{"manifestVersion":"1","name":"x","description":"d","framework":"nextjs","schemas":["s.json"]}`, "title is required"},
		{"missing description", `{"manifestVersion":"1","name":"x","title":"X","framework":"nextjs","schemas":["s.json"]}`, "description is required"},
		{"missing framework", `{"manifestVersion":"1","name":"x","title":"X","description":"d","schemas":["s.json"]}`, "framework is required"},
		{"bad framework", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"svelte","schemas":["s.json"]}`, "unsupported framework"},
		{"no schemas", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":[]}`, "at least one schema"},
		{"empty schema path", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":[""]}`, "schemas[0] is empty"},
		{"seed no path", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"seed":{"publish":true}}`, "seed.path is required"},
		{"seed bad format", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"seed":{"path":"p","format":"xml"}}`, "seed.format"},
		{"publish without type", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"seed":{"path":"p","publish":true}}`, "seed.publishType is required"},
		{"env no key", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"env":[{"role":"server","source":"api_url"}]}`, "key is required"},
		{"env bad role", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"env":[{"key":"K","role":"secret","source":"api_url"}]}`, "is not server|public"},
		{"env bad source", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"env":[{"key":"K","role":"server","source":"magic"}]}`, "is not a known source"},
		{"literal no value", `{"manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs","schemas":["s.json"],"env":[{"key":"K","role":"server","source":"literal"}]}`, "requires a value"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tpl, err := Load([]byte(tc.json))
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			err = tpl.Validate()
			if err == nil {
				t.Fatalf("expected validation error containing %q, got nil", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

// TestFrameworkEnumAcceptsWidenedValues pins the W2 widening ITSELF, not just
// its rejection half: TestValidateRejects only proves "svelte" fails, which
// stays true if astro and phoenix are deleted from the switch. This test reds
// the moment either accepted value is removed from Validate.
func TestFrameworkEnumAcceptsWidenedValues(t *testing.T) {
	for _, fw := range []string{FrameworkNextJS, FrameworkAstro, FrameworkPhoenix} {
		t.Run(fw, func(t *testing.T) {
			tpl, err := Load([]byte(`{
  "manifestVersion":"1","name":"x","title":"X","description":"d",
  "framework":"` + fw + `","schemas":["s.json"]
}`))
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if err := tpl.Validate(); err != nil {
				t.Fatalf("framework %q must validate (W2 widened the enum): %v", fw, err)
			}
		})
	}
}

// TestThemeValidation covers the optional `theme` field end to end: omitted is
// legal, each shipped palette is accepted, and an unknown palette is rejected
// by name. Before this test the whole knownThemes map was unexercised — every
// branch of the theme check could be deleted with the suite still green.
func TestThemeValidation(t *testing.T) {
	load := func(t *testing.T, themeJSON string) *Template {
		t.Helper()
		tpl, err := Load([]byte(`{
  "manifestVersion":"1","name":"x","title":"X","description":"d",
  "framework":"nextjs","schemas":["s.json"]` + themeJSON + `
}`))
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		return tpl
	}

	t.Run("omitted", func(t *testing.T) {
		tpl := load(t, "")
		if tpl.Theme != "" {
			t.Fatalf("Theme = %q, want empty", tpl.Theme)
		}
		if err := tpl.Validate(); err != nil {
			t.Fatalf("theme is optional: %v", err)
		}
	})

	for _, theme := range []string{"evergreen", "ember", "fjord", "charple"} {
		t.Run("accepts/"+theme, func(t *testing.T) {
			tpl := load(t, `,"theme":"`+theme+`"`)
			if tpl.Theme != theme {
				t.Fatalf("Theme = %q, want %q", tpl.Theme, theme)
			}
			if err := tpl.Validate(); err != nil {
				t.Fatalf("shipped palette %q must validate: %v", theme, err)
			}
		})
	}

	t.Run("rejects unknown", func(t *testing.T) {
		tpl := load(t, `,"theme":"neon"`)
		err := tpl.Validate()
		if err == nil {
			t.Fatal("expected an unknown theme to be rejected, got nil")
		}
		if !strings.Contains(err.Error(), `unknown theme "neon"`) {
			t.Fatalf("error %q does not name the bad theme", err.Error())
		}
	})
}

// TestScriptSeedNoPublishType: a "script" seed publishes itself, so publishType
// is NOT required even with publish=true.
func TestScriptSeedNoPublishType(t *testing.T) {
	tpl, err := Load([]byte(`{
  "manifestVersion":"1","name":"x","title":"X","description":"d","framework":"nextjs",
  "schemas":["s.json"],"seed":{"path":"seeds/seed.ts","format":"script","publish":true}
}`))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := tpl.Validate(); err != nil {
		t.Fatalf("script seed should validate without publishType: %v", err)
	}
}

// TestRealManifests is the drift gate: EVERY checked-in barkpark.template.json
// in the repo must load, validate, AND have its referenced schema/seed paths
// present on disk.
//
// Enrolment is BY PREDICATE, not by a written-down list. The list this replaced
// named three files while the repo carried fourteen: search-starter and
// astro-search-starter — the templates the W2 catalog family exists for — were
// validated by no Go test at all, and every embedded and mirrored copy was
// likewise unchecked. A list cannot enrol a template nobody remembered to add
// to it; a predicate enrols it the moment the file lands.
func TestRealManifests(t *testing.T) {
	root := repoRoot(t)
	manifests := findManifests(t, root)

	// A floor, so a walk that silently finds nothing cannot pass vacuously:
	// zero subtests is also zero failures. The number is deliberately below the
	// current count — it is a "the walk worked" assertion, not a census to
	// maintain.
	const floor = 10
	if len(manifests) < floor {
		t.Fatalf("found only %d barkpark.template.json files under %s, want >= %d — the walk is broken, not the repo", len(manifests), root, floor)
	}

	for _, mf := range manifests {
		rel, err := filepath.Rel(root, mf)
		if err != nil {
			rel = mf
		}
		t.Run(filepath.ToSlash(rel), func(t *testing.T) {
			data, err := os.ReadFile(mf)
			if err != nil {
				t.Fatalf("read %s: %v", mf, err)
			}
			tpl, err := Load(data)
			if err != nil {
				t.Fatalf("Load %s: %v", mf, err)
			}
			if err := tpl.Validate(); err != nil {
				t.Fatalf("Validate %s: %v", mf, err)
			}
			dir := filepath.Dir(mf)
			for _, s := range tpl.Schemas {
				if _, err := os.Stat(filepath.Join(dir, s)); err != nil {
					t.Errorf("%s: schema path %q does not exist: %v", mf, s, err)
				}
			}
			if tpl.Seed != nil {
				if _, err := os.Stat(filepath.Join(dir, tpl.Seed.Path)); err != nil {
					t.Errorf("%s: seed path %q does not exist: %v", mf, tpl.Seed.Path, err)
				}
			}
		})
	}
}

// findManifests walks the repo for every barkpark.template.json, skipping the
// directories that hold generated or vendored copies of other people's files
// (node_modules, build output, VCS metadata). Result is sorted so subtest names
// and failure order are deterministic.
func findManifests(t *testing.T, root string) []string {
	t.Helper()
	skip := map[string]bool{
		"node_modules": true,
		".git":         true,
		"_build":       true,
		"deps":         true,
		"dist":         true,
		".next":        true,
		"vendor":       true,
	}
	var out []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if p != root && skip[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() == "barkpark.template.json" {
			out = append(out, p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s for manifests: %v", root, err)
	}
	sort.Strings(out)
	return out
}

// repoRoot walks up from the package dir to the module root (the dir with go.mod).
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find repo root (go.mod)")
		}
		dir = parent
	}
}
