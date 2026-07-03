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
	out.errf("  -s, --server <name|url> API base URL or a saved server name (see 'bp servers')")
	out.errf("      --token <tok>      bearer token (overrides a named server's saved token)")
	out.errf("  -w <slug>              workspace")
	out.errf("  -p <slug>              project")
	out.errf("  -d, --dataset <name>   dataset (default production)")
	out.errf("  -o, --output <fmt>     table | json | yaml | minimal")
	out.errf("      --json             shorthand for -o json")
	out.errf("  -q                     minimal receipt (writes: rev + ids)")
	out.errf("  -v                     verbose (diagnostics on stderr)")
	out.errf("      --no-color         disable colour")
	out.errf("      --set <k=v>        write body field (repeatable); --file <path>|- for JSON")
	out.errf("  -f <path>              alias for --file (JSON body from a file or '-' for stdin)")
	out.errf("      --dry-run          print the request, do not send")
	out.errf("      --yes              skip the prod write confirmation")
	out.errf("      --limit/--offset/--all   pagination")
	out.errf("      --manifest <path>  load the manifest from a file (offline)")
	out.errf("")
	out.errf("built-ins: use · servers · migrate · export · paper · vercel · tinker · seed · make · capabilities · whoami · version · upgrade · uninstall · signup · login · completion")
	out.errf("")
	out.errf("server switching:")
	out.errf("  bp servers             list saved servers (★ = active)")
	out.errf("  bp use <name|url>      make a saved server active (instant, no network)")
	out.errf("  bp -s <name> <cmd>     run one command against a saved server")
	out.errf("")
	out.errf("data migration:")
	out.errf("  bp migrate <from> <to> copy documents server→server (dry-run by default;")
	out.errf("                         --yes to execute; cloud target needs --yes + ⚠)")
	out.errf("  bp export [--type T]   stream the active dataset as NDJSON to stdout")
	out.errf("                         (backup: bp export > backup.ndjson; --perspective p)")
	out.errf("")
	out.errf("papers:")
	out.errf("  bp paper view <slug>   render a Bulldocs paper to the terminal (the CLI")
	out.errf("                         counterpart to opening it in the browser)")
	out.errf("")
	out.errf("new-site deploy:")
	out.errf("  bp vercel quick-setup --site <slug> --app-dir <path>")
	out.errf("                         provision a workspace + schema + seed + read token,")
	out.errf("                         then link/env/deploy to Vercel (--no-deploy to stop early)")
	out.errf("")
	out.errf("schema authoring + local dev:")
	out.errf("  bp make schema <name>  print a fill-the-blanks schema v2 JSON skeleton")
	out.errf("  bp seed <type> [--count N]   fabricate sample documents as drafts")
	out.errf("  bp tinker [--dataset <d>]    interactive REPL (query/doc/mutate) on a dataset")
	out.errf("")
	out.errf("Barkpark Cloud (requires bp login):")
	out.errf("  bp barkparks           list every Barkpark in your fleet")
	out.errf("  bp launch hetzner --name <n>    provision a Barkpark into a connected provider")
	out.errf("  bp go-live --name <n>           provision a fully-managed Barkpark")
	out.errf("  bp sites               list / create / inspect hosted sites running on a Barkpark")
	out.errf("  bp deploy <site> --artifact-url <url>   enqueue a build for a hosted site")
	out.errf("")
	out.errf("direct provider control (your own credentials, no control plane):")
	out.errf("  bp cloud hetzner <resource> <verb>   servers / ssh-keys / images / pricing")
	out.errf("                         straight against the Hetzner API (bp cloud hetzner -h)")
	out.errf("")
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

	// Positional args carry a `summary` in the manifest, but the signature line
	// above shows only their names — so on a usage error (missing/misordered
	// arg) the user never learns what each one MEANS. Surface the descriptions,
	// mirroring the flags block. Rendered only when at least one arg has a
	// summary, to avoid an empty header for summary-less commands.
	if anyArgSummary(cmd.Args) {
		out.errf("")
		out.errf("arguments:")
		for _, a := range cmd.Args {
			out.errf("  %-16s %s", a.Name, a.Summary)
		}
	}

	// A manifest write command takes its body from --set/--file/-f, but that is
	// carried by the generic flag machinery, not the per-command Flags list — so
	// without this line `bp doc create -h` shows a signature with no hint of HOW
	// to supply the document. Surface it right under the summary, before flags.
	if cmd.Writes {
		out.errf("")
		out.errf("body: --set key=value (repeatable) | --file <path>|-  (JSON from a file or stdin)")
	}

	if len(cmd.Flags) > 0 {
		out.errf("")
		out.errf("flags:")
		for _, f := range cmd.Flags {
			// A bool flag takes no value; everything else does. Show a <value>
			// placeholder for value flags so the two are distinguishable, matching
			// the native surfaces' `--name <value>` style.
			name := f.Name
			if f.Type != "bool" {
				name = f.Name + " <value>"
			}
			out.errf("  --%-14s %s", name, f.Summary)
		}
	}

	// Manifest commands don't list the generic pagination/write globals in their
	// per-command Flags, so surface the ones relevant to this command's kind.
	if cmd.Paginated {
		out.errf("")
		out.errf("pagination: --limit <n> · --offset <n> · --all")
	}
	if cmd.Writes {
		out.errf("")
		out.errf("write globals: --dry-run (print the request, don't send) · --yes (skip the prod confirmation)")
	}
}

func anyArgSummary(args []manifest.Arg) bool {
	for _, a := range args {
		if a.Summary != "" {
			return true
		}
	}
	return false
}

// usageSuggestNouns prints a "did you mean?" hint for the closest known noun
// (when the typed noun looks like a typo), then the full noun list.
func usageSuggestNouns(out *writer, tree *manifest.Tree, typed string) {
	nouns := tree.NounNames()
	if best, ok := nearestNoun(typed, nouns); ok {
		out.errf("did you mean `barkpark %s`?", best)
	}
	out.errf("known nouns: %s", strings.Join(nouns, ", "))
	out.errf("run `barkpark capabilities` for the full command list.")
}

// usageSuggestVerb prints a "did you mean?" hint for the closest verb under a
// known noun (when the typed verb looks like a typo), then the noun's full verb
// list. It is usageSuggestNouns one level down the tree.
func usageSuggestVerb(out *writer, tree *manifest.Tree, noun, typedVerb string) {
	if n, ok := lookupNoun(tree, noun); ok {
		verbs := make([]string, 0, len(n.Verbs))
		for _, c := range n.Verbs {
			verbs = append(verbs, c.Verb)
		}
		if best, ok := nearestVerb(typedVerb, verbs); ok {
			out.errf("did you mean `barkpark %s %s`?", noun, best)
		}
	}
	usageNoun(out, tree, noun)
}

// nearestNoun returns the known noun closest to typed by Levenshtein distance,
// when that distance is small enough to be a likely typo. Returns ("", false)
// when nothing is close, so an unrelated word doesn't get a misleading hint.
func nearestNoun(typed string, nouns []string) (string, bool) {
	return nearestToken(typed, nouns)
}

// nearestVerb returns the verb closest to typed by Levenshtein distance, using
// the same likely-typo threshold as nearestNoun. Powers the verb-level "did you
// mean?" hint when a known noun is followed by a mistyped verb.
func nearestVerb(typed string, verbs []string) (string, bool) {
	return nearestToken(typed, verbs)
}

// nearestToken is the shared edit-distance matcher behind the noun- and
// verb-level "did you mean?" hints. It returns the candidate closest to typed
// when that distance is small enough to be a likely typo, and ("", false)
// otherwise so an unrelated word never gets a misleading hint.
func nearestToken(typed string, candidates []string) (string, bool) {
	best := ""
	bestDist := 1 << 30
	for _, c := range candidates {
		if d := levenshtein(typed, c); d < bestDist {
			bestDist, best = d, c
		}
	}
	maxDist := 2
	if len(typed) < 4 {
		maxDist = 1
	}
	if best != "" && bestDist <= maxDist && bestDist < len(typed) {
		return best, true
	}
	return "", false
}

// levenshtein is the classic edit distance over bytes (noun names are ASCII).
func levenshtein(a, b string) int {
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}
	prev := make([]int, lb+1)
	for j := 0; j <= lb; j++ {
		prev[j] = j
	}
	for i := 1; i <= la; i++ {
		cur := make([]int, lb+1)
		cur[0] = i
		for j := 1; j <= lb; j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(cur[j-1]+1, min(prev[j]+1, prev[j-1]+cost))
		}
		prev = cur
	}
	return prev[lb]
}

func sortedVerbs(n *manifest.TreeNoun) []*manifest.Command {
	verbs := make([]*manifest.Command, len(n.Verbs))
	copy(verbs, n.Verbs)
	sort.Slice(verbs, func(i, j int) bool { return verbs[i].Verb < verbs[j].Verb })
	return verbs
}
