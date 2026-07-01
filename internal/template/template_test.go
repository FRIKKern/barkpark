package template

import (
	"os"
	"path/filepath"
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

// realManifests is the drift gate: every checked-in barkpark.template.json must
// load, validate, AND its referenced schema/seed paths must exist on disk.
// A broken or drifted manifest fails CI here.
func TestRealManifests(t *testing.T) {
	root := repoRoot(t)
	manifests := []string{
		filepath.Join(root, "templates", "place-directory", "barkpark.template.json"),
		filepath.Join(root, "js", "packages", "create-barkpark-app", "templates", "website-starter", "barkpark.template.json"),
		filepath.Join(root, "js", "packages", "create-barkpark-app", "templates", "blog-starter", "barkpark.template.json"),
	}
	for _, mf := range manifests {
		t.Run(filepath.Base(filepath.Dir(mf)), func(t *testing.T) {
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
			for _, rel := range tpl.Schemas {
				if _, err := os.Stat(filepath.Join(dir, rel)); err != nil {
					t.Errorf("%s: schema path %q does not exist: %v", mf, rel, err)
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
