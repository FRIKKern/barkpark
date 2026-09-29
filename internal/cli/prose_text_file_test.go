package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// proseSpecimen is the round-trip payload the row names: backticks, a $(...),
// a literal newline, and a double quote. Written as a Go string literal so no
// shell is ever involved in producing it.
const proseSpecimen = "Line one with a `echo INJECTED_BY_SHELL` and $(echo ALSO_INJECTED) plus a \"double quote\".\n" +
	"Line two: $HOME and a literal newline above this one.\n" +
	"Line three: ends here."

func writeSpecimen(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// resolvedValue pulls the value the resolver put on --<field>= out of a tail.
func resolvedValue(t *testing.T, tail []string, field string) string {
	t.Helper()
	for _, a := range tail {
		if name, val, inline := splitFlagToken(a); inline && name == "--"+field {
			return val
		}
	}
	t.Fatalf("no --%s=<value> in resolved tail %q", field, tail)
	return ""
}

// ── c0: THE FILE DOOR DELIVERS THE BYTES ────────────────────────────────────

// TestProseFileDeliversBytesIdentically is the unit half of the round trip: the
// bytes on disk are the bytes that leave this process. FAILS IF the resolver
// ever trims, unquotes, re-encodes or line-wraps the value.
func TestProseFileDeliversBytesIdentically(t *testing.T) {
	for _, field := range []string{"description", "title"} {
		p := writeSpecimen(t, field+".txt", proseSpecimen+"\n") // one redirect newline
		got, err := resolveProseTextFiles([]string{"a title", "--" + field + "-file", p}, nil, nil)
		if err != nil {
			t.Fatalf("%s: %v", field, err)
		}
		if v := resolvedValue(t, got, field); v != proseSpecimen {
			t.Fatalf("%s: bytes changed\n want %q\n  got %q", field, proseSpecimen, v)
		}
	}
}

// TestProseFileStdinArm proves `-` reads stdin with the same byte fidelity.
func TestProseFileStdinArm(t *testing.T) {
	old := proseStdin
	t.Cleanup(func() { proseStdin = old })
	proseStdin = strings.NewReader(proseSpecimen + "\n")

	got, err := resolveProseTextFiles([]string{"--description-file", "-"}, nil, nil)
	if err != nil {
		t.Fatalf("stdin arm: %v", err)
	}
	if v := resolvedValue(t, got, "description"); v != proseSpecimen {
		t.Fatalf("stdin arm changed bytes:\n want %q\n  got %q", proseSpecimen, v)
	}
}

// ── c1: THE POSITIVE CONTROL — A SHELL REALLY DOES SUBSTITUTE ───────────────
//
// THE CONTROL MUST BE ABLE TO DIFFER FROM ITS SUBJECT. The subject above never
// touches a shell, so on its own it would pass on a build where the file flag
// did not exist and the value were simply typed. This test runs the SAME bytes
// through a real shell as an inline double-quoted argument — exactly how an
// author types them — and asserts what arrives is NOT the specimen.
//
// It uses /bin/sh, not $SHELL, because the substitution rule under test
// (backticks and $(...) inside double quotes) is POSIX and therefore present in
// every shell CI could hand us, and because a harness that exec's argv directly
// performs no substitution at all — which would make this a second copy of the
// subject instead of a control. The shell is invoked EXPLICITLY here so there
// is nothing to assume about the harness. (Measured on the authoring host:
// /bin/zsh 5.9; same result.)
func TestInlineArgumentIsMangledByARealShell(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skipf("no sh on PATH: %v", err)
	}

	// The MINIMUM an author does to make the command parse: escape the inner
	// double quote. Backticks, $(...) and $HOME are left exactly as typed.
	inline := strings.ReplaceAll(proseSpecimen, `"`, `\"`)
	script := `printf '%s' "` + inline + `"`

	out, err := exec.Command(sh, "-c", script).Output()
	if err != nil {
		t.Fatalf("running the control through %s: %v", sh, err)
	}
	got := string(out)

	// PRECONDITION, asserted rather than assumed: the shell must actually have
	// substituted. If this arm ever stops firing the test below is vacuous.
	if !strings.Contains(got, "INJECTED_BY_SHELL") || strings.Contains(got, "`") {
		t.Fatalf("control did not substitute — %s left the backticks alone; this test measures nothing as written.\n got %q", sh, got)
	}
	if got == proseSpecimen {
		t.Fatalf("INLINE and FILE stored identical bytes — the control cannot fail, so the file-door test proves nothing.\n got %q", got)
	}
	t.Logf("control: inline arg arrived as %d bytes, file arg is %d bytes; differ = %v", len(got), len(proseSpecimen), got != proseSpecimen)
}

// ── c2: AN IMPLAUSIBLE PAYLOAD IS NOTICED ───────────────────────────────────

// TestProseInlineCeilingMutationArm is the MUTATION ARM the row asks for: one
// byte over the line is refused and the refusal NAMES the limit; the line
// itself passes through unchanged.
func TestProseInlineCeilingMutationArm(t *testing.T) {
	for _, p := range proseCeilings() {
		over := strings.Repeat("a", p.refuseBytes+1)
		_, err := resolveProseTextFiles([]string{"--" + p.name, over}, nil, nil)
		if err == nil {
			t.Fatalf("%s: %d bytes was accepted; the ceiling is %d", p.name, len(over), p.refuseBytes)
		}
		for _, want := range []string{
			itoa(p.refuseBytes), // the limit itself
			itoa(len(over)),     // what arrived
			p.fileFlag(),        // the documented way past it
		} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("%s: refusal does not name %q:\n%v", p.name, want, err)
			}
		}

		under := strings.Repeat("b", p.refuseBytes)
		got, err := resolveProseTextFiles([]string{"--" + p.name, under}, nil, nil)
		if err != nil {
			t.Fatalf("%s: %d bytes (exactly the limit) was refused: %v", p.name, len(under), err)
		}
		// Unchanged: the resolver leaves a space-form inline flag alone.
		if strings.Join(got, "\x00") != strings.Join([]string{"--" + p.name, under}, "\x00") {
			t.Fatalf("%s: a value at the limit was altered in passing", p.name)
		}
	}
}

// TestProseFileIsTheDocumentedWayPastTheCeiling — the same oversize payload is
// ACCEPTED from a file, because the file is the escape the refusal names. A
// ceiling with no way past it would just move the outage.
func TestProseFileIsTheDocumentedWayPastTheCeiling(t *testing.T) {
	for _, p := range proseCeilings() {
		body := strings.Repeat("a", p.refuseBytes+1)
		path := writeSpecimen(t, p.name+"-big.txt", body)

		var warned []string
		got, err := resolveProseTextFiles([]string{p.fileFlag(), path}, nil,
			func(f string, a ...any) { warned = append(warned, f) })
		if err != nil {
			t.Fatalf("%s: the file door refused an oversize payload it is supposed to allow: %v", p.name, err)
		}
		if v := resolvedValue(t, got, p.name); v != body {
			t.Fatalf("%s: oversize file payload was altered", p.name)
		}
		if len(warned) == 0 {
			t.Fatalf("%s: an oversize payload from a file was stored SILENTLY — the row's whole point is that it is noticed", p.name)
		}
	}
}

// TestProseWarnThresholdIsLoudButNotFatal — between warn and refuse a value is
// written AND announced.
func TestProseWarnThresholdIsLoudButNotFatal(t *testing.T) {
	p := proseCeilings()[0] // description
	body := strings.Repeat("a", p.warnBytes+1)
	var warned int
	if _, err := resolveProseTextFiles([]string{"--" + p.name, body}, nil,
		func(string, ...any) { warned++ }); err != nil {
		t.Fatalf("a value above the WARN line must still be written: %v", err)
	}
	if warned != 1 {
		t.Fatalf("want exactly one warning above %d bytes, got %d", p.warnBytes, warned)
	}
	// CONTROL: one byte below the warn line is silent.
	warned = 0
	quiet := strings.Repeat("a", p.warnBytes)
	if _, err := resolveProseTextFiles([]string{"--" + p.name, quiet}, nil,
		func(string, ...any) { warned++ }); err != nil {
		t.Fatalf("unexpected refusal at the warn line: %v", err)
	}
	if warned != 0 {
		t.Fatalf("a value AT the warn line warned %d times — the threshold is off by one", warned)
	}
}

// ── REFUSALS THAT MUST NOT FALL BACK TO AN UNGUARDED WRITE ──────────────────

func TestProseFileRefusals(t *testing.T) {
	empty := writeSpecimen(t, "empty.txt", "   \n")
	good := writeSpecimen(t, "good.txt", "some prose")

	cases := []struct {
		name string
		tail []string
		want string
	}{
		{"no path", []string{"--description-file"}, "needs a path"},
		{"flag-shaped path", []string{"--description-file", "--publish"}, "needs a path"},
		{"empty path", []string{"--description-file="}, "empty path"},
		{"unreadable", []string{"--description-file", filepath.Join(t.TempDir(), "nope.txt")}, "reading the description from"},
		{"blank file", []string{"--description-file", empty}, "is empty"},
		{"passed twice", []string{"--description-file", good, "--description-file", good}, "passed twice"},
		{"both doors", []string{"--description", "x", "--description-file", good}, "not both"},
		{"both doors, other order", []string{"--description-file", good, "--description", "x"}, "not both"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveProseTextFiles(c.tail, nil, nil)
			if err == nil {
				t.Fatalf("accepted %q -> %q; a write that cannot read its own prose must send nothing", c.tail, got)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("refusal does not say %q: %v", c.want, err)
			}
		})
	}
}

// ── SCOPE: A COMMAND ONLY GROWS THE SIBLINGS IT ALREADY DECLARES ────────────

func TestProseFileScopeFollowsTheManifest(t *testing.T) {
	descOnly := manifest.Command{Flags: []manifest.Flag{{Name: "description", Type: "string"}}}
	scope := proseFileScopeForCommand(descOnly)
	if !scope["description"] || scope["title"] {
		t.Fatalf("scope for a description-only command = %v; want description only", scope)
	}
	// --title-file is then NOT consumed: it must fall through to splitArgs and
	// be refused there as an unknown flag, not silently swallowed here.
	got, err := resolveProseTextFiles([]string{"--title-file", "x.txt"}, scope, nil)
	if err != nil {
		t.Fatalf("out-of-scope flag should pass through untouched: %v", err)
	}
	if strings.Join(got, " ") != "--title-file x.txt" {
		t.Fatalf("out-of-scope flag was rewritten: %q", got)
	}

	none := manifest.Command{Flags: []manifest.Flag{{Name: "publish", Type: "bool"}}}
	if s := proseFileScopeForCommand(none); s != nil {
		t.Fatalf("a command declaring neither prose flag got scope %v", s)
	}

	// A SERVER-DECLARED --description-file wins: the client door stands down so
	// there is one implementation and not two.
	both := manifest.Command{Flags: []manifest.Flag{
		{Name: "description", Type: "string"},
		{Name: "description-file", Type: "string"},
	}}
	if s := proseFileScopeForCommand(both); s["description"] {
		t.Fatalf("client door shadowed a server-declared --description-file: %v", s)
	}
}

// ── c3: THE UNSATISFIABLE REMEDY STAYS WRITTEN DOWN ─────────────────────────
//
// A WRITTEN FINDING DOES NOT FIRE BY ITSELF. The whole load-bearing point of
// this row — that bp CANNOT detect a backtick in an inline argument, because
// the shell substitutes before bp is executed and argv carries only the result
// — is a comment, and a comment is deletable by anyone tidying up. This test is
// its trigger: delete or reword the paragraph and the package goes red, with a
// message saying why the sentence is load-bearing.
func TestUnsatisfiableRemedyIsRecordedAtTheCodeSite(t *testing.T) {
	src, err := os.ReadFile("prose_text_file.go")
	if err != nil {
		t.Fatalf("reading prose_text_file.go: %v", err)
	}
	s := string(src)
	for _, want := range []string{
		"bp CANNOT DETECT A BACKTICK IN AN INLINE ARGUMENT",
		"before bp is executed",
		"argv",
		"UNSATISFIABLE",
		"THIS IS THE REASON THE FILE-BASED FLAG IS THE FIX",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("prose_text_file.go no longer records %q.\n"+
				"That paragraph is the reason this flag exists: without it the next reader files or builds a\n"+
				"content-inspection guard that CANNOT WORK, because the backticks are already gone from argv by\n"+
				"the time bp runs. Restore the sentence rather than this assertion.", want)
		}
	}

	// The same statement must also be reachable from the surface a USER meets,
	// not only from the source a maintainer meets.
	help := strings.Join(proseFileHelpLines(nil), "\n")
	for _, want := range []string{"CANNOT detect", "before bp is executed", "a file is the fix, not validation"} {
		if !strings.Contains(help, want) {
			t.Fatalf("`--help` no longer states %q; a future reader meets the help, not the comment:\n%s", want, help)
		}
	}
}
