// Package manifest models the Barkpark CLI capabilities manifest emitted by
// GET /v1/capabilities and turns it into the data structures the CLI drives off
// of: a typed manifest, an on-disk ETag cache, a precedence-resolved Context, a
// flat-path URL builder (with local scoped-prefix prepend, contract spine rule
// #4), and a noun->verb Tree built purely from the manifest commands.
//
// The package hardcodes NO noun, verb, flag, or route. Every command tree it
// produces is a pure function of the manifest document — a future plugin adds
// commands with zero code change here. The frozen schema lives at
// docs/cli/manifest.schema.json; the struct field json tags mirror it exactly.
package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Manifest is the root capabilities document. Field names mirror
// manifest.schema.json exactly; optional/additive fields use omitempty.
type Manifest struct {
	// Comment is the optional root-only "$comment" annotation. It carries no
	// contract meaning; modelling it lets a strict decode still accept the
	// documented fixtures.
	Comment         string    `json:"$comment,omitempty"`
	ManifestVersion string    `json:"manifest_version"`
	Server          Server    `json:"server"`
	AuthTier        string    `json:"auth_tier"`
	GeneratedAt     string    `json:"generated_at"`
	ETag            string    `json:"etag"`
	Nouns           []Noun    `json:"nouns"`
	Commands        []Command `json:"commands"`
}

// Server identifies the responding Barkpark instance. APIVersion and MinCLI are
// optional/additive (pointers + omitempty) so a manifest that omits them parses.
type Server struct {
	Name       string  `json:"name"`
	Version    string  `json:"version"`
	BaseURL    string  `json:"base_url"`
	APIVersion *string `json:"api_version,omitempty"`
	MinCLI     *string `json:"min_cli,omitempty"`
}

// Noun is a top-level resource in the CLI tree. Plugin is nil for a core host
// noun, or the owning plugin slug for a plugin-contributed one.
type Noun struct {
	Name    string  `json:"name"`
	Summary string  `json:"summary"`
	Plugin  *string `json:"plugin,omitempty"`
}

// HTTP is the single API call a command makes. PathTemplate is FLAT — the CLI
// prepends its own /w/:ws/p/:project prefix locally when ScopedPrefix is set.
type HTTP struct {
	Method       string `json:"method"`
	PathTemplate string `json:"path_template"`
}

// Command is one <noun> <verb> leaf of the CLI tree = one API call. ScopedPrefix,
// Source, and Since are optional/additive.
type Command struct {
	ID            string  `json:"id"`
	Noun          string  `json:"noun"`
	Verb          string  `json:"verb"`
	Summary       string  `json:"summary"`
	HTTP          HTTP    `json:"http"`
	AuthTier      string  `json:"auth_tier"`
	Args          []Arg   `json:"args"`
	Flags         []Flag  `json:"flags"`
	Writes        bool    `json:"writes"`
	Batch         bool    `json:"batch"`
	Paginated     bool    `json:"paginated"`
	DryRun        bool    `json:"dry_run"`
	DefaultOutput string  `json:"default_output"`
	ScopedPrefix  *string `json:"scoped_prefix,omitempty"`
	Source        *string `json:"source,omitempty"`
	Since         *string `json:"since,omitempty"`
	// MutationOp, when set, wraps the body-arg object into a single mutation:
	// `{mutations: [{<MutationOp>: <body>}]}` — turns `doc delete post p1` into a
	// `{delete:{type,id}}` mutate POST. Empty for non-mutation commands.
	MutationOp string `json:"mutation_op,omitempty"`
	// SetKey, when set, nests the `--set` fields under that key in the body
	// instead of merging them flat — `doc patch` needs `{patch:{id,type,set:{…}}}`.
	SetKey string `json:"set_key,omitempty"`
}

// Arg is a positional argument (thin per the M0 freeze: name/required/type/summary).
//
// In is an OPTIONAL transport hint the Elixir manifest track MAY emit:
// "path" | "query" | "body". It is omitempty so a manifest that does not carry
// it still decodes cleanly (the strict Parse only rejects UNKNOWN fields, so a
// present "in" must be modelled here). When absent, the CLI INFERS the location:
// path if the arg name appears as a :placeholder in http.path_template, else
// query for a read (GET) or body for a write (POST/PUT/PATCH). See
// Command.ArgLocation.
type Arg struct {
	Name     string `json:"name"`
	Required bool   `json:"required"`
	Type     string `json:"type"`
	Summary  string `json:"summary"`
	In       string `json:"in,omitempty"`
}

// Flag is a named command-local flag. Default is any JSON value (absent = no
// default); Repeatable is optional and defaults to false.
type Flag struct {
	Name       string      `json:"name"`
	Type       string      `json:"type"`
	Default    interface{} `json:"default,omitempty"`
	Summary    string      `json:"summary"`
	Repeatable bool        `json:"repeatable,omitempty"`
}

// Parse decodes a manifest document. It rejects unknown top-level/structural
// fields the same way the frozen schema's additionalProperties:false does, so a
// typo or stray field fails fast instead of being silently dropped.
func Parse(body []byte) (*Manifest, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var m Manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	if m.ManifestVersion == "" {
		return nil, fmt.Errorf("parse manifest: missing manifest_version")
	}
	return &m, nil
}
