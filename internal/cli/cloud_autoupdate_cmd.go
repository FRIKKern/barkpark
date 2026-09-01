package cli

// cloud_autoupdate_cmd.go carries the two self-update POLICY verbs that turn the
// fleet's autoupdate from an opaque default into an operator-driven control
// (isu-w5 — "from nag to product"):
//
//   bp cloud autoupdate pin <instance> <release>   freeze a box at/above a version
//   bp cloud autoupdate unpin <instance>           let it ride blessed releases again
//   bp cloud autoupdate pause <instance>           temporary hold (no update)
//   bp cloud autoupdate resume <instance>          release the hold
//
//   bp cloud rollout status                        the fleet-wide rollout state
//   bp cloud rollout halt                          global brake — stop advancing
//   bp cloud rollout resume                        restart a halted rollout
//
// `autoupdate` PATCHes ONE instance's policy (PATCH /v1/barkparks/:id/autoupdate,
// team-admin-gated); `rollout` drives the FLEET brake (GET/POST
// /v1/operator/autoupdate*, PLATFORM-OPERATOR gated — the caller's own bp-login
// session, allowlisted by PLATFORM_ADMIN_EMAILS. It used to call the
// worker-gated /v1/admin/autoupdate* trio, which no human credential can open;
// isu-backlog-operator-principal ruled the platform operator to be THE principal
// for the fleet brake and this verb now honours it).
// Both mirror cloud_deploy_cmd.go's style and — like
// every control-plane verb here — its HARD INVARIANT: they NEVER write bp config.
// They resolve the instance by name/id via the fleet list and the Cloud session
// token, exactly like `bp cloud verify` / `bp cloud domain`, and touch nothing
// local.
//
// Honesty the receipts carry (charter OC10, spike-resolved): a pin HOLDS a box at
// or above its current version — it is a freeze flag, not a downgrade. The copy
// says so; the CLI never promises a rollback the mechanism can't do.

import (
	"errors"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// runCloudAutoupdate routes `bp cloud autoupdate <verb> …` to the per-instance
// policy verbs. Unknown verbs and the bare namespace print usage.
func runCloudAutoupdate(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudAutoupdateHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 || args[0] == "help" {
		if g.help || (len(args) > 0 && args[0] == "help") {
			printCloudAutoupdateHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing autoupdate command (run `bp cloud autoupdate -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "pin":
		return runAutoupdatePin(out, g, args[1:])
	case "unpin":
		return runAutoupdateSet(out, g, args[1:], "unpin", map[string]any{"pinned_release": ""})
	case "pause":
		return runAutoupdateSet(out, g, args[1:], "pause", map[string]any{"autoupdate_paused": true})
	case "resume":
		return runAutoupdateSet(out, g, args[1:], "resume", map[string]any{"autoupdate_paused": false})
	default:
		return useError(out, "usage", fmt.Sprintf("unknown autoupdate command %q (run `bp cloud autoupdate -h` for usage)", args[0]), exitUsage)
	}
}

// runAutoupdatePin is `bp cloud autoupdate pin <instance> <release>` — it needs a
// second positional (the release tag) the other verbs don't, so it parses on its
// own before delegating to the shared PATCH path with a {pinned_release} body.
func runAutoupdatePin(out *writer, g globals, args []string) int {
	const usage = "bp cloud autoupdate pin <instance> <release>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 2 {
		return useError(out, "usage", fmt.Sprintf("want <instance> and <release> (usage: %s)", usage), exitUsage)
	}
	release := strings.TrimSpace(a.pos[1])
	if release == "" {
		return useError(out, "usage", "the release to pin cannot be blank — pass a version tag (use `bp cloud autoupdate unpin` to clear a pin)", exitUsage)
	}
	return applyAutoupdate(out, "pin", a.pos[0], map[string]any{"pinned_release": release})
}

// runAutoupdateSet is the shared path for the single-<instance> verbs (unpin /
// pause / resume): parse exactly one positional, then PATCH with the fixed body.
func runAutoupdateSet(out *writer, g globals, args []string, verb string, patch map[string]any) int {
	usage := "bp cloud autoupdate " + verb + " <instance>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <instance> (usage: %s)", usage), exitUsage)
	}
	return applyAutoupdate(out, verb, a.pos[0], patch)
}

// applyAutoupdate resolves the instance, PATCHes its policy, and renders the
// receipt (human or -o json). It is the ONE place the four verbs converge on the
// control-plane call, so the auth/resolve/error handling is identical.
func applyAutoupdate(out *writer, verb, ref string, patch map[string]any) int {
	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to manage autoupdate", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	policy, perr := cfg.CloudClient().SetAutoupdate(cloudCtx(), id, patch)
	if perr != nil {
		return autoupdateFail(out, ref, perr)
	}

	applied := autoupdateApplied(verb, policy)

	if out.output == "json" || out.output == "yaml" {
		out.emitStructured(map[string]any{
			"ok":       applied,
			"instance": ref,
			"autoupdate": map[string]any{
				"enabled":        policy.Enabled,
				"paused":         policy.Paused,
				"pinned_release": policy.PinnedRelease,
			},
		})
		if !applied {
			return exitGeneric
		}
		return exitOK
	}

	out.outf("%s", autoupdateReceipt(verb, ref, policy))
	out.outf("  policy: %s", autoupdatePolicySummary(policy))
	if !applied {
		out.userErr("the control plane accepted the %s request but its returned policy does not carry the change — re-run, or check `bp cloud status`", verb)
		return exitGeneric
	}
	return exitOK
}

// autoupdateApplied reads the SERVER-RETURNED policy and reports whether it
// actually carries the change the verb asked for. This is the whole point of the
// PATCH returning a policy: a 200 means "the request was accepted", it does NOT
// mean the box's policy now says what the operator asked for. Anything that
// prints a checkmark on the 200 alone is claiming a post-condition it never read
// (PDS success-claim law, class A3 → A2).
func autoupdateApplied(verb string, policy cloudclient.AutoupdatePolicy) bool {
	switch verb {
	case "pin":
		return strings.TrimSpace(policy.PinnedRelease) != ""
	case "unpin":
		return strings.TrimSpace(policy.PinnedRelease) == ""
	case "pause":
		return policy.Paused
	case "resume":
		return !policy.Paused
	default:
		// An unknown verb makes no specific claim, so there is nothing to
		// contradict — the receipt below reports the policy verbatim instead.
		return true
	}
}

// autoupdateReceipt is the one-line human confirmation per verb — the immediate
// feedback that names WHAT changed, in the operator's words, and (for pin) the
// honest "holds at or above, does not roll back" caveat.
//
// Every branch READS the returned policy: the success wording only prints when
// the policy the control plane echoed back actually carries the change, and the
// contradicting wording says so in the same breath rather than asserting a state
// nobody measured. Feed this function a policy that contradicts the verb and the
// printed sentence CHANGES — that property is what
// success_claim_registry_test.go enrolls it for.
func autoupdateReceipt(verb, ref string, policy cloudclient.AutoupdatePolicy) string {
	pin := strings.TrimSpace(policy.PinnedRelease)
	switch verb {
	case "pin":
		if pin == "" {
			return fmt.Sprintf("✗ %s is NOT pinned — the control plane returned a policy with no pin, so nothing is holding this box.", ref)
		}
		return fmt.Sprintf("✓ %s pinned to %s — autoupdate holds it at or above this version (a pin does not roll back).", ref, pin)
	case "unpin":
		if pin != "" {
			return fmt.Sprintf("✗ %s is STILL pinned to %s — the control plane did not clear the pin.", ref, pin)
		}
		return fmt.Sprintf("✓ %s unpinned — autoupdate rides blessed releases again.", ref)
	case "pause":
		if !policy.Paused {
			return fmt.Sprintf("✗ %s is NOT paused — the control plane returned an unpaused policy, so it can still update.", ref)
		}
		return fmt.Sprintf("✓ %s autoupdate paused — it will not update until resumed.", ref)
	case "resume":
		if policy.Paused {
			return fmt.Sprintf("✗ %s is STILL paused — the control plane did not lift the hold.", ref)
		}
		return fmt.Sprintf("✓ %s autoupdate resumed.", ref)
	default:
		return fmt.Sprintf("✓ %s autoupdate updated — %s.", ref, autoupdatePolicySummary(policy))
	}
}

// autoupdatePolicySummary renders the resulting policy compactly (the same
// vocabulary the status POLICY cell uses): the enabled master, a pause note, and
// the pin.
func autoupdatePolicySummary(policy cloudclient.AutoupdatePolicy) string {
	master := "on"
	if !policy.Enabled {
		master = "off"
	}
	parts := []string{"autoupdate " + master}
	if policy.Paused {
		parts = append(parts, "paused")
	}
	if pin := strings.TrimSpace(policy.PinnedRelease); pin != "" {
		parts = append(parts, "pinned@"+pin)
	} else {
		parts = append(parts, "unpinned")
	}
	return strings.Join(parts, " · ")
}

// autoupdateFail maps a refused policy PATCH onto the `bp:` error seam: the
// team-scoped 404 (no existence leak) and the 422 invalid body are contract
// refusals; anything else (an expired session, a gateway page) routes through
// cloudFail so auth handling stays identical to every other cloud verb.
func autoupdateFail(out *writer, ref string, err error) int {
	var re *cloudclient.CloudRouteError
	if errors.As(err, &re) {
		switch re.Code {
		case "not_found":
			return useError(out, "not_found",
				fmt.Sprintf("no such instance %q (or it is not in your team)", ref),
				exitNotFound)
		case "invalid":
			return useError(out, "usage",
				fmt.Sprintf("the control plane rejected that autoupdate change for %q (invalid value)", ref),
				exitUsage)
		}
	}
	return cloudFail(out, "set autoupdate", err)
}

// runCloudRollout routes `bp cloud rollout <verb> …` — the FLEET rollout brake.
func runCloudRollout(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudRolloutHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 || args[0] == "help" {
		if g.help || (len(args) > 0 && args[0] == "help") {
			printCloudRolloutHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing rollout command (run `bp cloud rollout -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "status":
		return runRolloutAction(out, g, args[1:], "status")
	case "halt":
		return runRolloutAction(out, g, args[1:], "halt")
	case "resume":
		return runRolloutAction(out, g, args[1:], "resume")
	default:
		return useError(out, "usage", fmt.Sprintf("unknown rollout command %q (run `bp cloud rollout -h` for usage)", args[0]), exitUsage)
	}
}

// runRolloutAction runs one rollout verb (status/halt/resume). All three take no
// positional args and render the resulting fleet state; halt/resume also print a
// change receipt first.
func runRolloutAction(out *writer, g globals, args []string, verb string) int {
	usage := "bp cloud rollout " + verb
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", fmt.Sprintf("%s takes no arguments (usage: %s)", verb, usage), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to manage the fleet rollout", exitAuth)
	}

	client := cfg.CloudClient()
	var state cloudclient.RolloutState
	var rerr error
	switch verb {
	case "status":
		state, rerr = client.RolloutStatus(cloudCtx())
	case "halt":
		state, rerr = client.RolloutHalt(cloudCtx())
	case "resume":
		state, rerr = client.RolloutResume(cloudCtx())
	}
	if rerr != nil {
		return rolloutFail(out, rerr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitRolloutRaw(out, state)
		return exitOK
	}

	switch verb {
	case "halt":
		out.outf("✓ fleet rollout halted — no instance will auto-update until resumed.")
	case "resume":
		out.outf("✓ fleet rollout resumed — instances resume riding blessed releases.")
	}
	renderRolloutState(out, state)
	return exitOK
}

// renderRolloutState prints the human view: the headline halted/running line and
// any counters the control plane reported (each shown only when present — an
// older CP that omits them is honest about that, never a fabricated zero).
func renderRolloutState(out *writer, state cloudclient.RolloutState) {
	if state.Halted {
		out.outf("%s", out.paintCell("rollout: HALTED", "warn"))
	} else {
		out.outf("%s", out.paintCell("rollout: running", "ok"))
	}
	if state.Eligible != nil {
		out.outf("  eligible:  %d", *state.Eligible)
	}
	if state.Behind != nil {
		out.outf("  behind:    %d", *state.Behind)
	}
	if state.InFlight != nil {
		out.outf("  in-flight: %d", *state.InFlight)
	}
}

// emitRolloutRaw writes the rollout envelope for a machine consumer: json is the
// control plane's exact bytes (the envelope IS the contract — this client never
// becomes a second, drifting definition of it); yaml is a faithful re-encode. A
// state with no raw bytes (a defensive fallback) re-emits the parsed headline.
func emitRolloutRaw(out *writer, state cloudclient.RolloutState) {
	if len(state.Raw) > 0 {
		out.renderRaw(state.Raw)
		return
	}
	out.emitStructured(map[string]any{"ok": true, "halted": state.Halted})
}

// rolloutFail maps a refused rollout call onto the `bp:` error seam. A 404 (an
// older control plane that predates the /v1/operator seam) is a distinct, honest
// "your control plane doesn't have this yet"; a 403 is the platform-operator
// allowlist; anything else (including the 401 of an expired session) routes
// through cloudFail so auth handling stays shared.
//
// The 403 sentence names PLATFORM_ADMIN_EMAILS on purpose. The refusal is NOT
// "log in again" — the caller already holds a valid session, and re-running
// `bp login` will produce the identical 403 forever. The only thing that moves
// this refusal is the control plane's allowlist, so the message says which knob
// and where it lives; anything vaguer sends an operator round a login loop
// during the exact incident the brake exists for. (It is unset on prod today —
// tracked separately as the ops gate, not as a CLI defect.)
func rolloutFail(out *writer, err error) int {
	var re *cloudclient.CloudRouteError
	if errors.As(err, &re) {
		switch re.Code {
		case "not_found":
			return useError(out, "not_found",
				"this control plane has no fleet-rollout control (update it, or this is an older deployment)",
				exitNotFound)
		case "forbidden":
			return useError(out, "auth",
				"you are signed in, but this account is not a platform operator — the fleet brake is "+
					"gated on the control plane's PLATFORM_ADMIN_EMAILS allowlist, and your login email is not on it "+
					"(re-running `bp login` will not change this; the allowlist must be set on the control plane). "+
					"Per-instance pause/pin needs no operator: see `bp cloud autoupdate`.",
				exitAuth)
		}
	}
	return cloudFail(out, "fleet rollout", err)
}

// printCloudAutoupdateHelp writes `bp cloud autoupdate` usage.
func printCloudAutoupdateHelp(out *writer) {
	const help = `bp cloud autoupdate — control ONE instance's self-update policy.

USAGE
  bp cloud autoupdate pin <instance> <release>
  bp cloud autoupdate unpin <instance>
  bp cloud autoupdate pause <instance>
  bp cloud autoupdate resume <instance>
  [-o json|yaml]

WHAT IT DOES
  Managed instances ride new blessed releases by default (opt-out). These verbs
  are the escape hatch — they PATCH the control plane's autoupdate policy for one
  box (needs 'bp login'; team-admin-gated). <instance> is a fleet name or id (the
  forms 'bp cloud status' shows).

    pin <release>   hold the box at or above <release> — a FREEZE. A pin does NOT
                    roll back: it stops the box moving PAST the pin, it never moves
                    it earlier (the updater only fast-forwards).
    unpin           clear the pin — the box rides blessed releases again.
    pause           temporary hold — no update until resumed.
    resume          release a pause.

  See the resulting policy at a glance in 'bp cloud status' (the POLICY column:
  pin@<tag> · paused · off · auto).

OUTPUT
  a one-line receipt + the resulting policy; -o json emits
  {ok, instance, autoupdate:{enabled, paused, pinned_release}}.`
	out.outf("%s", help)
}

// printCloudRolloutHelp writes `bp cloud rollout` usage.
func printCloudRolloutHelp(out *writer) {
	const help = `bp cloud rollout — the fleet-wide autoupdate brake (platform operator).

USAGE
  bp cloud rollout status
  bp cloud rollout halt
  bp cloud rollout resume
  [-o json|yaml]

WHAT IT DOES
  The control plane rolls blessed releases across the fleet one health-gated box
  at a time. These verbs are the GLOBAL control over that rollout. They run on
  YOUR bp-login session ('bp login') and are PLATFORM-OPERATOR gated: the control
  plane accepts them only when your login email is on its PLATFORM_ADMIN_EMAILS
  allowlist (the same allowlist that lights the console's Operator surface). A
  plain team session is refused with a 403 that says so — owner or admin on a
  team is a different axis and does not grant it:

    status   is the rollout running or halted, and how many boxes are eligible /
             behind / in-flight (each shown when the control plane reports it).
    halt     stop advancing ANY instance — the emergency brake when a blessed
             release turns out bad. In-flight boxes finish; nothing new starts.
    resume   restart a halted rollout.

  Per-instance policy (pin/pause) lives in 'bp cloud autoupdate'; this is the
  fleet-level switch above it.

OUTPUT
  the headline running/halted state + any reported counters; -o json emits the
  control plane's rollout envelope verbatim.`
	out.outf("%s", help)
}
