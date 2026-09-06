package cli

import (
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// BRIEF-KEEP-LIST v1 — the born-brief projection of the capabilities manifest
// (ctx-compression charter decisions 3, 6; task ctx-s1-brief-manifest).
//
// `bp capabilities` piped output is the single largest first-party payload an
// agent session swallows (95.9 KB full, 142 commands) and every byte re-bills
// on later turns. This file projects the manifest to an INVOKE-COMPLETE brief
// at the exact seam where the payload enters context — the print in
// runCapabilities — cutting ~3.6x while keeping everything needed to compose
// any command: noun, verb, summary, auth_tier, writes, every arg
// (name/type/required), every flag (name/type).
//
// The spec pins FIELDS *and* ENCODING (identical fields span 2.07–4.47x by
// encoding alone): array-of-tuples JSON with a legend header. Tuples-JSON is
// STRUCTURALLY collision-free — TSV/packed encodings are only data-dependently
// safe and a future re-add of a defaulted flag would break them silently —
// while staying one `json.loads` away from a dict.
//
// CUT (recoverable via --full, never truth-bearing for invocation): the nouns
// catalog; per-command http, id, mutation_op, set_key, scoped_prefix,
// default_output, dry_run, batch, source, paginated, views, since; arg
// summaries + in; flag summaries, defaults, repeatable.
//
// Server-portable: a later server-side ?view=brief adopts this shape verbatim.
// Nothing here touches the wire, the schema, or the fetch/cache path — the CLI
// still always fetches and caches the FULL manifest; only the print changes.

// briefLegend names the tuple positions so the brief is self-describing: a
// consumer reads legend.command once and indexes every command tuple by it.
// Field order here IS the tuple order in briefCommandTuple — the legend pin
// test (TestBriefManifestLegendPin) and the invoke-completeness test hold the
// two together.
type briefLegend struct {
	Command []string `json:"command"`
	Arg     []string `json:"arg"`
	Flag    []string `json:"flag"`
}

// briefLegendKey is the top-level key that MARKS a document as the rendered
// brief. It is the briefDoc.Legend json tag, restated as a const because a Go
// struct tag cannot reference one — TestBriefLegendKeyMatchesRender pins the
// two together. The manifest FILE loader (renderedBriefView, load.go) reads
// this key to tell an operator they handed it the rendering instead of the
// manifest, so a rename here without a rename there silently returns the old
// internal-field-name error.
const briefLegendKey = "legend"

// briefDoc is the top-level BRIEF-KEEP-LIST v1 document. Typed (not a map) so
// the JSON key order is pinned by the struct and two renders of the same
// manifest are byte-identical.
type briefDoc struct {
	ManifestVersion string          `json:"manifest_version"`
	Server          manifest.Server `json:"server"`
	AuthTier        string          `json:"auth_tier"`
	ETag            string          `json:"etag"`
	Legend          briefLegend     `json:"legend"`
	Commands        [][]any         `json:"commands"`
}

// briefManifest projects m into BRIEF-KEEP-LIST v1. It is a PURE function of
// the manifest: commands, args, and flags keep their manifest source order
// (source-order stable per the charter), no sorting, no I/O, no globals — so
// determinism reduces to encoding/json's (deterministic over these types).
func briefManifest(m *manifest.Manifest) any {
	commands := make([][]any, 0, len(m.Commands))
	for _, c := range m.Commands {
		args := make([][]any, 0, len(c.Args))
		for _, a := range c.Args {
			args = append(args, []any{a.Name, a.Type, a.Required})
		}
		flags := make([][]any, 0, len(c.Flags))
		for _, f := range c.Flags {
			flags = append(flags, []any{f.Name, f.Type})
		}
		commands = append(commands, []any{c.Noun, c.Verb, c.Summary, c.AuthTier, c.Writes, args, flags})
	}
	return briefDoc{
		ManifestVersion: m.ManifestVersion,
		Server:          m.Server,
		AuthTier:        m.AuthTier,
		ETag:            m.ETag,
		Legend: briefLegend{
			Command: []string{"noun", "verb", "summary", "auth_tier", "writes", "args", "flags"},
			Arg:     []string{"name", "type", "required"},
			Flag:    []string{"name", "type"},
		},
		Commands: commands,
	}
}
