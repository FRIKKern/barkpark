package cli

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

// `bp cloud site create` SPAWNS a durable, tenant-scoped object. Its destination
// workspace/project/dataset must come from a triple the operator TYPED, never
// from an ambient one — the saved config's dataset, BARKPARK_DATASET, or the
// mid-run rewrite paper_cmd.go:169 performs on g.dataset from a pasted Paper URL.
//
// The verb reads the global capture because parseGlobals eats -d/--dataset
// wherever it appears in argv, so the verb's own flag set never sees it. The
// trap is reading g.dataset UNCONDITIONALLY: a non-empty g.dataset proves only
// that SOMETHING supplied a value, not that a human typed one. globals.datasetSet
// is the discriminator (globals.go), and cloud_workspace_cmd.go's
// exportDatasetScope already gates on exactly it.
//
// These tests are the fence in both directions: an untyped triple must be
// REFUSED with the usage error, and a typed one must still be honored.

// captureExecuteOutput runs fn with BOTH os.Stdout and os.Stderr redirected to a
// pipe and returns everything written. Execute() builds its own writer over the
// real process streams, and useError renders the machine envelope on STDOUT, so
// an argv-level assertion on what the operator reads has to capture both.
func captureExecuteOutput(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	origOut, origErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		done <- buf.String()
	}()
	fn()
	os.Stdout, os.Stderr = origOut, origErr
	_ = w.Close()
	s := <-done
	_ = r.Close()
	return s
}

// TestCloudSiteCreateRefusesAmbientDatasetTriple is the DETECTOR. A globals
// carrying a perfectly well-formed triple that was NOT typed (datasetSet false —
// the shape an ambient or mid-run-rewritten value has) must not spawn a site
// against it.
func TestCloudSiteCreateRefusesAmbientDatasetTriple(t *testing.T) {
	out, sout, serr := newTestWriter()
	g := globals{dataset: "ambient-ws/ambient-proj/ambient-ds"} // datasetSet deliberately false
	code := runCloud(out, g, []string{"site", "create", "--name", "blog", "--instance", "box-1"})
	if code != exitUsage {
		t.Fatalf("site create with an AMBIENT dataset triple = exit %d, want %d (usage refusal).\n"+
			"stdout:\n%s\nstderr:\n%s", code, exitUsage, sout.String(), serr.String())
	}
	if !strings.Contains(sout.String()+serr.String(), "--dataset is required") {
		t.Fatalf("refusal must name the flag the operator has to type; output:\n%s\n%s",
			sout.String(), serr.String())
	}
	if strings.Contains(sout.String()+serr.String(), "ambient-ws") {
		t.Fatalf("the ambient triple must never reach the request or the message; output:\n%s\n%s",
			sout.String(), serr.String())
	}
}

// TestCloudSiteCreateHonorsTypedDatasetTriple is the other half: with the SAME
// value but datasetSet true (the global stripper captured a typed -d/--dataset),
// the triple is accepted and the command moves on to its next check. Without
// this arm the test above would also pass if the fallback were deleted outright.
func TestCloudSiteCreateHonorsTypedDatasetTriple(t *testing.T) {
	out, sout, serr := newTestWriter()
	g := globals{dataset: "ws1/proj1/ds1", datasetSet: true}
	// No --instance: the dataset gate is BEFORE the instance gate, so reaching
	// the instance error proves the typed triple parsed and was accepted.
	code := runCloud(out, g, []string{"site", "create", "--name", "blog"})
	if code != exitUsage {
		t.Fatalf("exit %d, want %d", code, exitUsage)
	}
	all := sout.String() + serr.String()
	if strings.Contains(all, "--dataset is required") {
		t.Fatalf("a TYPED triple must still be honored; output:\n%s", all)
	}
	if !strings.Contains(all, "--instance is required") {
		t.Fatalf("expected to reach the --instance gate; output:\n%s", all)
	}
}

// TestExecuteCloudSiteCreateRefusesAmbientDataset is the ARGV-LEVEL fence, through
// Execute (the real entry point: parseGlobals, repo-file load, context resolution,
// noun dispatch) rather than runCloud. The ambient dataset is supplied the two
// ways an operator actually has one — a saved config and BARKPARK_DATASET — and
// no --dataset is typed anywhere in argv.
//
// Today neither layer feeds g.dataset, so this arm is the REGRESSION FENCE that
// makes wiring one in impossible to do silently; the runCloud detector above is
// what reds on the current defect. The typed control arm proves the argv path
// reaches the create verb at all, so an empty stderr can never read as a pass.
func TestExecuteCloudSiteCreateRefusesAmbientDataset(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir())

	if err := SaveConfig(&Config{
		Server:    "http://127.0.0.1:1",
		Token:     "tok",
		Workspace: "saved-ws",
		Project:   "saved-proj",
		Dataset:   "saved-ws/saved-proj/saved-ds",
		Output:    "json",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_DATASET", "env-ws/env-proj/env-ds")

	var code int
	stderr := captureExecuteOutput(t, func() {
		code = Execute([]string{"cloud", "site", "create", "--name", "blog", "--instance", "box-1"})
	})
	if code != exitUsage {
		t.Fatalf("Execute(cloud site create) with an ambient dataset and no typed --dataset = %d, want %d.\nstderr:\n%s",
			code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "--dataset is required") {
		t.Fatalf("want the honest usage error; stderr:\n%s", stderr)
	}
	for _, leak := range []string{"saved-ws", "env-ws"} {
		if strings.Contains(stderr, leak) {
			t.Fatalf("an ambient triple (%s) reached the site create path; stderr:\n%s", leak, stderr)
		}
	}

	// CONTROL: the same argv WITH a typed --dataset gets past the dataset gate.
	// -d/--dataset is eaten by the global stripper, so this also pins that the
	// typed value still arrives via g.dataset+datasetSet.
	var code2 int
	stderr2 := captureExecuteOutput(t, func() {
		code2 = Execute([]string{"cloud", "site", "create", "--name", "blog", "--dataset", "ws1/proj1/ds1"})
	})
	if code2 != exitUsage {
		t.Fatalf("control arm exit = %d, want %d\nstderr:\n%s", code2, exitUsage, stderr2)
	}
	if strings.Contains(stderr2, "--dataset is required") {
		t.Fatalf("a TYPED --dataset must survive the argv path; stderr:\n%s", stderr2)
	}
	if !strings.Contains(stderr2, "--instance is required") {
		t.Fatalf("control arm did not reach the create verb's instance gate; stderr:\n%s", stderr2)
	}
}
