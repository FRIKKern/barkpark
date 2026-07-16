package cli

// cloud_site_preflight_test.go proves the two load-bearing pure pieces of
// `bp cloud site preflight`: parsing the engines' `--self-test` summary, and the
// FAILS==0 gate that must NEVER pin an exact total. It also exercises the verb
// end-to-end with the self-test runner + build runner stubbed, so the dispatch,
// the observed→expected→next failure grammar, and the non-zero exit are covered
// without shelling out to bash or npm.

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSelfTest(t *testing.T) {
	cases := []struct {
		name       string
		output     string
		wantPassed int
		wantTotal  int
		wantFails  int
		wantTerm   string
		wantFound  bool
	}{
		{
			name:       "static green 87/87",
			output:     "[selftest] some check\n[selftest] 87/87 checks passed\n[selftest] PASS\n",
			wantPassed: 87, wantTotal: 87, wantFails: 0, wantTerm: "PASS", wantFound: true,
		},
		{
			name:       "node green 76/76 — total is NOT pinned",
			output:     "[selftest] 76/76 checks passed\n[selftest] PASS\n",
			wantPassed: 76, wantTotal: 76, wantFails: 0, wantTerm: "PASS", wantFound: true,
		},
		{
			name:       "grows to 90/90 and still parses",
			output:     "[selftest] 90/90 checks passed\n[selftest] PASS\n",
			wantPassed: 90, wantTotal: 90, wantFails: 0, wantTerm: "PASS", wantFound: true,
		},
		{
			name:       "failed run reports the FAILED(k) count",
			output:     "[selftest] 84/87 checks passed\n[selftest] FAILED (3)\n",
			wantPassed: 84, wantTotal: 87, wantFails: 3, wantTerm: "FAILED", wantFound: true,
		},
		{
			name:       "FAILED(k) wins over the count-derived delta",
			output:     "[selftest] 80/87 checks passed\n[selftest] FAILED (7)\n",
			wantPassed: 80, wantTotal: 87, wantFails: 7, wantTerm: "FAILED", wantFound: true,
		},
		{
			name:      "unrecognized output — nothing parsed",
			output:    "boom: bash: command not found\n",
			wantFound: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseSelfTest(tc.output)
			if got.Passed != tc.wantPassed || got.Total != tc.wantTotal || got.Fails != tc.wantFails {
				t.Errorf("parseSelfTest passed/total/fails = %d/%d/%d, want %d/%d/%d",
					got.Passed, got.Total, got.Fails, tc.wantPassed, tc.wantTotal, tc.wantFails)
			}
			if got.Terminal != tc.wantTerm {
				t.Errorf("Terminal = %q, want %q", got.Terminal, tc.wantTerm)
			}
			if got.Found != tc.wantFound {
				t.Errorf("Found = %v, want %v", got.Found, tc.wantFound)
			}
		})
	}
}

func TestSelfTestGate(t *testing.T) {
	cases := []struct {
		name   string
		sum    selfTestSummary
		runErr error
		wantOK bool
	}{
		{
			name:   "clean pass — FAILS==0, exit 0",
			sum:    selfTestSummary{Passed: 87, Total: 87, Fails: 0, Terminal: "PASS", Found: true},
			wantOK: true,
		},
		{
			name:   "grown total still passes (never pins an exact total)",
			sum:    selfTestSummary{Passed: 90, Total: 90, Fails: 0, Terminal: "PASS", Found: true},
			wantOK: true,
		},
		{
			name:   "any failure fails the gate",
			sum:    selfTestSummary{Passed: 84, Total: 87, Fails: 3, Terminal: "FAILED", Found: true},
			wantOK: false,
		},
		{
			name:   "unparseable output is a FAIL, never a vacuous green",
			sum:    selfTestSummary{Found: false},
			runErr: errors.New("exit status 127"),
			wantOK: false,
		},
		{
			name:   "summary parsed clean but process exited non-zero → distrust and fail",
			sum:    selfTestSummary{Passed: 87, Total: 87, Fails: 0, Terminal: "PASS", Found: true},
			runErr: errors.New("exit status 1"),
			wantOK: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ok, observed, expected, next := selfTestGate(tc.sum, tc.runErr)
			if ok != tc.wantOK {
				t.Fatalf("selfTestGate ok = %v, want %v", ok, tc.wantOK)
			}
			if !ok {
				if observed == "" || expected == "" || next == "" {
					t.Errorf("failing gate must carry observed→expected→next, got %q / %q / %q", observed, expected, next)
				}
			}
		})
	}
}

func TestMissingMarkers(t *testing.T) {
	all := `<meta name="bp-build-id" content="b1"><meta name=bp-content-rev content=r1><meta name='bp-doc-id' content='d1'>`
	if got := missingMarkers(all); len(got) != 0 {
		t.Errorf("all markers present, want none missing, got %v", got)
	}
	partial := `<meta name="bp-build-id" content="b1">`
	got := missingMarkers(partial)
	if len(got) != 2 || got[0] != "bp-content-rev" || got[1] != "bp-doc-id" {
		t.Errorf("missingMarkers(partial) = %v, want [bp-content-rev bp-doc-id]", got)
	}
	if got := missingMarkers("nothing here"); len(got) != 3 {
		t.Errorf("no markers, want all 3 missing, got %v", got)
	}
}

func TestAmbientTokenShadow(t *testing.T) {
	env := map[string]string{"BARKPARK_TOKEN": "sk-secret-abcd1234"}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	shadowed, tail := ambientTokenShadow(lookup)
	if !shadowed {
		t.Fatal("ambient BARKPARK_TOKEN must be flagged as a shadow hazard")
	}
	if !strings.HasPrefix(tail, "…") {
		t.Errorf("tail should mask the value, got %q", tail)
	}
	// Absent / blank → no hazard.
	if s, _ := ambientTokenShadow(func(string) (string, bool) { return "", false }); s {
		t.Error("no BARKPARK_TOKEN → no shadow")
	}
	if s, _ := ambientTokenShadow(func(string) (string, bool) { return "   ", true }); s {
		t.Error("blank BARKPARK_TOKEN → no shadow")
	}
}

func TestBasePathOK(t *testing.T) {
	good := []string{"/", "/sites/blog/", "/sites/my-site/"}
	bad := []string{"", "/sites/blog", "sites/blog/", "no-slashes"}
	for _, b := range good {
		if !basePathOK(b) {
			t.Errorf("basePathOK(%q) = false, want true", b)
		}
	}
	for _, b := range bad {
		if basePathOK(b) {
			t.Errorf("basePathOK(%q) = true, want false", b)
		}
	}
}

// TestPreflightGreen drives the whole verb with both engine harnesses stubbed
// green and the build skipped — it proves the dispatch, the passing render, and
// exit 0.
func TestPreflightGreen(t *testing.T) {
	stubEngines(t)
	// A blank BARKPARK_TOKEN is treated as "no hazard", so this keeps the
	// env-contract check green regardless of the developer's ambient shell.
	t.Setenv("BARKPARK_TOKEN", "")
	restore := runSiteSelfTest
	runSiteSelfTest = func(_ context.Context, _ string) (string, error) {
		return "[selftest] 87/87 checks passed\n[selftest] PASS\n", nil
	}
	defer func() { runSiteSelfTest = restore }()

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	code := runCloudSitePreflight(w, globals{}, []string{"--dir", t.TempDir(), "--skip-build"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stdout=%s stderr=%s", code, exitOK, sout.String(), serr.String())
	}
	if !strings.Contains(sout.String(), "preflight passed") {
		t.Errorf("want a passing summary, got:\n%s", sout.String())
	}
}

// TestPreflightSelfTestFailureExitsNonZero proves that a FAILS>0 harness makes
// the whole verb exit non-zero and print the observed→expected→next block — the
// gate that makes preflight worth running.
func TestPreflightSelfTestFailureExitsNonZero(t *testing.T) {
	stubEngines(t)
	restore := runSiteSelfTest
	runSiteSelfTest = func(_ context.Context, _ string) (string, error) {
		return "[selftest] 84/87 checks passed\n[selftest] FAILED (3)\n", errors.New("exit status 1")
	}
	defer func() { runSiteSelfTest = restore }()

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	code := runCloudSitePreflight(w, globals{}, []string{"--dir", t.TempDir(), "--skip-build"})
	if code == exitOK {
		t.Fatalf("a failed self-test must exit non-zero, got %d", code)
	}
	out := sout.String()
	for _, want := range []string{"observed:", "expected:", "next:", "FAILED"} {
		if !strings.Contains(out, want) {
			t.Errorf("failure output missing %q; got:\n%s", want, out)
		}
	}
}

// TestPreflightMissingDirIsUsageError proves a bad --dir is a clean usage error,
// not a crash.
func TestPreflightMissingDirIsUsageError(t *testing.T) {
	stubEngines(t)
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	code := runCloudSitePreflight(w, globals{}, []string{"--dir", filepath.Join(t.TempDir(), "does-not-exist")})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
}

// TestPreflightHelpDisambiguates proves `bp cloud site preflight --help` reaches
// the DEDICATED help page (not the family catch-all) and disambiguates from the
// box-side --rollback-preflight — the D26 requirement.
func TestPreflightHelpDisambiguates(t *testing.T) {
	for _, flag := range []string{"-h", "--help"} {
		var sout, serr bytes.Buffer
		w := newWriter(&sout, &serr)
		code := runCloudSite(w, globals{}, []string{"preflight", flag})
		if code != exitOK {
			t.Fatalf("%s exit = %d, want %d", flag, code, exitOK)
		}
		out := sout.String()
		if !strings.Contains(out, "--rollback-preflight") {
			t.Errorf("%s help must disambiguate from --rollback-preflight; got:\n%s", flag, out)
		}
		if !strings.Contains(out, "bp cloud site preflight") {
			t.Errorf("%s help should name the verb; got:\n%s", flag, out)
		}
	}
}

// stubEngines points findSiteDeployScripts at two real temp files so the
// script-exists check passes without depending on the repo layout, and restores
// the original after the test.
func stubEngines(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	static := filepath.Join(dir, "site-deploy.sh")
	node := filepath.Join(dir, "site-deploy-node.sh")
	for _, p := range []string{static, node} {
		if err := os.WriteFile(p, []byte("#!/usr/bin/env bash\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	restore := findSiteDeployScripts
	findSiteDeployScripts = func() (string, string, error) { return static, node, nil }
	t.Cleanup(func() { findSiteDeployScripts = restore })
}
