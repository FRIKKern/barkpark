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
		{nil, []string{"usage: bp scaffy <validate|fmt>", "validate <path>...", "fmt [--check] <path>...", "examples:", "exit codes:", "5  validation findings"}},
		{[]string{"validate"}, []string{"usage: bp scaffy validate <path>...", "file:line: RULE-ID message", "exit codes:", "-o json"}},
		{[]string{"fmt"}, []string{"usage: bp scaffy fmt [--check] <path>...", "--check", "exit codes:", "fixpoint"}},
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
