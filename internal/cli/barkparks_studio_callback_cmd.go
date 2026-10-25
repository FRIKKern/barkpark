package cli

// barkparks_studio_callback_cmd.go — `bp barkparks studio-callback`: the
// "Sign in with Barkpark Cloud" allowlist for Studios deployed apart from their
// instance (barkpark-studio on Vercel, say). A Studio's sign-in may only
// return to a callback URL listed here, matched exactly.

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

const studioCallbackUsage = "bp barkparks studio-callback ls|add|rm <instance> [<https://studio/auth/cloud/callback>]"

func runBarkparksStudioCallback(out *writer, args []string) int {
	if len(args) < 2 {
		return useError(out, "usage", "usage: "+studioCallbackUsage, exitUsage)
	}
	verb, ref := args[0], args[1]
	var callbackURL string
	switch verb {
	case "ls", "list":
		if len(args) != 2 {
			return useError(out, "usage", "usage: "+studioCallbackUsage, exitUsage)
		}
	case "add", "rm", "remove":
		if len(args) != 3 || strings.TrimSpace(args[2]) == "" {
			return useError(out, "usage", verb+" needs the Studio callback URL (usage: "+studioCallbackUsage+")", exitUsage)
		}
		callbackURL = strings.TrimSpace(args[2])
	default:
		return useError(out, "usage", "unknown studio-callback verb "+verb+" (usage: "+studioCallbackUsage+")", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	id, err := resolveOpenBarkparkID(cfg, ref)
	if err != nil {
		return cloudFail(out, "resolve "+ref, err)
	}

	client := cfg.CloudClient()
	ctx := context.Background()
	var res cloudclient.StudioCallbacks
	var cerr error
	switch verb {
	case "add":
		res, cerr = client.AddStudioCallback(ctx, id, callbackURL)
	case "rm", "remove":
		res, cerr = client.RemoveStudioCallback(ctx, id, callbackURL)
	default:
		res, cerr = client.ListStudioCallbacks(ctx, id)
	}
	if cerr != nil {
		return cloudFail(out, "studio-callback "+verb+" "+ref, cerr)
	}

	var envelope map[string]any
	if json.Unmarshal(res.Raw, &envelope) == nil && out.emitStructured(envelope) {
		return exitOK
	}
	if len(res.Callbacks) == 0 {
		out.outf("No Studio may sign in with %s through Barkpark Cloud.", ref)
		return exitOK
	}
	out.outf("Studios that may sign in with %s through Barkpark Cloud:", ref)
	for _, u := range res.Callbacks {
		out.outf("  %s", u)
	}
	return exitOK
}
