package cli

import (
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// usageBuiltins is the noun list behind the top-level "built-ins:" usage line —
// the third copy of the CLI-native noun set (dispatch in cli.go, completion in
// builtins.go, this line). It was a hand-maintained prose string until
// 2026-07-17 and drifted 27 nouns behind the dispatch switch (stuck at 19 since
// ba95b12e5, 2026-07-03); now it is a slice so (a) the drift gate
// TestUsageBuiltinsCoverAllDispatchedBuiltins (usage_test.go) reds when a
// dispatched noun is missing here, and (b) scaffy's ensure-cli-noun command can
// append an entry mechanically (comma-safe INSERT after the opening line, same
// shape as completionNouns). Order inside the slice never matters — rendering
// sorts — so entries may accrete at the head.
var usageBuiltins = []string{
	"agent", "attach", "barkparks", "capabilities", "chat", "cloud", "cmux", "completion", "context", "deploy",
	"doctor", "export", "go-live", "help", "instance", "launch", "listen", "login", "logout",
	"make", "mcp", "migrate", "onramp", "paper", "provider", "register", "scaffy", "seed", "server",
	"servers", "setup", "signup", "sites", "style", "subscribe", "task", "tasks", "team", "teams",
	"tinker", "uninstall", "upgrade", "use", "vercel", "version", "whoami",
}

// usageBuiltinLines renders the "built-ins:" block for usageTop: the noun set
// sorted, greedy-wrapped so no emitted line runs past ~100 columns (46 nouns on
// one line would wrap raggedly in any terminal).
func usageBuiltinLines() []string {
	nouns := append([]string(nil), usageBuiltins...)
	sort.Strings(nouns)
	const prefix = "built-ins: "
	const indent = "  "
	const width = 100
	var lines []string
	cur := ""
	for _, n := range nouns {
		if cur == "" {
			cur = n
			continue
		}
		if len(prefix)+len(cur)+len(" · ")+len(n) > width {
			lines = append(lines, cur)
			cur = n
			continue
		}
		cur += " · " + n
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	for i := range lines {
		if i == 0 {
			lines[i] = prefix + lines[i]
		} else {
			lines[i] = indent + lines[i]
		}
	}
	return lines
}

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
	for _, line := range usageBuiltinLines() {
		out.errf("%s", line)
	}
	out.errf("")
	out.errf("tasks:")
	out.errf("  bp tasks               open the live portrait task board (glanceable pane;")
	out.errf("                         the scriptable verbs stay under `bp task …`)")
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
	out.errf("  bp bulldocs publish <slug> --file payload.json")
	out.errf("                         WRITE a paper — a blocks payload, never hand-rolled")
	out.errf("                         HTML. Guide: /papers/paper-authoring-excellence")
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

	// A manifest write command takes its body from --set/--file/-f, but those
	// are PER-COMMAND manifest flags, not universal machinery — `doc patch`
	// declares only [set] and its parser rightly rejects --file. Compose the
	// hint from the flags this command actually declares, so `bp doc create -h`
	// still says HOW to supply the document while help never advertises a flag
	// the parser will refuse. A write with neither flag (body from positional
	// args, e.g. task claim) gets no body line at all.
	if cmd.Writes {
		if hint := writeBodyHint(cmd); hint != "" {
			out.errf("")
			out.errf("body: %s", hint)
		}
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

	// `--match` is honoured entirely client-side (see tasks_match.go), so the
	// manifest cannot declare it and the flags block above cannot show it. A
	// flag nobody can discover is a flag nobody uses — and this one exists
	// precisely because the reader who needs it is following a hint.
	if cmd.ID == taskLsCommandID {
		out.errf("")
		out.errf("search: --match <substring>  case-insensitive over doc_id and title, walks every page")
	}
	if cmd.Writes {
		out.errf("")
		out.errf("write globals: --dry-run (print the request, don't send) · --yes (skip the prod confirmation)")
	}
}

// writeBodyHint composes the body-source hint for a write command from the
// flags its manifest declares. Empty when the command declares neither --set
// nor --file (its body comes from positional args).
func writeBodyHint(cmd manifest.Command) string {
	hasSet := false
	for _, f := range cmd.Flags {
		if f.Name == "set" {
			hasSet = true
			break
		}
	}
	var parts []string
	if hasSet {
		parts = append(parts, "--set key=value (repeatable)")
	}
	if commandHasFileFlag(cmd) {
		parts = append(parts, "--file <path>|-  (JSON from a file or stdin)")
	}
	return strings.Join(parts, " | ")
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

// authHiddenNoun reports whether `typed` names a REAL command that the server
// filtered out of this caller's tier-scoped manifest — the noun exists in the
// product but is invisible to this caller because their AuthTier is too low — as
// opposed to a genuine typo or an unsupported command.
//
// It is true only when ALL hold:
//   - the caller is NOT admin: an admin's manifest is the whole tree, so a noun
//     missing for them is genuinely unknown, never merely hidden (this is what
//     keeps admin callers from ever receiving a false auth-hidden diagnosis);
//   - `typed` is in the baked, non-secret noun catalog (completionNouns, owned by
//     builtins.go) — the client's static knowledge of every command that CAN
//     exist, independent of any one caller's tier;
//   - `typed` is absent from the tier-filtered tree the server actually returned.
//
// This leaks nothing the server hides: it reports only that the non-secret noun
// NAME exists (the baked catalog already ships that list in cleartext) — never a
// hidden verb, arg, or route. The server's existence-hiding of the verbs stays
// intact; the CLI only turns a misleading "unknown command" into "authenticate".
func authHiddenNoun(tree *manifest.Tree, tier, typed string) bool {
	if tier == "admin" {
		return false
	}
	if _, visible := lookupNoun(tree, typed); visible {
		return false
	}
	for _, n := range completionNouns {
		if n == typed {
			return true
		}
	}
	return false
}

// authTierLabel renders an auth tier for a user-facing message, mapping the empty
// tier (no credential presented) to the explicit word "none" so the diagnosis
// never prints a bare "tier=".
func authTierLabel(tier string) string {
	if tier == "" {
		return "none"
	}
	return tier
}

// suggestUnknownNoun renders the diagnosis for an unrecognised TOP-LEVEL noun,
// distinguishing a tier-HIDDEN real command from a genuine typo. When `typed`
// names a baked-catalog noun the server filtered out of this caller's tier tree
// (authHiddenNoun), it reports the command as existing-but-hidden and points at
// `bp login` / --token instead of emitting a misleading "did you mean?" — so a
// hidden noun is also never offered as a typo target, and (because a hidden noun
// is by definition absent from the tree) soleReadVerb up in the dispatch switch
// never sees it to auto-infer its verb. Otherwise it falls back to the ordinary
// noun typo suggestion (usageSuggestNouns / nounHint). Always returns exitUsage.
//
// This is the single classification point wired into every unknown-noun site in
// cli.go's dispatch (help <noun>, bare noun, and noun+token), so the three paths
// can never drift on how they treat a tier-hidden command.
// THE REFUSAL NAMES THE CREDENTIAL IT USED (task-06d3d67167306406). "tier=none,
// run barkpark login" is true and useless when the caller ALREADY has a working
// login and a stale BARKPARK_TOKEN in the shell outranked it: the advice is to
// redo the thing that already works, and nothing on screen says which credential
// produced the tier. prov (resolveContextProv) supplies the missing noun — the
// source label, plus, in the shadow case, the one-line remedy that actually
// restores the command. Anonymous/default callers still see the login advice,
// which for them is correct.
func suggestUnknownNoun(out *writer, tree *manifest.Tree, tier, typed string, prov tokenProvenance) int {
	if authHiddenNoun(tree, tier, typed) {
		label := authTierLabel(tier)
		cred := prov.describe()
		shadow := prov.shadowsSaved()
		return usageErrHintf(out, func() {
			out.errf("`barkpark %s` is a real command, but it is not available at your current auth tier (tier=%s).", typed, label)
			out.errf("credential in use: %s", cred)
			if shadow {
				out.errf("%s", prov.shadowWarning(shadowReasonTierNone))
				out.errf("%s", prov.shadowFix())
				return
			}
			out.errf("run `barkpark login` — or pass `--token <tok>` — with a credential that grants it, then retry.")
		}, tierHiddenHint(prov), tierHiddenMsg(prov), typed, label, cred)
	}
	return usageErrHintf(out, func() { usageSuggestNouns(out, tree, typed) }, nounHint(tree, typed), "unknown command %q", typed)
}

// tierHiddenMsg is the machine-readable refusal for a tier-hidden noun. The
// %q/%s/%s slots are (typed, tier label, credential source) — the credential is
// the field this row added, and it is in BOTH shapes so a JSON consumer and a
// human read the same fact.
func tierHiddenMsg(prov tokenProvenance) string {
	if prov.shadowsSaved() {
		return "command %q exists but is hidden at your auth tier (tier=%s); the credential in use came from %s — " +
			prov.EnvVar + " is set in your shell and shadows the " + prov.Alt +
			" credential for this server, so `unset " + prov.EnvVar + "` and retry before logging in again"
	}
	return "command %q exists but is hidden at your auth tier (tier=%s); the credential in use came from %s — run `barkpark login` (or pass --token <tok>) with a credential that grants it"
}

// tierHiddenHint is the copy-pasteable fix. In the shadow case the fix is NOT
// `barkpark login` — the login already exists; it is unsetting the env var that
// buried it.
func tierHiddenHint(prov tokenProvenance) string {
	if prov.shadowsSaved() {
		return "unset " + prov.EnvVar
	}
	return "barkpark login"
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

// soleReadVerb reports the ONE verb a verbless invocation of n can safely be
// re-dispatched to, and whether that inference may fire at all. See the rule
// documented at the dispatch site (cli.go): exactly one verb, non-writing, and
// the typed token must not be a near-typo of that verb (a mistyped verb is a
// typo to correct, not an argument to forward) nor look like a flag.
func soleReadVerb(n *manifest.TreeNoun, typed string) (*manifest.Command, bool) {
	if len(n.Verbs) != 1 {
		return nil, false
	}
	sole := n.Verbs[0]
	if sole.Writes || strings.HasPrefix(typed, "-") || typed == "" {
		return nil, false
	}
	if _, isTypo := nearestVerb(typed, []string{sole.Verb}); isTypo {
		return nil, false
	}
	return sole, true
}

// noVerbMsg is the error line for a REAL noun followed by no valid verb. It
// never says the noun is unknown (that was the bug), and it carries the fix in
// the message itself — which matters because `-o json` renders only this string
// in the error envelope and skips the usage help block entirely.
func noVerbMsg(n *manifest.TreeNoun, noun, typed string) string {
	verbs := make([]string, 0, len(n.Verbs))
	for _, c := range n.Verbs {
		verbs = append(verbs, c.Verb)
	}
	base := fmt.Sprintf("no verb %q under `barkpark %s` — `%s` is a known noun", typed, noun, noun)
	if len(n.Verbs) == 1 {
		// One obvious answer, but not auto-run (a writing verb, or the token
		// looked like a typo/flag) — name the literal corrected command. When the
		// token is a near-typo of that verb it IS the mistyped verb, so it must be
		// replaced rather than appended as an argument (`search quer` →
		// `search query`, never `search query quer`).
		sole := n.Verbs[0].Verb
		fixed := fmt.Sprintf("barkpark %s %s", noun, sole)
		if _, isTypo := nearestVerb(typed, []string{sole}); !isTypo && typed != "" && !strings.HasPrefix(typed, "-") {
			fixed += " " + typed
		}
		return fmt.Sprintf("%s; did you mean `%s`?", base, fixed)
	}
	if len(verbs) == 0 {
		return base + "; it declares no verbs"
	}
	return fmt.Sprintf("%s with verbs: %s", base, strings.Join(verbs, ", "))
}

// nounHint returns the machine-mode did-you-mean suggestion for a mistyped noun
// — the ready-to-run "barkpark <noun>" for the nearest known noun, or "" when
// nothing is close enough to be a likely typo. It replays nearestNoun (the same
// matcher usageSuggestNouns prints to human stderr) so the `-o json` error
// envelope's `hint` field carries the identical suggestion an agent can execute.
func nounHint(tree *manifest.Tree, typed string) string {
	if best, ok := nearestNoun(typed, tree.NounNames()); ok {
		return "barkpark " + best
	}
	return ""
}

// verbHint returns the machine-mode did-you-mean suggestion for a mistyped verb
// under a KNOWN noun — "barkpark <noun> <verb>" for the nearest verb, or "" when
// nothing is close. The verb-level sibling of nounHint (replays nearestVerb,
// mirroring usageSuggestVerb's human stderr line).
func verbHint(tree *manifest.Tree, noun, typed string) string {
	n, ok := lookupNoun(tree, noun)
	if !ok {
		return ""
	}
	verbs := make([]string, 0, len(n.Verbs))
	for _, c := range n.Verbs {
		verbs = append(verbs, c.Verb)
	}
	if best, ok := nearestVerb(typed, verbs); ok {
		return "barkpark " + noun + " " + best
	}
	return ""
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
