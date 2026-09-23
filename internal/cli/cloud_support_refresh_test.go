package cli

// cloud_support_refresh_test.go gates `bp cloud support refresh`
// (pdf-bl-fleet-run-refresh): the post-condition read-back is the verb's
// verdict — a roster that reports a different runner sha (or none) is a
// NON-ZERO exit, a matching one is green — plus the busy refusal, the identity
// fence, the no-fallback pin, and the files step's real shell semantics.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

const supportTestSHA = "2b97ded4fb4cd1043f59fe88c00b3d6a95fe2651"

// refreshRunner is the fake box: when the restart step runs, the listener
// "comes back" and its next beat reports afterSHA on the main's roster.
type refreshRunner struct {
	*fakeSupportRunner
	main     *supportMainRecorder
	afterSHA string // "" ⇒ the restarted runner beats no runner_sha
}

func (f *refreshRunner) Run(ctx context.Context, s cloud.CaddyStep) error {
	if err := f.fakeSupportRunner.Run(ctx, s); err != nil {
		return err
	}
	if strings.Contains(s.Title, "restart the fleet listener") {
		capMap := map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1}
		if f.afterSHA != "" {
			capMap["runner_sha"] = f.afterSHA
		}
		f.main.mu.Lock()
		f.main.rosterRow = map[string]any{"worker": "hex", "status": "idle", "capacity": capMap}
		f.main.mu.Unlock()
	}
	return nil
}

// refreshWiring seeds one labeled box, a main whose roster row reports an OLD
// runner, and a runner whose restart makes the row report afterSHA.
func refreshWiring(t *testing.T, beforeStatus, afterSHA string) (*refreshRunner, *supportMainRecorder, string) {
	t.Helper()
	supportEnvIsolate(t)
	supportSaveSeams(t)
	supportRosterPollInterval = 0
	supportRosterPollBudget = 0
	supportSeedBox(t, nil, "warm-cafe01", "hex")
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{"worker": "hex", "status": beforeStatus, "capacity": map[string]any{
		"size_class": "standard", "slots_total": 1, "slots_free": 1,
		"runner_sha": "1111111111111111111111111111111111111111",
	}}
	srv := main.serve(t)
	runner := &refreshRunner{fakeSupportRunner: newFakeSupportRunner(), main: main, afterSHA: afterSHA}
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }
	return runner, main, srv.URL
}

// TestCloudSupportRefreshReadBackMatchIsGreen: the pushed sha reads back off the
// main's roster → exit 0, both printed side by side.
func TestCloudSupportRefreshReadBackMatchIsGreen(t *testing.T) {
	runner, _, url := refreshWiring(t, "idle", supportTestSHA)
	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code != exitOK {
		t.Fatalf("want exit 0 on a matching read-back, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{
		"origin/main is " + supportTestSHA,
		"pushed runner " + supportTestSHA + ", the main's roster reports runner_sha " + supportTestSHA,
		"before:   1111111111111111111111111111111111111111",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout lacks %q\nstdout:\n%s", want, stdout)
		}
	}
	// The push is the SAME builder add runs, pinned, with NO checkout fallback,
	// then a restart — and nothing else from the runtime leg (env/unit untouched).
	if len(runner.steps) != 2 {
		t.Fatalf("want exactly 2 on-box steps (push, restart), got %d: %s", len(runner.steps), runner.scripts())
	}
	want := supportFleetFilesStep(supportTestSHA, false)
	if strings.Join(runner.steps[0].Argv, " ") != strings.Join(want.Argv, " ") {
		t.Fatalf("push step is not supportFleetFilesStep(sha, false):\n%s", strings.Join(runner.steps[0].Argv, " "))
	}
	if !strings.Contains(runner.steps[1].Title, "restart the fleet listener") {
		t.Fatalf("second step is not the restart: %q", runner.steps[1].Title)
	}
	if s := runner.scripts(); strings.Contains(s, "fleet-listener.env") || strings.Contains(s, "BARKPARK_API_TOKEN") {
		t.Fatalf("refresh touched the 0600 env — it must re-run the file leg only:\n%s", s)
	}
}

// TestCloudSupportRefreshReadBackMismatchExitsNonZero: the restarted runner
// reports a DIFFERENT sha → non-zero exit naming both, never a warning.
func TestCloudSupportRefreshReadBackMismatchExitsNonZero(t *testing.T) {
	const other = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	_, _, url := refreshWiring(t, "idle", other)
	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code == exitOK {
		t.Fatalf("a mismatched read-back exited 0\nstdout:\n%s\nstderr:\n%s", stdout, stderr)
	}
	if !strings.Contains(stderr, "MISMATCH") || !strings.Contains(stderr, "pushed runner "+supportTestSHA) ||
		!strings.Contains(stderr, "reports runner_sha "+other) {
		t.Fatalf("the mismatch must name pushed AND reported\nstderr:\n%s", stderr)
	}
	if strings.Contains(stdout, "runs the current fleet runner") {
		t.Fatalf("success receipt printed on a mismatch\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportRefreshUnreportedExitsNonZero: a runner that beats no
// runner_sha at all is a mismatch too — absence never reads as agreement.
func TestCloudSupportRefreshUnreportedExitsNonZero(t *testing.T) {
	_, _, url := refreshWiring(t, "idle", "")
	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code == exitOK || !strings.Contains(stderr, "(none — unreported)") {
		t.Fatalf("an unreported runner must exit non-zero and say so; code=%d\nstderr:\n%s", code, stderr)
	}
}

// TestCloudSupportRefreshJSONCarriesBothShas: -o json carries pushed and
// reported on both the green and the red path.
func TestCloudSupportRefreshJSONCarriesBothShas(t *testing.T) {
	const other = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	for _, tc := range []struct {
		after  string
		wantOK bool
	}{{supportTestSHA, true}, {other, false}} {
		_, _, url := refreshWiring(t, "idle", tc.after)
		stdout, _, code := runSupport(t, globals{server: url, token: "op-tok", output: "json"}, "refresh", "hex")
		var got map[string]any
		if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &got); err != nil {
			t.Fatalf("receipt not one JSON doc: %v\n%s", err, stdout)
		}
		if got["ok"] != tc.wantOK || got["pushed_sha"] != supportTestSHA || got["reported_sha"] != tc.after || (code == exitOK) != tc.wantOK {
			t.Fatalf("after=%s: code=%d receipt=%v", tc.after, code, got)
		}
	}
}

// TestCloudSupportRefreshRefusesWorkingWithoutForce: a restart would kill the
// in-flight order, so a working row is refused and the box is not touched;
// --force proceeds.
func TestCloudSupportRefreshRefusesWorkingWithoutForce(t *testing.T) {
	runner, _, url := refreshWiring(t, "working", supportTestSHA)
	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code != exitConflict || !strings.Contains(stderr, "reads working") {
		t.Fatalf("want exit %d refusing a working listener, got %d\nstderr:\n%s", exitConflict, code, stderr)
	}
	if len(runner.steps) != 0 {
		t.Fatalf("a refused refresh touched the box: %s", runner.scripts())
	}

	_, _, url = refreshWiring(t, "working", supportTestSHA)
	stdout, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex", "--force")
	if code != exitOK {
		t.Fatalf("--force must proceed, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
}

// TestCloudSupportRefreshIdentityFence: remove's fence, shared — a foreign
// label is refused and nothing runs on any box; no box is not-found.
func TestCloudSupportRefreshIdentityFence(t *testing.T) {
	runner, _, url := refreshWiring(t, "idle", supportTestSHA)
	p := supportSeedBox(t, nil, "", "")
	p.foreign = []cloud.Server{{Name: "warm-other", IP: "198.51.100.4", Labels: map[string]string{cloud.FleetSupportLabelKey: "other"}}}
	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code == exitOK || !strings.Contains(stderr, "REFUSING to touch a foreign identity") || len(runner.steps) != 0 {
		t.Fatalf("foreign identity not refused: code=%d steps=%d\nstderr:\n%s", code, len(runner.steps), stderr)
	}

	runner, _, url = refreshWiring(t, "idle", supportTestSHA)
	supportSeedBox(t, nil, "", "")
	_, stderr, code = runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code != exitNotFound || len(runner.steps) != 0 {
		t.Fatalf("no box: want exit %d and no steps, got %d\nstderr:\n%s", exitNotFound, code, stderr)
	}
}

// TestCloudSupportRefreshUnresolvableShaTouchesNothing: refresh has no
// fallback — without a sha it prints the cause and never reaches the box.
func TestCloudSupportRefreshUnresolvableShaTouchesNothing(t *testing.T) {
	runner, main, url := refreshWiring(t, "idle", supportTestSHA)
	supportResolveMainSHA = func() (string, error) { return "", fmt.Errorf("api.github.com unreachable") }
	_, stderr, code := runSupport(t, globals{server: url, token: "op-tok"}, "refresh", "hex")
	if code == exitOK || !strings.Contains(stderr, "api.github.com unreachable") || len(runner.steps) != 0 || main.count("GET") != 0 {
		t.Fatalf("unresolved sha must stop before the box and the main: code=%d steps=%d\nstderr:\n%s", code, len(runner.steps), stderr)
	}
}

// TestCloudSupportAddPinsTheRuntimeSha: add runs the same builder, pinned to
// the resolved sha WITH the checkout fallback; an unresolvable sha degrades to
// the checkout loudly instead of failing the bring-up.
func TestCloudSupportAddPinsTheRuntimeSha(t *testing.T) {
	for _, resolved := range []bool{true, false} {
		supportEnvIsolate(t)
		runner := newFakeSupportRunner()
		supportHappyWiring(t, runner)
		if !resolved {
			supportResolveMainSHA = func() (string, error) { return "", fmt.Errorf("rate limited") }
		}
		main := newSupportMainRecorder()
		main.rosterRow = map[string]any{"worker": "hex", "status": "idle",
			"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1}}
		srv := main.serve(t)
		supportSeedCP(t, srv.URL)
		stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
		if code != exitOK {
			t.Fatalf("resolved=%v: add exit %d\nstdout:\n%s\nstderr:\n%s", resolved, code, stdout, stderr)
		}
		wantSHA := ""
		if resolved {
			wantSHA = supportTestSHA
		} else if !strings.Contains(stderr, "could not resolve origin/main's sha (rate limited)") {
			t.Fatalf("an unresolved sha must degrade LOUDLY\nstderr:\n%s", stderr)
		}
		want := strings.Join(supportFleetFilesStep(wantSHA, true).Argv, " ")
		found := false
		for _, s := range runner.steps {
			if strings.Join(s.Argv, " ") == want {
				found = true
			}
		}
		if !found {
			t.Fatalf("resolved=%v: add did not run supportFleetFilesStep(%q, true)\n%s", resolved, wantSHA, runner.scripts())
		}
	}
}

// TestSupportFleetFilesStepShellSemantics runs the REAL files-step script with
// only its two path roots rebased into a temp dir and curl/git stubbed, and
// asserts: a pinned fetch writes all three files + the version file; refresh
// mode (no fallback) with an unreachable commit changes NOTHING on disk; add
// mode falls back to the checkout and records the checkout's HEAD.
func TestSupportFleetFilesStepShellSemantics(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	root := t.TempDir()
	fleet, checkout, raw, bin := filepath.Join(root, "fleet"), filepath.Join(root, "checkout"), filepath.Join(root, "raw"), filepath.Join(root, "bin")
	files := []string{"tooling/fleet/fleet-run.sh", "tooling/fleet/fleet-protocol.md", "scripts/lib/bp-read.sh"}
	for _, f := range files {
		for dir, content := range map[string]string{
			filepath.Join(raw, supportTestSHA, f): "pinned " + f,
			filepath.Join(checkout, f):            "checkout " + f,
		} {
			if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(dir, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	// curl stub: serve <raw>/<ref>/<path> for the rebased raw root, fail otherwise.
	curl := "#!/bin/bash\nout=''; url=''\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2;; -*) shift;; *) url=\"$1\"; shift;; esac; done\n" +
		"p=\"${url#" + supportRawRoot + "/}\"; [ -f \"" + raw + "/$p\" ] || exit 22; cp \"" + raw + "/$p\" \"$out\"\n"
	git := "#!/bin/bash\necho cccccccccccccccccccccccccccccccccccccccc\n"
	for name, body := range map[string]string{"curl": curl, "git": git} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	run := func(step cloud.CaddyStep) error {
		script := step.Argv[2]
		script = strings.ReplaceAll(script, "/opt/barkpark-fleet", fleet)
		script = strings.ReplaceAll(script, "/opt/barkpark/", checkout+"/")
		cmd := exec.Command("bash", "-c", script)
		cmd.Env = append(os.Environ(), "PATH="+bin+":/usr/bin:/bin")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%v: %s", err, out)
		}
		return nil
	}
	read := func(name string) string {
		b, _ := os.ReadFile(filepath.Join(fleet, name))
		return strings.TrimSpace(string(b))
	}

	if err := run(supportFleetFilesStep(supportTestSHA, false)); err != nil {
		t.Fatalf("pinned fetch failed: %v", err)
	}
	if read("fleet-run.version") != supportTestSHA || read("fleet-run.sh") != "pinned tooling/fleet/fleet-run.sh" ||
		read("bp-read.sh") != "pinned scripts/lib/bp-read.sh" || read("fleet-protocol.md") != "pinned tooling/fleet/fleet-protocol.md" {
		t.Fatalf("pinned fetch wrote the wrong content: version=%q run=%q bp-read=%q", read("fleet-run.version"), read("fleet-run.sh"), read("bp-read.sh"))
	}
	if st, err := os.Stat(filepath.Join(fleet, "fleet-run.sh")); err != nil || st.Mode().Perm()&0o100 == 0 {
		t.Fatalf("fleet-run.sh not executable: %v %v", st, err)
	}

	const missing = "0000000000000000000000000000000000000000"
	if err := run(supportFleetFilesStep(missing, false)); err == nil {
		t.Fatal("refresh mode with an unfetchable commit must FAIL (no checkout fallback)")
	}
	if read("fleet-run.version") != supportTestSHA || read("fleet-run.sh") != "pinned tooling/fleet/fleet-run.sh" {
		t.Fatalf("a failed refresh changed the installed runner: version=%q", read("fleet-run.version"))
	}
	if m, _ := filepath.Glob(filepath.Join(fleet, "*.bpnew")); len(m) != 0 {
		t.Fatalf("a failed refresh left staging files: %v", m)
	}

	if err := run(supportFleetFilesStep(missing, true)); err != nil {
		t.Fatalf("add mode must fall back to the checkout: %v", err)
	}
	if read("fleet-run.version") != "cccccccccccccccccccccccccccccccccccccccc" || read("fleet-run.sh") != "checkout tooling/fleet/fleet-run.sh" {
		t.Fatalf("checkout fallback must write checkout content + its HEAD: version=%q run=%q", read("fleet-run.version"), read("fleet-run.sh"))
	}
}

// TestSupportRefreshNarrationReadsTheRow: the verdict comes from the row —
// the same pushed sha yields a different sentence and verdict when the row
// says otherwise.
func TestSupportRefreshNarrationReadsTheRow(t *testing.T) {
	row := func(sha string) map[string]any {
		return map[string]any{"capacity": map[string]any{"size_class": "standard", "runner_sha": sha}}
	}
	a, okA := supportRefreshNarration("hex", supportTestSHA, row(supportTestSHA))
	b, okB := supportRefreshNarration("hex", supportTestSHA, row("deadbeef"))
	c, okC := supportRefreshNarration("hex", supportTestSHA, nil)
	if !okA || okB || okC || a == b || b == c {
		t.Fatalf("narration ignores the row: %q/%v %q/%v %q/%v", a, okA, b, okB, c, okC)
	}
}
