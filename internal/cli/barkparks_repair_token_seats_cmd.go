package cli

// barkparks_repair_token_seats_cmd.go — `bp barkparks repair-token-seats
// <instance>`: give a token on one box back the workspace seats its revoked
// predecessor held (POST /v1/operator/barkparks/:id/token-seats/restore,
// operator only). Cloud calls the box with the admin token it holds; the box
// decides from its own audit rows what may be restored. A dry run unless
// --apply. Only token ids, slugs and roles are printed.
//
// The flags are --seat and --token-id, not --workspace and --token: those two
// are global flags (the server's workspace and token) that the global parser
// takes from anywhere on the line.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

const repairTokenSeatsUsage = "bp barkparks repair-token-seats <instance> [--token-id <id>] [--seat <workspace> ...] [--apply]"

type repairTokenSeatsArgs struct {
	ref   string
	req   cloudclient.TokenSeatRestoreRequest
	apply bool
}

func parseRepairTokenSeatsArgs(args []string) (repairTokenSeatsArgs, error) {
	var a repairTokenSeatsArgs
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := splitTokenFlag(args[i])
		if name == "" {
			if a.ref != "" {
				return a, fmt.Errorf("unexpected argument %q (usage: %s)", args[i], repairTokenSeatsUsage)
			}
			a.ref = strings.TrimSpace(args[i])
			continue
		}
		if name == "apply" {
			if hasInline && inline != "true" {
				return a, fmt.Errorf("--apply takes no value (usage: %s)", repairTokenSeatsUsage)
			}
			a.apply = true
			continue
		}
		value := inline
		if !hasInline {
			if i+1 >= len(args) {
				return a, fmt.Errorf("--%s needs a value (usage: %s)", name, repairTokenSeatsUsage)
			}
			i++
			value = args[i]
		}
		value = strings.TrimSpace(value)
		switch name {
		case "token-id":
			a.req.TokenID = value
		case "seat":
			a.req.Workspaces = append(a.req.Workspaces, splitCommaList(value)...)
		default:
			return a, fmt.Errorf("unknown flag --%s (usage: %s)", name, repairTokenSeatsUsage)
		}
	}
	if a.ref == "" {
		return a, fmt.Errorf("usage: %s", repairTokenSeatsUsage)
	}
	a.req.Apply = a.apply
	return a, nil
}

func runBarkparksRepairTokenSeats(out *writer, args []string) int {
	a, perr := parseRepairTokenSeatsArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	id, err := resolveOpenBarkparkID(cfg, a.ref)
	if err != nil {
		return cloudFail(out, "resolve "+a.ref, err)
	}

	res, rerr := cfg.CloudClient().RestoreTokenSeats(context.Background(), id, a.req)
	if rerr != nil {
		return cloudFail(out, "repair-token-seats "+a.ref, rerr)
	}

	code := exitOK
	if len(res.Plan.Refused) > 0 {
		code = exitGeneric
	}

	var envelope map[string]any
	if json.Unmarshal(res.Raw, &envelope) == nil && out.emitStructured(envelope) {
		return code
	}

	p := res.Plan
	if p.Applied {
		out.outf("Restored seats for token %s on %s (%s).", p.TokenID, a.ref, res.BarkparkID)
	} else {
		out.outf("Dry run for token %s on %s (%s). Nothing was written; pass --apply to write.", p.TokenID, a.ref, res.BarkparkID)
	}
	if len(p.Predecessors) == 0 {
		out.outf("  revoked predecessors: none found")
	} else {
		out.outf("  revoked predecessors: %s", strings.Join(p.Predecessors, ", "))
	}
	verb := "would restore"
	if p.Applied {
		verb = "restored"
	}
	if len(p.Restore) == 0 {
		out.outf("  %s: none", verb)
	}
	for _, s := range p.Restore {
		out.outf("  %s: %s as %s, held by %s", verb, s.Workspace, s.Role, s.FromToken)
	}
	if len(p.Already) > 0 {
		out.outf("  already seated: %s", strings.Join(p.Already, ", "))
	}
	for _, r := range p.Refused {
		out.outf("  refused: %s (%s)", r.Workspace, r.Reason)
	}
	return code
}
