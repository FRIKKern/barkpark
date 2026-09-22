package cli

import (
	"strings"
	"testing"
)

// ssw9-cli-prebuilt-followups — the two halves this file proves.
//
// (1) STATIC-ONLY. `--prebuilt` stages a built tree and flips a symlink. That is
// the whole mechanism, and it is the only one the lane has (charter D96 files
// node/SSR later). The MERGED control plane draws no such line: its deploy route
// sends `site.kind in ["static", "node"]` down the same arm, and `prebuilt_enabled`
// is per-site with no kind scoping — so before this guard a node site that had
// opted in minted a nonced row, packed its dist/, and uploaded bytes nothing on
// the box would ever start a server for.
//
// (2) THE UPLOAD RECEIPT reads the control plane's OWN answer. The merged route
// returns `artifact_sha256` on every success and `status:"already_uploaded"` on
// the 200 retry arm — where it deliberately does NOT re-start the driver. The Go
// struct declared neither, so json.Unmarshal dropped both in silence.

// TestPrebuiltNodeSiteIsNoLongerRefusedHere is the RETIREMENT of (1) above, kept
// in this file so the reversal is read beside the rule it reverses.
//
// (1) stood for one reason and one only: `--prebuilt` had no node mechanism to
// hand bytes to. deploy/site-deploy-node.sh now carries PLAN_MODE=prebuilt — it
// stages the uploaded standalone tree, records .bp-prebuilt-sha256, runs no npm,
// and refuses a declared-ABI mismatch BEFORE STAGE with exit 17. The premise
// expired, so the refusal did.
//
// The deep end-to-end arms for the node lane (mint+upload counters, the packed
// .bp-node-abi, the engine's own reader over it) live in
// cloud_site_prebuilt_node_abi_test.go. This one asserts only what this file is
// about: the SENTENCE is gone for node.
func TestPrebuiltNodeSiteIsNoLongerRefusedHere(t *testing.T) {
	if clause := prebuiltUnservableClause("node", "node-slot"); clause != "" {
		t.Fatalf("node now has an engine arm; --prebuilt must not refuse it, got %q", clause)
	}
	// And the guard has NOT been gutted: the axis it was built for still bites.
	if prebuiltUnservableClause("static", "wasm-edge") == "" {
		t.Fatalf("a runtime with no engine arm must still be refused")
	}
}

// TestPrebuiltRefusesANodeSiteOnKindAloneBeforeItsFirstDeploy is the second
// specimen: a node site that has never deployed carries NO runtime_target (the
// box stamps that), so a guard reading only runtime_target would wave it through
// on exactly the run where nothing has been built yet.
func TestPrebuiltRefusesANodeSiteOnKindAloneBeforeItsFirstDeploy(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"node","framework":"nextjs","prebuilt_enabled":true}}`}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"` + buildID + `","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"bytes":10}`}
	cp.serve()

	_, _, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code == exitOK {
		t.Fatalf("a node site with no runtime_target yet must still be refused")
	}
	if cp.deployHits != 0 || cp.artifactHits != 0 {
		t.Fatalf("nothing may be minted or packed (deploy=%d artifact=%d)", cp.deployHits, cp.artifactHits)
	}
}

// TestPrebuiltStaticSiteIsUntouchedByTheNodeGuard is the QUIET ARM. The guard
// must fire on a DEFINITE node and on nothing else: a static site still mints,
// packs, uploads and streams exactly as before. Without this, a guard that
// refused every site would pass the two tests above.
func TestPrebuiltStaticSiteIsUntouchedByTheNodeGuard(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","runtime_target":"static-symlink-swap","prebuilt_enabled":true}}`}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactRespFn = func(sha string, n int) fakeResp {
		return fakeResp{201, `{"artifact_sha256":"` + sha + `","bytes":` + itoa(n) + `}`}
	}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/blog/"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code != exitOK {
		t.Fatalf("a static site must still deploy --prebuilt: exit=%d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 1 || cp.artifactHits != 1 {
		t.Fatalf("the static lane must mint once and upload once (deploy=%d artifact=%d)", cp.deployHits, cp.artifactHits)
	}
	all := stdout + stderr
	if strings.Contains(all, "static-only") {
		t.Fatalf("the node refusal must not be printed for a static site:\n%s", all)
	}
	// A digest the control plane AGREES with must produce no warning at all.
	if strings.Contains(all, "the control plane stored sha256") {
		t.Fatalf("a matching digest must be silent:\n%s", all)
	}
	if !strings.Contains(all, "stages these bytes") {
		t.Fatalf("a fresh 201 must say the bytes are about to be staged:\n%s", all)
	}
}

// TestPrebuiltUploadNamesTheAlreadyUploadedRetryArm: the merged control plane
// answers a same-digest re-POST `200 {"status":"already_uploaded"}` and
// explicitly does NOT restart the driver. Before this the CLI decoded only
// `bytes`, so it printed "the box verifies the digest, then stages these bytes"
// — a sentence about a deploy that this request did not cause.
func TestPrebuiltUploadNamesTheAlreadyUploadedRetryArm(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"` + buildID + `","source":"prebuilt"}}`}
	cp.artifactRespFn = func(sha string, n int) fakeResp {
		return fakeResp{200, `{"artifact_sha256":"` + sha + `","bytes":` + itoa(n) + `,"status":"already_uploaded"}`}
	}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/blog/"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code != exitOK {
		t.Fatalf("an already_uploaded retry is a success: exit=%d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	all := stdout + stderr
	if !strings.Contains(all, "already uploaded") {
		t.Fatalf("the retry arm must be NAMED, not rendered as a fresh upload:\n%s", all)
	}
	if strings.Contains(all, "stages these bytes") {
		t.Fatalf("this request started no deploy — it must not claim these bytes are about to be staged:\n%s", all)
	}
}

// TestPrebuiltUploadReportsADigestTheControlPlaneDisagreesWith: the box verifies
// against the CONTROL PLANE's hash, never the client's. If the two ever diverge,
// every downstream check agrees on the wrong bytes — so the divergence is said
// out loud rather than dropped by a struct that never declared the field.
func TestPrebuiltUploadReportsADigestTheControlPlaneDisagreesWith(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"` + buildID + `","source":"prebuilt"}}`}
	cp.artifactRespFn = func(sha string, n int) fakeResp {
		return fakeResp{201, `{"artifact_sha256":"` + strings.Repeat("a", 64) + `","bytes":` + itoa(n) + `}`}
	}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/blog/"}}`}
	cp.serve()

	stdout, stderr, _ := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	all := stdout + stderr
	if !strings.Contains(all, "the control plane stored sha256") {
		t.Fatalf("a digest the control plane does not share must be reported:\n%s", all)
	}
	if !strings.Contains(all, strings.Repeat("a", 64)) {
		t.Fatalf("the refusal must quote the digest the control plane actually stored:\n%s", all)
	}
}
