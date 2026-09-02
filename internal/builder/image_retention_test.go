package builder

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"
)

// writeTar drops a named file in dir with a controlled mtime, so a test can
// order candidates without sleeping.
func writeTar(t *testing.T, dir, name string, age time.Duration) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(name), 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	mt := time.Now().Add(-age)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatalf("chtimes %s: %v", name, err)
	}
	return p
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return out
}

// TestPruneImageCacheKeepsNewest is the whole point: the sweep leaves exactly
// `keep` tarballs and they are the NEWEST ones — the rollback window — not an
// arbitrary `keep` picked off a directory listing.
func TestPruneImageCacheKeepsNewest(t *testing.T) {
	dir := t.TempDir()
	// Deliberately named so alphabetical order DISAGREES with mtime order: if
	// the sweep sorted by name it would keep aaa/bbb and delete the newest.
	writeTar(t, dir, "site-b376168d-zzzznew.tar", 1*time.Minute)
	writeTar(t, dir, "site-b376168d-yyyymid.tar", 2*time.Hour)
	writeTar(t, dir, "site-b376168d-aaaaold.tar", 24*time.Hour)
	writeTar(t, dir, "site-b376168d-bbbbold.tar", 48*time.Hour)

	removed := pruneImageCache(dir, "site-b376168d-zzzznew", 2, nil)

	if len(removed) != 2 {
		t.Fatalf("removed %v, want 2 tarballs", removed)
	}
	got := names(t, dir)
	want := []string{"site-b376168d-yyyymid.tar", "site-b376168d-zzzznew.tar"}
	if len(got) != len(want) {
		t.Fatalf("survivors = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("survivors = %v, want %v", got, want)
		}
	}
}

// TestPruneImageCacheNeverDeletesTheFreshBuild pins the safety rule that
// matters most: the tarball this build just wrote survives even when its mtime
// makes it look like the oldest candidate in the directory (a clock skew, a
// restored file, a filesystem with coarse timestamps). Deleting it would strand
// the deployment the runtime is about to `docker load`.
func TestPruneImageCacheNeverDeletesTheFreshBuild(t *testing.T) {
	dir := t.TempDir()
	writeTar(t, dir, "site-b376168d-fresh001.tar", 99*time.Hour) // oldest by mtime
	writeTar(t, dir, "site-b376168d-newer001.tar", 1*time.Hour)
	writeTar(t, dir, "site-b376168d-newer002.tar", 2*time.Hour)

	removed := pruneImageCache(dir, "site-b376168d-fresh001", 1, nil)

	for _, r := range removed {
		if r == "site-b376168d-fresh001.tar" {
			t.Fatalf("sweep deleted the tarball the build just wrote: removed=%v", removed)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "site-b376168d-fresh001.tar")); err != nil {
		t.Fatalf("fresh tarball gone: %v", err)
	}
}

// TestPruneImageCacheIsSiteScoped: a build plane hosts many sites. Sweeping
// site A must never touch site B, whose newest image may be the one serving.
func TestPruneImageCacheIsSiteScoped(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"site-aaaaaaaa-d1.tar", "site-aaaaaaaa-d2.tar", "site-aaaaaaaa-d3.tar"} {
		writeTar(t, dir, n, time.Hour)
	}
	for _, n := range []string{"site-bbbbbbbb-d1.tar", "site-bbbbbbbb-d2.tar", "site-bbbbbbbb-d3.tar"} {
		writeTar(t, dir, n, time.Hour)
	}

	pruneImageCache(dir, "site-aaaaaaaa-d3", 1, nil)

	for _, n := range []string{"site-bbbbbbbb-d1.tar", "site-bbbbbbbb-d2.tar", "site-bbbbbbbb-d3.tar"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Fatalf("sweeping site aaaaaaaa removed another site's %s: %v", n, err)
		}
	}
}

// TestPruneImageCaseLeavesNonTarballsAlone: the cache directory's neighbours —
// a partial download, a README, the uploads/ subtree, a non-site tarball — are
// not this sweep's business. It deletes only <sitePrefix>*.tar regular files.
func TestPruneImageCacheLeavesNonTarballsAlone(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "site-b376168d-adir.tar"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeTar(t, dir, "site-b376168d-old001.tar", 48*time.Hour)
	writeTar(t, dir, "site-b376168d-old002.tar", 47*time.Hour)
	writeTar(t, dir, "site-b376168d-new001.tar", 1*time.Hour)
	writeTar(t, dir, "site-b376168d-old001.tar.partial", 48*time.Hour)
	writeTar(t, dir, "README", 48*time.Hour)
	writeTar(t, dir, "unrelated.tar", 48*time.Hour)

	pruneImageCache(dir, "site-b376168d-new001", 1, nil)

	for _, n := range []string{"site-b376168d-adir.tar", "site-b376168d-old001.tar.partial", "README", "unrelated.tar"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Fatalf("sweep removed %s, which it must never consider: %v", n, err)
		}
	}
	// Non-vacuity: it DID do its job on the real candidates.
	if _, err := os.Stat(filepath.Join(dir, "site-b376168d-old001.tar")); !os.IsNotExist(err) {
		t.Fatalf("sweep kept an old tarball it should have removed (err=%v)", err)
	}
}

// TestPruneImageCacheDisabled: keep <= 0 must delete NOTHING. This is the
// escape hatch (RetainImagesUnlimited) and the pre-existing behaviour.
func TestPruneImageCacheDisabled(t *testing.T) {
	for _, keep := range []int{0, -1, RetainImagesUnlimited} {
		dir := t.TempDir()
		for _, n := range []string{"site-b376168d-d1.tar", "site-b376168d-d2.tar", "site-b376168d-d3.tar"} {
			writeTar(t, dir, n, time.Hour)
		}
		if removed := pruneImageCache(dir, "site-b376168d-d3", keep, nil); removed != nil {
			t.Fatalf("keep=%d removed %v, want nothing", keep, removed)
		}
		if got := names(t, dir); len(got) != 3 {
			t.Fatalf("keep=%d left %v, want all three", keep, got)
		}
	}
}

// TestPruneImageCacheUnparseableTagSweepsNothing: an image tag that is not
// "site-<x>-<y>" yields an EMPTY prefix, and an empty prefix must not be read
// as "matches every file in the directory". The failure this pins is a sweep
// that deletes the whole cache because one tag was malformed.
func TestPruneImageCacheUnparseableTagSweepsNothing(t *testing.T) {
	for _, tag := range []string{"", "-", "nodashes", "site-", "-leading", "trailing-", "other-a-b"} {
		dir := t.TempDir()
		for _, n := range []string{"site-b376168d-d1.tar", "site-b376168d-d2.tar", "site-b376168d-d3.tar"} {
			writeTar(t, dir, n, time.Hour)
		}
		if removed := pruneImageCache(dir, tag, 1, nil); removed != nil {
			t.Fatalf("tag %q removed %v, want nothing", tag, removed)
		}
		if got := names(t, dir); len(got) != 3 {
			t.Fatalf("tag %q left %v, want all three", tag, got)
		}
	}
}

// TestSitePrefix covers the parse directly, including the "other-a-b" case:
// a tag that HAS two dashes but is not one of ours.
func TestSitePrefix(t *testing.T) {
	cases := map[string]string{
		"site-b376168d-4b8b886b": "site-b376168d-",
		"site-a-b":               "site-a-",
		"site-b376168d-":         "",
		"site-":                  "",
		"other-a-b":              "",
		"nodashes":               "",
		"":                       "",
		"-":                      "",
	}
	for in, want := range cases {
		if got := sitePrefix(in); got != want {
			t.Errorf("sitePrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestRetainImagesDefault: zero is UNSET, not "unlimited". A Builder that
// never sets the field must still sweep — otherwise the fix ships dormant on
// every box that predates a CLI flag.
func TestRetainImagesDefault(t *testing.T) {
	if got := (&Builder{}).retainImages(); got != DefaultRetainImages {
		t.Fatalf("unset RetainImages = %d, want DefaultRetainImages (%d)", got, DefaultRetainImages)
	}
	if got := (&Builder{RetainImages: RetainImagesUnlimited}).retainImages(); got > 0 {
		t.Fatalf("RetainImagesUnlimited resolved to %d, want a sweep-disabling value", got)
	}
	if got := (&Builder{RetainImages: 3}).retainImages(); got != 3 {
		t.Fatalf("RetainImages=3 resolved to %d", got)
	}
}

// TestPruneImageCacheReportsRemoveFailures: an undeletable tarball is reported
// through onErr and skipped, and the sweep carries on to the next victim
// rather than aborting the whole pass on the first error.
func TestPruneImageCacheReportsRemoveFailures(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: a 0500 directory does not block unlink")
	}
	dir := t.TempDir()
	sub := filepath.Join(dir, "locked")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeTar(t, sub, "site-b376168d-old001.tar", 48*time.Hour)
	writeTar(t, sub, "site-b376168d-new001.tar", 1*time.Hour)
	if err := os.Chmod(sub, 0o500); err != nil { // readable, not writable: unlink fails
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(sub, 0o700) })

	var gotName string
	var gotErr error
	removed := pruneImageCache(sub, "site-b376168d-new001", 1, func(n string, err error) {
		gotName, gotErr = n, err
	})

	if len(removed) != 0 {
		t.Fatalf("removed %v, want nothing (the unlink must have failed)", removed)
	}
	if gotName != "site-b376168d-old001.tar" || gotErr == nil {
		t.Fatalf("onErr got (%q, %v), want the old tarball and a non-nil error", gotName, gotErr)
	}
}
