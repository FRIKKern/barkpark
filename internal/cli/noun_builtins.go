package cli

import (
	"sort"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// noun_builtins.go — THE dispatch table for verb-level CLI built-ins.
//
// THE HOLE THIS CLOSES. `bp task create` has existed for months as a
// client-side built-in intercepted in cli.go's Execute switch, while
// `bp task --help` and `bp capabilities` are both rendered from the SERVER
// manifest — which has no `create` verb under `task`. So the front door was
// invisible from every surface an agent is told to read: readers concluded the
// verb did not exist and filed tasks through a raw `doc mutate`, landing drafts
// (task-b2f6e594819f9ae7, routed from the rot on task-cc83c7e8daef09a5).
//
// THE RULE. A verb the CLI dispatches under a noun is registered HERE, and
// Execute dispatches it by looking it up here — so the help renderer and the
// dispatcher read the SAME table and cannot drift. Nothing hand-lists built-ins
// for display: usageNoun (usage.go) appends builtinVerbLines(noun) under the
// manifest verbs, and `bp capabilities` points at it. The drift guard
// TestDispatchedVerbLiteralsAreRegisteredOrManifest (noun_builtins_test.go)
// keeps a future hand-written `if verb == "…"` intercept from re-opening the
// hole: every verb literal in cli.go's dispatch must be EITHER registered here
// (help lists it as a built-in) OR a real manifest verb of that noun (help
// lists it from the manifest). There is no exemption list — both branches are
// self-justifying.
//
// WHOLE-NOUN built-ins (`bp tasks`, `bp cmux`, `bp paper`, …) are NOT in this
// table: their noun is not a manifest noun and they own their whole help. This
// table is only for the verb LEVEL — a verb under a noun whose help is rendered
// somewhere else.

// nounBuiltin is one CLI-native verb dispatched under a noun. Summary is what
// the noun's help prints beside the verb; keep it one line, imperative, and
// honest about what the built-in does that the manifest path cannot.
type nounBuiltin struct {
	Noun    string
	Verb    string
	Summary string

	// When, when non-nil, gates the intercept: the built-in fires only if it
	// returns true, otherwise the verb falls through to the manifest dispatch.
	// This is how `task next --frontier` shadows nothing — a bare
	// `bp task next <worker>` still rides the server's claim endpoint.
	When func(g globals, tail []string) bool

	// GateHint is the flag that makes a gated entry fire, for DISPLAY only —
	// `bp capabilities` names built-ins in one compact line and a gated verb
	// that also exists in the manifest (task next) would read as a duplicate
	// without it. Purely cosmetic: dispatch consults When, never this.
	GateHint string

	// Run executes the built-in. tail is everything after `<noun> <verb>`.
	Run func(out *writer, g globals, ctx manifest.Context, tail []string) int
}

// label is how one built-in is named in a compact list: `task create`, or
// `task next --frontier` for a gated entry.
func (b nounBuiltin) label() string {
	if b.GateHint != "" {
		return b.Noun + " " + b.Verb + " " + b.GateHint
	}
	return b.Noun + " " + b.Verb
}

// nounBuiltins is the registry Execute dispatches from and the noun help
// renders from. Registration order is the display order within a noun.
var nounBuiltins = []nounBuiltin{
	{
		Noun:    "task",
		Verb:    "create",
		Summary: "File a new task — injects the schema's required kind/lifecycle_status defaults.",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runTaskCreate(out, g, ctx, tail)
		},
	},
	{
		Noun:    "task",
		Verb:    "frontier",
		Summary: "The dispatch frontier: ready tasks whose blast radii do not collide.",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runTaskFrontier(out, g, ctx, tail)
		},
	},
	{
		Noun:    "task",
		Verb:    "lint",
		Summary: "Advisory nudge: workable leaves carrying no authored area: label (always exits 0).",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runTaskLint(out, g, ctx, tail)
		},
	},
	{
		Noun:    "task",
		Verb:    "tui",
		Summary: "Open the live portrait task board (the same reader as `bp tasks`).",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runTasksBoard(out, g, ctx, tail)
		},
	},
	{
		Noun:     "task",
		Verb:     "next",
		Summary:  "With --frontier: claim the top NON-COLLIDING ready pick (a bare `next` is the manifest verb).",
		GateHint: "--frontier",
		When:     func(g globals, tail []string) bool { return hasFlag(tail, "--frontier") },
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			worker, fopts, err := parseNextFrontierArgs(tail)
			if err != nil {
				return usageErrf(out, func() { printTaskFrontierHelp(out) }, "%v", err)
			}
			return runTaskNextFrontier(out, g, ctx, worker, fopts)
		},
	},
	{
		Noun:    "server",
		Verb:    "ls",
		Summary: "List saved servers (the singular-noun spelling of `bp servers`).",
		Run:     func(out *writer, g globals, ctx manifest.Context, tail []string) int { return runServers(out, tail) },
	},
	{
		Noun:    "mcp",
		Verb:    "serve",
		Summary: "Run a stdio Model-Context-Protocol server exposing Barkpark to MCP clients.",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runMCPServe(out, g, ctx, tail)
		},
	},
	{
		Noun:    "context",
		Verb:    "pack",
		Summary: "Pack files into an optical context bundle (PNG pages + a verbatim sidecar).",
		Run: func(out *writer, g globals, ctx manifest.Context, tail []string) int {
			return runContextPack(out, g, tail)
		},
	},
}

// lookupNounBuiltin returns the built-in Execute must run for (noun, verb),
// honouring a gated entry's When predicate. This is the ONLY dispatch path for
// verb-level built-ins — the help renderer reads the same slice, so a verb that
// runs is a verb that prints.
func lookupNounBuiltin(noun, verb string, g globals, tail []string) (nounBuiltin, bool) {
	if verb == "" {
		return nounBuiltin{}, false
	}
	for _, b := range nounBuiltins {
		if b.Noun != noun || b.Verb != verb {
			continue
		}
		if b.When != nil && !b.When(g, tail) {
			continue
		}
		return b, true
	}
	return nounBuiltin{}, false
}

// builtinVerbsFor returns the built-ins registered under noun, in registration
// order. Empty for a noun that carries none.
func builtinVerbsFor(noun string) []nounBuiltin {
	var out []nounBuiltin
	for _, b := range nounBuiltins {
		if b.Noun == noun {
			out = append(out, b)
		}
	}
	return out
}

// builtinNounNames returns the sorted set of nouns carrying at least one
// verb-level built-in. `bp capabilities` names them so a reader of the manifest
// learns, in one line, that these nouns carry verbs the manifest does not.
func builtinNounNames() []string {
	seen := map[string]bool{}
	var names []string
	for _, b := range nounBuiltins {
		if seen[b.Noun] {
			continue
		}
		seen[b.Noun] = true
		names = append(names, b.Noun)
	}
	sort.Strings(names)
	return names
}

// builtinVerbLines renders the noun's built-in block for a help surface: a
// header naming what these verbs ARE, then one aligned line per verb. Empty
// when the noun carries no built-in, so a caller can append it unconditionally.
// Shared by usageNoun (manifest nouns) and printServerNounHelp so the two can
// never disagree on the wording.
func builtinVerbLines(noun string) []string {
	bs := builtinVerbsFor(noun)
	if len(bs) == 0 {
		return nil
	}
	lines := []string{"built-ins (CLI-native — dispatched by bp, not declared by the server manifest):"}
	for _, b := range bs {
		lines = append(lines, fmtVerbLine(b.Verb, b.Summary))
	}
	return lines
}

// fmtVerbLine matches usageNoun's manifest-verb column so the built-in block
// reads as one continuous list with the verbs above it.
func fmtVerbLine(verb, summary string) string {
	return "  " + padRight(verb, 16) + " " + summary
}

// builtinPointerLine is the ONE line `bp capabilities` machine output prints on
// STDERR — stdout stays byte-identical, so every script and every brief-manifest
// parser is untouched, while an agent that was told "read capabilities, don't
// guess" learns in one line that these verbs exist and where they are listed.
// The manifest contract is not touched at all: no new key, no server change.
func builtinPointerLine() string {
	if len(nounBuiltins) == 0 {
		return ""
	}
	labels := make([]string, 0, len(nounBuiltins))
	for _, b := range nounBuiltins {
		labels = append(labels, "`bp "+b.label()+"`")
	}
	return "note: " + strconv.Itoa(len(nounBuiltins)) + " CLI built-in verbs are NOT in this manifest — " +
		strings.Join(labels, ", ") + ". Run `bp <noun> --help` (e.g. `bp task --help`) to see them listed per noun."
}

// builtinCapabilityLines renders the built-ins section for `bp capabilities`'s
// human output — the "clearly separate key" half of the same fix, in the column
// layout of the commands list right above it.
func builtinCapabilityLines() []string {
	if len(nounBuiltins) == 0 {
		return nil
	}
	lines := []string{"cli built-ins (dispatched by bp, NOT declared by this manifest — see `bp <noun> --help`):"}
	for _, b := range nounBuiltins {
		verb := b.Verb
		if b.GateHint != "" {
			verb += " " + b.GateHint
		}
		lines = append(lines, "  "+padRight(b.Noun, 10)+" "+padRight(verb, 16)+" "+b.Summary)
	}
	return lines
}

// printServerNounHelp answers `bp server --help`. `server` is not a manifest
// noun (the noun is `servers`), so nothing else would ever print its one
// built-in verb — without this, `bp server ls` runs but is unlisted everywhere,
// which is exactly the defect this file exists to close.
func printServerNounHelp(out *writer) {
	out.errf("usage: barkpark server <verb> [args]")
	out.errf("  Saved-server aliases. `server` is not a manifest noun.")
	out.errf("")
	for _, line := range builtinVerbLines("server") {
		out.errf("%s", line)
	}
}
