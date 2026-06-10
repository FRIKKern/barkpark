package setup

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
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

// TestCheckNoRunningServerDetectsBarkpark: a server answering 2xx JSON on
// /v1/capabilities is a running Barkpark → the preflight fails early with the
// stop-it / connect-instead options (it would hold DB connections and make
// `mix ecto.reset` die with object_in_use).
func TestCheckNoRunningServerDetectsBarkpark(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/capabilities" {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"server":{"name":"barkpark"},"capabilities":[]}`)
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	err := checkNoRunningServer(srv.URL, SetupPlan{Target: TargetLocal})
	if err == nil {
		t.Fatal("preflight must fail when a Barkpark server is already answering")
	}
	for _, want := range []string{
		"already running",
		"holds database connections",
		"object_in_use",
		"stop it (Ctrl-C in its terminal)",
		"bp setup --target connect --server " + srv.URL,
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("preflight error missing %q:\n%s", want, err)
		}
	}
}

// TestCheckNoRunningServerPassesWhenAbsent: nothing answering (or something
// answering that is not Barkpark-shaped) is NOT a preflight failure.
func TestCheckNoRunningServerPassesWhenAbsent(t *testing.T) {
	// A server that 404s every probe path: not Barkpark.
	srv := httptest.NewServer(http.NotFoundHandler())
	if err := checkNoRunningServer(srv.URL, SetupPlan{Target: TargetLocal}); err != nil {
		t.Fatalf("404-everything server must pass the preflight, got: %v", err)
	}
	// Connection refused: no server at all.
	srv.Close()
	if err := checkNoRunningServer(srv.URL, SetupPlan{Target: TargetLocal}); err != nil {
		t.Fatalf("dead port must pass the preflight, got: %v", err)
	}
	// 2xx but a non-JSON body (some other dev server squatting the port).
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<html>hello</html>")
	}))
	defer other.Close()
	if err := checkNoRunningServer(other.URL, SetupPlan{Target: TargetLocal}); err != nil {
		t.Fatalf("non-Barkpark 2xx must pass the preflight, got: %v", err)
	}
}

// TestWrapEctoResetErrObjectInUse: postgres' object_in_use in the reset step's
// output gets the actionable stop-the-holders hint, with the original error
// preserved in the chain.
func TestWrapEctoResetErrObjectInUse(t *testing.T) {
	base := fmt.Errorf("step %q failed: exit status 1", "reset + seed the database (drop, create, migrate, seed)")
	out := `** (Mix) The database for Barkpark.Repo couldn't be dropped: ERROR 55006 (object_in_use): database "barkpark_dev" is being accessed by other users

There are 11 other sessions using the database.`
	got := wrapEctoResetErr(base, out)
	if !errors.Is(got, base) {
		t.Fatalf("wrapped error must keep the original in the chain, got: %v", got)
	}
	for _, want := range []string{
		"held by other sessions",
		"object_in_use",
		"stop them (Ctrl-C in their terminals)",
		"bp setup --target connect --server " + localServerURL,
	} {
		if !strings.Contains(got.Error(), want) {
			t.Fatalf("wrapped error missing %q:\n%s", want, got)
		}
	}
}

// TestWrapEctoResetErrPassthrough: unrelated failures pass through untouched —
// no hint noise on a compile error or a missing role.
func TestWrapEctoResetErrPassthrough(t *testing.T) {
	base := fmt.Errorf("step %q failed: exit status 1", "reset + seed the database (drop, create, migrate, seed)")
	if got := wrapEctoResetErr(base, "** (Mix) role \"postgres\" does not exist"); got != base {
		t.Fatalf("unrelated output must pass the error through unchanged, got: %v", got)
	}
}

// TestLocalStepsResetCarriesMapErr: BOTH paths' destructive reset step carries
// the object_in_use mapper (native mix and docker compose exec).
func TestLocalStepsResetCarriesMapErr(t *testing.T) {
	lc := localContext{root: "/tmp/x", apiDir: "/tmp/x/api"}
	for _, docker := range []bool{false, true} {
		steps := localSteps(SetupPlan{Target: TargetLocal, Docker: docker}, lc, "", false, "")
		found := false
		for _, s := range steps {
			if strings.HasPrefix(s.Title, "reset + seed the database") {
				found = true
				if s.MapErr == nil {
					t.Fatalf("docker=%v: reset step must carry MapErr", docker)
				}
			}
		}
		if !found {
			t.Fatalf("docker=%v: no reset step found", docker)
		}
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
