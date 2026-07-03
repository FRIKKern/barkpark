package taskboard

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// tasksFrom builds a []Task from doc_id -> title pairs; a "" title is fine.
func tasksFrom(pairs ...[2]string) []Task {
	ts := make([]Task, 0, len(pairs))
	for _, p := range pairs {
		ts = append(ts, Task{DocID: p[0], Title: p[1]})
	}
	return ts
}

func TestCorrelateRepo_Table(t *testing.T) {
	cases := []struct {
		name     string
		subjects []string
		branch   string
		tasks    []Task
		want     map[string]int
	}{
		{
			name:     "plain hit in a subject",
			subjects: []string{"fix t42 crash on paste"},
			tasks:    tasksFrom([2]string{"t42", "paste crash"}),
			want:     map[string]int{"t42": 1},
		},
		{
			name:     "clean miss",
			subjects: []string{"unrelated refactor of the parser"},
			tasks:    tasksFrom([2]string{"t42", "paste crash"}),
			want:     map[string]int{},
		},
		{
			name:     "same id twice in one subject counts twice",
			subjects: []string{"t42 and t42 again in one line"},
			tasks:    tasksFrom([2]string{"t42", ""}),
			want:     map[string]int{"t42": 2},
		},
		{
			name:     "id across two subjects accumulates",
			subjects: []string{"land t42 first", "then revert t42"},
			tasks:    tasksFrom([2]string{"t42", ""}),
			want:     map[string]int{"t42": 2},
		},
		{
			name:     "drafts.-prefixed id matches whole token",
			subjects: []string{"resolve drafts.abc123 lease expiry"},
			tasks: tasksFrom(
				[2]string{"drafts.abc123", ""},
				[2]string{"abc123", ""}, // bare suffix must NOT match after the '.'
			),
			want: map[string]int{"drafts.abc123": 1},
		},
		{
			name:     "hyphenated id does not match a shorter prefix id",
			subjects: []string{"landed drafts.a-doc today"},
			tasks: tasksFrom(
				[2]string{"drafts.a-doc", ""},
				[2]string{"drafts.a", ""}, // '-' is an id char, so no right boundary
			),
			want: map[string]int{"drafts.a-doc": 1},
		},
		{
			name:     "ambiguous short id never matches inside a longer word",
			subjects: []string{"cover t12 and point1 edge cases"},
			tasks: tasksFrom(
				[2]string{"t1", ""},  // inside t12 and point1 -> no match
				[2]string{"t12", ""}, // standalone -> match
			),
			want: map[string]int{"t12": 1},
		},
		{
			name:     "doc_id mentioned in the branch name",
			subjects: nil,
			branch:   "feature/t42",
			tasks:    tasksFrom([2]string{"t42", ""}),
			want:     map[string]int{"t42": 1},
		},
		{
			name:     "title slug matches a branch segment",
			subjects: nil,
			branch:   "loop-epic/repo-correlator-git-log-branch-scan-badg-4",
			tasks:    tasksFrom([2]string{"t99", "Repo correlator git log branch scan"}),
			want:     map[string]int{"t99": 1},
		},
		{
			name:     "short slug is ignored (below the conservative floor)",
			subjects: nil,
			branch:   "feat/fix-bug",
			tasks:    tasksFrom([2]string{"t7", "Fix bug"}), // slug "fix-bug" is 7 < 8
			want:     map[string]int{},
		},
		{
			name:     "slug is only scanned in the branch, never in commit subjects",
			subjects: []string{"refactor: tidy the repo-correlator-git-log path"},
			branch:   "work/doc-fresh",
			tasks:    tasksFrom([2]string{"t50", "Repo correlator git log"}),
			want:     map[string]int{},
		},
		{
			name:     "empty doc_id is skipped",
			subjects: []string{"whatever t42"},
			tasks:    tasksFrom([2]string{"", "no id"}, [2]string{"t42", ""}),
			want:     map[string]int{"t42": 1},
		},
		{
			name:     "zero-value path: no subjects, no branch, no tasks",
			subjects: nil,
			branch:   "",
			tasks:    nil,
			want:     map[string]int{},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := CorrelateRepo(tc.subjects, tc.branch, "demo-repo", tc.tasks)
			if got.RepoName != "demo-repo" {
				t.Errorf("RepoName = %q, want demo-repo", got.RepoName)
			}
			if got.Branch != tc.branch {
				t.Errorf("Branch = %q, want %q", got.Branch, tc.branch)
			}
			if got.Mentioned == nil {
				t.Fatalf("Mentioned is nil; CorrelateRepo must always return a non-nil map")
			}
			if !reflect.DeepEqual(got.Mentioned, tc.want) {
				t.Errorf("Mentioned = %v, want %v", got.Mentioned, tc.want)
			}
		})
	}
}

// TestCorrelateRepo_Fixture drives the pure scanner against a real git-log
// subject list captured in testdata, exercising hits, misses, the drafts.
// prefix, short-id safety, and a branch-slug match together.
func TestCorrelateRepo_Fixture(t *testing.T) {
	subjects := loadFixtureSubjects(t, "gitlog_fixture.txt")
	const branch = "work/doc-fresh"

	tasks := tasksFrom(
		[2]string{"t42", "grid paste"},           // subjects 3 + 4 -> 2
		[2]string{"drafts.abc123", "lease expiry"}, // subject 2 -> 1
		[2]string{"abc123", "bare id"},             // suffix after '.' -> 0
		[2]string{"t1", "one"},                     // inside t12/point1 -> 0
		[2]string{"t12", "twelve"},                 // subject 5 -> 1
		[2]string{"point1", "pointer"},             // subject 5 -> 1
		[2]string{"t99", "Doc fresh"},              // slug "doc-fresh" in branch -> 1
		[2]string{"t50", "Repo correlator git log"}, // slug only in a subject -> 0
	)

	want := map[string]int{
		"t42":           2,
		"drafts.abc123": 1,
		"t12":           1,
		"point1":        1,
		"t99":           1,
	}

	got := CorrelateRepo(subjects, branch, "barkpark", tasks)
	if !reflect.DeepEqual(got.Mentioned, want) {
		t.Errorf("Mentioned = %v, want %v", got.Mentioned, want)
	}
}

func TestCorrelateRepo_PreservesIdentityWithNoTasks(t *testing.T) {
	got := CorrelateRepo([]string{"some subject"}, "my-branch", "my-repo", nil)
	if got.RepoName != "my-repo" || got.Branch != "my-branch" {
		t.Errorf("identity not preserved: %+v", got)
	}
	if got.Mentioned == nil || len(got.Mentioned) != 0 {
		t.Errorf("Mentioned = %v, want empty non-nil map", got.Mentioned)
	}
}

func TestSlugify(t *testing.T) {
	cases := map[string]string{
		"Repo correlator git log": "repo-correlator-git-log",
		"  Fix   the BUG!! ":       "fix-the-bug",
		"already-kebab":            "already-kebab",
		"":                         "",
		"---":                      "",
		"v2.1 API layer":           "v2-1-api-layer", // punctuation collapses to one hyphen
	}
	for in, want := range cases {
		if got := slugify(in); got != want {
			t.Errorf("slugify(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestGatherRepoContext_NotARepo confirms the shell fails closed: a directory
// that is not a git repo (or a host with no git binary) yields the zero value.
func TestGatherRepoContext_NotARepo(t *testing.T) {
	got := GatherRepoContext(t.TempDir())
	if !reflect.DeepEqual(got, RepoContext{}) {
		t.Errorf("GatherRepoContext(non-repo) = %+v, want zero RepoContext", got)
	}
}

// TestGatherRepoContext_TempRepo builds a throwaway repo and checks the shell
// resolves its name and branch. Skipped when git is unavailable.
func TestGatherRepoContext_TempRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
			"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init")
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "-m", "seed: task t42 lands")
	git("branch", "-M", "wt-branch")

	got := GatherRepoContext(dir)
	if got.RepoName == "" {
		t.Errorf("RepoName is empty; want the temp dir's base name")
	}
	if got.Branch != "wt-branch" {
		t.Errorf("Branch = %q, want wt-branch", got.Branch)
	}
	if got.Mentioned == nil {
		t.Errorf("Mentioned is nil; a detected repo must carry a non-nil map")
	}
}

// TestGatherGit_TempRepoSubjects proves the reusable seam returns commit
// subjects the integration slice can feed to CorrelateRepo. Skipped w/o git.
func TestGatherGit_TempRepoSubjects(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
			"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init")
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "-m", "seed: wire drafts.abc123 lease")

	name, branch, subjects, ok := gatherGit(dir)
	if !ok {
		t.Fatal("gatherGit ok=false on a valid repo")
	}
	if name == "" {
		t.Error("empty repo name")
	}
	_ = branch // default branch name varies by git config; not asserted
	joined := strings.Join(subjects, "\n")
	if !strings.Contains(joined, "drafts.abc123") {
		t.Errorf("subjects missing the seed commit: %q", joined)
	}

	// End-to-end: the gathered subjects correlate to the task.
	rc := CorrelateRepo(subjects, branch, name, tasksFrom([2]string{"drafts.abc123", ""}))
	if rc.Mentioned["drafts.abc123"] != 1 {
		t.Errorf("Mentioned = %v, want drafts.abc123:1", rc.Mentioned)
	}
}

func loadFixtureSubjects(t *testing.T, name string) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var subjects []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			subjects = append(subjects, line)
		}
	}
	return subjects
}
