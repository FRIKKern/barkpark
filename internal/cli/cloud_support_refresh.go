package cli

// cloud_support_refresh.go is `bp cloud support refresh <name>` — bring an
// EXISTING support box to the current fleet runner without hand-curling a file
// over SSH (pdf-bl-fleet-run-refresh).
//
// THE GAP IT CLOSES. tooling/fleet/fleet-run.sh reaches a support box exactly
// once, in add's runtime leg (supportFleetFilesStep). Nothing re-ran that leg,
// so an existing box ran the runner it was born with forever, and nothing
// reported which runner that was — detecting a half-upgraded fleet took SSH.
//
// THE DECISION (criterion 0): an OPERATOR VERB, not a chain leg that runs on
// its own and not a listener self-update. The trust story is the reason:
//
//   - The box NEVER pulls its own runner. There is no timer, no on-start fetch,
//     no URL in the listener's config — a box that pulls itself is a box that
//     can be steered into pulling something else. It gains no new capability.
//   - A refresh is COMMANDED under the operator's own credentials, the same
//     ones `support add` needs: the provider token (the box is located by its
//     barkpark-fleet-support label, behind remove's identity fence) and the
//     operator's SSH access as root. Whoever can refresh could already
//     provision; nobody else can.
//   - The CONTENT is an immutable commit: bp resolves origin/main to a 40-hex
//     sha (api.github.com), fences its shape, PRINTS it, and the box fetches
//     raw.githubusercontent.com/<repo>/<sha>/… — a sha URL cannot be moved
//     under the verb. Refresh runs the step WITHOUT add's checkout fallback, so
//     the sha printed is the sha written or the verb fails.
//   - It reuses supportFleetFilesStep — the one builder add runs — and nothing
//     else from the runtime leg: the 0600 env (the ledger token) and the unit
//     are left untouched, so a refresh cannot rotate or leak the credential.
//
// OBSERVABILITY WITHOUT SSH (criterion 2). The files step writes the sha into
// /opt/barkpark-fleet/fleet-run.version; fleet-run.sh adds it to the capacity
// JSON it already beats (capacity.runner_sha). The server stores the capacity
// map whole (api/lib/barkpark/tasks/fleet.ex validate_capacity checks only
// size_class/slots/budget), so it surfaces on GET /v1/fleet/roster and
// `bp fleet roster` with no server change.
//
// THE POST-CONDITION (criterion 1). After the restart the verb polls the MAIN's
// roster until capacity.runner_sha equals the pushed sha, and prints both side
// by side. A mismatch — or a row that never reports one — is a non-zero exit,
// never a warning.

import (
	"fmt"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/fleetruntime"
)

// supportSHARe fences the resolved commit before it is single-quoted into the
// on-box script and printed as the version: exactly 40 lowercase hex. One
// definition, shared with the provisioner chain (fleetruntime.SHARe).
var supportSHARe = fleetruntime.SHARe

// supportResolveMainSHA resolves origin/main to a commit sha on the OPERATOR's
// machine (fleetruntime.ResolveMainSHA). A seam so tests never touch GitHub.
var supportResolveMainSHA = func() (string, error) {
	return fleetruntime.ResolveMainSHA(supportCtx())
}

// supportRestartListenerStep restarts the listener so the new runner is the
// running one, and fails when the unit does not come back active.
func supportRestartListenerStep() cloud.CaddyStep {
	return cloud.CaddyStep{
		Title: "restart the fleet listener on the refreshed runner",
		Argv:  []string{"bash", "-lc", "set -e; systemctl restart barkpark-fleet-listener; sleep 2; systemctl is-active --quiet barkpark-fleet-listener"},
	}
}

// supportRunnerSHAOf reads the runner version a roster row reports
// (capacity.runner_sha), "" when the row, its capacity, or the key is absent —
// a runner that predates version reporting never beats it.
func supportRunnerSHAOf(row map[string]any) string {
	capMap, _ := row["capacity"].(map[string]any)
	sha, _ := capMap["runner_sha"].(string)
	return sha
}

// supportRefreshNarration composes the post-condition from the MAIN'S ROSTER
// ROW, taken whole (PDS-D431): the pushed sha beside what the row reports, and
// whether they match. PURE, so tests call the production sentence.
func supportRefreshNarration(name, pushed string, row map[string]any) (string, bool) {
	reported := supportRunnerSHAOf(row)
	return fmt.Sprintf("%s: pushed runner %s, the main's roster reports runner_sha %s",
		name, pushed, supportOr(reported, "(none — unreported)")), reported == pushed
}

// supportRefreshRun carries one `support refresh` invocation.
type supportRefreshRun struct {
	out *writer
	g   globals

	name    string
	dataset string
	force   bool

	base  string // the MAIN
	token string

	sha    string // the origin/main commit this refresh pushes
	box    cloud.Server
	runner cloud.SupportRunner

	before   string // runner_sha the roster reported BEFORE the refresh ("" = unreported)
	reported string // runner_sha the roster reported AFTER the restart
}

func runCloudSupportRefresh(out *writer, g globals, args []string) int {
	const usage = "bp cloud support refresh <name> [--dataset <slug>] [--force]"
	a, err := parseHzArgs(args, []string{"dataset"}, []string{"force"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
	}
	r := &supportRefreshRun{out: out, g: g, name: a.pos[0], force: a.bools["force"]}
	if !supportNameRe.MatchString(r.name) {
		return useError(out, "usage",
			fmt.Sprintf("invalid support name %q — want a DNS-label shape (the name is the identity the refresh resolves by)", r.name),
			exitUsage)
	}

	ctx := resolveContext(g)
	r.base = strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	r.token = strings.TrimSpace(ctx.Token)
	if r.base == "" {
		return useError(out, "failed", "no main Barkpark resolved — run `bp use <name>` (or set BARKPARK_API_URL) so refresh can read the support's roster row back", exitGeneric)
	}
	r.dataset = strings.TrimSpace(a.val("dataset"))
	if r.dataset == "" && g.datasetSet {
		r.dataset = strings.TrimSpace(g.dataset)
	}
	if r.dataset == "" {
		r.dataset = strings.TrimSpace(ctx.Dataset)
	}
	if r.dataset == "" {
		r.dataset = "production"
	}
	if !supportSlugRe.MatchString(r.dataset) {
		return useError(out, "usage", fmt.Sprintf("invalid dataset slug %q", r.dataset), exitUsage)
	}

	if g.dryRun {
		out.progressf("DRY RUN — bp cloud support refresh %s would run, in order:", r.name)
		out.progressf("  1. resolve     origin/main → a 40-hex commit sha (printed; the box fetches THAT commit)")
		out.progressf("  2. locate      the box labeled %s=%s (identity-fenced; foreign identity or >1 match refused)", cloud.FleetSupportLabelKey, r.name)
		out.progressf("  3. busy        read listener-%s on %s (dataset %s); a working row is refused without --force", r.name, r.base, r.dataset)
		out.progressf("  4. push        fleet-run.sh + fleet-protocol.md + bp-read.sh at that sha, fleet-run.version beside them (no checkout fallback)")
		out.progressf("  5. restart     systemctl restart barkpark-fleet-listener (env + unit untouched)")
		out.progressf("  6. read-back   poll the main's roster until capacity.runner_sha == the pushed sha (budget %s); a mismatch exits non-zero", supportRosterPollBudget)
		return exitOK
	}
	return r.run()
}

func (r *supportRefreshRun) run() int {
	steps := []func() (int, bool){
		r.stepResolve,
		r.stepLocate,
		r.stepBusy,
		r.stepPush,
		r.stepRestart,
		r.stepReadBack,
	}
	for _, step := range steps {
		if code, stop := step(); stop {
			return code
		}
	}
	return r.success()
}

func (r *supportRefreshRun) state(step, msg string) { r.out.progressf("→ %s: %s", step, msg) }
func (r *supportRefreshRun) done(step, msg string)  { r.out.progressf("✓ %s — %s", step, msg) }

func (r *supportRefreshRun) fail(step, reason, standing string, code int) (int, bool) {
	if r.out.emitStructured(map[string]any{
		"ok":           false,
		"support":      r.name,
		"step":         step,
		"error":        map[string]any{"code": "failed", "message": reason},
		"state":        standing,
		"pushed_sha":   r.sha,
		"reported_sha": r.reported,
		"next":         "fix the named cause, then re-run `bp cloud support refresh " + r.name + "` — the refresh is idempotent",
	}) {
		return code, true
	}
	r.out.userErr("✗ %s failed — %s", step, reason)
	r.out.errf("  state: %s", standing)
	r.out.errf("  next:  fix the named cause, then re-run `bp cloud support refresh %s` — the refresh is idempotent", r.name)
	return code, true
}

// stepResolve pins the refresh to ONE commit and prints it before anything
// touches the box.
func (r *supportRefreshRun) stepResolve() (int, bool) {
	r.state("resolve", "resolving origin/main to a commit sha")
	sha, err := supportResolveMainSHA()
	if err == nil && !supportSHARe.MatchString(sha) {
		err = fmt.Errorf("unexpected sha shape %q", sha)
	}
	if err != nil {
		return r.fail("resolve", "cannot resolve origin/main: "+err.Error(), "nothing touched", exitGeneric)
	}
	r.sha = sha
	r.done("resolve", "origin/main is "+sha)
	return exitOK, false
}

// stepLocate finds the ONE box behind the name — the same label lookup and
// identity fence remove uses.
func (r *supportRefreshRun) stepLocate() (int, bool) {
	provider, perr := supportProviderFor()
	if perr != nil {
		return r.fail("locate", perr.Error(),
			"nothing touched — fix the provider credential (hetzner: set HCLOUD_TOKEN or an `hcloud context`)", exitAuth)
	}
	lister, ok := provider.(cloud.LabelLister)
	if !ok {
		return r.fail("locate", "provider cannot list by label — cannot safely locate the support box", "nothing touched", exitGeneric)
	}
	r.state("locate", fmt.Sprintf("listing boxes labeled %s=%s", cloud.FleetSupportLabelKey, r.name))
	boxes, err := lister.ListByLabel(supportCtx(), cloud.FleetSupportLabelKey, r.name)
	if err != nil {
		return r.fail("locate", "list by label failed: "+err.Error(), "nothing touched", exitGeneric)
	}
	if refusal := supportIdentityFence(boxes, r.name); refusal != "" {
		return r.fail("locate", refusal, "nothing touched", exitGeneric)
	}
	if len(boxes) == 0 {
		return r.fail("locate", fmt.Sprintf("no box carries %s=%s — nothing to refresh", cloud.FleetSupportLabelKey, r.name),
			"nothing touched — bring one up with `bp cloud support add "+r.name+"`", exitNotFound)
	}
	r.box = boxes[0]
	r.runner = supportRunnerFor(r.box.IP)
	r.done("locate", fmt.Sprintf("%s at %s (identity verified: %s=%s)", r.box.Name, r.box.IP, cloud.FleetSupportLabelKey, r.name))
	return exitOK, false
}

// stepBusy reads the roster row BEFORE touching the box: a restart kills the
// in-flight agent turn, so a working listener is refused unless --force. It
// also records the runner version the box reported before the refresh.
func (r *supportRefreshRun) stepBusy() (int, bool) {
	r.state("busy", fmt.Sprintf("reading listener-%s on the main's roster", r.name))
	row, err := supportRosterRow(r.base, r.token, r.dataset, r.name)
	if err != nil {
		return r.fail("busy", "cannot read the main's roster: "+err.Error()+" — the post-condition read needs it too",
			"nothing touched", exitGeneric)
	}
	if row == nil {
		r.out.errf("⚠ busy: no listener-%s row on the roster (dataset %s) — refreshing anyway; the read-back will need the listener to beat", r.name, r.dataset)
		return exitOK, false
	}
	r.before = supportRunnerSHAOf(row)
	st, _ := row["status"].(string)
	if st == "working" && !r.force {
		return r.fail("busy", fmt.Sprintf("listener-%s reads working — a restart would kill the in-flight order's agent turn", r.name),
			"nothing touched — wait for the order to finish, or re-run with --force", exitConflict)
	}
	r.done("busy", fmt.Sprintf("listener-%s reads %s; runner before: %s", r.name, supportOr(st, "unknown"), supportOr(r.before, "(unreported)")))
	return exitOK, false
}

// stepPush re-runs add's runtime file write — the SAME builder — at the pinned
// sha, with NO checkout fallback.
func (r *supportRefreshRun) stepPush() (int, bool) {
	r.state("push", "writing fleet-run.sh + fleet-protocol.md + bp-read.sh at "+r.sha)
	if err := r.runner.Run(supportCtx(), supportFleetFilesStep(r.sha, false)); err != nil {
		return r.fail("push", "runtime file write failed: "+err.Error(),
			"the files are written as *.bpnew and moved into place only after every fetch succeeds — the box still runs its previous runner", exitGeneric)
	}
	r.done("push", "runner files + fleet-run.version written at "+r.sha)
	return exitOK, false
}

func (r *supportRefreshRun) stepRestart() (int, bool) {
	r.state("restart", "restarting barkpark-fleet-listener")
	if err := r.runner.Run(supportCtx(), supportRestartListenerStep()); err != nil {
		return r.fail("restart", "listener restart failed: "+err.Error(),
			fmt.Sprintf("the runner at %s is on disk; the listener is not confirmed active — `ssh root@%s 'journalctl -u barkpark-fleet-listener -n 50'`", r.sha, r.box.IP),
			exitGeneric)
	}
	r.done("restart", "barkpark-fleet-listener active")
	return exitOK, false
}

// stepReadBack is the post-condition: the MAIN's roster must report the sha
// that was pushed. The last reading is printed either way; a mismatch exits
// non-zero.
func (r *supportRefreshRun) stepReadBack() (int, bool) {
	r.state("read-back", fmt.Sprintf("polling the main's roster until listener-%s reports runner_sha %s (budget %s)", r.name, r.sha, supportRosterPollBudget))
	deadline := supportClock().Add(supportRosterPollBudget)
	var last map[string]any
	for {
		row, err := supportRosterRow(r.base, r.token, r.dataset, r.name)
		if err == nil && row != nil {
			last = row
			r.reported = supportRunnerSHAOf(row)
			if line, ok := supportRefreshNarration(r.name, r.sha, row); ok {
				r.done("read-back", line)
				return exitOK, false
			}
		}
		if !supportClock().Before(deadline) {
			line, _ := supportRefreshNarration(r.name, r.sha, last)
			return r.fail("read-back",
				fmt.Sprintf("MISMATCH after %s — %s", supportRosterPollBudget, line),
				fmt.Sprintf("the runner at %s is on disk and the listener was restarted, but the main does not read it back", r.sha),
				exitGeneric)
		}
		time.Sleep(supportRosterPollInterval)
	}
}

func (r *supportRefreshRun) success() int {
	if r.out.emitStructured(map[string]any{
		"ok":           true,
		"support":      r.name,
		"server":       r.box.Name,
		"ip":           r.box.IP,
		"pushed_sha":   r.sha,
		"reported_sha": r.reported,
		"before_sha":   r.before,
		"main":         map[string]any{"url": r.base, "dataset": r.dataset},
	}) {
		return exitOK
	}
	r.out.outf("")
	r.out.outf("✓ support %s runs the current fleet runner", r.name)
	r.out.outf("  pushed:   %s (origin/main, resolved by this bp)", r.sha)
	r.out.outf("  reported: %s (capacity.runner_sha on the main's roster)", r.reported)
	r.out.outf("  before:   %s", supportOr(r.before, "(unreported — the runner predated version reporting)"))
	r.out.outf("  box:      %s at %s", r.box.Name, r.box.IP)
	return exitOK
}
