package provisioner

import (
	"context"
	"fmt"
	"net"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// enable-apply job (isu-w5 gap): flip BARKPARK_SELF_UPDATE_APPLY=1 on a managed
// box and restart the app, so the instance's one-click/autoupdate executor
// works. The flag ships fail-closed for SELF-HOSTED installs (an operator must
// opt in on their own box), but a MANAGED box is cloud-operated by definition —
// the team admin enabling the autoupdate policy IS the consent, and without
// this job every fleet rollout parks on "needs BARKPARK_SELF_UPDATE_APPLY=1".
// Enqueued by PATCH /v1/barkparks/:id/autoupdate {enabled: true}; also written
// at provision time for new boxes (provision.go), so this job is the retrofit
// path for boxes provisioned before the flag existed.
//
// Deliberately the thinnest sibling of the attach-domain rail: no DNS, no
// Caddy — one idempotent env write + one restart, same StepRunner seam, same
// fail-closed validation posture.

// EnableApplyFunc executes one validated enable-apply job. Injected like
// AttachDomainFunc so the worker stays transport-only and tests drive fakes.
type EnableApplyFunc func(ctx context.Context, spec EnableApplySpec) error

// validateEnableApplySpec is the fail-closed gate: ip reaches the SSH argv, so
// it is re-validated here — the worker never trusts the control-plane payload.
func validateEnableApplySpec(spec EnableApplySpec) error {
	if net.ParseIP(spec.IP) == nil {
		return fmt.Errorf("enable-apply: ip %q is not a valid IP address — refusing before any side effect", spec.IP)
	}
	return nil
}

// setSelfUpdateApplyStep renders the idempotent "ensure
// BARKPARK_SELF_UPDATE_APPLY=1 is in the app env" step — grep-guarded append,
// same portable rewrite discipline as mergeExtraOriginStep (no sed -i; tests
// execute it with real bash against a temp file).
func setSelfUpdateApplyStep(envFile string) cloud.CaddyStep {
	script := "grep -q '^BARKPARK_SELF_UPDATE_APPLY=1$' " + envFile + " 2>/dev/null || " +
		"printf 'BARKPARK_SELF_UPDATE_APPLY=1\\n' >> " + envFile
	return cloud.CaddyStep{
		Title: "enable the self-update executor (BARKPARK_SELF_UPDATE_APPLY=1)",
		Cmd:   script,
		Argv:  []string{"bash", "-lc", script},
	}
}

// enableApplySteps is the ordered remote plan — env flag, then app restart
// (the Runner reads its enabled-flag config at boot). Pure, like
// attachDomainSteps, so tests exercise the rendered script directly.
func enableApplySteps(envFile string) []cloud.CaddyStep {
	return []cloud.CaddyStep{
		setSelfUpdateApplyStep(envFile),
		instanceRestartStep(),
	}
}

// EnableApplyWith flips the executor flag on the box at spec.IP via the seams'
// per-host runner. Idempotent end to end — a re-run after a dropped
// succeed-report appends nothing and just restarts again.
func EnableApplyWith(ctx context.Context, seams Seams, spec EnableApplySpec) error {
	if err := validateEnableApplySpec(spec); err != nil {
		return err
	}

	runnerFor := seams.RunnerFor
	if runnerFor == nil {
		runnerFor = func(host string) cloud.StepRunner { return cloud.NewSSHStepRunner(host) }
	}
	runner := runnerFor(spec.IP)
	for _, s := range enableApplySteps(attachEnvFile) {
		if err := runner.Run(ctx, s); err != nil {
			return fmt.Errorf("enable-apply %s: %w", spec.IP, err)
		}
	}
	return nil
}

// DefaultEnableApply returns an EnableApplyFunc bound to seams — the value the
// Worker calls per enable-apply job.
func DefaultEnableApply(seams Seams) EnableApplyFunc {
	return func(ctx context.Context, spec EnableApplySpec) error {
		return EnableApplyWith(ctx, seams, spec)
	}
}
