package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// jpf-bl-siteplane-verify-probe — the AGENT half's tests.
//
// TWO ARMS, and they are pointed at different things on purpose.
//
//  1. THE HONESTY ARM (TestSitePlane*Unmeasured*, TestSitePlaneCompleteIsNil*)
//     reds the moment a three-state fact is collapsed into a two-state one — a
//     timeout reported as `present: false`, or a roll-up that answers over an
//     unknown. That is the reversion this whole design exists to prevent, and
//     the whole reason the record is pointers rather than bools.
//  2. THE SHAPE ARM (TestSitePlaneHealthyBox*, TestReportOmitsSitePlane*) pins
//     what actually reaches the control plane: the seven facts a healthy box
//     lands, and the fact that an UNWIRED probe puts no `site_plane` key on the
//     wire at all.

// Real `--version` output, captured from a box carrying the plane
// deploy/site-runtime-install.sh installs.
const (
	liveDockerVersion   = "Docker version 24.0.7, build 24.0.7-0ubuntu4.1\n"
	liveGitVersion      = "git version 2.43.0\n"
	liveBuildxVersion   = "github.com/docker/buildx v0.12.1 default-build\n"
	liveNixpacksVersion = "nixpacks 1.21.2\n"
	liveGoVersion       = "go version go1.24.5 linux/arm64\n"
)

// liveSitePlaneUnitsShow is `systemctl show -p Id,ActiveState` for the pair on a
// box where the plane installed cleanly. Property order is systemd's own and is
// deliberately NOT the order `-p` asked for — the trap a positional parser falls
// into.
const liveSitePlaneUnitsShow = `ActiveState=active
Id=barkpark-builder.service

ActiveState=active
Id=barkpark-runtime.service
`

// planeLessUnitsShow is what systemd prints for two units it has never heard of:
// a clean, parseable block per unit with ActiveState=inactive. It is NOT an
// error, which is exactly why a non-zero systemctl has to mean something else.
const planeLessUnitsShow = `ActiveState=inactive
Id=barkpark-builder.service

ActiveState=inactive
Id=barkpark-runtime.service
`

// fakePlane is the sitePlaneRunner seam. It answers by the command AND its first
// argument, so one probe (buildx) can be failed while the docker it rides on
// stays healthy — which is the exact shape of a docker.io install without the
// buildx plugin.
type fakePlane struct {
	answers map[string]sitePlaneResult
	calls   [][]string
}

func (f *fakePlane) key(name string, args ...string) string {
	if name == "docker" && len(args) > 0 && args[0] == "buildx" {
		return "docker buildx"
	}
	return name
}

func (f *fakePlane) run(name string, args ...string) sitePlaneResult {
	f.calls = append(f.calls, append([]string{name}, args...))
	res, ok := f.answers[f.key(name, args...)]
	if !ok {
		return sitePlaneResult{err: errors.New("no fixture for " + f.key(name, args...))}
	}
	return res
}

// healthyPlane is every command answering as a fully-installed box.
func healthyPlane() *fakePlane {
	return &fakePlane{answers: map[string]sitePlaneResult{
		"docker":        {out: liveDockerVersion},
		"git":           {out: liveGitVersion},
		"docker buildx": {out: liveBuildxVersion},
		"nixpacks":      {out: liveNixpacksVersion},
		sitePlaneGoPath: {out: liveGoVersion},
		"systemctl":     {out: liveSitePlaneUnitsShow},
	}}
}

func mustBool(t *testing.T, p *bool, want bool, what string) {
	t.Helper()
	if p == nil {
		t.Fatalf("%s = nil (UNMEASURED), want %v", what, want)
	}
	if *p != want {
		t.Fatalf("%s = %v, want %v", what, *p, want)
	}
}

// ── ARM 2: the shape a healthy box lands ──────────────────────────────────

func TestSitePlaneHealthyBoxLandsAllSevenFactsAndCompletes(t *testing.T) {
	plane, err := newSitePlaneProbeWith(healthyPlane().run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mustBool(t, plane.Docker.Present, true, "docker.present")
	mustBool(t, plane.Buildx.Present, true, "buildx.present")
	mustBool(t, plane.Nixpacks.Present, true, "nixpacks.present")
	mustBool(t, plane.Go.Present, true, "go.present")
	mustBool(t, plane.Git.Present, true, "git.present")
	mustBool(t, plane.BuilderUnitActive, true, "builder_unit_active")
	mustBool(t, plane.RuntimeUnitActive, true, "runtime_unit_active")
	mustBool(t, plane.Complete, true, "complete")

	if plane.Go.Version != "go version go1.24.5 linux/arm64" {
		t.Errorf("go.version = %q, want the box's own first line", plane.Go.Version)
	}
	if plane.Docker.Version != "Docker version 24.0.7, build 24.0.7-0ubuntu4.1" {
		t.Errorf("docker.version = %q", plane.Docker.Version)
	}
}

// The Go toolchain is probed at its ABSOLUTE installer path, not through $PATH.
// deploy/site-runtime-install.sh deliberately does not put it on the fleet's
// PATH (`GO=/usr/local/go/bin/go`), so a PATH lookup would report the plane's
// own Go as absent on every box that has it.
func TestSitePlaneProbesGoAtTheInstallerPathNotOnPATH(t *testing.T) {
	f := healthyPlane()
	if _, err := newSitePlaneProbeWith(f.run)(); err != nil {
		t.Fatalf("probe: %v", err)
	}
	var sawAbs, sawBare bool
	for _, c := range f.calls {
		switch c[0] {
		case sitePlaneGoPath:
			sawAbs = true
		case "go":
			sawBare = true
		}
	}
	if !sawAbs {
		t.Errorf("probe never ran %s; calls=%v", sitePlaneGoPath, f.calls)
	}
	if sawBare {
		t.Errorf("probe ran a bare `go` — the plane's toolchain is not on PATH; calls=%v", f.calls)
	}
}

// A box that never got the plane must report seven measured FALSEs, not seven
// nils: the box WAS asked. This is the whole reason step 7c's non-fatal degrade
// stops being invisible.
func TestSitePlanePlaneLessBoxLandsMeasuredFalse(t *testing.T) {
	f := &fakePlane{answers: map[string]sitePlaneResult{
		"docker":        {notFound: true},
		"git":           {notFound: true},
		"docker buildx": {notFound: true},
		"nixpacks":      {notFound: true},
		sitePlaneGoPath: {notFound: true},
		"systemctl":     {out: planeLessUnitsShow},
	}}
	plane, err := newSitePlaneProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mustBool(t, plane.Docker.Present, false, "docker.present")
	mustBool(t, plane.BuilderUnitActive, false, "builder_unit_active")
	mustBool(t, plane.RuntimeUnitActive, false, "runtime_unit_active")
	mustBool(t, plane.Complete, false, "complete")
	if plane.Docker.Version != "" {
		t.Errorf("docker.version = %q on an absent docker; a failing command's output is an error message, not a version", plane.Docker.Version)
	}
}

// A docker.io without the buildx plugin: `docker --version` succeeds and
// `docker buildx version` RUNS and exits non-zero. That is a measured false, and
// the roll-up must say the plane is incomplete while docker itself stays true.
func TestSitePlaneBuildxMissingIsAMeasuredFalseNotAnAbsentDocker(t *testing.T) {
	f := healthyPlane()
	f.answers["docker buildx"] = sitePlaneResult{out: "docker: 'buildx' is not a docker command.\n", exited: true}
	plane, err := newSitePlaneProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mustBool(t, plane.Docker.Present, true, "docker.present")
	mustBool(t, plane.Buildx.Present, false, "buildx.present")
	mustBool(t, plane.Complete, false, "complete")
	if plane.Buildx.Version != "" {
		t.Errorf("buildx.version = %q; a refusal message must never ride a version field", plane.Buildx.Version)
	}
}

// ── ARM 1: the honesty arm — this is what reds on a reversion ─────────────

// THE CENTRAL REVERSION. A wedged docker daemon times out. Collapsing that into
// `present: false` would tell the control plane the box has no docker — a
// verdict nobody measured, about a box that may be perfectly equipped. Delete
// the `default:` arm of sitePlaneTool (or fold `res.err != nil` in with
// notFound/exited) and this test reds.
func TestSitePlaneTimeoutIsUnmeasuredNotAbsent(t *testing.T) {
	f := healthyPlane()
	f.answers["docker"] = sitePlaneResult{err: context.DeadlineExceeded}
	plane, err := newSitePlaneProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if plane.Docker.Present != nil {
		t.Fatalf("docker.present = %v on a TIMEOUT; a probe that could not ask must not answer", *plane.Docker.Present)
	}
	if plane.Complete != nil {
		t.Fatalf("complete = %v with one fact unmeasured; a roll-up over an unknown is an unknown", *plane.Complete)
	}
	// And the facts that WERE measured still land — one wedged command must not
	// cost the other six.
	mustBool(t, plane.Nixpacks.Present, true, "nixpacks.present")
	mustBool(t, plane.BuilderUnitActive, true, "builder_unit_active")
}

// The roll-up's nil rule DOMINATES its false rule. Six greens and one thing we
// could not look at is not a complete plane; but neither is it an incomplete
// one, and a `&&` chain that short-circuits on the first false would report
// `complete: false` for a box nobody finished measuring.
func TestSitePlaneCompleteIsNilWhenAnyFactIsUnmeasuredEvenBesideAFalse(t *testing.T) {
	f := healthyPlane()
	f.answers["nixpacks"] = sitePlaneResult{notFound: true}                            // a measured FALSE
	f.answers[sitePlaneGoPath] = sitePlaneResult{err: errors.New("permission denied")} // an UNMEASURED
	plane, err := newSitePlaneProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mustBool(t, plane.Nixpacks.Present, false, "nixpacks.present")
	if plane.Go.Present != nil {
		t.Fatalf("go.present = %v on a permission error, want nil", *plane.Go.Present)
	}
	if plane.Complete != nil {
		t.Fatalf("complete = %v; nil must dominate false", *plane.Complete)
	}
}

// A non-zero `systemctl` means the QUERY failed (no dbus, a busybox systemctl),
// NOT that the units are inactive — systemd prints a clean inactive block for a
// unit it has never heard of, so a real absence arrives through the parse path.
// Both halves land nil together; a half-read pair would invite the reader to
// treat the missing half as absent.
func TestSitePlaneSystemctlFailureIsUnmeasuredForBothUnits(t *testing.T) {
	for _, tc := range []struct {
		name string
		res  sitePlaneResult
	}{
		{"exited non-zero", sitePlaneResult{out: "Failed to connect to bus", exited: true}},
		{"not found", sitePlaneResult{notFound: true}},
		{"timed out", sitePlaneResult{err: context.DeadlineExceeded}},
		{"ran but printed nothing parseable", sitePlaneResult{out: "\n"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := healthyPlane()
			f.answers["systemctl"] = tc.res
			plane, err := newSitePlaneProbeWith(f.run)()
			if err != nil {
				t.Fatalf("probe: %v", err)
			}
			if plane.BuilderUnitActive != nil || plane.RuntimeUnitActive != nil {
				t.Fatalf("units = (%v, %v), want both nil", plane.BuilderUnitActive, plane.RuntimeUnitActive)
			}
			if plane.Complete != nil {
				t.Fatalf("complete = %v with the unit pair unmeasured", *plane.Complete)
			}
		})
	}
}

// A `systemctl show` that answered for only ONE of the two named units leaves
// the OTHER nil — it is an answer we did not get, not an inactive unit.
func TestSitePlaneShortUnitAnswerLeavesTheMissingHalfNil(t *testing.T) {
	f := healthyPlane()
	f.answers["systemctl"] = sitePlaneResult{out: "ActiveState=active\nId=" + sitePlaneBuilderUnit + "\n"}
	plane, err := newSitePlaneProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	mustBool(t, plane.BuilderUnitActive, true, "builder_unit_active")
	if plane.RuntimeUnitActive != nil {
		t.Fatalf("runtime_unit_active = %v; systemd printed no block for it", *plane.RuntimeUnitActive)
	}
}

// ── The production runner's own three-state classification ────────────────

// runSitePlaneCommand is the one place the three classes are DERIVED from a real
// os/exec error rather than handed in by a fixture, so it gets real processes.
func TestRunSitePlaneCommandClassifiesRealProcesses(t *testing.T) {
	t.Run("not found", func(t *testing.T) {
		res := runSitePlaneCommand("barkpark-no-such-binary-ever")
		if !res.notFound {
			t.Fatalf("notFound=false for a missing binary (err=%v)", res.err)
		}
		if res.ok() {
			t.Fatal("ok() true for a missing binary")
		}
	})
	t.Run("ran and exited non-zero", func(t *testing.T) {
		res := runSitePlaneCommand("false")
		if !res.exited {
			t.Fatalf("exited=false for `false` (notFound=%v err=%v)", res.notFound, res.err)
		}
		if res.notFound {
			t.Fatal("a command that RAN was classified as not found")
		}
	})
	t.Run("ran clean", func(t *testing.T) {
		res := runSitePlaneCommand("echo", "hello")
		if !res.ok() {
			t.Fatalf("ok()=false for `echo` (notFound=%v exited=%v err=%v)", res.notFound, res.exited, res.err)
		}
		if strings.TrimSpace(res.out) != "hello" {
			t.Errorf("out = %q", res.out)
		}
	})
}

// A killed process surfaces from os/exec as an ExitError. Classifying it by the
// error type alone would file every wedged docker as "ran and refused" — a
// measured false. The deadline check has to come FIRST, and this pins that it
// does, with a real timeout.
func TestRunSitePlaneCommandTimeoutOutranksTheExitError(t *testing.T) {
	old := sitePlaneProbeTimeout
	sitePlaneProbeTimeout = 20 * time.Millisecond
	defer func() { sitePlaneProbeTimeout = old }()

	res := runSitePlaneCommand("sleep", "5")
	if res.err == nil {
		t.Fatalf("err=nil for a killed process (notFound=%v exited=%v) — a timeout would land as a measured FALSE", res.notFound, res.exited)
	}
	if res.exited || res.notFound {
		t.Fatalf("timeout classified as exited=%v notFound=%v; it is UNMEASURED", res.exited, res.notFound)
	}
	var exitErr *exec.ExitError
	if errors.As(res.err, &exitErr) {
		t.Fatal("the raw ExitError escaped as the unmeasured reason")
	}
}

// ── The wire: what the control plane actually receives ────────────────────

// An UNWIRED probe must put NO `site_plane` key on the wire. Every agent in the
// fleet today is such a box, and an empty record would read as present.
func TestReportOmitsSitePlaneWhenTheProbeIsUnwired(t *testing.T) {
	r := gatherReport(ReportConfig{})
	if r.SitePlane != nil {
		t.Fatalf("SitePlane = %+v with no probe wired", r.SitePlane)
	}
	blob, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(blob), "site_plane") {
		t.Fatalf("site_plane key on the wire with no probe wired: %s", blob)
	}
}

// A probe that ERRORS is the same absence — gatherReport must not land whatever
// half-record came back beside the error.
func TestReportOmitsSitePlaneWhenTheProbeErrors(t *testing.T) {
	r := gatherReport(ReportConfig{
		SitePlaneProbe: func() (*SitePlaneCapability, error) {
			return &SitePlaneCapability{Complete: boolPtr(false)}, errors.New("probe blew up")
		},
	})
	if r.SitePlane != nil {
		t.Fatalf("SitePlane = %+v from an ERRORING probe", r.SitePlane)
	}
}

// And a wired, healthy probe lands the record with its keys spelled the way the
// control plane will read them.
func TestReportCarriesSitePlaneOnTheWire(t *testing.T) {
	r := gatherReport(ReportConfig{SitePlaneProbe: newSitePlaneProbeWith(healthyPlane().run)})
	if r.SitePlane == nil {
		t.Fatal("SitePlane = nil from a healthy probe")
	}
	blob, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var wire struct {
		SitePlane *struct {
			Docker            struct{ Present *bool } `json:"docker"`
			Git               struct{ Present *bool } `json:"git"`
			Buildx            struct{ Present *bool } `json:"buildx"`
			Nixpacks          struct{ Present *bool } `json:"nixpacks"`
			Go                struct{ Present *bool } `json:"go"`
			BuilderUnitActive *bool                   `json:"builder_unit_active"`
			RuntimeUnitActive *bool                   `json:"runtime_unit_active"`
			Complete          *bool                   `json:"complete"`
		} `json:"site_plane"`
	}
	if err := json.Unmarshal(blob, &wire); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if wire.SitePlane == nil {
		t.Fatalf("no site_plane on the wire: %s", blob)
	}
	mustBool(t, wire.SitePlane.Complete, true, "wire complete")
	mustBool(t, wire.SitePlane.Git.Present, true, "wire git.present")
	mustBool(t, wire.SitePlane.BuilderUnitActive, true, "wire builder_unit_active")
}
