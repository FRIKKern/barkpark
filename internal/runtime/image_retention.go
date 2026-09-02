package runtime

import (
	"bytes"
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// DefaultRetainImages is how many container GENERATIONS the executor keeps per
// SITE after a proven cutover — the one it just made live plus
// DefaultRetainImages-1 stopped rollback targets. Each retained generation
// pins exactly one loaded Docker image, so this is also the per-site image
// window.
//
// Why a sweep exists at all: executeDeploy `docker load`s a fresh image every
// deploy and RunOnce only ever `docker stop`s the previous container — it has
// never removed one, and a stopped container pins its image against every
// `docker image prune`. So a hosted box accumulates one container AND one
// ~1 GB image per deploy, forever. Measured on the jarl box (91.98.139.58)
// 2026-08-01: 18 images / 20.76 GB on a 38 GB disk, 100% full, which took the
// CMS down (incident jpf-box-prune-op).
//
// Why three and not one: the STOPPED previous container is the instant
// rollback (`docker start`), exactly as cp-deploy.sh keeps its old compose
// slot stopped rather than removed. Three keeps two instant-rollback
// generations (~3 GB per site) while bounding the store. The deeper rollback
// material is the builder's tarball cache — internal/builder/image_retention.go
// keeps DefaultRetainImages=5 tarballs per site, and any of those can be
// `docker load`ed back — so the loaded-image window does not need to be as
// deep as the tarball window.
const DefaultRetainImages = 3

// RetainImagesUnlimited (-1) disables the sweep entirely and restores the
// historical never-delete behaviour. Zero is NOT "unlimited" — zero means
// unset, and unset takes DefaultRetainImages. Same contract as the builder's
// constant of the same name, deliberately.
const RetainImagesUnlimited = -1

// DefaultBuildCacheKeep is the floor the co-located build plane's BuildKit
// cache is swept down to after a proven cutover. Empty (or "off") disables the
// build-cache arm; the image arm is independent of it.
const DefaultBuildCacheKeep = "5GB"

// retainImages resolves the configured retention. Zero (the unset zero value)
// takes the default; a negative value disables the sweep.
func (e *Executor) retainImages() int {
	if e.RetainImages == 0 {
		return DefaultRetainImages
	}
	return e.RetainImages
}

// buildCacheKeep resolves the configured BuildKit cache floor. The zero value
// takes the default; "off" (any case) disables the build-cache arm.
func (e *Executor) buildCacheKeep() string {
	if e.BuildCacheKeep == "" {
		return DefaultBuildCacheKeep
	}
	if strings.EqualFold(e.BuildCacheKeep, "off") {
		return ""
	}
	return e.BuildCacheKeep
}

// containerName is the ONE place the per-deployment container name is formed.
// Every producer (docker run, the three teardown paths) and the retention
// sweep's "never touch the container I just made live" guard read it from
// here, so the name can never drift between the code that creates a container
// and the code that decides whether to delete one.
func containerName(slug, deploymentID string) string {
	return fmt.Sprintf("site-%s-%s", slug, short(deploymentID))
}

// dockerCreatedAtLayout parses the `docker ps --format {{.CreatedAt}}` stamp,
// e.g. "2026-09-01 04:12:33 +0200 CEST". The numeric offset is what fixes the
// instant; the trailing abbreviation is decorative and an unknown one does not
// fail the parse.
const dockerCreatedAtLayout = "2006-01-02 15:04:05 -0700 MST"

// sweepPSFormat is the `docker ps -a --format` template the sweep reads. Tab
// separated because a container name, image ref and state never contain a tab.
const sweepPSFormat = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.CreatedAt}}"

// siteContainer is one row of the `docker ps -a` listing, already filtered to
// containers this executor created for one site.
type siteContainer struct {
	id      string
	name    string
	image   string
	state   string
	created time.Time
	hasTime bool
}

func (c siteContainer) running() bool { return strings.EqualFold(c.state, "running") }

// parsePSRows turns raw `docker ps -a` output into rows, keeping docker's own
// order (newest first). Malformed lines are skipped rather than failing the
// sweep: a listing we cannot fully understand must delete less, never more.
func parsePSRows(out string) []siteContainer {
	var rows []siteContainer
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			continue
		}
		r := siteContainer{
			id:    strings.TrimSpace(f[0]),
			name:  strings.TrimSpace(f[1]),
			image: strings.TrimSpace(f[2]),
			state: strings.TrimSpace(f[3]),
		}
		if r.id == "" || r.name == "" {
			continue
		}
		if len(f) >= 5 {
			if ts, err := time.Parse(dockerCreatedAtLayout, strings.TrimSpace(f[4])); err == nil {
				r.created = ts
				r.hasTime = true
			}
		}
		rows = append(rows, r)
	}
	return rows
}

// ownsContainer reports whether name is a container THIS executor created for
// slug, and not one it created for a different, longer site slug.
//
// The second half is the whole point. `docker ps --filter name=` is a loose
// substring regex and container names are "site-<slug>-<dep8>", so a sweep for
// slug "jarl" sees "site-jarl-website-2f92055a" as one of its own — and would
// delete a DIFFERENT live site's rollback container. The suffix charset cannot
// settle it (a slug may contain '-', and short() can return a dash-bearing
// prefix for a non-UUID id), so the discriminator is data, not a guess: any
// name that is also claimed by a LONGER slug the box is currently serving
// belongs to that slug, never to this one.
func ownsContainer(name, slug string, otherSlugs []string) bool {
	prefix := "site-" + slug + "-"
	if !strings.HasPrefix(name, prefix) || len(name) == len(prefix) {
		return false
	}
	for _, other := range otherSlugs {
		if len(other) <= len(slug) || other == slug {
			continue
		}
		if strings.HasPrefix(name, "site-"+other+"-") {
			return false
		}
	}
	return true
}

// otherSlugs returns every live site slug on the box except self — the input
// ownsContainer needs to refuse a longer slug's containers.
func otherSlugs(sites []caddyfile.Site, self string) []string {
	out := make([]string, 0, len(sites))
	for _, s := range sites {
		if s.Slug != self {
			out = append(out, s.Slug)
		}
	}
	return out
}

// planRetention ranks one site's containers and splits them into the ones to
// keep and the ones to reap. Pure — no docker, no I/O — so the retention rule
// itself is unit-testable without a daemon.
//
// Ranking: the container just made live is always first (it is the live slot
// regardless of what any clock says), then the rest newest-first. Rows are
// ordered by CreatedAt when every row carried a parseable stamp; otherwise
// docker's own newest-first output order is preserved rather than trusting a
// half-parsed sort. Name descending breaks a same-second tie so two deploys
// landing in the same second still produce a deterministic victim list.
//
// keep <= 0 reaps nothing (see RetainImagesUnlimited). A RUNNING container is
// never a victim even if it ranks past the window: something is serving from
// it, and the sweep's job is bounding growth, not stopping traffic.
func planRetention(rows []siteContainer, currentName string, keep int) (kept, doomed []siteContainer) {
	if keep <= 0 || len(rows) == 0 {
		return rows, nil
	}

	ranked := make([]siteContainer, 0, len(rows))
	rest := make([]siteContainer, 0, len(rows))
	for _, r := range rows {
		if r.name == currentName {
			ranked = append(ranked, r)
		} else {
			rest = append(rest, r)
		}
	}

	allTimed := true
	for _, r := range rest {
		if !r.hasTime {
			allTimed = false
			break
		}
	}
	if allTimed {
		sort.SliceStable(rest, func(i, j int) bool {
			if !rest[i].created.Equal(rest[j].created) {
				return rest[i].created.After(rest[j].created)
			}
			return rest[i].name > rest[j].name
		})
	}
	ranked = append(ranked, rest...)

	if len(ranked) <= keep {
		return ranked, nil
	}
	kept = append(kept, ranked[:keep]...)
	for _, r := range ranked[keep:] {
		if r.running() {
			// Never stop traffic to bound a disk.
			kept = append(kept, r)
			continue
		}
		doomed = append(doomed, r)
	}
	return kept, doomed
}

// sweepSiteImages reaps this site's out-of-window containers and the images
// they were pinning, then sweeps the co-located build plane's BuildKit cache
// down to a floor.
//
// CALLED FROM ONE PLACE ONLY — RunOnce, AFTER the `live` transition has been
// accepted by the control plane. That position is the safety property, not a
// detail: every failure path in a deploy (bad image tag, docker load, port
// allocate, site env, docker run, health-check, write caddyfile, caddy reload,
// the transition itself) returns before reaching here, so a deploy that did
// NOT cut over deletes nothing and its predecessor's container+image are still
// there to roll back to.
//
// Best-effort throughout: the deployment is already live and reported live, so
// nothing in the sweep may fail it. Every docker call's failure is logged and
// stepped over.
func (e *Executor) sweepSiteImages(ctx context.Context, slug, currentName string, others []string) {
	keep := e.retainImages()
	if keep <= 0 {
		e.logf("image retention: disabled (retain=%d) — site %s keeps every image forever", keep, slug)
		return
	}

	out, err := e.runOut(ctx, "docker", "ps", "-a", "--no-trunc",
		"--filter", "name=site-"+slug+"-", "--format", sweepPSFormat)
	if err != nil {
		e.logf("image retention: docker ps for site %s failed (nothing reaped): %v", slug, err)
		return
	}

	var mine []siteContainer
	for _, r := range parsePSRows(out) {
		if ownsContainer(r.name, slug, others) {
			mine = append(mine, r)
		}
	}

	kept, doomed := planRetention(mine, currentName, keep)
	if len(doomed) == 0 {
		e.logf("image retention: site %s has %d generation(s), window is %d — nothing to reap",
			slug, len(mine), keep)
		e.sweepBuildCache(ctx)
		return
	}

	// An image is protected if ANY kept container still references it — the
	// live one and every rollback target inside the window. Two generations
	// can share one image ref (a redeploy of the same build), so this is a set
	// lookup, not a comparison against the current image alone.
	protected := map[string]bool{}
	for _, k := range kept {
		protected[k.image] = true
	}

	var (
		reapedContainers []string
		reapedImages     []string
		reclaimed        int64
	)
	for _, victim := range doomed {
		if err := e.runner().Run(ctx, devNull{}, "docker", "rm", "-f", victim.id); err != nil {
			// Leave the image alone too: an un-removed container still pins it,
			// and `docker image rm` would fail anyway.
			e.logf("image retention: docker rm %s (%s) failed, keeping its image: %v",
				victim.name, victim.id, err)
			protected[victim.image] = true
			continue
		}
		reapedContainers = append(reapedContainers, victim.name)
	}

	for _, victim := range doomed {
		ref := victim.image
		if ref == "" || protected[ref] {
			continue
		}
		// Fail closed on a ref that is not a builder-minted tag. `docker ps`
		// reports the image as an ID (sha256:…) once its tag is gone, and a
		// bare ID could name an image some OTHER workload on the box owns.
		// safeImageTag is the same allowlist executeDeploy fails closed on.
		if !safeImageTag.MatchString(ref) {
			e.logf("image retention: refusing to remove image %q for site %s — not a builder-minted tag", ref, slug)
			protected[ref] = true
			continue
		}
		size := e.imageSize(ctx, ref)
		if err := e.runner().Run(ctx, devNull{}, "docker", "image", "rm", ref); err != nil {
			e.logf("image retention: docker image rm %s failed: %v", ref, err)
			continue
		}
		protected[ref] = true // never try the same ref twice
		reapedImages = append(reapedImages, fmt.Sprintf("%s (%s)", ref, humanBytes(size)))
		reclaimed += size
	}

	e.logf("image retention: site %s swept to a %d-generation window (1 live + %d rollback) — "+
		"removed %d container(s) [%s] and %d image(s) [%s], reclaimed %s",
		slug, keep, keep-1,
		len(reapedContainers), strings.Join(reapedContainers, " "),
		len(reapedImages), strings.Join(reapedImages, " "),
		humanBytes(reclaimed))

	e.sweepBuildCache(ctx)
}

// sweepBuildCache trims the box's BuildKit cache to a floor.
//
// Deliberately NOT `-a`. The build plane (barkpark-builder) is co-located on
// this box and its nixpacks builds reuse that cache; `docker builder prune -af`
// — what cp-deploy.sh runs, where the builder IS the deploy — would turn every
// subsequent site build into a cold build. Without -a only dangling/unreachable
// cache records are candidates, and BuildKit holds a lease on anything a
// running build is using, so this cannot race a concurrent build.
func (e *Executor) sweepBuildCache(ctx context.Context) {
	keep := e.buildCacheKeep()
	if keep == "" {
		return
	}
	out, err := e.runOut(ctx, "docker", "builder", "prune", "-f", "--keep-storage", keep)
	if err != nil {
		e.logf("image retention: docker builder prune failed (deploy unaffected): %v", err)
		return
	}
	if line := lastMatchingLine(out, "reclaimed", "Total"); line != "" {
		e.logf("image retention: build cache swept to a %s floor: %s", keep, line)
	}
}

// imageSize reads an image's on-disk size in bytes, or 0 when docker cannot
// answer. A size we cannot read must not stop a removal — it only makes the
// reclaimed figure conservative.
func (e *Executor) imageSize(ctx context.Context, ref string) int64 {
	out, err := e.runOut(ctx, "docker", "image", "inspect", "--format", "{{.Size}}", ref)
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// runOut runs a command and returns its combined output, for the handful of
// docker calls the sweep must READ rather than just fire.
func (e *Executor) runOut(ctx context.Context, name string, args ...string) (string, error) {
	var buf bytes.Buffer
	err := e.runner().Run(ctx, &buf, name, args...)
	return buf.String(), err
}

// lastMatchingLine returns the last line of out containing any of subs.
func lastMatchingLine(out string, subs ...string) string {
	found := ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		for _, s := range subs {
			if line != "" && strings.Contains(line, s) {
				found = line
			}
		}
	}
	return found
}

// humanBytes renders a byte count for the journal. The operator reading this
// after a disk-full incident wants "12.4 GB", not 13314398208.
func humanBytes(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit && exp < 4; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "kMGTP"[exp])
}
