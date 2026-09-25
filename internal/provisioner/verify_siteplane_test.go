package provisioner

import (
	"context"
	"strings"
	"testing"
	"time"
)

// jpf-bl-siteplane-verify-probe — verify.siteplane on the Go gate.
//
// Three callers, three settings, one probe:
//   - birth, chain ATTEMPTED step 7c → required; the installer's verdict decides;
//   - birth, chain never attempted (old control plane) → skipped;
//   - restore → skipped, always: a box that legitimately has no plane must
//     still restore green.

func boolRef(b bool) *bool { return &b }

// TestVerifySitePlaneProbeVerdicts pins the four arms of the probe itself.
func TestVerifySitePlaneProbeVerdicts(t *testing.T) {
	cases := []struct {
		name     string
		cfg      verifyConfig
		wantPass bool
		wantEv   string
	}{
		{"not required, no fact", verifyConfig{}, true, "skipped"},
		// A fact that says false is IGNORED when not required — the restore arm
		// must not trip over whatever a caller happens to carry.
		{"not required, fact false", verifyConfig{sitePlaneComplete: boolRef(false)}, true, "skipped"},
		{"required, installed", verifyConfig{sitePlaneRequired: true, sitePlaneComplete: boolRef(true)}, true, "installed"},
		{"required, install failed", verifyConfig{sitePlaneRequired: true, sitePlaneComplete: boolRef(false)}, false, "NOT installed"},
		// Required but nobody measured: FAIL, never a green with no subject.
		{"required, unmeasured", verifyConfig{sitePlaneRequired: true}, false, "UNMEASURED"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := verifySitePlane(context.Background(), tc.cfg, nil)
			if out.name != "verify.siteplane" {
				t.Errorf("name = %q, want verify.siteplane", out.name)
			}
			if out.pass != tc.wantPass {
				t.Errorf("pass = %v, want %v (evidence %q)", out.pass, tc.wantPass, out.evidence)
			}
			if !strings.Contains(out.evidence, tc.wantEv) {
				t.Errorf("evidence = %q, want it to contain %q", out.evidence, tc.wantEv)
			}
		})
	}
}

// TestProvisionVerifySitePlaneRequiredAndInstalled: a chain that attempted and
// completed step 7c makes the probe REQUIRED, and it passes on the installer's
// verdict — the probe says "installed", not "skipped".
func TestProvisionVerifySitePlaneRequiredAndInstalled(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	seams.ControlURL = "https://cloud.example.test"
	rec := &verifyRec{}
	seams.StepReporter = rec.Report

	job := JobSpec{JobID: "job-plane", Name: "Planed", Slug: "planed", Region: "nbg1", ServerType: "cax11", AgentToken: "agent-tok"}
	if _, _, _, _, err := ProvisionWith(context.Background(), seams, job); err != nil {
		t.Fatalf("ProvisionWith with an installed plane: %v", err)
	}
	progress := rec.details("verify", "progress")
	if len(progress) != 4 {
		t.Fatalf("want 4 verify/progress lines, got %d: %v", len(progress), progress)
	}
	if !strings.HasPrefix(progress[3], "verify.siteplane: site plane installed") {
		t.Errorf("verify/progress[3] = %q, want the REQUIRED arm's installed verdict (not a skip)", progress[3])
	}
}

// TestProvisionVerifyFailsWhenSitePlaneInstallFailed: step 7c ran and failed
// (non-fatal inside the chain) → the REQUIRED probe fails the gate on the same
// teardown path as any red probe: error, nil teardown, no server left.
func TestProvisionVerifyFailsWhenSitePlaneInstallFailed(t *testing.T) {
	seams, prov, _, runner := fakeSeams(t)
	seams.ControlURL = "https://cloud.example.test"
	runner.failOn = "site-hosting plane"
	rec := &verifyRec{}
	seams.StepReporter = rec.Report

	job := JobSpec{JobID: "job-noplane", Name: "Planeless", Slug: "planeless", Region: "nbg1", ServerType: "cax11", AgentToken: "agent-tok"}
	_, _, _, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith with a FAILED plane install returned nil, want the verify gate to fail it")
	}
	if !strings.Contains(err.Error(), "verify.siteplane") {
		t.Errorf("err = %v, want it to name verify.siteplane", err)
	}
	if teardown != nil {
		t.Error("non-nil teardown after a failed verify, want nil (the box was already cleaned up)")
	}
	if failed := rec.detail("verify", "failed"); !strings.Contains(failed, "verify.siteplane") {
		t.Errorf("verify/failed detail = %q, want it to name verify.siteplane", failed)
	}
	// The three HTTP probes passed first — the failure is the plane, nothing else.
	if got := len(rec.details("verify", "progress")); got != 3 {
		t.Errorf("want 3 green HTTP probes before the plane failed, got %d: %v", got, rec.details("verify", "progress"))
	}
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("failed siteplane verify left %d servers, want 0: %+v", len(hosts), hosts)
	}
}

// TestRestoreVerifySkipsSitePlane is the restore-path pin: CloudRestoreDriver
// runs the SAME gate, and a restored box — which nothing in the restore run
// installs or measures a plane on — must restore GREEN.
//
// The control arm is what makes the green mean something: against the very
// same all-green instance, a REQUIRED plane with no fact fails and names
// verify.siteplane. So the only thing standing between a restore and a red gate
// is the restore driver's choice not to require the plane.
func TestRestoreVerifySkipsSitePlane(t *testing.T) {
	inst := newFakeInstance(t, fakeInstanceBehavior{})
	d := &CloudRestoreDriver{
		VerifyBaseURL:      inst.URL,
		VerifyProbeTimeout: 2 * time.Second,
		VerifyTotalBudget:  5 * time.Second,
	}
	if err := d.Verify(context.Background(), "restored.barkpark.cloud"); err != nil {
		t.Fatalf("restore Verify on a plane-less box = %v, want green (verify.siteplane must be conditional)", err)
	}

	// Control: same instance, plane REQUIRED, nothing measured → red, by name.
	err := runVerifyGate(context.Background(), verifyConfig{
		baseURL:           inst.URL,
		probeTimeout:      2 * time.Second,
		totalBudget:       5 * time.Second,
		sitePlaneRequired: true,
	}, func(string, string, string) {})
	if err == nil || !strings.Contains(err.Error(), "verify.siteplane") {
		t.Fatalf("control: a required, unmeasured plane = %v, want a verify.siteplane failure", err)
	}
}
