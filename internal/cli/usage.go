package cli

import (
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// usageTop prints the top-level usage without a manifest (the earliest error
// path, before the tree is loaded).
func usageTop(out *writer) {
	out.errf("barkpark — headless CMS client (TUI with no args, CLI with a command)")
	out.errf("")
	out.errf("usage: barkpark [global flags] <noun> <verb> [args] [flags]")
	out.errf("       barkpark                       launch the interactive TUI")
	out.errf("")
	out.errf("global flags:")
	out.errf("  -s, --server <url>     API base URL")
	out.errf("  -w <slug>              workspace")
	out.errf("  -p <slug>              project")
	out.errf("  -d, --dataset <name>   dataset (default production)")
	out.errf("  -o, --output <fmt>     table | json | yaml | minimal")
	out.errf("      --json             shorthand for -o json")
	out.errf("  -q                     minimal receipt (writes: rev + ids)")
	out.errf("  -v                     verbose (diagnostics on stderr)")
	out.errf("      --no-color         disable colour")
	out.errf("      --dry-run          print the request, do not send")
	out.errf("      --yes              skip the prod write confirmation")
	out.errf("      --limit/--offset/--all   pagination")
	out.errf("      --manifest <path>  load the manifest from a file (offline)")
	out.errf("")
	out.errf("built-ins: capabilities · whoami · version · login · completion")
	out.errf("run `barkpark capabilities` to list manifest commands.")
}

// usageTreeTop lists every manifest command grouped by noun.
func usageTreeTop(out *writer, m *manifest.Manifest, tree *manifest.Tree) {
	out.outf("barkpark commands (server %s, tier %s):", m.Server.Name, m.AuthTier)
	out.outf("")
	for _, name := range tree.NounNames() {
		n, _ := lookupNoun(tree, name)
		out.outf("%s — %s", n.Name, n.Summary)
		for _, c := range sortedVerbs(n) {
			out.outf("  %-16s %s", c.Verb, c.Summary)
		}
		out.outf("")
	}
}

// usageNoun lists the verbs under one noun.
func usageNoun(out *writer, tree *manifest.Tree, noun string) {
	n, ok := lookupNoun(tree, noun)
	if !ok {
		return
	}
	out.errf("usage: barkpark %s <verb> [args]", noun)
	if n.Summary != "" {
		out.errf("  %s", n.Summary)
	}
	out.errf("")
	out.errf("verbs:")
	for _, c := range sortedVerbs(n) {
		out.errf("  %-16s %s", c.Verb, c.Summary)
	}
}

// usageCommand prints the arg/flag signature of one command.
func usageCommand(out *writer, cmd manifest.Command) {
	var sig strings.Builder
	sig.WriteString("usage: barkpark ")
	sig.WriteString(cmd.Noun)
	sig.WriteString(" ")
	sig.WriteString(cmd.Verb)
	for _, a := range cmd.Args {
		if a.Required {
			sig.WriteString(" <" + a.Name + ">")
		} else {
			sig.WriteString(" [" + a.Name + "]")
		}
	}
	out.errf("%s", sig.String())
	if cmd.Summary != "" {
		out.errf("  %s", cmd.Summary)
	}
	if len(cmd.Flags) > 0 {
		out.errf("")
		out.errf("flags:")
		for _, f := range cmd.Flags {
			out.errf("  --%-14s %s", f.Name, f.Summary)
		}
	}
}

// usageSuggestNouns lists known noun names after an unknown-command error.
func usageSuggestNouns(out *writer, tree *manifest.Tree) {
	out.errf("known nouns: %s", strings.Join(tree.NounNames(), ", "))
	out.errf("run `barkpark capabilities` for the full command list.")
}

func sortedVerbs(n *manifest.TreeNoun) []*manifest.Command {
	verbs := make([]*manifest.Command, len(n.Verbs))
	copy(verbs, n.Verbs)
	sort.Slice(verbs, func(i, j int) bool { return verbs[i].Verb < verbs[j].Verb })
	return verbs
}
