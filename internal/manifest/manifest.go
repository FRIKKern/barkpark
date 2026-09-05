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
	"io"
	"regexp"
)

// safeName constrains a manifest-supplied noun name and command verb to a
// shell-safe identifier: an opening lowercase letter or digit, then any run of
// lowercase letters, digits, underscores, or hyphens. No shell metacharacter,
// quote, whitespace, or `$(...)` can match.
//
// This is a CLIENT-SIDE TRUST BOUNDARY, not cosmetics. `bp completion <shell>`
// emits a script the user is told to eval — `eval "$(bp completion bash)"`,
// `bp completion fish | source` — and the bash/zsh/fish emitters bake manifest
// NOUN and VERB names into that script RAW (internal/cli/builtins.go). The same
// unvalidated names also flow into argv/path construction elsewhere. A hostile
// or compromised server the bp is pointed at could otherwise plant a noun named
// `x";touch /tmp/pwn;#` (or a `$(...)` / single-quote variant) that materializes
// verbatim in the emitted shell and executes the moment it is eval'd — a
// remote-to-eval RCE. Rejecting any name outside this charset at Parse, before a
// single name can reach an emitter, closes that chain at its true locus.
// Emitter-side quoting is tracked separately as defense-in-depth
// (bp-secgo-completion-emitter-quoting).
var safeName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

// Manifest is the root capabilities document. Field names mirror
// manifest.schema.json exactly; optional/additive fields use omitempty.
type Manifest struct {
	// Comment is the optional root-only "$comment" annotation. It carries no
	// contract meaning; modelling it lets a strict decode still accept the
	// documented fixtures.
	Comment         string `json:"$comment,omitempty"`
	ManifestVersion string `json:"manifest_version"`
	Server          Server `json:"server"`
	// Build is the server's build identity (version/release/commit/built_at,
	// instance-version space vA.B.C.D). Optional: servers older than the
	// self-update feature omit it, and the strict decode must accept both.
	Build       map[string]string `json:"build,omitempty"`
	AuthTier    string            `json:"auth_tier"`
	GeneratedAt string            `json:"generated_at"`
	ETag        string            `json:"etag"`
	Nouns       []Noun            `json:"nouns"`
	Commands    []Command         `json:"commands"`
	// Chat is the root chat capability-discovery block (charter D27): the
	// per-provider picker vocabulary. The server emits it only to callers that
	// opt in with ?chat=1 (fetch.go sends the param in the SAME commit that
	// models this field — intra-Go atomicity: no bp ever sends chat=1 without
	// being able to strict-decode the answer). Absent on older servers and on
	// tier "none" — nil means "discover nothing, degrade".
	Chat *ManifestChat `json:"chat,omitempty"`
}

// ManifestChat is the root "chat" discovery block: a flat map keyed by provider
// id ("claude", "codex", …). Every nested key is modelled — Parse's
// DisallowUnknownFields recurses, so an unmodelled server addition fails fast.
type ManifestChat struct {
	Providers map[string]ChatProviderCaps `json:"providers"`
}

// ChatProviderCaps is one provider's picker vocabulary. Empty slices are the
// honest degrade signal (codex ships all-empty today): offer no picker rather
// than inventing values.
type ChatProviderCaps struct {
	Modes   []string `json:"modes"`
	Models  []string `json:"models"`
	Efforts []string `json:"efforts"`
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

// writesKey is the manifest key whose ABSENCE the Writes tri-state exists to
// notice. Named once so the decoder and its doc comment cannot drift.
const writesKey = "writes"

// UnmarshalJSON decodes a Command and additionally records whether the document
// carried a `writes` key at all (Command.WritesDeclared).
//
// WHY THIS EXISTS. `Writes` is a plain bool, so Go's zero value makes an
// OMITTED `writes` key indistinguishable from an explicit `"writes": false` —
// and a MISSING key is not an UNKNOWN field, so Parse's DisallowUnknownFields
// never catches it either. Every consumer that defaults to "safe" on false then
// reads UNKNOWN as SAFE. For the verbless-inference gate (internal/cli
// soleReadVerb, which auto-re-dispatches a bare `bp <noun> <free text>` to a
// single-verb noun) that is a safety gate failing OPEN: one single-verb noun
// shipped without the flag — by a new plugin, or by a server on an older
// manifest schema — becomes eligible for AUTOMATIC EXECUTION from free text.
//
// The strict inner decode is not incidental: Parse's DisallowUnknownFields
// recurses into Command today, and a custom UnmarshalJSON would otherwise
// silently opt Command out of that trust boundary.
func (c *Command) UnmarshalJSON(data []byte) error {
	// commandFields sheds this method, so the nested decode does not recurse.
	type commandFields Command
	var fields commandFields
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&fields); err != nil {
		return err
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(data, &keys); err != nil {
		return err
	}
	*c = Command(fields)
	_, declared := keys[writesKey]
	c.WritesDeclared = declared
	return nil
}

// NonWriting reports that the manifest AFFIRMATIVELY declared this command
// non-writing. It is deliberately NOT `!c.Writes`: an UNDECLARED `writes` key
// answers false here, so a caller whose safe default is "refuse" fails CLOSED on
// a manifest this bp cannot fully vouch for. Use it for permission-shaped
// decisions; `c.Writes` remains the right read for "the manifest said this
// writes" (HTTP method inference, MCP hints, receipts).
func (c Command) NonWriting() bool { return c.WritesDeclared && !c.Writes }

// HTTP is the single API call a command makes. PathTemplate is FLAT — the CLI
// prepends its own /w/:ws/p/:project prefix locally when ScopedPrefix is set.
type HTTP struct {
	Method       string `json:"method"`
	PathTemplate string `json:"path_template"`
}

// Command is one <noun> <verb> leaf of the CLI tree = one API call. ScopedPrefix,
// Source, and Since are optional/additive.
type Command struct {
	ID       string `json:"id"`
	Noun     string `json:"noun"`
	Verb     string `json:"verb"`
	Summary  string `json:"summary"`
	HTTP     HTTP   `json:"http"`
	AuthTier string `json:"auth_tier"`
	Args     []Arg  `json:"args"`
	Flags    []Flag `json:"flags"`
	Writes   bool   `json:"writes"`
	// WritesDeclared reports whether the decoded manifest document AFFIRMATIVELY
	// carried a `writes` key for this command. It is the second half of a
	// TRI-STATE — {declared-writing, declared-non-writing, UNDECLARED} — that a
	// plain bool cannot express, and it is set only by Command.UnmarshalJSON,
	// never by the wire (json:"-": the JSON shape is unchanged).
	//
	// Read it through Command.NonWriting, not directly, for any decision whose
	// safe default on UNKNOWN is "refuse".
	WritesDeclared bool    `json:"-"`
	Batch          bool    `json:"batch"`
	Paginated      bool    `json:"paginated"`
	DryRun         bool    `json:"dry_run"`
	DefaultOutput  string  `json:"default_output"`
	ScopedPrefix   *string `json:"scoped_prefix,omitempty"`
	Source         *string `json:"source,omitempty"`
	Since          *string `json:"since,omitempty"`
	// MutationOp, when set, wraps the body-arg object into a single mutation:
	// `{mutations: [{<MutationOp>: <body>}]}` — turns `doc delete post p1` into a
	// `{delete:{type,id}}` mutate POST. Empty for non-mutation commands.
	MutationOp string `json:"mutation_op,omitempty"`
	// SetKey, when set, nests the `--set` fields under that key in the body
	// instead of merging them flat — `doc patch` needs `{patch:{id,type,set:{…}}}`.
	SetKey string `json:"set_key,omitempty"`
	// Views, when set, declares the response projections this command's route
	// supports (AXI brief views, axi-agent-ergonomics-review R1). The server
	// emits it only when the client opts in with ?views=1 on GET
	// /v1/capabilities, so older servers — and servers predating the views
	// feature — simply omit it and the field stays nil (dormant). A command
	// without a views declaration is full-only forever; the CLI/MCP consumers
	// must never send a ?view= param for it.
	Views *Views `json:"views,omitempty"`
}

// Views is a command's declared response-projection contract (frozen shape,
// charter bp-axi-brief-views decision 2): the supported view names, the
// server-side default when no ?view= is sent, and the view an agent-facing
// consumer (piped CLI, MCP) should request by default. Strict decode: every key
// the server emits is modelled here — an unknown key inside views fails Parse
// exactly like any other structural typo.
type Views struct {
	Supported        []string `json:"supported"`
	Default          string   `json:"default"`
	DefaultForAgents string   `json:"default_for_agents"`
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
	// The decoder reads exactly one value; anything after it (a doubled body, a
	// truncated-then-retried response, trailing garbage) must fail loud rather
	// than be silently dropped.
	if err := dec.Decode(new(struct{})); err != io.EOF {
		return nil, fmt.Errorf("parse manifest: trailing data after document")
	}
	// Value validation at the trust boundary: reject the WHOLE manifest if any
	// noun name or command verb carries a character outside the shell-safe
	// identifier charset, so a hostile name can never reach the eval'd completion
	// emitters (or argv/path construction). See safeName's doc comment.
	for _, n := range m.Nouns {
		if !safeName.MatchString(n.Name) {
			return nil, fmt.Errorf("parse manifest: unsafe noun name %q (must match %s)", n.Name, safeName)
		}
	}
	for _, c := range m.Commands {
		// Command.Noun is validated alongside Verb: Tree() synthesizes a noun
		// node from cmd.Noun for any command whose noun was not declared in
		// m.Nouns (tree.go), and that synthesized node name flows into the same
		// eval'd completion emitters — so a hostile Command.Noun would bypass a
		// Noun.Name-only check.
		if !safeName.MatchString(c.Noun) {
			return nil, fmt.Errorf("parse manifest: unsafe command noun %q (must match %s)", c.Noun, safeName)
		}
		if !safeName.MatchString(c.Verb) {
			return nil, fmt.Errorf("parse manifest: unsafe command verb %q (must match %s)", c.Verb, safeName)
		}
	}
	return &m, nil
}
