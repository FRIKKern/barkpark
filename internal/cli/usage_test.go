package cli

import (
	"bytes"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestUsageBuiltinsCoverAllDispatchedBuiltins is the drift guard for the
// usage "built-ins:" line — the mirror of builtins_test.go's
// TestCompletionNounsCoverAllDispatchedBuiltins, same parse, same direction:
// every noun dispatched by the cli.go switch must appear in usageBuiltins. A
// SUPERSET is legal (an entry may land before its dispatch case, exactly as a
// completionNouns entry may), so scaffy's ensure-cli-noun stays green when it
// plants the noun ahead of the hand-written handler. This test is what ended
// the 2026-07 drift where the prose line sat 27 nouns behind the switch.
func TestUsageBuiltinsCoverAllDispatchedBuiltins(t *testing.T) {
	src, err := os.ReadFile("cli.go")
	if err != nil {
		t.Fatalf("read cli.go: %v", err)
	}

	caseLine := regexp.MustCompile(`(?m)^\s*case\s+("[^"]+"(?:\s*,\s*"[^"]+")*)\s*:`)
	tokenRe := regexp.MustCompile(`"([^"]+)"`)

	have := make(map[string]bool, len(usageBuiltins))
	for _, n := range usageBuiltins {
		have[n] = true
	}

	seen := map[string]bool{}
	var missing []string
	for _, m := range caseLine.FindAllStringSubmatch(string(src), -1) {
		for _, tok := range tokenRe.FindAllStringSubmatch(m[1], -1) {
			verb := tok[1]
			if seen[verb] {
				continue
			}
			seen[verb] = true
			if !have[verb] {
				missing = append(missing, verb)
			}
		}
	}

	// Guard against a vacuous pass: if the switch/regex ever stops matching,
	// fail loudly rather than silently assert nothing.
	if len(seen) == 0 {
		t.Fatal("no dispatch `case \"…\":` lines found in cli.go — the switch " +
			"structure or the regex changed; fix this guard before trusting it")
	}

	if len(missing) > 0 {
		sort.Strings(missing)
		t.Errorf("usageBuiltins is missing dispatched built-in noun(s) %v — add "+
			"them to usage.go so the top-level usage names every command", missing)
	}
}

// TestUsageBuiltinLinesSortedAndBounded pins the rendering contract of the
// built-ins block: first line carries the "built-ins: " prefix, continuation
// lines the two-space indent, every noun appears exactly once, the whole block
// reads in sorted order, and no line exceeds the wrap width.
func TestUsageBuiltinLinesSortedAndBounded(t *testing.T) {
	lines := usageBuiltinLines()
	if len(lines) == 0 {
		t.Fatal("usageBuiltinLines returned no lines")
	}
	if !strings.HasPrefix(lines[0], "built-ins: ") {
		t.Errorf("first line %q lacks the built-ins prefix", lines[0])
	}
	var joined []string
	for i, line := range lines {
		if len(line) > 100 {
			t.Errorf("line %d is %d chars, past the 100-column wrap: %q", i, len(line), line)
		}
		body := strings.TrimPrefix(line, "built-ins: ")
		if i > 0 {
			if !strings.HasPrefix(line, "  ") {
				t.Errorf("continuation line %d %q lacks the two-space indent", i, line)
			}
			body = strings.TrimPrefix(line, "  ")
		}
		joined = append(joined, strings.Split(body, " · ")...)
	}
	want := append([]string(nil), usageBuiltins...)
	sort.Strings(want)
	if strings.Join(joined, " ") != strings.Join(want, " ") {
		t.Errorf("rendered nouns = %v; want the sorted usageBuiltins %v", joined, want)
	}
}

func TestUsageCommandShowsArgSummaries(t *testing.T) {
	cmd := manifest.Command{
		Noun:    "task",
		Verb:    "show",
		Summary: "Show a task by id.",
		Args: []manifest.Arg{
			{Name: "id", Required: true, Type: "string", Summary: "Task document id."},
			{Name: "depth", Required: false, Type: "int", Summary: "How many child levels to include."},
		},
		Flags: []manifest.Flag{
			{Name: "json", Summary: "Emit JSON."},
		},
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	out := stderr.String()

	// Signature still shows required/optional markers.
	for _, want := range []string{"usage: barkpark task show <id> [depth]", "Show a task by id."} {
		if !strings.Contains(out, want) {
			t.Errorf("usage missing %q:\n%s", want, out)
		}
	}
	// The new arguments block surfaces each arg's summary (the regression this
	// locks: the manifest carries them but usageCommand used to drop them).
	for _, want := range []string{"arguments:", "id", "Task document id.", "depth", "How many child levels to include."} {
		if !strings.Contains(out, want) {
			t.Errorf("usage missing arg detail %q:\n%s", want, out)
		}
	}
	// Flags block still renders.
	if !strings.Contains(out, "flags:") || !strings.Contains(out, "Emit JSON.") {
		t.Errorf("usage missing flags block:\n%s", out)
	}
}

func TestUsageCommandNoArgumentsBlockWhenNoSummaries(t *testing.T) {
	// Args with no summaries must NOT produce an empty "arguments:" header.
	cmd := manifest.Command{
		Noun: "doc",
		Verb: "get",
		Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	if strings.Contains(stderr.String(), "arguments:") {
		t.Errorf("summary-less args should not render an arguments block:\n%s", stderr.String())
	}
}

func TestUsageCommandWriteBodyAndTypedFlags(t *testing.T) {
	cmd := manifest.Command{
		Noun:      "doc",
		Verb:      "create",
		Summary:   "Create a document.",
		Writes:    true,
		Paginated: false,
		Flags: []manifest.Flag{
			{Name: "file", Type: "file", Summary: "Document fields as a JSON object from a file or - for stdin."},
			{Name: "set", Type: "string", Summary: "Field key=value (repeatable).", Repeatable: true},
			{Name: "publish", Type: "bool", Summary: "Publish immediately."},
			{Name: "type", Type: "string", Summary: "Document type."},
		},
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	out := stderr.String()

	// Writes command surfaces the --set/--file body line and the write globals.
	for _, want := range []string{"body:", "--set", "--file", "--dry-run", "--yes"} {
		if !strings.Contains(out, want) {
			t.Errorf("write-command usage missing %q:\n%s", want, out)
		}
	}
	// A value flag gets a <value> placeholder; a bool flag does not.
	if !strings.Contains(out, "--type <value>") {
		t.Errorf("value flag should show <value> placeholder:\n%s", out)
	}
	if strings.Contains(out, "--publish <value>") {
		t.Errorf("bool flag must NOT show a <value> placeholder:\n%s", out)
	}
}

// TestUsageCommandBodyLineMatchesDeclaredFlags is the W18-5 regression for
// bp-doc-patch-file-flag-broken: usage.go advertised
// `--file <path>|-` for EVERY write command, but --set/--file are per-command
// manifest flags — `bp doc patch` declares only [set], and its parser rightly
// rejects --file with exit 2. Help must never advertise a flag the parser
// will refuse: the body hint is composed from the flags the command declares.
func TestUsageCommandBodyLineMatchesDeclaredFlags(t *testing.T) {
	render := func(cmd manifest.Command) string {
		t.Helper()
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		usageCommand(w, cmd)
		return stderr.String()
	}

	t.Run("set-only write (doc patch) omits --file from the body line", func(t *testing.T) {
		out := render(manifest.Command{
			Noun: "doc", Verb: "patch", Writes: true,
			Flags: []manifest.Flag{{Name: "set", Type: "string", Summary: "Field key=value to change (repeatable).", Repeatable: true}},
		})
		if !strings.Contains(out, "body: --set key=value (repeatable)") {
			t.Errorf("set-only write should keep the --set body hint:\n%s", out)
		}
		if strings.Contains(out, "--file") {
			t.Errorf("help must not advertise --file when the manifest declares no file flag:\n%s", out)
		}
	})

	t.Run("file-only write (schema apply) omits --set from the body line", func(t *testing.T) {
		out := render(manifest.Command{
			Noun: "schema", Verb: "apply", Writes: true,
			Flags: []manifest.Flag{{Name: "file", Type: "file", Summary: "Schema JSON from a file or - for stdin."}},
		})
		if !strings.Contains(out, "body: --file <path>|-") {
			t.Errorf("file-only write should keep the --file body hint:\n%s", out)
		}
		if strings.Contains(out, "--set key=value") {
			t.Errorf("help must not advertise --set when the manifest declares no set flag:\n%s", out)
		}
	})

	t.Run("write with neither flag renders no body line", func(t *testing.T) {
		out := render(manifest.Command{
			Noun: "task", Verb: "claim", Writes: true,
			Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
		})
		if strings.Contains(out, "body:") {
			t.Errorf("a write whose body comes from positional args must not render a body hint:\n%s", out)
		}
		// The write globals still apply — they ride parseGlobals, not the
		// per-command flag list.
		if !strings.Contains(out, "write globals:") {
			t.Errorf("write globals line should stay:\n%s", out)
		}
	})
}

func TestUsageCommandNonWriteHasNoBodyOrGlobals(t *testing.T) {
	// A read command must not advertise write-body/globals it can't use, but a
	// paginated read should surface the pagination globals.
	cmd := manifest.Command{
		Noun:      "doc",
		Verb:      "ls",
		Paginated: true,
	}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	usageCommand(w, cmd)
	out := stderr.String()

	for _, unwanted := range []string{"body:", "write globals"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("read command should not show %q:\n%s", unwanted, out)
		}
	}
	if !strings.Contains(out, "--limit") || !strings.Contains(out, "--all") {
		t.Errorf("paginated command should surface pagination globals:\n%s", out)
	}
}

func TestLevenshtein(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"a", "", 1},
		{"", "abc", 3},
		{"kitten", "sitting", 3},
		{"doctor", "doctor", 0},
		{"doctr", "doctor", 1},
		{"scema", "schema", 1},
	}
	for _, c := range cases {
		if got := levenshtein(c.a, c.b); got != c.want {
			t.Errorf("levenshtein(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestNearestNoun(t *testing.T) {
	nouns := []string{"doc", "schema", "media", "doctor", "task", "workspace", "search"}

	// Close typos → a suggestion.
	for _, c := range []struct{ typed, want string }{
		{"doctr", "doctor"},
		{"scema", "schema"},
		{"workspce", "workspace"},
		{"serach", "search"},
	} {
		got, ok := nearestNoun(c.typed, nouns)
		if !ok || got != c.want {
			t.Errorf("nearestNoun(%q) = %q,%v; want %q,true", c.typed, got, ok, c.want)
		}
	}

	// Unrelated / too-distant input → no misleading hint.
	for _, typed := range []string{"xyzzy", "completelyoff", "z"} {
		if got, ok := nearestNoun(typed, nouns); ok {
			t.Errorf("nearestNoun(%q) = %q,true; want no suggestion", typed, got)
		}
	}
}

func TestNearestVerb(t *testing.T) {
	verbs := []string{"ls", "get", "create", "update", "delete", "publish", "backlinks"}

	// Close typos → a suggestion.
	for _, c := range []struct{ typed, want string }{
		{"lst", "ls"},
		{"crate", "create"},
		{"udpate", "update"},
		{"publsh", "publish"},
	} {
		got, ok := nearestVerb(c.typed, verbs)
		if !ok || got != c.want {
			t.Errorf("nearestVerb(%q) = %q,%v; want %q,true", c.typed, got, ok, c.want)
		}
	}

	// Unrelated / too-distant input → no misleading hint.
	for _, typed := range []string{"xyzzy", "completelyoff"} {
		if got, ok := nearestVerb(typed, verbs); ok {
			t.Errorf("nearestVerb(%q) = %q,true; want no suggestion", typed, got)
		}
	}
}

// tierFilteredTree builds a small manifest tree that stands in for a
// server-filtered manifest: it declares `doc` and `search` but deliberately
// OMITS `task` (and every other tier-gated noun), exactly as the server would
// for a low-tier caller. `task` is in the baked catalog (completionNouns), so a
// low-tier caller typing it is the auth-hidden case; a word never in the catalog
// is a genuine typo.
func tierFilteredTree() *manifest.Tree {
	m := &manifest.Manifest{
		AuthTier: "none",
		Nouns: []manifest.Noun{
			{Name: "doc", Summary: "Documents."},
			{Name: "search", Summary: "Full-text search."},
		},
		Commands: []manifest.Command{
			{ID: "doc.ls", Noun: "doc", Verb: "ls"},
			{ID: "doc.get", Noun: "doc", Verb: "get"},
			{ID: "search.query", Noun: "search", Verb: "query"},
		},
	}
	return m.Tree()
}

// TestAuthHiddenNoun drives the classification predicate directly: a baked-catalog
// noun absent from a low-tier tree is hidden; a visible noun, a non-catalog word,
// and — critically — ANY noun for an admin caller are not.
func TestAuthHiddenNoun(t *testing.T) {
	tree := tierFilteredTree()

	// `task` is a real baked-catalog noun the low-tier tree does not carry → hidden.
	if !authHiddenNoun(tree, "none", "task") {
		t.Error("a baked-catalog noun absent from a low-tier tree must classify as auth-hidden")
	}
	// `workspace` and `token` are likewise catalog nouns filtered out at low tier.
	for _, hidden := range []string{"workspace", "token", "webhook"} {
		if !authHiddenNoun(tree, "read", hidden) {
			t.Errorf("catalog noun %q absent from a low-tier tree must be auth-hidden", hidden)
		}
	}

	// A noun the tree DOES carry is never hidden — it is dispatched normally.
	if authHiddenNoun(tree, "none", "doc") {
		t.Error("a visible noun must never be classified auth-hidden")
	}

	// A word that is not in the baked catalog at all is a genuine typo, not hidden.
	for _, typo := range []string{"tsk", "zqxwvut", "workspce"} {
		if authHiddenNoun(tree, "none", typo) {
			t.Errorf("non-catalog word %q must not be classified auth-hidden", typo)
		}
	}

	// ADMIN NEVER HIDDEN: an admin's manifest is the whole tree, so a noun missing
	// for them is genuinely unknown — the auth-hidden diagnosis must never fire and
	// falsely tell an admin to re-authenticate.
	if authHiddenNoun(tree, "admin", "task") {
		t.Error("admin callers must never receive an auth-hidden diagnosis")
	}
}

// TestSuggestUnknownNounAuthHidden pins the auth-hidden branch end to end: the
// message names the tier and points at `bp login` (both on the human help block
// and in the machine-readable error envelope), and it does NOT emit a misleading
// "did you mean?" typo suggestion for the hidden noun.
func TestSuggestUnknownNounAuthHidden(t *testing.T) {
	tree := tierFilteredTree()

	// Human output (table/plain): both the primary line and the help block render.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := suggestUnknownNoun(w, tree, "none", "task", tokenProvenance{})
	if code != exitUsage {
		t.Errorf("auth-hidden exit = %d, want %d", code, exitUsage)
	}
	human := stderr.String()
	for _, want := range []string{"real command", "tier=none", "barkpark login", "--token"} {
		if !strings.Contains(human, want) {
			t.Errorf("auth-hidden human output missing %q:\n%s", want, human)
		}
	}
	// It must NOT masquerade as a typo of a visible noun.
	if strings.Contains(human, "did you mean") || strings.Contains(human, "unknown command") {
		t.Errorf("auth-hidden noun must not get a typo/unknown-command diagnosis:\n%s", human)
	}

	// Machine output (-o json): the login remedy must ride the error envelope hint,
	// since the human help block is skipped entirely there — an agent parsing the
	// envelope must still learn to authenticate.
	var mstdout, mstderr bytes.Buffer
	mw := newWriter(&mstdout, &mstderr)
	mw.output = "json"
	suggestUnknownNoun(mw, tree, "none", "task", tokenProvenance{})
	env := mstdout.String()
	for _, want := range []string{`"hint"`, "barkpark login", "hidden at your auth tier"} {
		if !strings.Contains(env, want) {
			t.Errorf("auth-hidden json envelope missing %q:\n%s", want, env)
		}
	}
}

// TestSuggestUnknownNounGenuineTypo is the negative guard: a word that is NOT a
// baked-catalog noun keeps the ordinary typo/unsupported diagnosis (nearest known
// noun + "unknown command"), never a false auth-hidden login prompt.
func TestSuggestUnknownNounGenuineTypo(t *testing.T) {
	tree := tierFilteredTree()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := suggestUnknownNoun(w, tree, "none", "serach", tokenProvenance{})
	if code != exitUsage {
		t.Errorf("typo exit = %d, want %d", code, exitUsage)
	}
	out := stderr.String()
	if !strings.Contains(out, "unknown command") {
		t.Errorf("genuine typo lost its unknown-command line:\n%s", out)
	}
	if strings.Contains(out, "auth tier") || strings.Contains(out, "barkpark login") {
		t.Errorf("genuine typo must not get an auth-hidden login prompt:\n%s", out)
	}
	// The nearest visible noun is still suggested.
	if !strings.Contains(out, "did you mean `barkpark search`") {
		t.Errorf("genuine typo lost its did-you-mean suggestion:\n%s", out)
	}
}

// TestSuggestUnknownNounAdminNeverHidden guards the admin path through the full
// classifier: an admin who names a noun their (complete) tree lacks gets the
// ordinary unknown-command diagnosis, never a spurious re-authenticate prompt.
func TestSuggestUnknownNounAdminNeverHidden(t *testing.T) {
	tree := tierFilteredTree()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	suggestUnknownNoun(w, tree, "admin", "task", tokenProvenance{})
	out := stderr.String()
	if !strings.Contains(out, "unknown command") {
		t.Errorf("admin should get the ordinary unknown-command diagnosis:\n%s", out)
	}
	if strings.Contains(out, "auth tier") || strings.Contains(out, "barkpark login") {
		t.Errorf("admin must never be told to re-authenticate for a missing noun:\n%s", out)
	}
}
