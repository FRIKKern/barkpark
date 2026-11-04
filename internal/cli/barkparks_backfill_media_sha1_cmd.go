package cli

// barkparks_backfill_media_sha1_cmd.go — `bp barkparks backfill-media-sha1
// <instance>`: hash the media files on one box that were born before
// media_files.sha1 (POST /v1/operator/barkparks/:id/media-sha1-backfill,
// operator only). Cloud calls the box with the admin token it holds. It is the
// shell-free form of
// `bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'`.
//
// A dry run unless --apply. An apply asks for one page at a time and follows
// the box's cursor until it is empty, so no single request outlives Cloud's
// call timeout. Files the box could not read stay without a SHA-1 and are
// listed with the reason; the command then exits 1.

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

const backfillMediaSha1Usage = "bp barkparks backfill-media-sha1 <instance> [--apply] [--page-size <n>]"

// backfillMediaSha1MaxPages bounds the loop, in case a box keeps answering a
// cursor. 1,000 pages of the box's default 200 files is 200,000 files.
const backfillMediaSha1MaxPages = 1000

type backfillMediaSha1Args struct {
	ref      string
	apply    bool
	pageSize int
}

func parseBackfillMediaSha1Args(args []string) (backfillMediaSha1Args, error) {
	var a backfillMediaSha1Args
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := splitTokenFlag(args[i])
		if name == "" {
			if a.ref != "" {
				return a, fmt.Errorf("unexpected argument %q (usage: %s)", args[i], backfillMediaSha1Usage)
			}
			a.ref = strings.TrimSpace(args[i])
			continue
		}
		switch name {
		case "apply":
			if hasInline && inline != "true" {
				return a, fmt.Errorf("--apply takes no value (usage: %s)", backfillMediaSha1Usage)
			}
			a.apply = true
		case "page-size":
			value := inline
			if !hasInline {
				if i+1 >= len(args) {
					return a, fmt.Errorf("--page-size needs a value (usage: %s)", backfillMediaSha1Usage)
				}
				i++
				value = args[i]
			}
			n, err := strconv.Atoi(strings.TrimSpace(value))
			if err != nil || n < 1 || n > 500 {
				return a, fmt.Errorf("--page-size must be 1 to 500 (usage: %s)", backfillMediaSha1Usage)
			}
			a.pageSize = n
		default:
			return a, fmt.Errorf("unknown flag --%s (usage: %s)", name, backfillMediaSha1Usage)
		}
	}
	if a.ref == "" {
		return a, fmt.Errorf("usage: %s", backfillMediaSha1Usage)
	}
	return a, nil
}

func runBarkparksBackfillMediaSha1(out *writer, args []string) int {
	a, perr := parseBackfillMediaSha1Args(args)
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
	client := cfg.CloudClient()
	ctx := context.Background()

	if !a.apply {
		res, rerr := client.BackfillMediaSha1(ctx, id, cloudclient.MediaSha1BackfillRequest{})
		if rerr != nil {
			return cloudFail(out, "backfill-media-sha1 "+a.ref, rerr)
		}
		p := res.Backfill
		if out.emitStructured(map[string]any{
			"ok": true, "barkpark_id": res.BarkparkID, "applied": false,
			"unhashed": p.Unhashed, "datasets": p.Datasets,
		}) {
			return exitOK
		}
		out.outf("Dry run on %s (%s). Nothing was written; pass --apply to hash.", a.ref, res.BarkparkID)
		out.outf("  media files with no SHA-1: %d", p.Unhashed)
		for _, d := range p.Datasets {
			out.outf("  %s/%s: %d", workspaceOrNone(d.Workspace), d.Dataset, d.Unhashed)
		}
		return exitOK
	}

	var (
		hashed   int
		failed   []cloudclient.MediaSha1BackfillFailure
		unhashed int
		after    string
		pages    int
		barkID   string
	)
	for {
		if pages >= backfillMediaSha1MaxPages {
			out.errf("backfill-media-sha1: stopped after %d pages; run it again to continue", pages)
			break
		}
		res, rerr := client.BackfillMediaSha1(ctx, id, cloudclient.MediaSha1BackfillRequest{Apply: true, After: after, Limit: a.pageSize})
		if rerr != nil {
			if pages > 0 {
				out.errf("backfill-media-sha1: page %d failed after %d file(s) hashed", pages+1, hashed)
			}
			return cloudFail(out, "backfill-media-sha1 "+a.ref, rerr)
		}
		pages++
		barkID = res.BarkparkID
		p := res.Backfill
		hashed += p.Hashed
		failed = append(failed, p.Failed...)
		unhashed = p.Unhashed
		out.errf("  page %d: %d hashed, %d failed, %d left without a SHA-1", pages, p.Hashed, len(p.Failed), p.Unhashed)
		if p.NextAfter == "" || p.NextAfter == after {
			break
		}
		after = p.NextAfter
	}

	code := exitOK
	if len(failed) > 0 {
		code = exitGeneric
	}
	if failed == nil {
		failed = []cloudclient.MediaSha1BackfillFailure{}
	}
	if out.emitStructured(map[string]any{
		"ok": true, "barkpark_id": barkID, "applied": true, "pages": pages,
		"hashed": hashed, "failed": failed, "unhashed": unhashed,
	}) {
		return code
	}
	out.outf("Hashed %d media file(s) on %s (%s) in %d page(s).", hashed, a.ref, barkID, pages)
	out.outf("  could not hash: %d", len(failed))
	for _, f := range failed {
		out.outf("  %s %s/%s: %s", f.ID, workspaceOrNone(f.Workspace), f.Dataset, f.Reason)
	}
	out.outf("  media files still with no SHA-1: %d", unhashed)
	return code
}

func workspaceOrNone(s string) string {
	if s == "" {
		return "(no workspace)"
	}
	return s
}
