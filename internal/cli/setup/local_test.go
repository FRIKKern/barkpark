package setup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// chdir moves the test into dir and restores the old cwd on cleanup.
func chdir(t *testing.T, dir string) {
	t.Helper()
	old, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir %s: %v", dir, err)
	}
	t.Cleanup(func() { _ = os.Chdir(old) })
}

// TestBuildLocalPlanCloneStepOutsideCheckout: with no api/mix.exs anywhere
// above cwd, the local plan prepends the shallow-clone step rooted at
// ${BARKPARK_HOME}/src and requires git in the needs.
func TestBuildLocalPlanCloneStepOutsideCheckout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("BARKPARK_HOME", home)
	chdir(t, t.TempDir())

	p := buildLocalPlan(SetupPlan{Target: TargetLocal}, Options{})
	if len(p.Steps) == 0 || !strings.Contains(p.Steps[0].Description, "clone the barkpark repo") {
		t.Fatalf("first step should be the clone, got %+v", p.Steps)
	}
	wantRoot := filepath.Join(home, "src")
	if !strings.Contains(p.Steps[0].Command, "git clone --depth 1 "+localRepoURL+" "+wantRoot) {
		t.Fatalf("clone command wrong: %q", p.Steps[0].Command)
	}
	foundGit := false
	for _, n := range p.Needs {
		if n.What == "git" {
			foundGit = true
		}
	}
	if !foundGit {
		t.Fatalf("needs should include git when cloning, got %+v", p.Needs)
	}
}

// TestBuildLocalPlanPullOnRerun: when the managed clone dir already exists, the
// prepended step is a fast-forward pull instead of a fresh clone.
func TestBuildLocalPlanPullOnRerun(t *testing.T) {
	home := t.TempDir()
	t.Setenv("BARKPARK_HOME", home)
	if err := os.MkdirAll(filepath.Join(home, "src"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	chdir(t, t.TempDir())

	p := buildLocalPlan(SetupPlan{Target: TargetLocal}, Options{})
	if len(p.Steps) == 0 || !strings.Contains(p.Steps[0].Command, "pull --ff-only") {
		t.Fatalf("re-run should pull --ff-only, got %+v", p.Steps[0])
	}
}

// TestBuildLocalPlanNoCloneInsideCheckout: from the repo itself, no clone step
// and no git need.
func TestBuildLocalPlanNoCloneInsideCheckout(t *testing.T) {
	// The test binary runs inside internal/cli/setup — the walk-up finds the
	// real checkout's api/mix.exs.
	p := buildLocalPlan(SetupPlan{Target: TargetLocal}, Options{})
	for _, s := range p.Steps {
		if strings.Contains(s.Description, "clone the barkpark repo") {
			t.Fatalf("clone step must not appear inside a checkout: %+v", p.Steps)
		}
	}
	for _, n := range p.Needs {
		if n.What == "git" {
			t.Fatalf("git need must not appear inside a checkout, got %+v", p.Needs)
		}
	}
}
