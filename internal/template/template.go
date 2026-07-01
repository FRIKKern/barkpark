// Package template models the declarative deploy descriptor
// `barkpark.template.json` — the manifest a deploy-button UI enumerates and a
// server-side bootstrap job (dwb-4) consumes to stand up a Barkpark-backed site
// without an ad-hoc install.sh.
//
// It is DELIBERATELY separate from internal/manifest (the CLI *capabilities*
// manifest, GET /v1/capabilities): different document, different lifecycle. The
// public surface is intentionally small — Load([]byte) → *Template, then
// (*Template).Validate() — so the future provisioner imports exactly two things.
//
// The spec doc + JSON Schema live next to the templates:
//   templates/MANIFEST.md
//   templates/barkpark.template.schema.json
// The struct json tags mirror the JSON Schema field names exactly.
package template

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// FrameworkNextJS is the only deployable-app framework v1 targets. The enum
// exists so the schema can grow without a struct change and so Validate rejects
// a typo'd framework loudly.
const FrameworkNextJS = "nextjs"

// EnvRole is the browser-exposure class of an env var. "server" = server-only
// (never shipped to the browser — secrets, tokens, API base); "public" = safe
// to expose (a Next.js NEXT_PUBLIC_ value). The provisioner uses this to decide
// whether a value is written as a plain or a NEXT_PUBLIC_ env.
const (
	EnvRoleServer = "server"
	EnvRolePublic = "public"
)

// EnvSource tells the provisioner WHERE a value comes from during bootstrap:
// a minted read token, the resolved API URL, the chosen dataset/workspace/
// project slug, a generated webhook/preview secret, or a literal baked into the
// manifest. It is the wiring contract between the manifest and dwb-4.
const (
	SourceAPIURL        = "api_url"
	SourceReadToken     = "read_token"
	SourceDataset       = "dataset"
	SourceWorkspace     = "workspace"
	SourceProject       = "project"
	SourceWebhookSecret = "webhook_secret"
	SourceLiteral       = "literal"
)

// SeedFormat classifies how the seed file is applied:
//   - "mutations": a {"mutations":[…]} JSON body POSTed to /v1/data/mutate
//     (the place-directory shape). createOrReplace lands DRAFTS, so a separate
//     publish pass is needed — hence PublishType is required when Publish is set.
//   - "ndjson":    newline-delimited documents (a dataset export/import shape).
//   - "script":    an executable seed script (e.g. seeds/seed.ts) that does its
//     OWN create + publish. No PublishType — the script owns per-doc typing.
const (
	SeedFormatMutations = "mutations"
	SeedFormatNDJSON    = "ndjson"
	SeedFormatScript    = "script"
)

// DefaultDataset is the dataset a manifest inherits when it omits `dataset`.
const DefaultDataset = "production"

// Template is the parsed `barkpark.template.json` descriptor. All relative
// paths (Schemas[i], Seed.Path) are resolved against the directory the manifest
// file lives in.
type Template struct {
	// Schema is the optional "$schema" pointer; carried so a strict decode of a
	// documented file still succeeds.
	Schema string `json:"$schema,omitempty"`
	// ManifestVersion pins the descriptor format. v1 files carry "1".
	ManifestVersion string `json:"manifestVersion"`

	Name        string `json:"name"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Framework   string `json:"framework"`

	// Repo is the git URL of the deployable app (optional — a template that
	// lives in this monorepo can omit it; the deploy UI falls back to the
	// monorepo path).
	Repo string `json:"repo,omitempty"`

	// DatasetName defaults to DefaultDataset when empty (see Dataset()).
	DatasetName string `json:"dataset,omitempty"`
	// DemoContent flags a template that ships illustrative sample content (as
	// opposed to a bare scaffold). Advisory metadata for the deploy UI.
	DemoContent bool `json:"demoContent,omitempty"`

	// Schemas are relative paths to schema files applied in order. At least one.
	Schemas []string `json:"schemas"`

	// Seed is optional — a template may ship schema-only.
	Seed *Seed `json:"seed,omitempty"`

	// Env is the environment the provisioner must materialize on the deploy
	// target. Optional (a static template needs none).
	Env []EnvVar `json:"env,omitempty"`
}

// Seed describes the seed content and how to apply it.
type Seed struct {
	// Path is the relative path to the seed file.
	Path string `json:"path"`
	// SeedFormat is one of the SeedFormat* constants; empty means "mutations".
	SeedFormat string `json:"format,omitempty"`
	// Publish requests a publish pass after the seed lands (createOrReplace
	// writes DRAFTS — publish is a separate mutation). Ignored for the "script"
	// format, where the script owns publishing.
	Publish bool `json:"publish,omitempty"`
	// PublishType is the document type to publish. REQUIRED when Publish is set
	// on the "mutations" format, because the publish mutation needs {id,type}.
	PublishType string `json:"publishType,omitempty"`
}

// EnvVar is one environment variable the deploy target needs.
type EnvVar struct {
	Key         string `json:"key"`
	Role        string `json:"role"`
	Source      string `json:"source"`
	Description string `json:"description,omitempty"`
	// Value is only meaningful for Source=="literal": the baked value.
	Value string `json:"value,omitempty"`
}

// Dataset returns the effective dataset, applying the default.
func (t *Template) Dataset() string {
	if t.DatasetName == "" {
		return DefaultDataset
	}
	return t.DatasetName
}

// Format returns the effective seed format, applying the default.
func (s *Seed) Format() string {
	if s == nil || s.SeedFormat == "" {
		return SeedFormatMutations
	}
	return s.SeedFormat
}

// Load decodes a barkpark.template.json document. It rejects UNKNOWN fields —
// like the CLI manifest parser — so a typo or stray key fails fast instead of
// being silently dropped. Load does NOT validate semantics; call Validate for
// that.
//
// @canonical capability:template-manifest aka:barkpark.template.json,deploy-descriptor,template-descriptor doc:templates/MANIFEST.md
func Load(body []byte) (*Template, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var t Template
	if err := dec.Decode(&t); err != nil {
		return nil, fmt.Errorf("parse template manifest: %w", err)
	}
	// Reject trailing garbage / a doubled body.
	if dec.More() {
		return nil, fmt.Errorf("parse template manifest: trailing data after document")
	}
	return &t, nil
}

// Validate checks the semantic rules the JSON Schema encodes: required fields,
// enum membership, and the cross-field publish rule. It returns the FIRST
// violation (deterministic ordering) so a CI gate prints one clear reason.
func (t *Template) Validate() error {
	if t.ManifestVersion == "" {
		return fmt.Errorf("manifestVersion is required")
	}
	if t.ManifestVersion != "1" {
		return fmt.Errorf("unsupported manifestVersion %q (expected \"1\")", t.ManifestVersion)
	}
	if err := validateSlug("name", t.Name); err != nil {
		return err
	}
	if strings.TrimSpace(t.Title) == "" {
		return fmt.Errorf("title is required")
	}
	if strings.TrimSpace(t.Description) == "" {
		return fmt.Errorf("description is required")
	}
	switch t.Framework {
	case FrameworkNextJS:
	case "":
		return fmt.Errorf("framework is required")
	default:
		return fmt.Errorf("unsupported framework %q (expected %q)", t.Framework, FrameworkNextJS)
	}

	if len(t.Schemas) == 0 {
		return fmt.Errorf("schemas must list at least one schema path")
	}
	for i, s := range t.Schemas {
		if strings.TrimSpace(s) == "" {
			return fmt.Errorf("schemas[%d] is empty", i)
		}
	}

	if t.Seed != nil {
		if err := t.Seed.validate(); err != nil {
			return err
		}
	}

	for i, e := range t.Env {
		if err := e.validate(i); err != nil {
			return err
		}
	}
	return nil
}

func (s *Seed) validate() error {
	if strings.TrimSpace(s.Path) == "" {
		return fmt.Errorf("seed.path is required when seed is present")
	}
	switch s.Format() {
	case SeedFormatMutations, SeedFormatNDJSON, SeedFormatScript:
	default:
		return fmt.Errorf("seed.format %q is not one of mutations|ndjson|script", s.SeedFormat)
	}
	// The publish-needs-type rule: a mutations seed lands DRAFTS, and the
	// publish mutation requires {id,type}, so a publishType is mandatory.
	if s.Publish && s.Format() == SeedFormatMutations && strings.TrimSpace(s.PublishType) == "" {
		return fmt.Errorf("seed.publishType is required when seed.publish is true on the mutations format")
	}
	return nil
}

func (e EnvVar) validate(i int) error {
	if strings.TrimSpace(e.Key) == "" {
		return fmt.Errorf("env[%d].key is required", i)
	}
	switch e.Role {
	case EnvRoleServer, EnvRolePublic:
	case "":
		return fmt.Errorf("env[%d] (%s): role is required", i, e.Key)
	default:
		return fmt.Errorf("env[%d] (%s): role %q is not server|public", i, e.Key, e.Role)
	}
	switch e.Source {
	case SourceAPIURL, SourceReadToken, SourceDataset, SourceWorkspace,
		SourceProject, SourceWebhookSecret, SourceLiteral:
	case "":
		return fmt.Errorf("env[%d] (%s): source is required", i, e.Key)
	default:
		return fmt.Errorf("env[%d] (%s): source %q is not a known source", i, e.Key, e.Source)
	}
	if e.Source == SourceLiteral && e.Value == "" {
		return fmt.Errorf("env[%d] (%s): source \"literal\" requires a value", i, e.Key)
	}
	return nil
}

// validateSlug enforces a lowercase kebab slug — the identity a deploy UI keys
// and routes on.
func validateSlug(field, v string) error {
	if v == "" {
		return fmt.Errorf("%s is required", field)
	}
	for _, r := range v {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
		if !ok {
			return fmt.Errorf("%s %q must be a lowercase kebab slug ([a-z0-9-])", field, v)
		}
	}
	if strings.HasPrefix(v, "-") || strings.HasSuffix(v, "-") {
		return fmt.Errorf("%s %q must not start or end with '-'", field, v)
	}
	return nil
}
