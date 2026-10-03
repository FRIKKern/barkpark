package cli

import (
	"fmt"
	"strings"
)

// runCloudSiteCancel is `bp cloud site cancel <site> <deployment-id>` (also
// `bp sites cancel`), the OPERATOR cancel (task-4187bcf6d0424cfc): POST
// /v1/sites/:id/deployments/:dep_id/cancel.
//
// The control plane decides; this verb only relays the decision.
//
//   - A queued row, or a container row still building, becomes cancelled
//     (failure_reason operator_cancelled) and the active slot is free at once.
//     The receipt says so and names the rebuild.
//   - A row that is already cancelled answers 200 already_cancelled. That is
//     idempotent, and the receipt says nothing new was written.
//   - live/failed/deferred is 409 illegal_transition, and a box-driven build
//     (static/node building, or any pushing) is 409 in_flight. Both exit
//     non-zero and carry the plane's own detail sentence. The CLI never prints
//     a "cancelled" the plane did not write.
func runCloudSiteCancel(out *writer, g globals, args []string) int {
	const usage = "bp cloud site cancel <site> <deployment-id>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 2 {
		return useError(out, "usage", fmt.Sprintf("want <site> and <deployment-id> (usage: %s; list deployment ids with `bp cloud site deployments <site>`)", usage), exitUsage)
	}
	ref, depID := a.pos[0], strings.TrimSpace(a.pos[1])
	if depID == "" {
		return useError(out, "usage", "empty <deployment-id> (usage: "+usage+")", exitUsage)
	}

	cfg, ok := siteCloudConfig(out, "cancel a deployment")
	if !ok {
		return exitAuth
	}
	id, rerr := resolveOpenSiteID(cfg, ref)
	if rerr != nil {
		return openResolveFail(out, rerr)
	}
	res, cerr := cfg.CloudClient().CancelDeployment(cloudCtx(), id, depID)
	if cerr != nil {
		return cloudFail(out, "cancel deployment "+depID, cerr)
	}

	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, strings.TrimRight(string(res.Raw), "\n"))
		return exitOK
	case "yaml":
		out.renderRaw(res.Raw)
		return exitOK
	}
	renderDeploymentCancelled(out, ref, depID, res.Status, res.Next)
	return exitOK
}

// renderDeploymentCancelled is the human receipt. Its three facts are the
// row's state, the free slot, and the way back.
func renderDeploymentCancelled(out *writer, ref, depID, status, next string) {
	if status == "already_cancelled" {
		out.outf("✓ deployment %s on %s was already cancelled — nothing new was written.", depID, ref)
	} else {
		out.outf("✓ cancelled deployment %s on %s.", depID, ref)
	}
	out.outf("  the build slot is free.")
	if strings.TrimSpace(next) != "" {
		out.outf("  next: %s", next)
	}
}
