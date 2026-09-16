package cli

// Arms for the foreign-repo adoption hint on `bp scaffy pull`.
//
// The pair that matters: one arm REDS if the hint is reverted (a first pull
// into a repo with no .scaffy/ ignore line must say so), and three arms stay
// QUIET when the hint would be noise (a second pull, a repo that already
// ignores the store, and the machine-readable envelope). A fourth pins the
// honest failure direction: an unwritable marker store repeats the greeting
// instead of silently swallowing it forever.
//
// Nothing here touches a real .gitignore or the developer's real config dir:
// every test runs in a temp cwd with a temp marker home and a stubbed
// check-ignore, and each asserts pull left no .gitignore behind.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTempHintMarkerHome points the already-greeted marker at a temp dir.
// os.UserConfigDir does NOT follow XDG_CONFIG_HOME on darwin, so the package
// var is the only safe seam.
func withTempHintMarkerHome(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	prev := userConfigDir
	userConfigDir = func() (string, error) { return dir, nil }
	t.Cleanup(func() { userConfigDir = prev })
	return dir
}

// withGitignoreCheckExit pins `git check-ignore` to a chosen exit code: 0
// ignored, 1 not ignored, 128 "not an answer" (no work tree / no git).
func withGitignoreCheckExit(t *testing.T, code int) {
	t.Helper()
	prev := scaffyGitignoreCheckRunner
	scaffyGitignoreCheckRunner = func(string) (int, error) { return code, nil }
	t.Cleanup(func() { scaffyGitignoreCheckRunner = prev })
}

// pullNoteForHintTest runs one `scaffy pull note` against a fixture server.
func pullNoteForHintTest(t *testing.T, output string) (int, string, string) {
	t.Helper()
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	return runScaffyTest(t, globals{server: srv.URL}, output, "pull", "note")
}

func assertNoGitignoreWritten(t *testing.T, root, wantContent string) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(root, ".gitignore"))
	switch {
	case wantContent == "":
		if err == nil {
			t.Errorf("pull created a .gitignore — the hint is print-only:\n%s", got)
		}
	case err != nil:
		t.Fatalf("fixture .gitignore vanished: %v", err)
	case string(got) != wantContent:
		t.Errorf(".gitignore was rewritten:\ngot  %q\nwant %q", got, wantContent)
	}
}

// RED-WHEN-REVERTED arm: the first pull into a repo with no .scaffy/ ignore
// line greets the adopter, and records that it did.
func TestScaffyPullGreetsUnignoredRepoOnce(t *testing.T) {
	withTempConfigHome(t)
	root := chdirTemp(t)
	markerHome := withTempHintMarkerHome(t)

	code, stdout, stderr := pullNoteForHintTest(t, "")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	for _, want := range []string{".scaffy/", "your .gitignore", "receipts"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("first pull did not greet the adopter (missing %q):\n%s", want, stdout)
		}
	}
	assertNoGitignoreWritten(t, root, "")

	marker, err := scaffyGitignoreHintMarker(root)
	if err != nil {
		t.Fatalf("marker path: %v", err)
	}
	if !strings.HasPrefix(marker, markerHome) {
		t.Fatalf("marker %q escaped the temp config home %q", marker, markerHome)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Errorf("first pull printed the hint but recorded no marker: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".scaffy")); err == nil {
		t.Error("the hint created .scaffy/ in the adopted repo — the bit must live outside it")
	}
}

// QUIET arm #1: a second pull into the same repo says nothing.
func TestScaffyPullGreetsOnlyOncePerRepo(t *testing.T) {
	withTempConfigHome(t)
	root := chdirTemp(t)
	withTempHintMarkerHome(t)

	if code, stdout, _ := pullNoteForHintTest(t, ""); code != exitOK || !strings.Contains(stdout, "your .gitignore") {
		t.Fatalf("precondition: first pull must greet (exit %d):\n%s", code, stdout)
	}
	code, stdout, stderr := pullNoteForHintTest(t, "")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	if strings.Contains(stdout, "your .gitignore") {
		t.Errorf("second pull repeated the one-time hint:\n%s", stdout)
	}
	assertNoGitignoreWritten(t, root, "")
}

// QUIET arm #2: a repo that already ignores the store hears nothing on the
// FIRST pull — both when git answers and when only the file can be read.
func TestScaffyPullSaysNothingWhenStoreAlreadyIgnored(t *testing.T) {
	const content = "node_modules/\n.scaffy/\n"

	t.Run("literal gitignore", func(t *testing.T) {
		withTempConfigHome(t)
		root := chdirTemp(t) // pins check-ignore to "not an answer"
		withTempHintMarkerHome(t)
		if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		code, stdout, stderr := pullNoteForHintTest(t, "")
		if code != exitOK {
			t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
		}
		if strings.Contains(stdout, "your .gitignore") {
			t.Errorf("greeted a repo that already ignores the store:\n%s", stdout)
		}
		assertNoGitignoreWritten(t, root, content)
	})

	t.Run("git says ignored with no .gitignore at this root", func(t *testing.T) {
		withTempConfigHome(t)
		root := chdirTemp(t)
		withTempHintMarkerHome(t)
		withGitignoreCheckExit(t, 0) // e.g. .git/info/exclude or a parent .gitignore
		code, stdout, stderr := pullNoteForHintTest(t, "")
		if code != exitOK {
			t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
		}
		if strings.Contains(stdout, "your .gitignore") {
			t.Errorf("greeted although git reports the store ignored:\n%s", stdout)
		}
		assertNoGitignoreWritten(t, root, "")
	})

	t.Run("git says not ignored despite a decoy line", func(t *testing.T) {
		withTempConfigHome(t)
		root := chdirTemp(t)
		withTempHintMarkerHome(t)
		// The file lists the store, but git — which sees the whole rule
		// stack, negations included — reports it NOT ignored. git wins.
		if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte(".scaffy/\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		withGitignoreCheckExit(t, 1)
		code, stdout, _ := pullNoteForHintTest(t, "")
		if code != exitOK {
			t.Fatalf("exit = %d, want %d", code, exitOK)
		}
		if !strings.Contains(stdout, "your .gitignore") {
			t.Errorf("git answered NOT ignored and the hint stayed silent:\n%s", stdout)
		}
	})
}

// QUIET arm #3: the machine envelope is a contract — no advice lines in it.
func TestScaffyPullJSONCarriesNoHint(t *testing.T) {
	withTempConfigHome(t)
	root := chdirTemp(t)
	withTempHintMarkerHome(t)

	code, stdout, stderr := pullNoteForHintTest(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	if strings.Contains(stdout, "your .gitignore") {
		t.Errorf("hint leaked into the JSON envelope:\n%s", stdout)
	}
	assertNoGitignoreWritten(t, root, "")

	// And the mark was NOT taken, so a later human pull still greets.
	code, stdout, _ = pullNoteForHintTest(t, "")
	if code != exitOK || !strings.Contains(stdout, "your .gitignore") {
		t.Errorf("a json pull silenced the greeting for the following human pull (exit %d):\n%s", code, stdout)
	}
}

// HONEST FAILURE arm: when the marker store cannot be reached, the hint
// REPEATS. Noisy is acceptable; silent-forever is not.
func TestScaffyPullHintRepeatsWhenMarkerStoreUnavailable(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	prev := userConfigDir
	userConfigDir = func() (string, error) { return "", os.ErrNotExist }
	t.Cleanup(func() { userConfigDir = prev })

	for i := 1; i <= 2; i++ {
		code, stdout, stderr := pullNoteForHintTest(t, "")
		if code != exitOK {
			t.Fatalf("pull %d: exit = %d, want %d\nstderr:\n%s", i, code, exitOK, stderr)
		}
		if !strings.Contains(stdout, "your .gitignore") {
			t.Errorf("pull %d went silent with no marker store — suppression must never outlive a failed write:\n%s", i, stdout)
		}
	}
}

func TestScaffyStoreIsIgnoredByFile(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    bool
	}{
		{"missing file", "", false},
		{"unrelated lines", "node_modules/\n*.log\n", false},
		{"bare dir", ".scaffy/\n", true},
		{"no slash", ".scaffy\n", true},
		{"rooted", "/.scaffy/\n", true},
		{"contents glob", ".scaffy/*\n", true},
		{"anydepth", "**/.scaffy\n", true},
		{"indented with comment above", "# receipts\n  .scaffy/  \n", true},
		{"commented out", "#.scaffy/\n", false},
		{"prefix lookalike", ".scaffyrc\n.scaffy-old/\n", false},
		{"negated after", ".scaffy/\n!.scaffy\n", false},
		{"re-ignored after negation", "!.scaffy\n.scaffy/\n", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".gitignore")
			if tc.content != "" {
				if err := os.WriteFile(path, []byte(tc.content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if got := scaffyStoreIsIgnoredByFile(path); got != tc.want {
				t.Errorf("ignored = %v, want %v for:\n%s", got, tc.want, tc.content)
			}
		})
	}
}

// git's verdict wins when it gives one; an exit that is not a verdict falls
// back to the literal scan rather than guessing either way.
func TestScaffyStoreIsIgnoredGitPrecedence(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("node_modules/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withGitignoreCheckExit(t, 0)
	if !scaffyStoreIsIgnored(root) {
		t.Error("git exit 0 (ignored) was not honoured over the file scan")
	}
	withGitignoreCheckExit(t, 1)
	if scaffyStoreIsIgnored(root) {
		t.Error("git exit 1 (not ignored) was not honoured")
	}
	withGitignoreCheckExit(t, 128)
	if scaffyStoreIsIgnored(root) {
		t.Error("no git verdict must fall back to the file, which does not list the store")
	}
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("node_modules/\n.scaffy/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !scaffyStoreIsIgnored(root) {
		t.Error("no git verdict must fall back to the file, which now lists the store")
	}
}

// The marker is keyed by the ABSOLUTE root, so two checkouts are two adoptions.
func TestScaffyGitignoreHintMarkerIsPerRoot(t *testing.T) {
	withTempHintMarkerHome(t)
	a, err := scaffyGitignoreHintMarker(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	b, err := scaffyGitignoreHintMarker(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Errorf("two roots share one marker path: %s", a)
	}
}
