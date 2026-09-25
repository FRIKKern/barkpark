package cli

// cloud_site_prebuilt_appledouble_test.go covers the macOS-metadata ADVISORY on
// `bp cloud site deploy --prebuilt` (charter D121): `._*` entries are counted
// and named once before the mint, the deploy still succeeds, and isIgnored
// keeps its exact-match rule so a real file named `._foo` still ships.

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeMetaFixture(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// TestCloudSitePrebuiltDeploySucceedsWithAppleMetadata: a Finder-touched dist
// deploys to exit 0, the `._*` entries ship (they are not dropped), .DS_Store
// does not (prebuiltTarballIgnores drops it by exact basename), and the advisory
// prints exactly once, in exactly this shape, before the mint.
func TestCloudSitePrebuiltDeploySucceedsWithAppleMetadata(t *testing.T) {
	const buildID = "a11eda11eda11eda"
	dir := writeDistFixture(t, buildID)
	writeMetaFixture(t, filepath.Join(dir, "._."), "appledouble")
	writeMetaFixture(t, filepath.Join(dir, "._index.html"), "appledouble")
	writeMetaFixture(t, filepath.Join(dir, "_astro", "._app.css"), "appledouble")
	writeMetaFixture(t, filepath.Join(dir, ".DS_Store"), "finder")

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"artifact_url":"db://artifact/dep-1","filename":"dep-1.tar.gz"}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/blog/","stages":[{"name":"SWITCH","status":"ok"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code != exitOK {
		t.Fatalf("metadata entries must not fail the deploy: exit=%d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 1 || cp.artifactHits != 1 {
		t.Fatalf("deploy hits=%d artifact hits=%d, want 1 and 1", cp.deployHits, cp.artifactHits)
	}

	names := tarEntryNames(t, bytes.NewReader(cp.artifactBody))
	for _, want := range []string{"._.", "._index.html", "_astro/._app.css", "index.html"} {
		if _, ok := names[want]; !ok {
			t.Fatalf("uploaded archive is missing %s — the advisory must not drop anything", want)
		}
	}
	if _, ok := names[".DS_Store"]; ok {
		t.Fatalf(".DS_Store was uploaded — prebuiltTarballIgnores drops it by exact basename")
	}

	want := "! 3 macOS metadata entries will ship with --prebuilt " + dir + " and be served as-is: ._., ._index.html, _astro/._app.css\n" +
		"  The deploy continues. If these are Finder or tar leftovers, delete them and re-run: find " + dir + " -name '._*' -delete (bp does not drop them itself, because a file named ._foo can be real content)\n"
	all := stdout + stderr
	if n := strings.Count(all, want); n != 1 {
		t.Fatalf("advisory rendered %d times, want exactly 1 of:\n%s\ngot:\n%s", n, want, all)
	}
	if n := strings.Count(all, "macOS metadata"); n != 1 {
		t.Fatalf("advisory header appears %d times, want 1:\n%s", n, all)
	}
	// Pre-mint: the notice lands before the mint's receipt line.
	if strings.Index(all, want) > strings.Index(all, "minted deployment") {
		t.Fatalf("the advisory must print before the mint:\n%s", all)
	}
}

// TestCloudSitePrebuiltCleanDistPrintsNoMetadataAdvisory: no `._*`, no notice.
func TestCloudSitePrebuiltCleanDistPrintsNoMetadataAdvisory(t *testing.T) {
	const buildID = "c1ea0c1ea0c1ea0c"
	dir := writeDistFixture(t, buildID)
	writeMetaFixture(t, filepath.Join(dir, ".DS_Store"), "finder")

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"artifact_url":"db://artifact/dep-1","filename":"dep-1.tar.gz"}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--no-follow")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if all := stdout + stderr; strings.Contains(all, "macOS metadata") {
		t.Fatalf("a dist whose only metadata is the dropped .DS_Store must print no advisory:\n%s", all)
	}
}

// TestPrebuiltMetadataAdvisoryRendering pins the exact text: the count is exact,
// the list stops at prebuiltMetadataNameLimit with an "and N more" tail, one
// entry takes the singular, and nothing renders to nothing.
func TestPrebuiltMetadataAdvisoryRendering(t *testing.T) {
	remedy := "  The deploy continues. If these are Finder or tar leftovers, delete them and re-run: find ./dist -name '._*' -delete (bp does not drop them itself, because a file named ._foo can be real content)"

	got := prebuiltMetadataAdvisory("./dist", []string{"._.", "._a.html", "._b.html", "._c.html", "._d.html", "x/._e.js", "x/._f.js"})
	want := []string{
		"! 7 macOS metadata entries will ship with --prebuilt ./dist and be served as-is: ._., ._a.html, ._b.html, ._c.html, ._d.html, and 2 more",
		remedy,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("over the limit:\ngot  %q\nwant %q", got, want)
	}

	got = prebuiltMetadataAdvisory("./dist", []string{"._index.html"})
	want = []string{
		"! 1 macOS metadata entry will ship with --prebuilt ./dist and be served as-is: ._index.html",
		remedy,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("single entry:\ngot  %q\nwant %q", got, want)
	}

	if got := prebuiltMetadataAdvisory("./dist", nil); got != nil {
		t.Fatalf("no metadata must render nothing, got %q", got)
	}
}

// TestIsAppleMetadataNameMatchesBasenamesOnly: the advisory predicate covers
// `._*` and `.DS_Store` by basename and nothing that merely contains them.
func TestIsAppleMetadataNameMatchesBasenamesOnly(t *testing.T) {
	for name, want := range map[string]bool{
		"._.": true, "._index.html": true, ".DS_Store": true,
		"index.html": false, "a._b": false, "._": true, ".DS_Store.bak": false, "_._x": false,
	} {
		if got := isAppleMetadataName(name); got != want {
			t.Errorf("isAppleMetadataName(%q)=%v want %v", name, got, want)
		}
	}
}

// TestPrebuiltLegitDotUnderscoreFileStillPacks is the D121 guard on isIgnored:
// it stays exact-match, so a real file named `._foo` is packed and shipped. A
// `._` prefix rule in isIgnored would silently delete it from every deploy.
func TestPrebuiltLegitDotUnderscoreFileStillPacks(t *testing.T) {
	dir := t.TempDir()
	writeMetaFixture(t, filepath.Join(dir, "index.html"), "<html></html>")
	writeMetaFixture(t, filepath.Join(dir, "._foo"), "real content")
	writeMetaFixture(t, filepath.Join(dir, "docs", "._foo"), "real content")

	ignores := tarballIgnoreSet(dir, prebuiltTarballIgnores)
	for _, rel := range []string{"._foo", "docs/._foo"} {
		if isIgnored(rel, ignores) {
			t.Fatalf("isIgnored(%q) = true — isIgnored must stay exact-match (charter D121)", rel)
		}
	}

	art, err := packPrebuiltDir(dir)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	defer art.Cleanup()
	f, err := os.Open(art.Path)
	if err != nil {
		t.Fatalf("open artifact: %v", err)
	}
	defer f.Close()
	names := tarEntryNames(t, f)
	for _, want := range []string{"._foo", "docs/._foo"} {
		if _, ok := names[want]; !ok {
			t.Fatalf("%s was not packed — a legitimately-named ._foo must ship", want)
		}
	}
}
