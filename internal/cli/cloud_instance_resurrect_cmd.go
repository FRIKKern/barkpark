package cli

// cloud_instance_resurrect_cmd.go is the PROVIDER-NEUTRAL resurrect surface
// (charter S14, Decisions 12 + 20-21):
//
//	bp cloud instance resurrect <name|fqdn> --provider hetzner|azure [--bundle <key>] [--fast]
//
// A resurrect rebuilds a whole instance from a PORTABLE archive bundle (manifest +
// pg_dump + media + sealed identity secrets) — the bold cross-provider bet: a box
// archived on Hetzner comes back on Azure and vice-versa. The default path POSTs
// /v1/resurrect to the control plane, which enqueues a resurrect job the worker
// restores in RESTORE MODE (never a warm-assign, D40) and the /new-style step feed
// narrates. `--fast` is a HETZNER-ONLY optimization that boots the newest Hetzner
// snapshot instead — byte-identical to the legacy `bp cloud hetzner instance
// resurrect` (Decision 12 demotes the snapshot to `--fast`).
//
// Azure has no snapshot substrate, so azure resurrect is portable-only; `--fast`
// on azure is a usage error, not a silent lie.

import (
	"encoding/json"
	"fmt"
	"net/http"
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

// runResurrectPortable POSTs /v1/resurrect to the control plane to restore a
// portable bundle onto a fresh box for `kind`, then reports the enqueued job so the
// caller can follow the same live step feed a /new launch renders. With no
// --bundle the control plane resolves the NEWEST bundle for the instance. It needs
// the control plane (a WORKER_TOKEN) — the bundle store + resurrect queue live
// there, never on the box.
func runResurrectPortable(out *writer, g globals, kind string, args []string) int {
	usage := "bp cloud instance resurrect <name|fqdn> --provider " + kind + " [--bundle <key>] [--control-url <u>] [--worker-token <t>]"
	a, err := parseHzArgs(args, []string{"bundle", "control-url", "worker-token"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name|fqdn> (usage: "+usage+")", exitUsage)
	}
	name := strings.TrimSpace(a.pos[0])

	cp := instCP(a)
	if cp == nil {
		return useError(out, "auth",
			"resurrect needs the control plane (the bundle store + resurrect queue) — set WORKER_TOKEN (or --worker-token)",
			exitAuth)
	}

	body := map[string]any{"name": name, "provider": kind}
	if b := strings.TrimSpace(a.val("bundle")); b != "" {
		body["bundle"] = b
	}
	res, rerr := cp.Resurrect(body)
	if rerr != nil {
		return useError(out, "failed", "resurrect "+name+": "+rerr.Error(), exitGeneric)
	}

	report := map[string]any{
		"ok":       true,
		"provider": kind,
		"action":   cloud.VerbResurrect,
		"instance": map[string]any{"name": name},
		"job_id":   res.JobID,
		"status":   res.Status,
	}
	if res.Bundle != "" {
		report["bundle"] = res.Bundle
	}
	if res.FollowURL != "" {
		report["follow_url"] = res.FollowURL
	}
	if out.emitStructured(report) {
		return exitOK
	}
	out.outf("✓ resurrect of %s queued on %s (job %s)", name, kind, res.JobID)
	if res.Bundle != "" {
		out.info("restoring from bundle %s", res.Bundle)
	}
	if res.FollowURL != "" {
		out.info("follow the live step feed: %s", res.FollowURL)
	}
	return exitOK
}

// cpResurrectResult is the control plane's response to POST /v1/resurrect (charter
// S14): the enqueued resurrect job the worker restores + the /new-style feed
// narrates. Fields are additive/omitempty so an older control plane that returns
// only {job_id,status} still decodes.
type cpResurrectResult struct {
	JobID     string `json:"job_id"`
	Status    string `json:"status"`
	Bundle    string `json:"bundle"`
	FollowURL string `json:"follow_url"`
	Error     string `json:"error"`
}

// Resurrect enqueues a portable-bundle resurrect on the control plane. The body
// carries {name, provider, bundle?}; the control plane resolves the newest bundle
// when none is named, seals the carried KEK into the claim, and queues a
// kind=resurrect job the worker restores.
func (cp *cpFleet) Resurrect(body map[string]any) (*cpResurrectResult, error) {
	resp, err := cp.do(http.MethodPost, "/v1/resurrect", body)
	if err != nil {
		return nil, fmt.Errorf("control plane resurrect: %w", err)
	}
	defer resp.Body.Close()
	var res cpResurrectResult
	_ = json.NewDecoder(resp.Body).Decode(&res)
	switch resp.StatusCode {
	case http.StatusOK, http.StatusAccepted, http.StatusCreated:
		if res.JobID == "" {
			return nil, fmt.Errorf("control plane resurrect: accepted but returned no job id")
		}
		return &res, nil
	default:
		what := res.Error
		if what == "" {
			what = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		return nil, fmt.Errorf("control plane resurrect: %s", what)
	}
}
