package builder

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// DefaultRetainImages is how many image tarballs the builder keeps per SITE in
// CacheDir when Builder.RetainImages is left zero.
//
// Why a sweep exists at all: build() docker-saves every successful build to
// <CacheDir>/<imageTag>.tar and NOTHING in this repo has ever deleted one. The
// runtime only ever reads them (`docker load -i`), so a co-located build plane
// accumulates one ~500 MB tarball per deploy, forever. Measured on jarl
// (91.98.139.58) 2026-09-01: 24 tarballs, 11,573,633,024 bytes (10.8 GiB), all
// for ONE site, written across four days — 23 of them dead weight.
//
// Why five and not one: the tarball is the ONLY on-box source for a `docker
// load` of an older image, so it is the rollback material. Five keeps a
// short redeploy/rollback window (~2.5 GiB per site) while bounding the store.
const DefaultRetainImages = 5

// RetainImagesUnlimited (-1) disables the sweep entirely and restores the
// historical never-delete behaviour. Zero is NOT "unlimited" — zero means
// unset, and unset takes DefaultRetainImages.
const RetainImagesUnlimited = -1

// retainImages resolves the configured retention. Zero (the unset zero value)
// takes the default; a negative value disables the sweep.
func (b *Builder) retainImages() int {
	if b.RetainImages == 0 {
		return DefaultRetainImages
	}
	return b.RetainImages
}

// sitePrefix returns the "site-<siteid>-" prefix shared by every image tag
// built for one site — build() forms tags as fmt.Sprintf("site-%s-%s",
// short(SiteID), short(ID)), so everything up to and including the LAST '-'
// identifies the site and the remainder identifies the deployment.
//
// It returns "" for any tag that does not carry that shape. A "" prefix must
// never be treated as "matches everything": an unparseable tag makes the sweep
// do nothing rather than widen to every file in the directory.
func sitePrefix(imageTag string) string {
	i := strings.LastIndex(imageTag, "-")
	if i <= 0 || i == len(imageTag)-1 {
		return ""
	}
	if !strings.HasPrefix(imageTag, "site-") {
		return ""
	}
	return imageTag[:i+1]
}

// pruneImageCache deletes the oldest image tarballs for ONE site from dir,
// keeping the newest keep of them. keepTag is the tag just written; it is
// never deleted regardless of how the mtimes sort, and it counts toward keep.
//
// Containment, because this function deletes files on a serving box:
//   - it only ever considers REGULAR files directly in dir (no recursion, no
//     directories, no symlinks — a symlink's Type() is not 0);
//   - a candidate must be exactly <sitePrefix(keepTag)><something>.tar, so
//     another site's tarballs, the uploads/ tree and any non-.tar file in the
//     cache are untouchable;
//   - an unparseable keepTag yields prefix "" and the sweep returns early;
//   - keep <= 0 disables the sweep (see RetainImagesUnlimited).
//
// It returns the names it removed, in deletion order, and never returns an
// error: a cache sweep must not fail a build that has already succeeded.
// Individual os.Remove failures are reported through onErr (may be nil).
func pruneImageCache(dir, keepTag string, keep int, onErr func(name string, err error)) []string {
	if dir == "" || keep <= 0 {
		return nil
	}
	prefix := sitePrefix(keepTag)
	if prefix == "" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	type tarball struct {
		name    string
		modUnix int64
	}
	var found []tarball
	keepName := keepTag + ".tar"
	for _, e := range entries {
		if !e.Type().IsRegular() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, ".tar") {
			continue
		}
		// Reject "site-<siteid>-.tar" — a prefix immediately followed by the
		// suffix names no deployment.
		if len(name) <= len(prefix)+len(".tar") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			// A tarball we cannot stat is a tarball we do not delete.
			continue
		}
		found = append(found, tarball{name: name, modUnix: info.ModTime().UnixNano()})
	}
	if len(found) <= keep {
		return nil
	}

	// Newest first. Name descending breaks an mtime tie so two builds landing
	// in the same nanosecond still produce a deterministic victim list.
	sort.Slice(found, func(i, j int) bool {
		if found[i].modUnix != found[j].modUnix {
			return found[i].modUnix > found[j].modUnix
		}
		return found[i].name > found[j].name
	})

	var removed []string
	for _, t := range found[keep:] {
		if t.name == keepName {
			// The tarball this build just wrote is never a victim, even if the
			// filesystem handed us a stale or zeroed mtime for it.
			continue
		}
		if err := os.Remove(filepath.Join(dir, t.name)); err != nil {
			if onErr != nil {
				onErr(t.name, err)
			}
			continue
		}
		removed = append(removed, t.name)
	}
	return removed
}
