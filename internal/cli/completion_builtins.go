package cli

// completion_builtins.go — THE completion source for CLI-native command trees
// the server manifest cannot describe.
//
// THE HOLE THIS CLOSES. Shell completion (runCompletion in builtins.go) builds
// its per-noun verb map and its per-command flag map EXCLUSIVELY from the
// fetched capabilities manifest, and the baked `completionNouns` list carries
// only TOP-LEVEL nouns. Control-plane verbs are architecturally absent from the
// manifest — `bp cloud …` talks to the Barkpark Cloud control plane, not to a
// content server — so `bp cloud <TAB>` offered nothing past the noun, `bp cloud
// site <TAB>` offered nothing at all, and `--prebuilt` was never completable.
// The existing invariant (TestCompletionNounsCoverAllDispatchedBuiltins) gates
// NOUNS only: it parses cli.go's `switch noun` and never looks one level deeper.
//
// THE RULE. A builtin command path that dispatches sub-tokens is registered
// HERE, keyed by the space-joined path of words that precede the completion
// point. `bp cloud site deploy --<TAB>` looks up "cloud site deploy".
// TestBuiltinCompletionPathsCoverDispatchedCloudTree parses the dispatch
// switches AND the parseHzArgs flag literals out of the source and fails when a
// new verb or flag reaches no completion source — so this table cannot silently
// rot the way the manifest-only path did.
//
// VERB-LEVEL builtins (`bp task create`, `bp context pack`, …) are NOT listed
// here: they already live in ONE registry, nounBuiltins (noun_builtins.go), and
// builtinNounVerbs below reads that registry directly. Two hand lists of the
// same fact is the drift this file exists to prevent.

import "sort"

// builtinCompletionPaths maps a space-joined command prefix to the tokens
// completion offers at the next position. Verbs for a dispatcher path, flags
// for a leaf path. Every value must be sorted (the emitters rely on a stable
// byte-for-byte script) — sortedBuiltinPathKeys/builtinPathCandidates enforce
// order at read time, so a hand edit here cannot destabilise the output.
//
// Aliases are listed alongside their canonical spelling on purpose: the
// invariant is "every literal the dispatcher accepts is completable", and an
// operator who types `bp cloud instances` deserves the same TAB as one who
// types `bp cloud instance`.
var builtinCompletionPaths = map[string][]string{
	// `bp cloud <TAB>` — runCloud's dispatcher (hetzner_cmd.go).
	"cloud": {
		"autoupdate", "azure", "deliveries", "deploy", "deployments", "domain", "domains",
		"hetzner", "instance", "instances", "member", "members", "open", "providers",
		"rollback", "rollout", "site", "sites", "status", "support", "supports",
		"token", "tokens", "update",
		"usage", "verify", "webhook", "webhooks", "workspace", "workspaces",
	},

	// `bp cloud token <TAB>` — the PAT verbs. The aliases (create/list/rm) are
	// deliberately NOT offered: one spelling per action keeps the completion a
	// teaching surface rather than a menu of synonyms.
	"cloud token": {"mint", "ls", "revoke"},

	// `bp cloud site <TAB>` / `bp cloud sites <TAB>` — every verb in the SITE
	// COMMAND MATRIX (site_verb_matrix.go), which both `bp cloud site` and the
	// top-level `bp sites` dispatch through. The plural spelling is a dispatcher
	// alias, so it carries the identical verb list.
	"cloud site": {
		"build", "create", "delete", "deploy", "deployments", "deploys",
		"doctor", "domain", "domains", "env", "get", "github", "list", "log",
		"logs", "ls", "matrix", "open", "preflight", "rm", "rollback",
		"settings", "show", "status",
	},
	"cloud sites": {
		"build", "create", "delete", "deploy", "deployments", "deploys",
		"doctor", "domain", "domains", "env", "get", "github", "list", "log",
		"logs", "ls", "matrix", "open", "preflight", "rm", "rollback",
		"settings", "show", "status",
	},

	// Per-verb flags. Sourced from each handler's parseHzArgs declaration; the
	// invariant test re-reads those declarations and reds on a new flag that
	// never reached this table.
	"cloud site create": {
		"--dataset", "--deploy", "--doc-type", "--framework", "--instance",
		"--kind", "--name", "--template", "--theme",
	},
	"cloud site deploy": {
		"--deployment", "--domain", "--force", "--no-follow", "--prebuilt",
		"--via", "--wait-for-live",
	},
	"cloud site build": {
		"--deployment", "--domain", "--force", "--no-follow", "--prebuilt",
		"--via", "--wait-for-live",
	},
	"cloud site delete":    {"--yes"},
	"cloud site rm":        {"--yes"},
	"cloud site open":      {"--print-only"},
	"cloud site preflight": {"--dir", "--skip-build"},
	"cloud site settings":  {"--doc-type", "--prebuilt-enabled", "--theme"},
	"cloud site status":    {"--window"},
}

// builtinNounVerbs derives noun -> verbs from the nounBuiltins registry — the
// SAME slice Execute dispatches from and every help surface renders from. No
// hand list: a built-in registered there is completable the moment it is
// registered, and one that is removed stops being offered.
func builtinNounVerbs() map[string][]string {
	vm := make(map[string][]string)
	for _, b := range nounBuiltins {
		vm[b.Noun] = append(vm[b.Noun], b.Verb)
	}
	for n, verbs := range vm {
		vm[n] = dedupeSorted(verbs)
	}
	return vm
}

// builtinPathCandidates returns the sorted, deduped tokens offered after the
// given space-joined prefix, or nil when the prefix carries none. A one-word
// prefix ALSO picks up the verb-level builtins registered under that noun, so
// `bp task <TAB>` offers `create`/`frontier`/… beside the manifest verbs.
func builtinPathCandidates(prefix string) []string {
	var toks []string
	toks = append(toks, builtinCompletionPaths[prefix]...)
	if !hasSpace(prefix) {
		toks = append(toks, builtinNounVerbs()[prefix]...)
	}
	if len(toks) == 0 {
		return nil
	}
	return dedupeSorted(toks)
}

// sortedBuiltinPathKeys is every prefix carrying builtin completions —
// registered paths plus the nouns from the nounBuiltins registry — sorted so
// the generated scripts stay byte-stable across runs.
func sortedBuiltinPathKeys() []string {
	seen := map[string]bool{}
	var keys []string
	for k := range builtinCompletionPaths {
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	for n := range builtinNounVerbs() {
		if !seen[n] {
			seen[n] = true
			keys = append(keys, n)
		}
	}
	sort.Strings(keys)
	return keys
}

// hasSpace reports whether s carries a path separator (a multi-word prefix).
func hasSpace(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' {
			return true
		}
	}
	return false
}

// dedupeSorted sorts and de-duplicates in one pass.
func dedupeSorted(xs []string) []string {
	seen := make(map[string]bool, len(xs))
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		if seen[x] {
			continue
		}
		seen[x] = true
		out = append(out, x)
	}
	sort.Strings(out)
	return out
}
