package cli

// barkparks_rotate_admin_token_cmd.go — `bp barkparks rotate-admin-token
// <instance>`: replace the admin token Barkpark Cloud holds for one box
// (POST /v1/operator/barkparks/:id/admin-token/rotate, operator only). Cloud
// mints a successor on the box with the held token, stores it, checks it, and
// then revokes the old one. Only token ids are printed.

import (
	"context"
	"encoding/json"
	"strings"
)

const rotateAdminTokenUsage = "bp barkparks rotate-admin-token <instance>"

func runBarkparksRotateAdminToken(out *writer, args []string) int {
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" || strings.HasPrefix(args[0], "-") {
		return useError(out, "usage", "usage: "+rotateAdminTokenUsage, exitUsage)
	}
	ref := strings.TrimSpace(args[0])

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	id, err := resolveOpenBarkparkID(cfg, ref)
	if err != nil {
		return cloudFail(out, "resolve "+ref, err)
	}

	res, rerr := cfg.CloudClient().RotateAdminToken(context.Background(), id)
	if rerr != nil {
		return cloudFail(out, "rotate-admin-token "+ref, rerr)
	}

	code := exitOK
	if res.Rotated.OldTokenStatus == nil || *res.Rotated.OldTokenStatus != 401 {
		code = exitGeneric
	}

	var envelope map[string]any
	if json.Unmarshal(res.Raw, &envelope) == nil && out.emitStructured(envelope) {
		return code
	}

	r := res.Rotated
	out.outf("Rotated the admin token Cloud holds for %s (%s).", ref, res.BarkparkID)
	out.outf("  old token %s  revoked", r.OldTokenID)
	out.outf("  new token %s  stored, label %q, workspace %s", r.NewTokenID, r.Label, r.Workspace)
	if len(r.SeatsCarried) > 0 {
		out.outf("  seats carried to the new token: %s", strings.Join(r.SeatsCarried, ", "))
	}
	if r.OldTokenStatus == nil {
		out.outf("  the box did not answer the check of the old token")
	} else {
		out.outf("  the old token now gets HTTP %d", *r.OldTokenStatus)
	}
	return code
}
