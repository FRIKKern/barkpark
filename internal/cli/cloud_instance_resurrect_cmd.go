package cli

// cloud_instance_resurrect_cmd.go is the PROVIDER-NEUTRAL resurrect surface
// (charter S14, Decisions 12 + 20-21):
//
//	bp cloud instance resurrect <name|fqdn> --provider hetzner|azure [--bundle <prefix>] [--fast]
//
// A resurrect rebuilds a whole instance from a PORTABLE archive bundle (manifest +
// pg_dump + media + sealed identity secrets) — the bold cross-provider bet: a box
// archived on Hetzner comes back on Azure and vice-versa. The default path POSTs
// /v1/resurrect to the control plane AS THE LOGGED-IN USER (the route is
// require_user + team-admin + entitlement-gated, exactly like `bp launch` —
// resurrecting stands up a billed box), which enqueues a resurrect job the worker
// restores in RESTORE MODE (never a warm-assign, D40) and the /new-style step feed
// narrates. `--fast` is a HETZNER-ONLY optimization that boots the newest Hetzner
// snapshot instead — byte-identical to the legacy `bp cloud hetzner instance
// resurrect` (Decision 12 demotes the snapshot to `--fast`).
//
// Azure has no snapshot substrate, so azure resurrect is portable-only; `--fast`
// on azure is a usage error, not a silent lie.
//
// The control plane requires an explicit bundle_ref (it holds no store reader on
// the write path yet), so with no --bundle the CLI resolves the NEWEST bundle for
// the instance from the bundle store itself — the same store env the archive verb
// writes through.

import (
	"context"
	"path"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// runHetznerResurrect is the hetzner column's resurrect dispatch. `--fast` selects
// the legacy snapshot restore (runInstanceResurrect, byte-identical); the default
// is the portable bundle path.
func runHetznerResurrect(out *writer, g globals, args []string) int {
	fast, rest := splitFastFlag(args)
	if fast {
		return runInstanceResurrect(out, g, rest)
	}
	return runResurrectPortable(out, g, cloud.ProviderHetzner, rest)
}

// runAzureInstanceResurrect is the azure column's resurrect dispatch. Azure has no
// snapshot substrate, so the ONLY path is portable; `--fast` is rejected with a
// reason rather than silently ignored.
func runAzureInstanceResurrect(out *writer, g globals, args []string) int {
	fast, rest := splitFastFlag(args)
	if fast {
		return useError(out, "usage",
			"azure has no --fast resurrect — Azure has no snapshot substrate; resurrect restores a portable bundle onto a fresh box",
			exitUsage)
	}
	return runResurrectPortable(out, g, cloud.ProviderAzure, rest)
}

// splitFastFlag pulls the boolean --fast out of a lifecycle tail and returns the
// REMAINING args verbatim, so the legacy free function (which does not declare
// --fast) receives an untouched tail and stays byte-identical.
func splitFastFlag(args []string) (fast bool, rest []string) {
	rest = make([]string, 0, len(args))
	for _, a := range args {
		if a == "--fast" {
			fast = true
			continue
		}
		rest = append(rest, a)
	}
	return fast, rest
}

// runResurrectPortable POSTs /v1/resurrect to the control plane (user Bearer, the
// `bp launch` plane) to restore a portable bundle onto a fresh box for `kind`,
// then reports the enqueued job — `bp barkparks` and the console /new feed track
// the live restore steps. With no --bundle the CLI resolves the NEWEST bundle for
// the instance from the bundle store (the same env the archive verb writes
// through); a named --bundle prefix is threaded verbatim as bundle_ref.
func runResurrectPortable(out *writer, _ globals, kind string, args []string) int {
	usage := "bp cloud instance resurrect <name|fqdn> --provider " + kind + " [--bundle <key-prefix>] [--zone <z>]"
	a, err := parseHzArgs(args, []string{"bundle", "zone", "team"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name|fqdn> (usage: "+usage+")", exitUsage)
	}
	name := strings.TrimSpace(a.pos[0])

	cfg, okc := requireCloud(out)
	if !okc {
		return exitAuth
	}

	bundleRef := strings.TrimSpace(a.val("bundle"))
	if bundleRef == "" {
		// Newest-default: the control plane requires an explicit bundle_ref, so
		// resolve the newest complete bundle for this instance from the store.
		zone := a.val("zone")
		if zone == "" {
			zone = instDefaultZone
		}
		fqdn := name
		if !strings.Contains(fqdn, ".") {
			fqdn = fqdn + "." + zone
		}
		store, sok := bundleStoreProvider(out)
		if !sok {
			return exitAuth
		}
		prefix, found, nerr := newestBundlePrefixFor(cloudInstanceCtx(), store, fqdn)
		if nerr != nil {
			return useError(out, "failed", "resurrect "+name+": find newest bundle: "+nerr.Error(), exitGeneric)
		}
		if !found {
			return useError(out, "failed",
				"no portable archive found for "+fqdn+" — create one with `bp cloud instance archive "+fqdn+"`, or name one with --bundle (see `bp cloud instance archives`)",
				exitNotFound)
		}
		bundleRef = prefix
	}

	res, rerr := cfg.CloudClient().Resurrect(cloudCtx(), kind, name, bundleRef)
	if rerr != nil {
		if code, msg, is402 := noSubscriptionError(rerr); is402 {
			return useError(out, "failed", msg, code)
		}
		return cloudFail(out, "resurrect", rerr)
	}

	report := map[string]any{
		"ok":         true,
		"provider":   kind,
		"action":     cloud.VerbResurrect,
		"instance":   map[string]any{"id": res.ID, "name": name},
		"job_id":     res.JobID,
		"bundle_ref": bundleRef,
	}
	if out.emitStructured(report) {
		return exitOK
	}
	out.outf("✓ resurrect of %s queued on %s (job %s)", name, kind, res.JobID)
	out.info("restoring from bundle %s", bundleRef)
	out.info("track it with `bp barkparks` or the console's /new step feed")
	return exitOK
}

// newestBundlePrefixFor scans the store's archives/ tree for the newest COMPLETE
// bundle whose manifest names fqdn, across every team prefix (a deprovisioned
// box's registry row is gone, so the team segment can't be re-derived — the
// manifest is the source of truth). Returns ("", false, nil) when the instance
// has no bundle yet.
func newestBundlePrefixFor(ctx context.Context, store cloud.BundleStore, fqdn string) (string, bool, error) {
	keys, err := store.List(ctx, "archives/")
	if err != nil {
		return "", false, err
	}
	best := ""
	var bestMan cloud.BundleManifest
	for _, key := range keys {
		if path.Base(key) != "manifest.json" {
			continue
		}
		prefix := strings.TrimSuffix(key, "manifest.json")
		man, merr := cloud.ReadManifest(ctx, store, prefix)
		if merr != nil || man.FQDN != fqdn {
			continue // torn/foreign bundles are skipped, not fatal
		}
		if best == "" || man.CreatedAt.After(bestMan.CreatedAt) ||
			(man.CreatedAt.Equal(bestMan.CreatedAt) && prefix > best) {
			best, bestMan = prefix, man
		}
	}
	return best, best != "", nil
}
