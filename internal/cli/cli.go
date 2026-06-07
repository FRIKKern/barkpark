// Package cli is the manifest-driven command layer for the barkpark binary.
//
// The SAME binary serves the interactive TUI (invoked with no args) and this
// CLI (invoked as `barkpark <noun> <verb> …`). main() routes to Execute when
// any positional arg is present; otherwise the TUI launches unchanged.
//
// Nothing in this package hardcodes a noun, verb, or route. The command tree is
// a pure function of the capabilities manifest (manifest.Tree); dispatch fills
// the per-command http.path_template via manifest.BuildURL. A future plugin that
// adds a noun/command appears in the CLI with zero code change here. Only a tiny
// set of CLI-native built-ins (capabilities, whoami, version, login, completion)
// live outside the manifest.
//
// Why hand-rolled instead of cobra: the command tree is *dynamic* — it is built
// at runtime from whatever manifest the server (or an override file) returns.
// cobra wants a static command graph registered at init; a manifest-driven
// dispatcher is the simpler fit and keeps the dependency surface at zero new
// modules. See the dispatch path in Execute below.
package cli

import (
	"os"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Exit codes — the stable scheme from docs/cli/error-exit-table.md. Codes 0–5
// are byte-identical to the published handbook; 6–8 are additive.
const (
	exitOK         = 0 // success
	exitGeneric    = 1 // other / network / timeout / unknown code fallback
	exitUsage      = 2 // bad args / unknown command / malformed request
	exitAuth       = 3 // missing/invalid credential or insufficient permission
	exitNotFound   = 4 // resource or schema does not exist
	exitValidation = 5 // payload failed schema/op validation
	exitConflict   = 6 // optimistic-concurrency / write-conflict / precondition
	exitRateLimit  = 7 // throttled
	exitServer     = 8 // server-side 5xx / internal_error
)

// Execute is the CLI entry point. args is os.Args[1:]. It returns the process
// exit code; main() passes it straight to os.Exit. Execute never calls os.Exit
// itself so it stays unit-testable.
func Execute(args []string) int {
	out := newWriter(os.Stdout, os.Stderr)

	g, rest, err := parseGlobals(args)
	if err != nil {
		out.errf("barkpark: %v", err)
		usageTop(out)
		return exitUsage
	}
	out.applyGlobals(g)

	if g.help && len(rest) == 0 {
		usageTop(out)
		return exitOK
	}
	if len(rest) == 0 {
		// No noun: a bare `barkpark -v` etc. Print top usage.
		usageTop(out)
		return exitUsage
	}

	noun := rest[0]
	verb := ""
	var tail []string
	if len(rest) > 1 {
		verb = rest[1]
		tail = rest[2:]
	}

	// Resolve the target context (flags > env > active > defaults).
	ctx := resolveContext(g)

	// Built-ins are CLI-native and do not consult the manifest tree for
	// dispatch (capabilities/version need no command; whoami composes /v1/meta
	// + the manifest's caller auth_tier).
	switch noun {
	case "version":
		return runVersion(out, g)
	case "completion":
		return runCompletion(out)
	case "login":
		return runLogin(out, ctx)
	case "capabilities":
		return runCapabilities(out, g, ctx)
	case "whoami":
		return runWhoami(out, g, ctx)
	case "help":
		// `barkpark help [noun]` — surface usage; manifest-driven below if loaded.
	}

	// Acquire the manifest (override file > cache/fetch).
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.errf("barkpark: %v", err)
		return exitGeneric
	}
	tree := m.Tree()

	if noun == "help" {
		usageTreeTop(out, m, tree)
		return exitOK
	}

	if verb == "" || g.help {
		// `barkpark <noun>` or `barkpark <noun> -h` → list the noun's verbs.
		if _, ok := lookupNoun(tree, noun); !ok {
			out.errf("barkpark: unknown command %q", noun)
			usageSuggestNouns(out, tree)
			return exitUsage
		}
		usageNoun(out, tree, noun)
		if verb == "" {
			return exitUsage // a noun with no verb is incomplete usage
		}
		return exitOK
	}

	cmd, ok := tree.Lookup(noun, verb)
	if !ok {
		out.errf("barkpark: unknown command %q %q", noun, verb)
		if _, nounOK := lookupNoun(tree, noun); nounOK {
			usageNoun(out, tree, noun)
		} else {
			usageSuggestNouns(out, tree)
		}
		return exitUsage
	}

	return runCommand(out, g, ctx, m, *cmd, tail)
}

// resolveContext composes the manifest.Context from globals + env + defaults.
// Env is read through apiclient.ConfigFromEnv so the CLI and TUI share one
// BARKPARK_* contract. Flags win over env; the baked DefaultDefaults are the
// floor.
func resolveContext(g globals) manifest.Context {
	env := apiclient.ConfigFromEnv()

	flags := map[string]string{}
	if g.server != "" {
		flags[manifest.FlagServer] = g.server
	}
	if g.workspace != "" {
		flags[manifest.FlagWorkspace] = g.workspace
	}
	if g.project != "" {
		flags[manifest.FlagProject] = g.project
	}
	if g.dataset != "" {
		flags[manifest.FlagDataset] = g.dataset
	}
	if g.output != "" {
		flags[manifest.FlagOutput] = g.output
	}

	return manifest.Resolve(flags, env, manifest.ActiveContext{}, manifest.DefaultDefaults())
}

// lookupNoun returns the noun node if present.
func lookupNoun(t *manifest.Tree, name string) (*manifest.TreeNoun, bool) {
	for _, n := range t.Nouns {
		if n.Name == name {
			return n, true
		}
	}
	return nil, false
}
