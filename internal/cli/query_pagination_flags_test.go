package cli

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestGlobalLimitReachesCommandsThatDeclareIt pins the DECLARATION rule in
// applyQuery: --limit / --offset ride whenever the command's own manifest
// declares the flag, not only when the command is `paginated: true`.
//
// The bug this replaces was silent and pre-request. --limit and --offset are
// GLOBAL flags — parseGlobals consumes them wherever they appear in argv, so a
// command-local `limit`/`offset` flag can never see them (globals.go:52
// documents the identical trap for --dataset). applyQuery then re-emitted them
// only under `cmd.Paginated`, so on every command that declares its own
// limit/offset WITHOUT being paginated the knob was accepted, parsed,
// validated (`--limit -1` is still rejected) and then dropped on the floor. The
// request went out bare, the server applied its own default, and the CLI
// exited 0.
//
// MUTATION PROOF: restore `if cmd.Paginated {` around the two blocks in
// applyQuery and every "declares it" subtest below fails, while the paginated
// and declares-nothing subtests stay green — which is what makes those two the
// control, not decoration.
func TestGlobalLimitReachesCommandsThatDeclareIt(t *testing.T) {
	limitFlag := manifest.Flag{Name: "limit", Type: "int"}
	offsetFlag := manifest.Flag{Name: "offset", Type: "int"}

	tests := []struct {
		name string
		cmd  manifest.Command
		g    globals
		want string
	}{
		{
			// doc.related / doc.history / media.suggest / task.prime /
			// task.events shape: declares limit, paginated false.
			name: "declares limit, not paginated",
			cmd:  manifest.Command{Noun: "doc", Verb: "related", Flags: []manifest.Flag{limitFlag}},
			g:    globals{limit: 25, limitSet: true},
			want: "https://x.test/v1/data/related/production/d1?limit=25",
		},
		{
			// media.search shape: declares BOTH, paginated false. Its own flag
			// summary reads "Hits to skip (paginate with --limit)" — neither
			// knob could leave the CLI, so every next page was page one.
			name: "declares limit and offset, not paginated",
			cmd:  manifest.Command{Noun: "media", Verb: "search", Flags: []manifest.Flag{limitFlag, offsetFlag}},
			g:    globals{limit: 100, limitSet: true, offset: 200, offsetSet: true},
			want: "https://x.test/v1/data/related/production/d1?limit=100&offset=200",
		},
		{
			// A command declaring ONLY limit must not acquire an offset it
			// cannot honour just because the caller typed one.
			name: "declares limit only, --offset also given",
			cmd:  manifest.Command{Noun: "doc", Verb: "history", Flags: []manifest.Flag{limitFlag}},
			g:    globals{limit: 3, limitSet: true, offset: 9, offsetSet: true},
			want: "https://x.test/v1/data/related/production/d1?limit=3",
		},
		{
			// CONTROL: the seven `paginated: true` commands take limit/offset as
			// protocol whether or not they also enumerate them as flags. This
			// subtest is what proves the fix ADDED a path rather than moving one.
			name: "paginated, declares nothing",
			cmd:  manifest.Command{Noun: "task", Verb: "ready", Paginated: true},
			g:    globals{limit: 7, limitSet: true, offset: 3, offsetSet: true},
			want: "https://x.test/v1/data/related/production/d1?limit=7&offset=3",
		},
		{
			// CONTROL: `bp doc get post p1 --limit 7` still sends no limit —
			// doc.get returns ONE document and declares no such flag. Widening
			// to "any command" would send a knob the route never reads.
			name: "declares nothing, not paginated",
			cmd:  manifest.Command{Noun: "doc", Verb: "get"},
			g:    globals{limit: 7, limitSet: true, offset: 2, offsetSet: true},
			want: "https://x.test/v1/data/related/production/d1",
		},
		{
			name: "unset globals add nothing even where declared",
			cmd:  manifest.Command{Noun: "doc", Verb: "related", Flags: []manifest.Flag{limitFlag, offsetFlag}},
			g:    globals{},
			want: "https://x.test/v1/data/related/production/d1",
		},
	}

	const base = "https://x.test/v1/data/related/production/d1"
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := applyQuery(base, tc.g, tc.cmd, map[string][]string{}, map[string]string{})
			if got != tc.want {
				t.Errorf("applyQuery = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestGlobalLimitNeverDuplicatesTheQueryKey guards the seam between the two
// producers of a `limit` query param: the globals block and the
// manifest-declared-flag loop. parseGlobals provably eats --limit before
// splitArgs runs, so `flags["limit"]` is unreachable from argv — but an MCP
// handler builds `flags` itself, and a duplicate scalar `limit=` would hand Plug
// the same decode-order coin-flip the repeatable-flag branch exists to avoid
// (Gyldendal #16). The globals value wins and the loop stands down.
func TestGlobalLimitNeverDuplicatesTheQueryKey(t *testing.T) {
	cmd := manifest.Command{
		Noun:  "doc",
		Verb:  "related",
		Flags: []manifest.Flag{{Name: "limit", Type: "int"}, {Name: "offset", Type: "int"}},
	}
	got := applyQuery(
		"https://x.test/v1/data/related/production/d1",
		globals{limit: 25, limitSet: true, offset: 5, offsetSet: true},
		cmd,
		map[string][]string{"limit": {"9"}, "offset": {"1"}},
		map[string]string{},
	)
	want := "https://x.test/v1/data/related/production/d1?limit=25&offset=5"
	if got != want {
		t.Fatalf("applyQuery = %q, want %q (exactly one limit= and one offset=)", got, want)
	}
	if strings.Count(got, "limit=") != 1 || strings.Count(got, "offset=") != 1 {
		t.Fatalf("duplicate pagination key in %q", got)
	}
}

// TestLimitDeclaringNonPaginatedCommandsExist keeps the rule above from going
// vacuous. It re-derives the population from the API source — the same idiom as
// TestPaginatedCommandsUseKnownEnvelopeKeys — instead of trusting a list in this
// file: every command that declares a limit/offset flag while NOT being
// `paginated: true` is fed through applyQuery as a synthesized command, and the
// knob must come out the other side.
//
// It deliberately records NO roster of ids. A lane that flips one of these
// commands to `paginated: true`, renames it, or adds a seventh must not have to
// touch this test; the guard only fails if the population empties out (the rule
// would then be untested) or if a member stops forwarding.
func TestLimitDeclaringNonPaginatedCommandsExist(t *testing.T) {
	root := filepath.Join("..", "..", "api", "lib", "barkpark", "plugins")
	if _, err := os.Stat(root); err != nil {
		t.Skipf("API source not present (%v) — guard runs in the monorepo checkout", err)
	}

	type cmdDecl struct {
		id        string
		flags     []string
		paginated bool
	}
	found := map[string]*cmdDecl{}

	// Both declaration shapes: capabilities.ex's `flag("limit", "int", …)` and
	// the plugin map form `%{name: "limit", …}` (tasks.ex).
	flagRe := regexp.MustCompile(`flag\("(limit|offset)"|name:\s*"(limit|offset)"`)

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".ex") {
			return err
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(src), "\n")
		for i, line := range lines {
			m := flagRe.FindStringSubmatch(line)
			if m == nil && !strings.Contains(line, "paginated: true") {
				continue
			}
			id := commandIDAbove(lines, i)
			if id == "" {
				continue
			}
			decl := found[id]
			if decl == nil {
				decl = &cmdDecl{id: id}
				found[id] = decl
			}
			if m != nil {
				name := m[1]
				if name == "" {
					name = m[2]
				}
				decl.flags = append(decl.flags, name)
			} else {
				decl.paginated = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", root, err)
	}

	checked := 0
	for _, decl := range found {
		if decl.paginated || len(decl.flags) == 0 {
			continue
		}
		flags := make([]manifest.Flag, 0, len(decl.flags))
		for _, name := range decl.flags {
			flags = append(flags, manifest.Flag{Name: name, Type: "int"})
		}
		cmd := manifest.Command{Noun: decl.id, Verb: "x", Flags: flags}
		got := applyQuery("https://x.test/r", globals{limit: 11, limitSet: true, offset: 22, offsetSet: true}, cmd, map[string][]string{}, map[string]string{})
		for _, name := range decl.flags {
			if !strings.Contains(got, name+"=") {
				t.Errorf("%s declares --%s but applyQuery dropped it: %q", decl.id, name, got)
			}
		}
		checked++
	}
	if checked == 0 {
		t.Fatalf("no non-paginated command declaring limit/offset found under %s — this guard is measuring nothing, and the declaration rule in applyQuery is untested", root)
	}
}
