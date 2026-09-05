package cli

// cloud_update_cmd.go is `bp cloud update <instance> [--force]` — the CLI twin of
// the console's Update button, and the command the console has been PRINTING as a
// recovery instruction with nothing behind it: `webhookErrorHtml` renders
// cliChipHtml("bp cloud update " + instance) on a capability_unavailable envelope
// (cloud/priv/static/app.js), pinned by a console test, while `bp cloud` knew no
// such verb. A recovery chip that resolves to "unknown cloud command" is worse
// than no chip: it fails at the operator's first copy-paste, mid-incident.
//
// It asks the control plane to start an IN-PLACE self-update run on ONE managed
// instance. The control plane relays POST /v1/admin/self-update to the box
// server-side with the stored admin token and relays the box's verdict back with
// its semantics intact (router.ex:3816) — so this command's job is to REPORT that
// verdict, never to author one. There is deliberately no canned success sentence
// here: the started line quotes the state the server named, and a control plane
// that answers 202 without naming one gets an honest "accepted, state not
// reported" rather than a confident lie.
//
// THE PIN IS THE INTERESTING REFUSAL. A pinned box is FROZEN, and an unforced
// trigger against it is a 409 {"error":{"code":"pinned","pinned_release":"…"}},
// not a silent no-op (isu-w5.2 pin honesty). `--force` overrides the pin for that
// ONE run — the same override the console's "Update anyway" button sends — and it
// is a REAL server field (`force? = conn.body_params["force"] == true`), not CLI
// theatre. It overrides the PIN and nothing else: already_running / not_enabled /
// not_live refuse a forced call exactly as they refuse an unforced one, and the
// copy says so rather than offering --force as a universal retry.
//
// Like every control-plane verb it NEVER writes bp config: it resolves the
// instance by name/id via the fleet list and the Cloud session token, exactly like
// `bp cloud rollback` / `bp cloud verify`, and touches nothing local.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// cloudUpdateUsage is the ONE command shape, in one place. The console prints
// "bp cloud update <instance>" as a copy-pasteable chip, so the CLI's usage string
// and that chip are two halves of a single contract: a test pins this constant
// byte-equal to the chip text, and the dispatch table routes exactly this verb.
// Drift on either side is a lie told to an operator mid-incident.
const cloudUpdateUsage = "bp cloud update <instance>"

// runCloudUpdate is `bp cloud update <instance> [--force]`: resolve the instance
// (name or id, the forms `bp cloud status`/`bp cloud rollback` accept), ask the
// control plane to trigger a self-update run, and render the server's verdict (or
// a typed refusal). Requires `bp login`.
func runCloudUpdate(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (the cloud-rollback convention;
	// no positional can legitimately start with "-").
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudUpdateHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudUpdateHelp(out)
		return exitOK
	}

	a, err := parseHzArgs(args, nil, []string{"force"}, cloudUpdateUsage+" [--force]")
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want 1 argument (usage: %s [--force])", cloudUpdateUsage), exitUsage)
	}
	ref := a.pos[0]
	force := a.bools["force"]

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to update an instance, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, uerr := cfg.CloudClient().TriggerSelfUpdate(cloudCtx(), id, force)
	if uerr != nil {
		return selfUpdateFail(out, ref, force, uerr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitSelfUpdateRaw(out, res)
		return exitOK
	}
	renderSelfUpdateResult(out, ref, force, res)
	return exitOK
}

// emitSelfUpdateRaw writes the envelope for a machine consumer: json is the exact
// control-plane bytes — verbatim, key order and all, so the CLI never becomes a
// second, drifting definition of the contract (the emitRollbackRaw idiom); yaml is
// a faithful re-encode (yaml consumers do not depend on key order).
func emitSelfUpdateRaw(out *writer, res cloudclient.SelfUpdateResult) {
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
	case "yaml":
		var v any
		if json.Unmarshal(res.Raw, &v) == nil {
			out.renderYAML(v)
		}
	}
}

// renderSelfUpdateResult prints the human view of a TRIGGERED run.
//
// The verdict line is built from the state the SERVER named (`status`, today
// "updating"). That is the whole point: a canned "✓ updated!" would be false twice
// over — the run is async and has only just started, and the word for what is
// happening belongs to the control plane. A 202 that names no state still gets a
// truthful line, and it says plainly that no state was reported.
func renderSelfUpdateResult(out *writer, ref string, force bool, res cloudclient.SelfUpdateResult) {
	if state := rollbackCell(res.Status); state != "" {
		out.outf("✓ self-update triggered on %s — the control plane relayed the request to the box, which reports %q.", ref, state)
	} else {
		// Defensive: a 202 with no status is a leaner/older control plane. Say what
		// is known (the request was accepted) and NOT what is not.
		out.outf("✓ self-update triggered on %s — the control plane accepted the request; it reported no run state.", ref)
	}
	if force {
		out.outf("  --force overrode the instance's pin for THIS run only — the pin is still set; `bp cloud autoupdate unpin %s` is what lifts it for good.", ref)
	}
	out.outf("  the run is async — it is not finished when this command returns; watch it land with `bp cloud status`.")
}

// selfUpdateFail maps a refused self-update onto the unified `bp:` error seam: each
// typed contract code becomes one plain, actionable sentence, exit-coded by the
// shared HTTP-status ladder. Anything outside the contract set (an expired session,
// a gateway page) routes through cloudFail so auth handling stays identical to
// every other cloud verb.
func selfUpdateFail(out *writer, ref string, force bool, err error) int {
	var se *cloudclient.SelfUpdateError
	if errors.As(err, &se) {
		return useError(out, rollbackErrLabel(se.Code), selfUpdateMessage(ref, force, se), rollbackExit(se.HTTPStatus, se.Reason, se.Code))
	}
	return cloudFail(out, "trigger a self-update", err)
}

// selfUpdateMessage is the one human sentence per refusal code. Each says WHAT
// happened AND that nothing was started where that is the truth (a deny path must
// never read like a partial action), and points at the fix or the next step.
//
// The PINNED arm mirrors the console's conflict modal ("This instance is pinned" /
// "Autoupdate is frozen at <release>. Pinning holds an instance at or above its
// current version; it does not roll back. Update anyway to override the pin for
// this one run.") so an operator who saw the modal and an operator who ran the
// chip are told the same thing about the same box. The affordance differs only in
// spelling: the modal's "Update anyway" button IS `--force`.
func selfUpdateMessage(ref string, force bool, se *cloudclient.SelfUpdateError) string {
	// The CAUSE the server named outranks the code (the rollback precedent): the
	// team gate refuses a teamless caller with the bare code "no_team" and with
	// the generic "forbidden" + reason "no_team", and both must produce the same
	// sentence and the same fix.
	if se.Reason == "no_team" || se.Code == "no_team" {
		return fmt.Sprintf("your Cloud login has no active team, so the control plane refused the self-update of %q — run `bp team use <team>` and retry. Nothing was started.", ref)
	}
	switch se.Code {
	case "pinned":
		at := ""
		if p := sanitizeCell(se.PinnedRelease); p != "" {
			at = " at " + p
		}
		// A pin refusal that arrives on an ALREADY forced call is not the operator
		// forgetting a flag — it is a control plane that did not honour the
		// override — so it must not be answered with "just add --force".
		if force {
			return fmt.Sprintf("instance %q is pinned%s and the control plane refused the update even with --force — the pin was not overridden. Nothing was started; run with -o json to inspect the envelope.", ref, at)
		}
		return fmt.Sprintf("instance %q is pinned%s — autoupdate is frozen there, so the update was refused rather than silently skipped. Pinning holds an instance at or above its current version; it does not roll back. Re-run with --force to override the pin for this ONE run, or `bp cloud autoupdate unpin %s` to lift it for good. Nothing was started.", ref, at, ref)
	case "already_running":
		return fmt.Sprintf("a self-update is already running on instance %q — one run at a time (--force overrides a pin, not a run in flight); wait for it to finish (watch `bp cloud status`) and retry. Nothing new was started.", ref)
	case "not_enabled", "feature_not_configured":
		return fmt.Sprintf("self-update is not enabled on instance %q — the box must run with BARKPARK_SELF_UPDATE_APPLY=1 to apply an update. Nothing was started.", ref)
	case "not_live":
		return fmt.Sprintf("instance %q is not live yet — it is still provisioning, so there is nothing to update. Nothing was started.", ref)
	case "suspended":
		return fmt.Sprintf("instance %q is suspended — the control plane will not run a maintenance action on a suspended box (nothing was stopped or deleted; billing is the fix). Nothing was started.", ref)
	case "identity_refused":
		return fmt.Sprintf("instance %q refused the control plane's stored admin credential, so the update was never sent — nothing reached the box. Barkpark Cloud stops spending a credential a box rejected; a re-provision restores it.", ref)
	case "not_supported":
		return fmt.Sprintf("instance %q predates the self-update machinery — its admin endpoint does not exist. Nothing was started.", ref)
	case "not_found":
		return fmt.Sprintf("no such instance %q (or it is not in your team)", ref)
	case "no_admin_token":
		return fmt.Sprintf("instance %q has no stored admin token — it is captured at provision time, so a pre-existing instance may need a re-provision. Nothing was started.", ref)
	case "decrypt_failed":
		return fmt.Sprintf("could not decrypt the admin token for instance %q — the stored credential looks corrupt. Nothing was started.", ref)
	case "runner_start_failed":
		return fmt.Sprintf("instance %q accepted the request and its update runner failed to start — the box is reachable, so this is worth retrying. Nothing was started.", ref)
	case "instance_unreachable", "instance_unavailable":
		return fmt.Sprintf("instance %q never answered the self-update request — check the box is running (`bp cloud status`); nothing was started", ref)
	case "instance_error":
		return fmt.Sprintf("instance %q answered the self-update request with an error — nothing was started; run with -o json to inspect the envelope", ref)
	default:
		if d := strings.TrimSpace(se.Detail); d != "" {
			return fmt.Sprintf("the control plane refused the self-update of %q (%s: %s)", ref, sanitizeCell(se.Code), sanitizeCell(d))
		}
		return fmt.Sprintf("the control plane refused the self-update of %q (%s)", ref, sanitizeCell(se.Code))
	}
}

// printCloudUpdateHelp writes `bp cloud update` usage. The USAGE line opens with
// the EXACT chip text the console prints, so a reader who copy-pasted the chip and
// then ran -h sees the same command shape twice.
func printCloudUpdateHelp(out *writer) {
	help := `bp cloud update — trigger an in-place self-update on ONE managed instance.

USAGE
  ` + cloudUpdateUsage + ` [--force] [-o json|yaml]

WHAT IT DOES
  Asks the control plane to start a self-update RUN on a managed box — the CLI
  twin of the console's Update button, and the command the console prints as a
  recovery chip. The control plane relays the request to the instance's own
  admin endpoint with the stored admin token (that token never reaches your
  machine) and relays the box's verdict straight back. <instance> is a fleet
  name or id (the forms 'bp cloud status' shows); needs 'bp login'
  (team-admin-gated).

  --force overrides a PIN for this one run — the same override the console's
  "Update anyway" button sends. It overrides the pin and NOTHING else: a run
  already in flight, a box without BARKPARK_SELF_UPDATE_APPLY=1, and a box that
  is not live all refuse a forced call exactly as they refuse an unforced one.
  To lift a pin for good, use 'bp cloud autoupdate unpin <instance>'.

HONEST STATES
  A 202 is TRIGGERED, not done — the run is async, so watch it land with
  'bp cloud status'. The verdict quotes the state the control plane named; this
  command never prints a success it made up. Refusals are one plain sentence
  + a stable exit:
    pinned (unforced)                  → nothing started; --force or unpin
    already running / not live         → nothing started
    self-update not enabled on the box → nothing started
    unreachable / errored instance     → nothing reached the box

OUTPUT + EXIT
  a one-line verdict naming the run state; -o json re-emits the control plane's
  envelope verbatim ({ok, status}). Exit codes: 0 triggered · 4 no such instance
  (or a box that predates self-update) · 6 refused (pinned / already running /
  not live / suspended) · 8 not enabled, unreachable or errored · 3 not logged in.`
	out.outf("%s", help)
}
