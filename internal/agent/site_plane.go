package agent

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

// jpf-bl-siteplane-verify-probe (step 1 of 3) — THE SITE-PLANE FACT SOURCE.
//
// WHY THIS FILE EXISTS. `bp cloud verify` and its Elixir twin are HTTP-only
// against the instance origin: three probes (verify.api / verify.login /
// verify.studio) that speak to the box's CMS. Nothing in either executor — and
// nothing anywhere else in the tree before this file — could see whether the
// box carries a SITE-HOSTING PLANE: docker + buildx, nixpacks, the isolated Go
// toolchain, git, and the barkpark-builder / barkpark-runtime units that
// warmpool.go's step 7c installs from deploy/site-runtime-install.sh.
//
// That blindness has teeth, because step 7c is NON-FATAL by design: an
// apt/nixpacks/network hiccup degrades into the provisioning worker's journal
// and the box then goes live serving its CMS perfectly while every site pointed
// at it sits `queued` forever. The only backstop today is the queue-age alarm,
// which fires LATER and downstream — it notices that sites stopped draining,
// not that the plane was never installed.
//
// A probe cannot be added to the verify executors first, because a verify probe
// has no transport that can see any of this: neither executor SSHes, and the
// CMS serves no plane facts. The AGENT is the one thing already running ON the
// box, and its beat already POSTs over HTTPS to the control plane. So the fact
// source is built here first, in the beat, and the verify probe is then a read
// of a stored fact rather than a reach nobody has.
//
// EVERY FACT IS THREE-STATE, and that is the whole honesty of the record. The
// law this file keeps is Report.SiteDeploy's, verbatim: nil means UNMEASURED,
// `false` is a VERDICT ABOUT THE BOX, and only a box that actually answered may
// produce one. The fleet is old; most boxes ran their agent long before this
// file existed, and the same beat shape must be able to say "I did not look"
// without that reading as "this box has no plane".

// sitePlaneProbeTimeout bounds EACH plane command. `docker --version` and
// friends are milliseconds on a healthy box; a wedged docker daemon must
// degrade this record to UNMEASURED, never stall the beat behind it.
var sitePlaneProbeTimeout = 5 * time.Second

// sitePlaneGoPath is where deploy/site-runtime-install.sh puts the isolated Go
// toolchain (`GO=/usr/local/go/bin/go`). It is probed at that ABSOLUTE path and
// not through $PATH: the installer deliberately does not put it on the fleet's
// PATH, so a PATH lookup would report the plane's own Go as absent on every box
// that has it.
const sitePlaneGoPath = "/usr/local/go/bin/go"

// sitePlaneBuilderUnit / sitePlaneRuntimeUnit are the two systemd units the
// installer writes and `systemctl enable --now`s. They are asked for BY NAME,
// like slotUnitNames and for the same reason: a discovery listing that returns
// only loaded-and-running units would silently omit exactly the dead half this
// record exists to report.
const (
	sitePlaneBuilderUnit = "barkpark-builder.service"
	sitePlaneRuntimeUnit = "barkpark-runtime.service"
)

// SitePlaneTool is one plane component's presence plus the version string it
// printed.
//
// Present IS A POINTER for the Report.SiteDeploy reason: nil is UNMEASURED (the
// probe is unwired, the command timed out, exec failed for a reason that is not
// absence). `false` means THE BOX WAS ASKED AND DOES NOT HAVE IT — either the
// binary is not on PATH, or it ran and refused (which is how a docker without
// the buildx plugin answers `docker buildx version`).
//
// Version is the first line of the command's own output, verbatim and trimmed,
// and is empty whenever Present is not true. It is deliberately NOT parsed into
// a comparable version: the operator reading a degraded box wants the string
// the box printed, and a parser that rejects an unexpected shape would throw
// away the only evidence.
type SitePlaneTool struct {
	Present *bool  `json:"present"`
	Version string `json:"version,omitempty"`
}

// SitePlaneCapability is the beat's record of the site-hosting plane.
//
// The five tools and the two units are the same seven things
// deploy/site-runtime-install.sh installs, in its own order. Git is one of them
// on purpose: it is the clone lane's unstated dependency — the installer's own
// `git ensure` block exists because the tools checkout AND the builder's own
// clones need it at BUILD time, and a box whose git is missing fails deploys in
// a way none of the other six facts would explain.
type SitePlaneCapability struct {
	Docker   SitePlaneTool `json:"docker"`
	Buildx   SitePlaneTool `json:"buildx"`
	Nixpacks SitePlaneTool `json:"nixpacks"`
	Go       SitePlaneTool `json:"go"`
	Git      SitePlaneTool `json:"git"`

	// BuilderUnitActive / RuntimeUnitActive are `systemctl show -p ActiveState`
	// on the two units, three-state like the tools: nil when systemd could not
	// be read at all, false when systemd answered with any state that is not
	// `active` (including a unit it has never heard of, which it still prints a
	// block for), true only on `active`.
	BuilderUnitActive *bool `json:"builder_unit_active"`
	RuntimeUnitActive *bool `json:"runtime_unit_active"`

	// Complete is the ROLL-UP the future verify.siteplane probe reads, and it is
	// derived here rather than by each reader so seven facts cannot be reduced
	// to a verdict seven different ways.
	//
	// It is true iff ALL SEVEN sub-facts were measured AND every one of them is
	// true. It is false iff every sub-fact was measured and at least one is
	// false. It is nil — UNMEASURED — whenever ANY sub-fact is nil, because a
	// roll-up over an unknown is an unknown: six greens and one thing we could
	// not look at is NOT a plane-less box, and it is not a complete one either.
	Complete *bool `json:"complete"`
}

// sitePlaneResult is one plane command's outcome, three-state on purpose.
//
// The distinction the probeRunner seam elsewhere in this package cannot make is
// exactly the one this record turns on: a command that was NOT FOUND and a
// command that RAN AND EXITED NON-ZERO are both definitive evidence about the
// box, while a timeout or a permission error is not evidence at all. Flattening
// all three into one `error` is what would force this probe to answer "absent"
// for a docker that merely hung.
type sitePlaneResult struct {
	// out is the command's combined output (empty unless it ran).
	out string
	// notFound is true when the binary is not on PATH / not at its path — the
	// PATH was searched and it is not there. Definitive ABSENCE.
	notFound bool
	// exited is true when the process started and exited NON-ZERO. Definitive
	// too: it is present but refuses the capability asked of it.
	exited bool
	// err is anything else — a timeout, a permission denial, a start failure
	// that is not absence. UNMEASURED; the caller must land nil.
	err error
}

// ok reports whether the command ran and exited zero.
func (r sitePlaneResult) ok() bool { return !r.notFound && !r.exited && r.err == nil }

// sitePlaneRunner is this probe's seam. Production is runSitePlaneCommand;
// tests pass a fake so every one of the four outcome classes above is provable
// without a box, a docker, or a systemd.
type sitePlaneRunner func(name string, args ...string) sitePlaneResult

// runSitePlaneCommand is the production sitePlaneRunner: a bounded, DIRECT-argv
// exec (no shell, no pipe — the psRunawayArgs contract) that sorts the failure
// into the three classes above.
func runSitePlaneCommand(name string, args ...string) sitePlaneResult {
	ctx, cancel := context.WithTimeout(context.Background(), sitePlaneProbeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err == nil {
		return sitePlaneResult{out: string(out)}
	}
	// The context deadline is checked FIRST and beats both classifications
	// below: a killed process surfaces as an ExitError, and reading that as
	// "the box refuses" would turn every hung docker daemon into a fabricated
	// `present: false`.
	if ctx.Err() != nil {
		return sitePlaneResult{err: ctx.Err()}
	}
	if errors.Is(err, exec.ErrNotFound) || errors.Is(err, exec.ErrDot) {
		return sitePlaneResult{notFound: true}
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return sitePlaneResult{out: string(out), exited: true}
	}
	return sitePlaneResult{err: err}
}

// NewSitePlaneProbe builds the production probe: six bounded, direct-argv
// commands per beat (five tool version reads plus one `systemctl show`).
//
// It is wired into the agent unconditionally because — unlike the HTTP probes —
// it needs no base URL and no token: the plane is LOCAL to the box the agent
// already runs on. A box without any of it simply reports every fact false,
// which is the true answer and the one the control plane needs.
func NewSitePlaneProbe() func() (*SitePlaneCapability, error) {
	return newSitePlaneProbeWith(runSitePlaneCommand)
}

func newSitePlaneProbeWith(run sitePlaneRunner) func() (*SitePlaneCapability, error) {
	return func() (*SitePlaneCapability, error) {
		cap := &SitePlaneCapability{
			// Order mirrors deploy/site-runtime-install.sh: docker, git, buildx,
			// nixpacks, go.
			Docker: sitePlaneTool(run, "docker", "--version"),
			Git:    sitePlaneTool(run, "git", "--version"),
			// buildx is a docker PLUGIN, not a binary: the only way to ask is to
			// run docker itself, which is why a `docker` that lacks it answers
			// with a non-zero exit (exited) rather than a not-found.
			Buildx:   sitePlaneTool(run, "docker", "buildx", "version"),
			Nixpacks: sitePlaneTool(run, "nixpacks", "--version"),
			Go:       sitePlaneTool(run, sitePlaneGoPath, "version"),
		}
		cap.BuilderUnitActive, cap.RuntimeUnitActive = sitePlaneUnits(run)
		cap.Complete = sitePlaneComplete(cap)
		return cap, nil
	}
}

// sitePlaneTool runs one version command and maps its outcome onto the
// three-state record. The mapping is the whole point of the function and is
// stated once here rather than five times at the call sites.
func sitePlaneTool(run sitePlaneRunner, name string, args ...string) SitePlaneTool {
	res := run(name, args...)
	switch {
	case res.ok():
		return SitePlaneTool{Present: boolPtr(true), Version: sitePlaneFirstLine(res.out)}
	case res.notFound, res.exited:
		// MEASURED ABSENCE. The box was asked and does not have it (not on PATH)
		// or has something that refuses (a docker without buildx). No version
		// string rides along: whatever a failing command printed is an error
		// message, and putting it in a field called `version` would be a lie
		// with a plausible shape.
		return SitePlaneTool{Present: boolPtr(false)}
	default:
		// UNMEASURED. Timeout, permission, anything that is not evidence about
		// the box's plane. Present stays nil.
		return SitePlaneTool{}
	}
}

// sitePlaneUnits reads the two units in ONE `systemctl show` and reuses
// parseSystemctlShow — the same parser, and the same reason: systemd does not
// promise property order, so blocks are read by name and never by position.
//
// The pair lands as ONE measurement (both nil, or both read). A systemctl that
// could not run costs both, because a half-read pair would invite the reader to
// treat the missing half as absent.
func sitePlaneUnits(run sitePlaneRunner) (builder, runtime *bool) {
	res := run("systemctl", "show", "-p", "Id,ActiveState", sitePlaneBuilderUnit, sitePlaneRuntimeUnit)
	if !res.ok() {
		// NOTE the deliberate width: even `exited` lands UNMEASURED here, unlike
		// the tool case. A non-zero systemctl means the QUERY failed (no dbus, a
		// busybox systemctl), not that the units are inactive — systemd prints a
		// clean `ActiveState=inactive` block for a unit it has never heard of,
		// so a real "no such unit" arrives through the ok() path below.
		return nil, nil
	}
	states := map[string]string{}
	for _, u := range parseSystemctlShow(res.out) {
		states[u.Unit] = u.ActiveState
	}
	if len(states) == 0 {
		// `systemctl show` prints a block even for a unit that does not exist,
		// so NOTHING parseable means the command did not really run.
		return nil, nil
	}
	return sitePlaneUnitActive(states, sitePlaneBuilderUnit), sitePlaneUnitActive(states, sitePlaneRuntimeUnit)
}

// sitePlaneUnitActive maps one unit's ActiveState to the three-state bool. A
// unit systemd printed no block for is nil, not false: this probe asked for two
// units by name, and an answer that came back short is an answer we did not get.
func sitePlaneUnitActive(states map[string]string, unit string) *bool {
	state, ok := states[unit]
	if !ok || state == "" {
		return nil
	}
	return boolPtr(state == "active")
}

// sitePlaneComplete derives the roll-up. It is written as an explicit walk over
// every sub-fact — no short-circuit on the first false — because the nil rule
// dominates: one unmeasured fact makes the whole verdict unmeasured even when
// another fact is already false, and a `&&` chain would silently report false
// for a box nobody finished looking at.
func sitePlaneComplete(c *SitePlaneCapability) *bool {
	allTrue := true
	for _, f := range []*bool{
		c.Docker.Present, c.Buildx.Present, c.Nixpacks.Present,
		c.Go.Present, c.Git.Present,
		c.BuilderUnitActive, c.RuntimeUnitActive,
	} {
		if f == nil {
			return nil
		}
		if !*f {
			allTrue = false
		}
	}
	return boolPtr(allTrue)
}

// sitePlaneFirstLine trims a version command's output to its first line, bounded.
// `go version` and `git --version` print one line; `docker buildx version` can
// print more, and an unbounded version string has no business riding a beat.
func sitePlaneFirstLine(out string) string {
	line := strings.TrimSpace(out)
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = strings.TrimSpace(line[:i])
	}
	return truncate(line, 120)
}

// boolPtr is the one-line helper that keeps every three-state assignment in this
// file readable. It exists because Go has no address-of for a literal.
func boolPtr(b bool) *bool { return &b }
