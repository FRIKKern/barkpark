package cli

// cloud_rollback_cmd.go is `bp cloud rollback <instance>` — the CLI twin of the
// console's Rollback button (isu-w6, charter W6 D24). It asks the control plane to
// roll ONE managed instance back to its previous blue/green code slot: the control
// plane runs the box's synchronous slot preflight, ATOMICALLY PINS the instance at
// the recovered target sha (so the 5-minute rollout worker can never silently
// re-update past the operator — an unpinned rollback is a lie), and spawns the
// async slot flip (git reset → reboot the idle slot → health-gate it on its own
// port → flip Caddy ONLY if it comes up green).
//
// This is INSTANCE rollback — the blue/green CODE-slot flip — deliberately DISTINCT
// from the site-deployment "roll back to this" promote (which re-queues an older
// build artifact). The copy says so, so the two surfaces never blur.
//
// Honest states, deliberately:
//   - a 202 is STARTED, not DONE — the flip is async and health-gated, so the
//     verdict points the operator at `bp cloud status` and states plainly that a
//     slot which boots dead fails closed with Caddy untouched;
//   - the receipt names the PIN (charter D16) so the operator sees the box is
//     frozen at the rolled-back version, and quotes the D19 schema law ("app-level
//     only; schema stays forward");
//   - every refusal is one plain sentence through the unified `bp:` error seam
//     (no previous slot, an in-flight run, a box that predates slots, an
//     unreachable box), exit-coded by the charter's ladder (409-family → 6,
//     404 → 4, auth → 3, 5xx → 8);
//   - `-o json` re-emits the control-plane envelope BYTES verbatim (D4 — the
//     envelope IS the contract), never a second, drifting definition of it.
//
// Like every control-plane verb here it NEVER writes bp config: it resolves the
// instance by name/id via the fleet list and the Cloud session token, exactly like
// `bp cloud verify` / `bp cloud autoupdate`, and touches nothing local.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// runCloudRollback is `bp cloud rollback <instance>`: resolve the instance (name
// or id, the same forms `bp cloud status`/`bp cloud verify` accept), ask the
// control plane to roll it back, and render the started-verdict (or a typed
// refusal). Requires `bp login`.
func runCloudRollback(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (the cloud-verify convention; no
	// positional can legitimately start with "-").
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudRollbackHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudRollbackHelp(out)
		return exitOK
	}

	const usage = "bp cloud rollback <instance>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want 1 argument (usage: %s)", usage), exitUsage)
	}
	ref := a.pos[0]

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to roll an instance back, or set BARKPARK_CLOUD_TOKEN for a CI job", exitAuth)
	}

	id, rerr := resolveOpenBarkparkID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}

	res, rberr := cfg.CloudClient().Rollback(cloudCtx(), id)
	if rberr != nil {
		return rollbackFail(out, ref, rberr)
	}

	if out.output == "json" || out.output == "yaml" {
		emitRollbackRaw(out, res)
		return exitOK
	}
	renderRollbackResult(out, ref, res)
	return exitOK
}

// emitRollbackRaw writes the envelope for a machine consumer: json is the exact
// control-plane bytes — verbatim, key order and all, so the CLI never becomes a
// second, drifting definition of the contract (the emitVerifyRaw idiom); yaml is a
// faithful re-encode (yaml consumers do not depend on key order).
func emitRollbackRaw(out *writer, res cloudclient.RollbackResult) {
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

// renderRollbackResult prints the human view of a STARTED rollback: the verdict
// line (naming the target sha when the control plane reported one), the pin the
// control plane wrote (charter D16), the D19 schema-forward law, and the honest
// "async + health-gated" note that sends the operator to `bp cloud status`.
func renderRollbackResult(out *writer, ref string, res cloudclient.RollbackResult) {
	if target := rollbackShortSHA(res.TargetSHA); target != "" {
		out.outf("✓ instance rollback started — %s is resetting to %s, health-gating the previous slot, and flipping Caddy only if it comes up green.", ref, target)
	} else {
		// Defensive: a 202 with no target sha is a leaner/older control plane. Say
		// what is happening without inventing a version.
		out.outf("✓ instance rollback started — %s is resetting to its previous slot, health-gating it, and flipping Caddy only if it comes up green.", ref)
	}
	if pin := rollbackCell(res.PinnedRelease); pin != "" {
		out.outf("  pinned at %s — the fleet auto-update worker cannot silently re-update past this rollback.", pin)
	}
	out.outf("  app-level only; schema stays forward — rolling back code does NOT undo a schema migration (write a compensating one).")
	out.outf("  the flip is async and health-gated — watch it land with `bp cloud status` (a slot that boots dead fails closed, Caddy untouched).")
}

// rollbackShortSHA renders the target sha clamped to 12 hex (the git-short idiom),
// scrubbed of control bytes like every server-authored cell. Empty for a nil/blank
// pointer so the caller can pick its no-sha wording.
func rollbackShortSHA(sha *string) string {
	s := rollbackCell(sha)
	if s == "" {
		return ""
	}
	if r := []rune(s); len(r) > 12 {
		s = string(r[:12])
	}
	return s
}

// rollbackCell trims + scrubs a nullable server-authored string; "" for a
// nil/blank pointer (the honest "not reported", never a fabricated value).
func rollbackCell(s *string) string {
	if s == nil {
		return ""
	}
	t := strings.TrimSpace(*s)
	if t == "" {
		return ""
	}
	return sanitizeCell(t)
}

// rollbackFail maps a refused rollback onto the unified `bp:` error seam: each
// typed contract code becomes one plain, actionable sentence, exit-coded by the
// charter's HTTP-status ladder (W6 D23 — 409-family → conflict, 404 → not-found,
// auth → auth, 5xx → server). Anything outside the contract set (an expired
// session, a gateway page) routes through cloudFail so auth handling stays
// identical to every other cloud verb.
func rollbackFail(out *writer, ref string, err error) int {
	var re *cloudclient.RollbackError
	if errors.As(err, &re) {
		return useError(out, rollbackErrLabel(re.Code), rollbackMessage(ref, re), rollbackExit(re.HTTPStatus, re.Reason, re.Code))
	}
	return cloudFail(out, "roll instance back", err)
}

// rollbackExit maps the refusal's HTTP status onto the CLI's stable exit ladder
// (charter W6 D23). Mapping by STATUS FAMILY (not by code) keeps a new refusal
// code the control plane may add exit-coded correctly without a CLI change.
//
// The ONE exception is the CAUSE the server explicitly named. This route is gated
// by require_primary_team_admin/1, whose teamless refusal is being converted from
// 422 {"error":"no_team"} (exit 1) to 403 {"error":"forbidden","reason":"no_team"}.
// DECIDED (cch-w40-s4): a no_team refusal stays exitGeneric on BOTH sides of that
// conversion. Exit 3 means "your credential is bad" — a script retries auth, a
// user re-runs `bp login` — and that is false here: the credential is fine, the
// login simply has no active team, and the fix is `bp team use <team>`. A
// server-side re-classification of the STATUS must not silently change the exit a
// caller has always seen for the same cause. Only a reason the CLI RECOGNISES may
// override the status, so an unknown cause can never move an exit code.
//
// The cause is read from `reason` OR from the code itself — the SAME predicate
// rollbackMessage/2 uses, and they must not diverge: a control plane that answers
// 403 {"error":"no_team"} (the flat shape, code-as-cause at the new status) would
// otherwise print the "run `bp team use`" sentence and exit 3 in the same breath,
// telling the reader two different things about the same refusal.
func rollbackExit(status int, reason, code string) int {
	if reason == "no_team" || code == "no_team" {
		return exitGeneric // 1 — the cause, not the status family
	}
	switch {
	case status == 404:
		return exitNotFound // 4
	case status == 409:
		return exitConflict // 6
	case status == 401 || status == 403:
		return exitAuth // 3
	case status >= 500:
		return exitServer // 8 — 502 unreachable/error, 500 decrypt, 503 not-configured
	default:
		return exitGeneric // 1
	}
}

// rollbackErrLabel is the `bp:` error-code label for a refusal — the control
// plane's own code where present, so the machine-readable envelope names the exact
// refusal, with a stable "failed" fallback for a codeless body.
func rollbackErrLabel(code string) string {
	if strings.TrimSpace(code) == "" {
		return "failed"
	}
	return code
}

// rollbackMessage is the one human sentence per refusal code. Each says WHAT
// happened AND that nothing was flipped where that is the truth (a deny path must
// never read like a partial action), and points at the fix or the next step.
func rollbackMessage(ref string, re *cloudclient.RollbackError) string {
	// The CAUSE the server named outranks the code: the team gate refuses a
	// teamless caller with the bare code "no_team" today and with the generic
	// "forbidden" + reason "no_team" after #9956. Both must produce the same
	// sentence and the same fix, or the conversion silently changes what the user
	// is told — and "forbidden" alone would send them to re-authenticate a
	// credential that is not the problem.
	if re.Reason == "no_team" || re.Code == "no_team" {
		return fmt.Sprintf("your Cloud login has no active team, so the control plane refused the rollback of %q — run `bp team use <team>` and retry. Nothing was flipped.", ref)
	}
	switch re.Code {
	case "no_previous_slot":
		return fmt.Sprintf("instance %q has no previous slot to roll back to — its idle blue/green slot has no recorded version (a box that has only deployed once, or whose slot stamp is missing). Nothing was flipped.", ref)
	case "already_running":
		return fmt.Sprintf("an update or rollback is already running on instance %q — one run at a time; wait for it to finish (watch `bp cloud status`) and retry. Nothing new was flipped.", ref)
	case "not_supported":
		return fmt.Sprintf("instance %q predates the blue/green slot machinery — it has no idle slot to roll back to. Nothing was flipped.", ref)
	case "not_found":
		return fmt.Sprintf("no such instance %q (or it is not in your team)", ref)
	case "no_admin_token":
		return fmt.Sprintf("instance %q has no stored admin token — it is captured at provision time, so a pre-existing instance may need a re-provision", ref)
	case "decrypt_failed":
		return fmt.Sprintf("could not decrypt the admin token for instance %q — the stored credential looks corrupt", ref)
	case "instance_unreachable":
		return fmt.Sprintf("instance %q never answered the rollback request — check the box is running (`bp cloud status`); nothing was flipped", ref)
	case "instance_error":
		return fmt.Sprintf("instance %q answered the rollback request with an error — nothing was flipped; run with -o json to inspect the envelope", ref)
	case "feature_not_configured", "not_enabled":
		return fmt.Sprintf("rollback is not enabled on instance %q — the box must run with BARKPARK_SELF_UPDATE_APPLY=1 to apply a rollback", ref)
	default:
		if d := strings.TrimSpace(re.Detail); d != "" {
			return fmt.Sprintf("the control plane refused the rollback of %q (%s: %s)", ref, sanitizeCell(re.Code), sanitizeCell(d))
		}
		return fmt.Sprintf("the control plane refused the rollback of %q (%s)", ref, sanitizeCell(re.Code))
	}
}

// printCloudRollbackHelp writes `bp cloud rollback` usage.
func printCloudRollbackHelp(out *writer) {
	const help = `bp cloud rollback — roll ONE managed instance back to its previous release.

USAGE
  bp cloud rollback <instance> [-o json|yaml]

WHAT IT DOES
  Asks the control plane to flip a managed instance back to its previous
  blue/green CODE slot — the version it was on before the last deploy. The
  control plane resolves the idle slot's recorded sha, PINS the instance at it
  (so the fleet auto-update worker can never silently re-update past your
  rollback), and starts the flip on the box: reset the shared checkout to that
  sha, reboot the idle slot, health-gate it on its OWN port, and flip Caddy
  ONLY if it comes up green. <instance> is a fleet name or id (the forms
  'bp cloud status' shows); needs 'bp login' (team-admin-gated).

  This is INSTANCE rollback — the blue/green code-slot flip. It is NOT the
  site-deployment "roll back to this" promote (which re-queues an older build).

  app-level only; schema stays forward — rolling back code does NOT undo a
  schema migration. If the last release ran one, write a compensating migration.

HONEST STATES
  A 202 is STARTED, not done — the flip is async and health-gated, so watch it
  land with 'bp cloud status'. If the old slot boots dead the box fails closed
  (Caddy untouched) and says so. Refusals are one plain sentence + a stable exit:
    no previous slot / not supported / already running   → nothing was flipped
    unreachable / errored instance                       → nothing was flipped

OUTPUT + EXIT
  a one-line verdict + the pinned target; -o json re-emits the control plane's
  rollback envelope verbatim ({status, target_sha, pinned_release}). Exit codes:
  0 started · 4 no such instance · 6 refused (no previous slot / already running /
  not supported) · 8 instance unreachable or errored · 3 not logged in.`
	out.outf("%s", help)
}
