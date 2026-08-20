package cli

// scaffy_cmd_test.go covers the `bp scaffy` builtin: verb dispatch + exit-code
// contract (0/2/4/5, D27), the compiler-style findings output with fix hints,
// the -o json machine envelope, fmt's in-place rewrite vs --check's write-
// nothing guarantee, and the help texts. All fixtures come from the merged
// internal/scaffy testdata + the live corpus — this file never restates
// grammar rules, only the CLI wiring around them.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

const (
	scaffyCorpusDir   = "../../scaffy/commands"
	scaffyGreenFile   = "../scaffy/testdata/green/add-widget.scaffy"
	scaffyRedFile     = "../scaffy/testdata/red/E-020-direction-missing.scaffy"
	scaffyMessyFile   = "../scaffy/testdata/fmt/messy.scaffy"
	scaffyMessyGolden = "../scaffy/testdata/fmt/messy.golden"
)

// copyFixture copies a fixture into dir under name and returns the new path.
func copyFixture(t *testing.T, src, dir, name string) string {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read fixture %s: %v", src, err)
	}
	dst := filepath.Join(dir, name)
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		t.Fatalf("write fixture %s: %v", dst, err)
	}
	return dst
}

func runScaffyTest(t *testing.T, g globals, output string, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if output != "" {
		w.output = output
	}
	code := runScaffy(w, g, args)
	return code, stdout.String(), stderr.String()
}

func TestScaffyValidateCleanCorpusExitsZero(t *testing.T) {
	if _, err := os.Stat(scaffyCorpusDir); err != nil {
		t.Fatalf("corpus dir missing: %v", err)
	}
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "validate", scaffyCorpusDir)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "clean:") || !strings.Contains(stdout, "0 findings") {
		t.Errorf("clean summary missing:\n%s", stdout)
	}
}

func TestScaffyValidateFindingsExitFive(t *testing.T) {
	dir := t.TempDir()
	broken := copyFixture(t, scaffyRedFile, dir, "broken.scaffy")
	code, stdout, _ := runScaffyTest(t, globals{}, "", "validate", broken)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s", code, exitValidation, stdout)
	}
	// Compiler-style "file:line: RULE-ID message" with the file path leading.
	lineRe := regexp.MustCompile(regexp.QuoteMeta(broken) + `:\d+: [EWP]-\d{3} `)
	if !lineRe.MatchString(stdout) {
		t.Errorf("no compiler-style finding line in:\n%s", stdout)
	}
	if !strings.Contains(stdout, "hint:") {
		t.Errorf("no fix-hint line in:\n%s", stdout)
	}
	if !strings.Contains(stdout, "finding(s)") {
		t.Errorf("no summary count in:\n%s", stdout)
	}
}

func TestScaffyValidateDirectoryGlobsScaffyFiles(t *testing.T) {
	dir := t.TempDir()
	copyFixture(t, scaffyGreenFile, dir, "good.scaffy")
	copyFixture(t, scaffyRedFile, dir, "bad.scaffy")
	if err := os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("not scaffy"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, stdout, _ := runScaffyTest(t, globals{}, "", "validate", dir)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s", code, exitValidation, stdout)
	}
	if !strings.Contains(stdout, "bad.scaffy") {
		t.Errorf("findings should name bad.scaffy:\n%s", stdout)
	}
	if strings.Contains(stdout, "ignored.txt") {
		t.Errorf("non-.scaffy file leaked into validation:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 file(s)") {
		t.Errorf("summary should count exactly the 2 .scaffy files:\n%s", stdout)
	}
}

// seedRepoAwareTree plants the token-free anchors the add-widget green
// fixture (scaffyGreenFile) targets, so `validate --repo` resolves them
// against a scratch tree. The js REPLACE anchor is {{.CountBefore}}-bearing
// and stays token-skipped without --var.
func seedRepoAwareTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	write := func(rel, content string) {
		abs := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("internal/widgets/registry.go", "package widgets\n\nfunc init() {\n\tregistry[\"heading\"] = headingWidget{}\n}\n")
	write("web/widgets/index.css", ".bp-heading { display: block; }\n")
	write("api/config/config.exs", "import Config\n\nconfig :barkpark, Oban,\n  crontab: [\n       {\"* * * * *\", Barkpark.Workers.Tail}\n  ]\n")
	write("js/widgets/widgets.test.ts", "test(\"cases\", () => {\n  expect(cases).toHaveLength(42)\n})\n")
	return root
}

// TestScaffyValidateRepoCleanReportsSkipped: --repo against a tree carrying
// the anchors verifies the token-free ones, exits 0, and the summary names
// the token-bearing anchor it skipped (never a vacuous green).
func TestScaffyValidateRepoCleanReportsSkipped(t *testing.T) {
	root := seedRepoAwareTree(t)
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "validate", "--repo", root, scaffyGreenFile)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "3 anchor(s) verified") {
		t.Errorf("summary should report 3 verified anchors:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 token-bearing anchor(s) skipped") {
		t.Errorf("summary must name the skipped token anchor:\n%s", stdout)
	}
}

// TestScaffyValidateRepoDriftReds: a drifted anchor (config.exs missing the
// cron tuple) reds with R-002 and exit 5.
func TestScaffyValidateRepoDriftReds(t *testing.T) {
	root := seedRepoAwareTree(t)
	if err := os.WriteFile(filepath.Join(root, "api/config/config.exs"), []byte("import Config\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, stdout, _ := runScaffyTest(t, globals{}, "", "validate", "--repo", root, scaffyGreenFile)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s", code, exitValidation, stdout)
	}
	if !strings.Contains(stdout, "R-002") {
		t.Errorf("want R-002 anchor-not-found finding:\n%s", stdout)
	}
}

// TestScaffyValidateRepoWithVarsChecksTokens: supplying the full --var set
// resolves the token-bearing anchor too — nothing skipped.
func TestScaffyValidateRepoWithVarsChecksTokens(t *testing.T) {
	root := seedRepoAwareTree(t)
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "validate", "--repo", root, scaffyGreenFile,
		"--var", "WidgetName=Timeline", "--var", "Ts=20260716100000", "--var", "CountBefore=42", "--var", "CountAfter=43")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "4 anchor(s) verified") {
		t.Errorf("summary should report all 4 anchors verified:\n%s", stdout)
	}
	if strings.Contains(stdout, "skipped") {
		t.Errorf("no anchor should be skipped when vars are supplied:\n%s", stdout)
	}
}

// TestScaffyValidateVarsWithoutRepoUsageError: --var without --repo is a
// usage error (text-level validate takes no vars).
func TestScaffyValidateVarsWithoutRepoUsageError(t *testing.T) {
	code, _, stderr := runScaffyTest(t, globals{}, "", "validate", "--var", "K=V", scaffyGreenFile)
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d; stderr:\n%s", code, exitUsage, stderr)
	}
}

// TestScaffyValidateRepoBadVarsUsageError: a --var set that violates the D37
// contract surfaces as a usage error (exit 2), like run.
func TestScaffyValidateRepoBadVarsUsageError(t *testing.T) {
	root := seedRepoAwareTree(t)
	code, _, stderr := runScaffyTest(t, globals{}, "", "validate", "--repo", root, scaffyGreenFile, "--var", "Nope=x")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d; stderr:\n%s", code, exitUsage, stderr)
	}
}

func TestScaffyValidateMissingPathExitsFour(t *testing.T) {
	code, _, stderr := runScaffyTest(t, globals{}, "", "validate", "no/such/path.scaffy")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no/such/path.scaffy") {
		t.Errorf("stderr should name the missing path:\n%s", stderr)
	}
}

func TestScaffyValidateEmptyDirExitsFour(t *testing.T) {
	code, _, stderr := runScaffyTest(t, globals{}, "", "validate", t.TempDir())
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d; stderr:\n%s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "no .scaffy files") {
		t.Errorf("stderr should say no .scaffy files were found:\n%s", stderr)
	}
}

func TestScaffyUsageErrorsExitTwo(t *testing.T) {
	cases := [][]string{
		{},                                  // bare `bp scaffy`
		{"validate"},                        // no paths
		{"fmt"},                             // no paths
		{"validate", "--bogus", "x.scaffy"}, // unknown validate flag
		{"fmt", "--bogus", "x.scaffy"},      // unknown fmt flag
		{"frobnicate", "x.scaffy"},          // unknown verb
		{"run"},                             // no command path
		{"run", "a.scaffy", "b.scaffy"},     // two command paths
		{"run", "x.scaffy", "--var"},        // dangling --var
		{"run", "x.scaffy", "--var", "KV"},  // malformed --var (no =)
		{"run", "x.scaffy", "--var", "=v"},  // malformed --var (empty key)
		{"run", "x.scaffy", "--var", "K=1", "--var", "K=2"}, // duplicate --var
		{"run", "--bogus", "x.scaffy"},                      // unknown run flag
		{"remove"},                                          // no command path
		{"remove", "x.scaffy", "--var", "KV"},               // malformed --var
		{"remove", "--bogus", "x.scaffy"},                   // unknown remove flag
	}
	for _, args := range cases {
		code, _, stderr := runScaffyTest(t, globals{}, "", args...)
		if code != exitUsage {
			t.Errorf("runScaffy(%v) exit = %d, want %d; stderr:\n%s", args, code, exitUsage, stderr)
		}
	}
}

func TestScaffyValidateJSONEnvelope(t *testing.T) {
	dir := t.TempDir()
	broken := copyFixture(t, scaffyRedFile, dir, "broken.scaffy")
	code, stdout, _ := runScaffyTest(t, globals{}, "json", "validate", broken)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d (exit follows findings, not output shape)", code, exitValidation)
	}
	var env struct {
		OK       bool `json:"ok"`
		Files    int  `json:"files"`
		Findings []struct {
			File    string `json:"file"`
			Line    int    `json:"line"`
			Rule    string `json:"rule"`
			Message string `json:"message"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a JSON envelope: %v\n%s", err, stdout)
	}
	if env.OK {
		t.Error("ok = true, want false on findings")
	}
	if env.Files != 1 {
		t.Errorf("files = %d, want 1", env.Files)
	}
	if len(env.Findings) == 0 {
		t.Fatal("findings empty")
	}
	f := env.Findings[0]
	if f.File != broken || f.Line == 0 || f.Rule == "" || f.Message == "" {
		t.Errorf("finding shape incomplete: %+v", f)
	}
}

func TestScaffyValidateCleanJSONEnvelope(t *testing.T) {
	dir := t.TempDir()
	good := copyFixture(t, scaffyGreenFile, dir, "good.scaffy")
	code, stdout, _ := runScaffyTest(t, globals{}, "json", "validate", good)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	var env struct {
		OK       bool  `json:"ok"`
		Findings []any `json:"findings"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a JSON envelope: %v\n%s", err, stdout)
	}
	if !env.OK || len(env.Findings) != 0 {
		t.Errorf("want ok:true findings:[] — got ok:%v findings:%v", env.OK, env.Findings)
	}
}

func TestScaffyFmtCheckNonFixpointExitsFiveWritesNothing(t *testing.T) {
	dir := t.TempDir()
	messy := copyFixture(t, scaffyMessyFile, dir, "messy.scaffy")
	before, _ := os.ReadFile(messy)

	code, stdout, _ := runScaffyTest(t, globals{}, "", "fmt", "--check", messy)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s", code, exitValidation, stdout)
	}
	if !strings.Contains(stdout, "messy.scaffy") {
		t.Errorf("--check should list the non-fixpoint file:\n%s", stdout)
	}
	after, _ := os.ReadFile(messy)
	if !bytes.Equal(before, after) {
		t.Error("--check wrote to the file — it must write NOTHING")
	}
}

func TestScaffyFmtRewritesInPlaceToGolden(t *testing.T) {
	dir := t.TempDir()
	messy := copyFixture(t, scaffyMessyFile, dir, "messy.scaffy")

	code, stdout, stderr := runScaffyTest(t, globals{}, "", "fmt", messy)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "rewrote 1 of 1 file(s)") {
		t.Errorf("rewrite summary missing:\n%s", stdout)
	}
	got, err := os.ReadFile(messy)
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile(scaffyMessyGolden)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("rewritten file != golden\ngot:\n%s\nwant:\n%s", got, want)
	}

	// Idempotence at the CLI level: a second --check is a clean fixpoint.
	code, stdout, _ = runScaffyTest(t, globals{}, "", "fmt", "--check", messy)
	if code != exitOK {
		t.Errorf("second fmt --check exit = %d, want %d (fixpoint)\n%s", code, exitOK, stdout)
	}
}

func TestScaffyFmtCheckCorpusIsFixpoint(t *testing.T) {
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "fmt", "--check", scaffyCorpusDir)
	if code != exitOK {
		t.Fatalf("committed corpus is not an fmt fixpoint (exit %d):\n%s\n%s", code, stdout, stderr)
	}
}

func TestScaffyFmtJSONEnvelope(t *testing.T) {
	dir := t.TempDir()
	messy := copyFixture(t, scaffyMessyFile, dir, "messy.scaffy")
	code, stdout, _ := runScaffyTest(t, globals{}, "json", "fmt", "--check", messy)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d", code, exitValidation)
	}
	var env struct {
		OK      bool     `json:"ok"`
		Mode    string   `json:"mode"`
		Files   int      `json:"files"`
		Changed []string `json:"changed"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a JSON envelope: %v\n%s", err, stdout)
	}
	if env.OK || env.Mode != "check" || env.Files != 1 || len(env.Changed) != 1 {
		t.Errorf("envelope = %+v, want ok:false mode:check files:1 changed:[messy]", env)
	}
}

func TestScaffyHelpTexts(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{nil, []string{"usage: bp scaffy <validate|fmt|run|remove|describe|discover>", "validate <path>...", "fmt [--check] <path>...", "run <command.scaffy> --var K=V...", "remove <command.scaffy> --var K=V...", "describe <command.scaffy|name>", "examples:", "exit codes:", "SCAFFY-DRIFT"}},
		{[]string{"describe"}, []string{"usage: bp scaffy describe <command.scaffy|name>", "synthesized kind", "opaque shape:<name>", "in.<verb_snake>", "{kind, tier, text}", "-o json", "exit codes:"}},
		{[]string{"validate"}, []string{"usage: bp scaffy validate [--repo <root>] [--var K=V...] <path>...", "file:line: RULE-ID message", "--repo <root>", "R-001 missing-file", "exit codes:", "-o json"}},
		{[]string{"fmt"}, []string{"usage: bp scaffy fmt [--check] <path>...", "--check", "exit codes:", "fixpoint"}},
		{[]string{"run"}, []string{"usage: bp scaffy run <command.scaffy> --var K=V...", "--var K=V", "--dry-run", "duration_ms", "examples:", "exit codes:", "5  validation findings"}},
		{[]string{"remove"}, []string{"usage: bp scaffy remove <command.scaffy> --var K=V...", "RECEIPT REPLAY", "D36", "--dry-run", "exit codes:", "SCAFFY-DRIFT"}},
	}
	for _, c := range cases {
		code, stdout, _ := runScaffyTest(t, globals{help: true}, "", c.args...)
		if code != exitOK {
			t.Errorf("help(%v) exit = %d, want %d", c.args, code, exitOK)
		}
		for _, w := range c.want {
			if !strings.Contains(stdout, w) {
				t.Errorf("help(%v) missing %q:\n%s", c.args, w, stdout)
			}
		}
	}
}

// ---- run/remove wiring (W3, D33–D43) --------------------------------------

// cliAddNoteSrc is the run/remove wiring fixture: one CREATE (guarded IF
// ABSENT), one marked INSERT, a FILE assert, a LOCAL CMD assert carrying a
// trailing hash-comment (display-strip probe) and a TIER ci CMD (deferred).
const cliAddNoteSrc = `COMMAND "add-note" DESCRIPTION "CLI wiring fixture: one CREATE plus one marked INSERT." CONCEPT "cli-note" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.note-name}}.txt"
::: note file :::
note {{.note-name}}
::: note file :::

IN "docs/list.txt"
INSERT AFTER FIRST
::: list head :::
head-anchor
::: list head :::
WITH
::: note entry :::
entry {{.note-name}} MARK:note-entry-{{.note-name}}
::: note entry :::
MARK "note-entry-{{.note-name}}"

ASSERT FILE "docs/{{.note-name}}.txt" CONTAINS "note {{.note-name}}"
ASSERT CMD "true # local sanity gate"
ASSERT CMD "cd api && mix test" TIER ci
`

// cliRemoveNoteSrc is a DIRECTION "remove" command — a `bp scaffy run`
// target; handing it to `bp scaffy remove` must be a usage error (D36).
const cliRemoveNoteSrc = `COMMAND "remove-note" DESCRIPTION "Retract a note (authored inverse)." CONCEPT "cli-note" DIRECTION "remove"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

IN "docs/list.txt"
REMOVE
::: note entry :::
entry {{.note-name}} MARK:note-entry-{{.note-name}}
::: note entry :::
MARK "note-entry-{{.note-name}}"
ASLONG FILE CONTAIN "MARK:note-entry-{{.note-name}}"
`

func writeCliFile(t *testing.T, root, rel, content string) {
	t.Helper()
	abs := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// seedCliNoteTree builds a temp repo tree for the fixture and chdirs into it
// (run/remove resolve the repo root from the cwd).
func seedCliNoteTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeCliFile(t, root, "add-note.scaffy", cliAddNoteSrc)
	writeCliFile(t, root, "remove-note.scaffy", cliRemoveNoteSrc)
	writeCliFile(t, root, "docs/list.txt", "head-anchor\ntail\n")
	t.Chdir(root)
	return root
}

// snapshotCliTree captures every file under root except .scaffy/ (receipts
// are allowed to persist across a byte-clean run→remove cycle).
func snapshotCliTree(t *testing.T, root string) map[string]string {
	t.Helper()
	snap := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if info.IsDir() {
			if rel == ".scaffy" {
				return filepath.SkipDir
			}
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		snap[rel] = string(b)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

func TestScaffyRunAppliesWritesReceiptAndRerunNoOps(t *testing.T) {
	root := seedCliNoteTree(t)

	code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("run exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	// House voice, one line per op / per assert (D39).
	for _, want := range []string{
		"● created docs/alpha.txt",
		"○ injected docs/list.txt @MARK:note-entry-alpha",
		"✔ pass file-contains",
		"✔ pass cmd true",
		"… deferred cmd cd api && mix test — TIER ci, runs in the PR",
		"receipt: ",
		"applied — 1 created, 1 injected, 1 mark(s), ",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("run output missing %q:\n%s", want, stdout)
		}
	}
	// The LOCAL CMD echo strips its trailing hash-comment for display only.
	if strings.Contains(stdout, "local sanity gate") {
		t.Errorf("CMD echo did not strip the trailing hash-comment:\n%s", stdout)
	}
	// Files landed and the fat receipt exists under .scaffy/receipts/.
	if got := readCliFile(t, root, "docs/alpha.txt"); got != "note alpha\n" {
		t.Errorf("created file = %q", got)
	}
	if !strings.Contains(readCliFile(t, root, "docs/list.txt"), "entry alpha MARK:note-entry-alpha") {
		t.Error("injected entry missing from docs/list.txt")
	}
	receipts, err := filepath.Glob(filepath.Join(root, ".scaffy", "receipts", "*.json"))
	if err != nil || len(receipts) != 1 {
		t.Fatalf("want exactly 1 receipt, got %v (err %v)", receipts, err)
	}

	// Re-run: every op skips clean, exit 0, receipt not clobbered.
	snap := snapshotCliTree(t, root)
	code, stdout, _ = runScaffyTest(t, globals{}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("re-run exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	for _, want := range []string{"= skipped docs/alpha.txt — file already exists (IF ABSENT)", "= skipped docs/list.txt", "no-op — nothing to do (2 skipped)"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("re-run output missing %q:\n%s", want, stdout)
		}
	}
	if after := snapshotCliTree(t, root); len(after) != len(snap) {
		t.Errorf("no-op re-run changed the tree: %d files -> %d", len(snap), len(after))
	} else {
		for rel, b := range snap {
			if after[rel] != b {
				t.Errorf("no-op re-run mutated %s", rel)
			}
		}
	}
}

func readCliFile(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

func TestScaffyRemoveRoundTripsByteClean(t *testing.T) {
	root := seedCliNoteTree(t)
	before := snapshotCliTree(t, root)

	if code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha"); code != exitOK {
		t.Fatalf("run exit = %d\n%s\n%s", code, stdout, stderr)
	}
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "remove", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("remove exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	for _, want := range []string{"✕ deleted docs/alpha.txt", "✕ removed docs/list.txt @MARK:note-entry-alpha", "removed — 1 removed, 1 deleted"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("remove output missing %q:\n%s", want, stdout)
		}
	}
	// Byte-clean (D34): the tree outside .scaffy/ is exactly the pre-run tree.
	after := snapshotCliTree(t, root)
	if len(after) != len(before) {
		t.Fatalf("remove not byte-clean: %d files, want %d\nafter: %v", len(after), len(before), after)
	}
	for rel, b := range before {
		if after[rel] != b {
			t.Errorf("remove left %s dirty:\n%s", rel, after[rel])
		}
	}

	// Idempotent second remove: every op skips clean, exit 0.
	code, stdout, _ = runScaffyTest(t, globals{}, "", "remove", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("second remove exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	if !strings.Contains(stdout, "no-op — already retracted (2 skipped)") {
		t.Errorf("second remove should be an already-retracted no-op:\n%s", stdout)
	}
}

func TestScaffyRemoveMissingReceiptExitsFour(t *testing.T) {
	seedCliNoteTree(t)
	// Never run at all → no receipt for any key.
	code, _, stderr := runScaffyTest(t, globals{}, "", "remove", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitNotFound {
		t.Fatalf("remove-without-receipt exit = %d, want %d\nstderr:\n%s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "no receipt") {
		t.Errorf("stderr should explain the receipt miss:\n%s", stderr)
	}

	// Run with Alpha, remove with Beta: different vars key a different
	// receipt — a miss, never a fuzzy match.
	if code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha"); code != exitOK {
		t.Fatalf("run exit = %d\n%s\n%s", code, stdout, stderr)
	}
	code, _, _ = runScaffyTest(t, globals{}, "", "remove", "add-note.scaffy", "--var", "NoteName=Beta")
	if code != exitNotFound {
		t.Fatalf("wrong-vars remove exit = %d, want %d", code, exitNotFound)
	}
}

func TestScaffyRemoveDirectionRemoveIsUsageError(t *testing.T) {
	seedCliNoteTree(t)
	code, _, stderr := runScaffyTest(t, globals{}, "", "remove", "remove-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitUsage {
		t.Fatalf("remove of a DIRECTION-remove command exit = %d, want %d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "D36") || !strings.Contains(stderr, "bp scaffy run") {
		t.Errorf("refusal must cite D36 and point at `bp scaffy run`:\n%s", stderr)
	}
}

func TestScaffyRunJSONEnvelope(t *testing.T) {
	seedCliNoteTree(t)
	code, stdout, _ := runScaffyTest(t, globals{}, "json", "run", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	var env struct {
		OK        bool              `json:"ok"`
		Command   string            `json:"command"`
		Direction string            `json:"direction"`
		Vars      map[string]string `json:"vars"`
		Ops       []struct {
			Kind   string `json:"kind"`
			Path   string `json:"path"`
			Status string `json:"status"`
		} `json:"ops"`
		Asserts []struct {
			Kind   string `json:"kind"`
			Status string `json:"status"`
			Tier   string `json:"tier"`
		} `json:"asserts"`
		Receipt    string `json:"receipt"`
		DurationMS *int64 `json:"duration_ms"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a JSON envelope: %v\n%s", err, stdout)
	}
	if !env.OK || env.Command != "add-note" || env.Direction != "add" {
		t.Errorf("envelope head wrong: ok=%v command=%q direction=%q", env.OK, env.Command, env.Direction)
	}
	if env.Vars["NoteName"] != "Alpha" {
		t.Errorf("vars = %v", env.Vars)
	}
	if len(env.Ops) != 2 || env.Ops[0].Status != "created" || env.Ops[1].Status != "injected" {
		t.Errorf("ops = %+v", env.Ops)
	}
	if len(env.Asserts) != 3 || env.Asserts[2].Status != "deferred" || env.Asserts[2].Tier != "ci" {
		t.Errorf("asserts = %+v", env.Asserts)
	}
	if env.Receipt == "" {
		t.Error("receipt path missing from the envelope")
	}
	if env.DurationMS == nil {
		t.Error("duration_ms missing from the envelope")
	}
}

func TestScaffyRunDryRunTouchesNothing(t *testing.T) {
	root := seedCliNoteTree(t)
	before := snapshotCliTree(t, root)

	code, stdout, stderr := runScaffyTest(t, globals{dryRun: true}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("dry-run exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	for _, want := range []string{
		"● would create docs/alpha.txt",
		"○ would inject docs/list.txt @MARK:note-entry-alpha",
		"+note alpha",           // per-file -/+ diff (D39)
		"… would run cmd true",  // LOCAL CMD listed, never executed
		"… deferred cmd cd api", // TIER ci stays deferred
		"dry-run — 1 created, 1 injected, 1 mark(s)",
		"nothing written, no receipt",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("dry-run output missing %q:\n%s", want, stdout)
		}
	}
	// ZERO writes: tree byte-identical, no receipt, no .scaffy dir at all.
	after := snapshotCliTree(t, root)
	if len(after) != len(before) {
		t.Fatalf("dry-run wrote files: %d -> %d", len(before), len(after))
	}
	for rel, b := range before {
		if after[rel] != b {
			t.Errorf("dry-run mutated %s", rel)
		}
	}
	if _, err := os.Stat(filepath.Join(root, ".scaffy")); !os.IsNotExist(err) {
		t.Errorf(".scaffy/ exists after a dry-run (stat err %v) — no receipt may be written", err)
	}
}

func TestScaffyRunValidationFindingsExitFive(t *testing.T) {
	// The red fixture fails the validate-first gate: exit 5, nothing applied.
	code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", scaffyRedFile)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	if !strings.Contains(stdout, "E-020") {
		t.Errorf("findings should print compiler-style:\n%s", stdout)
	}
	if !strings.Contains(stderr, "nothing applied") {
		t.Errorf("stderr should state nothing was applied:\n%s", stderr)
	}
}

func TestScaffyRunMissingCommandFileExitsFour(t *testing.T) {
	code, _, stderr := runScaffyTest(t, globals{}, "", "run", "no/such/command.scaffy")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "no/such/command.scaffy") {
		t.Errorf("stderr should name the missing command file:\n%s", stderr)
	}
}

func TestScaffyRemoveDriftExitsFive(t *testing.T) {
	root := seedCliNoteTree(t)
	if code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "add-note.scaffy", "--var", "NoteName=Alpha"); code != exitOK {
		t.Fatalf("run exit = %d\n%s\n%s", code, stdout, stderr)
	}
	// Hand-mutate the created file: remove must refuse with SCAFFY-DRIFT
	// (exit 5) and write NOTHING.
	writeCliFile(t, root, "docs/alpha.txt", "note alpha\nhand edit\n")
	before := snapshotCliTree(t, root)

	code, stdout, stderr := runScaffyTest(t, globals{}, "", "remove", "add-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitValidation {
		t.Fatalf("drifted remove exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	if !strings.Contains(stdout, "SCAFFY-DRIFT") {
		t.Errorf("drift refusal must print a SCAFFY-DRIFT finding:\n%s", stdout)
	}
	if !strings.Contains(stderr, "nothing written") {
		t.Errorf("stderr should state nothing was written:\n%s", stderr)
	}
	after := snapshotCliTree(t, root)
	for rel, b := range before {
		if after[rel] != b {
			t.Errorf("refused remove mutated %s", rel)
		}
	}
}

// TestScaffyPureLocal pins the D31 no-network law structurally: scaffy_cmd.go
// must never resolve a server context or load the manifest.
func TestScaffyPureLocal(t *testing.T) {
	src, err := os.ReadFile("scaffy_cmd.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, banned := range []string{"resolveContext", "loadManifest"} {
		if bytes.Contains(src, []byte(banned)) {
			t.Errorf("scaffy_cmd.go calls %s — bp scaffy must stay pure-local (D31)", banned)
		}
	}
}

// TestScaffyOpLineReplaceVoice pins the apply transcript voice for
// REPLACE-family ops: '○ replaced' (not '○ injected'), matching the
// remove-side '● restored'. Dry-run speaks 'would replace'. The glyph
// stays ○ — REPLACE is an in-file content edit, the inject family.
func TestScaffyOpLineReplaceVoice(t *testing.T) {
	op := scaffy.OpResult{Kind: "replace", Path: "api/config/config.exs", Status: scaffy.OpReplaced, Mark: "cron-timeline"}
	if got, want := scaffyOpLine(op, false), "○ replaced api/config/config.exs @MARK:cron-timeline"; got != want {
		t.Errorf("apply voice:\n got %q\nwant %q", got, want)
	}
	if got, want := scaffyOpLine(op, true), "○ would replace api/config/config.exs @MARK:cron-timeline"; got != want {
		t.Errorf("dry-run voice:\n got %q\nwant %q", got, want)
	}
	// It must NOT regress to the inject wording.
	if strings.Contains(scaffyOpLine(op, false), "injected") {
		t.Error("REPLACE op still says 'injected'")
	}
}
