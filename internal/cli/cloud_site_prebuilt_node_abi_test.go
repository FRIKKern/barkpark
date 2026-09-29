package cli

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// THE NODE PREBUILT LANE — the CLI half of the wire contract whose box half is
// deploy/site-deploy-node.sh's PLAN_MODE=prebuilt arm.
//
// Every test here is anchored to something the ENGINE does, not to something
// this package asserts about itself. The engine's own reader is executed over
// the packer's output (TestPackedNodeArtifactIsReadableByTheEnginesOwnReader),
// and the refusals mirrored here are the ones the engine raises at PLAN — exit
// 11 for a tree with no top-level server.js, exit 17 for a missing or unusable
// .bp-node-abi.

const nodeTestSiteRow = `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"node","framework":"nextjs","runtime_target":"node-slot","prebuilt_enabled":true}}`

// writeStandaloneFixture is a node release root in the shape the engine demands:
// server.js at the top, with .next/static and public/ ALREADY folded in (there
// is no $SITE_SRC on the box to take them from). No index.html — a standalone
// tree has none, which is exactly why the static lane's root guard and its
// build-id marker read cannot be applied to it.
func writeStandaloneFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write := func(rel, body string) {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}
	write("server.js", "require('./.next/standalone-marker')\n")
	write(".next/static/chunks/main.js", "console.log(1)\n")
	write("node_modules/.package-lock.json", "{}\n")
	write("public/favicon.ico", "ico")
	return dir
}

// artifactEntries decodes a packed artifact into name -> body. The archive is
// DECODED rather than trusted: "it packed something" must never pass for "it
// packed the declaration".
func artifactEntries(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open artifact: %v", err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	defer gz.Close()
	out := map[string]string{}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar: %v", err)
		}
		body, rerr := io.ReadAll(tr)
		if rerr != nil {
			t.Fatalf("read %s: %v", hdr.Name, rerr)
		}
		out[hdr.Name] = string(body)
	}
	return out
}

// TestNodePrebuiltDeployMintsAndUploads is the RED-WHEN-REVERTED arm of the
// retirement (criterion 0). Both write routes answer SUCCESS, so the two
// counters are the whole assertion: with prebuiltUnservableClause's node arm
// restored this test sees 0 and 0 and fails.
func TestNodePrebuiltDeployMintsAndUploads(t *testing.T) {
	const buildID = "c1c1c1c1c1c1c1c1"
	dir := writeStandaloneFixture(t)

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, nodeTestSiteRow}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-node-1","status":"queued","build_id":"` + buildID + `","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"bytes":10}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--no-follow")
	all := stdout + stderr
	if code != exitOK {
		t.Fatalf("a node site with an engine arm must accept --prebuilt (exit %d)\n%s", code, all)
	}
	if cp.deployHits != 1 {
		t.Fatalf("deploy hits=%d want 1 — the node lane must MINT", cp.deployHits)
	}
	if cp.artifactHits != 1 {
		t.Fatalf("artifact hits=%d want 1 — the node lane must UPLOAD", cp.artifactHits)
	}
	// The retired sentences must be gone, not merely unreached: a refusal that
	// still prints while the deploy proceeds is a different bug with the same
	// green counters.
	for _, gone := range []string{"static-only", "node/SSR"} {
		if strings.Contains(all, gone) {
			t.Fatalf("the retired refusal still speaks (%q):\n%s", gone, all)
		}
	}
	if !strings.Contains(all, nodeABIMarkName) {
		t.Fatalf("the node lane must say it packed %s:\n%s", nodeABIMarkName, all)
	}
}

// TestPackedNodeArtifactCarriesTheDeclarationAtTheArchiveRoot is criterion 1: the
// entry is at the ROOT of the archive (no directory prefix — the box reads
// $PREBUILT_DIR/.bp-node-abi, and a nested copy is a file nothing reads), and it
// holds BOTH required keys in the shapes the engine accepts.
func TestPackedNodeArtifactCarriesTheDeclarationAtTheArchiveRoot(t *testing.T) {
	dir := writeStandaloneFixture(t)
	art, err := packPrebuiltDirFor(dir, prebuiltRuntimeNode)
	if err != nil {
		t.Fatalf("packPrebuiltDirFor(node): %v", err)
	}
	defer art.Cleanup()

	entries := artifactEntries(t, art.Path)
	body, ok := entries[nodeABIMarkName]
	if !ok {
		names := make([]string, 0, len(entries))
		for n := range entries {
			names = append(names, n)
		}
		t.Fatalf("no %s at the archive root; entries: %v", nodeABIMarkName, names)
	}
	// The payload still has to be there — a declaration packed instead of the
	// release would satisfy the line above and serve nothing.
	if _, ok := entries["server.js"]; !ok {
		t.Fatalf("the archive lost server.js")
	}
	major, libc := readNodeABIDeclaration(body)
	if _, isInt := nodeABIIntegerMajor(major); !isInt {
		t.Fatalf("node_major=%q is not the bare integer the engine demands; body:\n%s", major, body)
	}
	switch libc {
	case nodeABILibcGlibc, nodeABILibcMusl, nodeABILibcUnknown:
	default:
		t.Fatalf("libc=%q is outside the engine's vocabulary (glibc|musl|unknown); body:\n%s", libc, body)
	}
}

// TestStaticPrebuiltArtifactCarriesNoNodeDeclaration is the QUIET arm: the change
// must not add the file to the lane that has no use for it. A static box has no
// reader for .bp-node-abi, and an artifact that carried one would be making a
// claim nothing checks.
func TestStaticPrebuiltArtifactCarriesNoNodeDeclaration(t *testing.T) {
	dir := writeDistFixture(t, "d0d0d0d0d0d0d0d0")
	art, err := packPrebuiltDir(dir)
	if err != nil {
		t.Fatalf("packPrebuiltDir: %v", err)
	}
	defer art.Cleanup()
	if _, found := artifactEntries(t, art.Path)[nodeABIMarkName]; found {
		t.Fatalf("the static lane packed %s — it has no reader for it", nodeABIMarkName)
	}
}

// engineABIReader extracts the awk program of `abi_decl_value` out of
// deploy/site-deploy-node.sh and runs it, so this test measures with THE
// ENGINE'S OWN READER instead of with a paraphrase of it living in this package.
// If the engine's reader changes shape, this reds — which is the point: a packer
// that reads its own file more generously than the box does waves through a
// declaration the box refuses.
func engineABIReader(t *testing.T, declaration, key string) string {
	t.Helper()
	enginePath := filepath.Join("..", "..", "deploy", "site-deploy-node.sh")
	src, err := os.ReadFile(enginePath)
	if err != nil {
		t.Fatalf("read the engine (%s): %v", enginePath, err)
	}
	const anchor = "awk -v k=\"$2\" '"
	i := strings.Index(string(src), anchor)
	if i < 0 {
		t.Fatalf("abi_decl_value's awk program is no longer in %s under %q — the reader this test measures with has moved; re-anchor it", enginePath, anchor)
	}
	rest := string(src)[i+len(anchor):]
	j := strings.Index(rest, "'")
	if j < 0 {
		t.Fatalf("unterminated awk program in %s", enginePath)
	}
	prog := rest[:j]
	if !strings.Contains(prog, "NR<=16") {
		t.Fatalf("extracted the wrong text as the engine's reader:\n%s", prog)
	}

	f, err := os.CreateTemp(t.TempDir(), "abi-*")
	if err != nil {
		t.Fatalf("temp: %v", err)
	}
	if _, err := f.WriteString(declaration); err != nil {
		t.Fatalf("write: %v", err)
	}
	_ = f.Close()

	out, err := exec.Command("awk", "-v", "k="+key, prog, f.Name()).Output()
	if err != nil {
		t.Fatalf("run the engine's reader: %v", err)
	}
	return strings.TrimSpace(string(out))
}

// TestPackedNodeArtifactIsReadableByTheEnginesOwnReader is criterion 2. It is
// the difference between "the file exists" and "the ENGINE accepts what is in
// it": the bytes the packer produced are handed to the engine's awk, and both
// required keys must come back with usable values.
func TestPackedNodeArtifactIsReadableByTheEnginesOwnReader(t *testing.T) {
	dir := writeStandaloneFixture(t)
	art, err := packPrebuiltDirFor(dir, prebuiltRuntimeNode)
	if err != nil {
		t.Fatalf("packPrebuiltDirFor(node): %v", err)
	}
	defer art.Cleanup()
	body, ok := artifactEntries(t, art.Path)[nodeABIMarkName]
	if !ok {
		t.Fatalf("no %s in the artifact", nodeABIMarkName)
	}

	major := engineABIReader(t, body, "node_major")
	if _, isInt := nodeABIIntegerMajor(major); !isInt {
		t.Fatalf("the engine's reader got node_major=%q out of the packer's declaration — it refuses anything but a bare integer (exit 17)\n%s", major, body)
	}
	libc := engineABIReader(t, body, "libc")
	if libc == "" {
		t.Fatalf("the engine's reader found no libc= line — both keys are required (exit 17)\n%s", body)
	}

	// THE CONTROL that this reader discriminates: a declaration the engine
	// REFUSES must not read back as usable. Without it, a reader that returned
	// "" for everything, or the whole line for everything, would pass above.
	if v := engineABIReader(t, "node_major=unknown\n", "node_major"); v != "unknown" {
		t.Fatalf("control: the engine's reader should hand back the literal %q, got %q", "unknown", v)
	}
	if _, isInt := nodeABIIntegerMajor("unknown"); isInt {
		t.Fatalf("control: node_major=unknown must not read as an integer")
	}
	if v := engineABIReader(t, "node_major=22\n", "libc"); v != "" {
		t.Fatalf("control: a declaration with no libc= line must read back empty, got %q", v)
	}
}

// TestNodePrebuiltRefusesADeclarationTheEngineWouldReject is the other half of
// criterion 2: a tree that brings its OWN unusable declaration is refused HERE,
// before the nonced mint, instead of by the box at PLAN after the upload.
func TestNodePrebuiltRefusesADeclarationTheEngineWouldReject(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		want string
	}{
		{"node_major is not an integer", "node_major=unknown\nlibc=glibc\n", "bare integer"},
		{"no libc line at all", "node_major=22\n", "no libc"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeStandaloneFixture(t)
			if err := os.WriteFile(filepath.Join(dir, nodeABIMarkName), []byte(tc.body), 0o644); err != nil {
				t.Fatalf("write declaration: %v", err)
			}
			cp := newSiteCP(t)
			cp.getResp = fakeResp{200, nodeTestSiteRow}
			cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-x","status":"queued","build_id":"c1c1c1c1c1c1c1c1","source":"prebuilt"}}`}
			cp.artifactResp = fakeResp{201, `{"bytes":10}`}
			cp.serve()

			stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--no-follow")
			all := stdout + stderr
			if code == exitOK {
				t.Fatalf("a declaration the engine refuses must not ship:\n%s", all)
			}
			if !strings.Contains(all, tc.want) {
				t.Fatalf("the refusal must name the fault (%q):\n%s", tc.want, all)
			}
			if cp.artifactHits != 0 {
				t.Fatalf("artifact hits=%d want 0 — refuse before the upload", cp.artifactHits)
			}
		})
	}
}

// TestNodePrebuiltKeepsAnAcceptableDeclarationTheTreeBrought is the QUIET arm for
// the same seam: a CI runner that cross-builds knows an answer the packing host
// does not, so an honest declaration already in the tree survives the packer
// untouched rather than being overwritten with the laptop's.
func TestNodePrebuiltKeepsAnAcceptableDeclarationTheTreeBrought(t *testing.T) {
	dir := writeStandaloneFixture(t)
	const declared = "node_major=18\nlibc=musl\npacker=ci\n"
	if err := os.WriteFile(filepath.Join(dir, nodeABIMarkName), []byte(declared), 0o644); err != nil {
		t.Fatalf("write declaration: %v", err)
	}
	art, err := packPrebuiltDirFor(dir, prebuiltRuntimeNode)
	if err != nil {
		t.Fatalf("packPrebuiltDirFor(node): %v", err)
	}
	defer art.Cleanup()
	got := artifactEntries(t, art.Path)[nodeABIMarkName]
	if got != declared {
		t.Fatalf("the packer rewrote a declaration the engine accepts:\n got: %q\nwant: %q", got, declared)
	}
}

// TestPrebuiltUnservableClauseStillRefusesRuntimesWithNoEngineArm is criterion 3.
// The retirement is for NODE, because node now has an engine arm. Every runtime
// that does not is still refused before the nonce — which is the whole reason
// this guard is a predicate over the CLOSED side rather than a list of the open
// one.
func TestPrebuiltUnservableClauseStillRefusesRuntimesWithNoEngineArm(t *testing.T) {
	for _, tc := range []struct {
		name, kind, target string
		refuse             bool
	}{
		{"node by runtime target", "node", "node-slot", false},
		{"node by kind alone", "node", "", false},
		{"container kind is the server's node enum", "container", "", false},
		{"static", "static", "static-symlink-swap", false},
		{"static by kind alone", "static", "", false},
		{"a runtime nobody has built an engine for", "static", "wasm-edge", true},
		{"a kind nobody has built an engine for", "deno", "", true},
		{"nothing said at all is not a refusal", "", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clause := prebuiltUnservableClause(tc.kind, tc.target)
			if tc.refuse && clause == "" {
				t.Fatalf("kind=%q target=%q must still be refused — it has no engine arm", tc.kind, tc.target)
			}
			if !tc.refuse && clause != "" {
				t.Fatalf("kind=%q target=%q must be served, got refusal %q", tc.kind, tc.target, clause)
			}
		})
	}
}

// TestPrebuiltStillRefusesAnUnknownRuntimeBeforeMinting is the end-to-end half of
// criterion 3: the predicate above has to still REACH the command.
func TestPrebuiltStillRefusesAnUnknownRuntimeBeforeMinting(t *testing.T) {
	dir := writeDistFixture(t, "e0e0e0e0e0e0e0e0")
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"static","runtime_target":"wasm-edge","prebuilt_enabled":true}}`}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-w","status":"queued","build_id":"e0e0e0e0e0e0e0e0","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"bytes":10}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--no-follow")
	all := stdout + stderr
	if code == exitOK {
		t.Fatalf("a runtime with no engine arm must still be refused:\n%s", all)
	}
	if cp.deployHits != 0 || cp.artifactHits != 0 {
		t.Fatalf("deploy=%d artifact=%d want 0/0 — refuse before the nonced mint", cp.deployHits, cp.artifactHits)
	}
	if !strings.Contains(all, "wasm-edge") {
		t.Fatalf("the refusal must quote the value that refused them:\n%s", all)
	}
}

// TestNodePrebuiltRefusesATreeWithNoServerJS mirrors the engine's exit-11 refusal
// on the laptop. The engine raises it AFTER a nonced mint and a full upload.
func TestNodePrebuiltRefusesATreeWithNoServerJS(t *testing.T) {
	dir := writeDistFixture(t, "f0f0f0f0f0f0f0f0") // a static dist/, aimed at a node site
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, nodeTestSiteRow}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-n","status":"queued","build_id":"f0f0f0f0f0f0f0f0","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"bytes":10}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--no-follow")
	all := stdout + stderr
	if code == exitOK {
		t.Fatalf("a node site must not accept a tree with no server.js at its root:\n%s", all)
	}
	if cp.deployHits != 0 {
		t.Fatalf("deploy hits=%d want 0 — the root guard runs before the mint", cp.deployHits)
	}
	if !strings.Contains(all, "server.js") || !strings.Contains(all, "standalone") {
		t.Fatalf("the refusal must name what to pack instead:\n%s", all)
	}
}

// TestPreMintRootGuardAcceptsEitherLaneButRefusesNeither is the union arm's whole
// contract (prebuiltRuntimeUnknown). It runs before any network read, so it must
// accept both release-root shapes — and must still refuse a project directory,
// which is the only refusal it can honestly make that early.
func TestPreMintRootGuardAcceptsEitherLaneButRefusesNeither(t *testing.T) {
	if _, err := validatePrebuiltDirFor(writeDistFixture(t, "aabb"), prebuiltRuntimeUnknown); err != nil {
		t.Fatalf("the union arm must accept a static dist/: %v", err)
	}
	if _, err := validatePrebuiltDirFor(writeStandaloneFixture(t), prebuiltRuntimeUnknown); err != nil {
		t.Fatalf("the union arm must accept a node standalone root: %v", err)
	}
	proj := t.TempDir()
	if err := os.WriteFile(filepath.Join(proj, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := validatePrebuiltDirFor(proj, prebuiltRuntimeUnknown)
	if err == nil {
		t.Fatalf("the union arm must still refuse a project directory")
	}
	if !strings.Contains(err.Error(), "neither an index.html nor a server.js") {
		t.Fatalf("the refusal must say what it looked for: %v", err)
	}
	// And the STRICT arms still discriminate — otherwise the union above would
	// have quietly become the only guard there is.
	if _, err := validatePrebuiltDirFor(writeStandaloneFixture(t), prebuiltRuntimeStatic); err == nil {
		t.Fatalf("the static arm must still demand index.html")
	}
	if _, err := validatePrebuiltDirFor(writeDistFixture(t, "aabb"), prebuiltRuntimeNode); err == nil {
		t.Fatalf("the node arm must still demand server.js")
	}
}

// TestProbeNodeABIAnswersEveryBranch drives the probe through branches this host
// cannot produce (a musl linux, a node-less machine, a bad override), because a
// probe only ever exercised on the developer's own laptop is a probe with one
// tested branch.
func TestProbeNodeABIAnswersEveryBranch(t *testing.T) {
	env := func(m map[string]string) func(string) (string, bool) {
		return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
	}
	base := nodeABIProbe{
		GOOS:        "linux",
		LookupEnv:   env(nil),
		NodeVersion: func() (string, error) { return "v22.11.0\n", nil },
		LddVersion:  func() (string, error) { return "ldd (GNU libc) 2.36", nil },
	}

	abi, err := probeNodeABI(base)
	if err != nil || abi.Major != 22 || abi.Libc != nodeABILibcGlibc {
		t.Fatalf("glibc linux: %+v %v", abi, err)
	}

	musl := base
	musl.LddVersion = func() (string, error) { return "musl libc (aarch64)\nVersion 1.2.4", nil }
	if abi, err := probeNodeABI(musl); err != nil || abi.Libc != nodeABILibcMusl {
		t.Fatalf("musl linux: %+v %v", abi, err)
	}

	mac := base
	mac.GOOS = "darwin"
	mac.LddVersion = func() (string, error) { t.Fatal("darwin must not shell out to ldd"); return "", nil }
	if abi, err := probeNodeABI(mac); err != nil || abi.Libc != nodeABILibcUnknown {
		t.Fatalf("darwin must declare libc=unknown, got %+v %v", abi, err)
	}

	// An UNREADABLE ldd is `unknown`, not a refusal: libc unknown is undecided
	// on the box, so there is nothing to refuse.
	blind := base
	blind.LddVersion = func() (string, error) { return "", os.ErrNotExist }
	if abi, err := probeNodeABI(blind); err != nil || abi.Libc != nodeABILibcUnknown {
		t.Fatalf("an unreadable ldd must be unknown, got %+v %v", abi, err)
	}

	// node_major has NO unknown. A host that cannot name its node is refused
	// here, with the export to set — the box would refuse it at PLAN instead,
	// after the upload.
	noNode := base
	noNode.NodeVersion = func() (string, error) { return "", os.ErrNotExist }
	_, err = probeNodeABI(noNode)
	if err == nil {
		t.Fatalf("a host that cannot name its node major must refuse, not declare unknown")
	}
	if !strings.Contains(err.Error(), nodeABIMajorEnv) {
		t.Fatalf("the refusal must name the escape hatch: %v", err)
	}

	// The overrides win outright — the cross-build case.
	over := base
	over.LookupEnv = env(map[string]string{nodeABIMajorEnv: "18", nodeABILibcEnv: "musl"})
	if abi, err := probeNodeABI(over); err != nil || abi.Major != 18 || abi.Libc != nodeABILibcMusl {
		t.Fatalf("overrides: %+v %v", abi, err)
	}

	// A non-integer override is refused rather than shipped: the box refuses it
	// at PLAN, and a lie that travels is worse than a refusal that does not.
	badOver := base
	badOver.LookupEnv = env(map[string]string{nodeABIMajorEnv: "twenty-two"})
	if _, err := probeNodeABI(badOver); err == nil {
		t.Fatalf("a non-integer %s must be refused", nodeABIMajorEnv)
	}

	// A libc override outside the vocabulary falls back to the PROBE rather than
	// travelling: the box compares three literals, and a fourth would either
	// refuse there or be silently unequal to everything.
	badLibc := base
	badLibc.LookupEnv = env(map[string]string{nodeABILibcEnv: "uclibc"})
	if abi, err := probeNodeABI(badLibc); err != nil || abi.Libc != nodeABILibcGlibc {
		t.Fatalf("an unreadable libc override must fall back to the probe, got %+v %v", abi, err)
	}
}

// TestSynthesizedEntryRefusesToShadowARealFile guards the tar seam itself: tar
// permits duplicate names and an extractor takes the LAST, so an unchecked
// append would make "what does this tree declare?" depend on entry order.
func TestSynthesizedEntryRefusesToShadowARealFile(t *testing.T) {
	dir := writeStandaloneFixture(t)
	_, err := bufferTarball(tarballOptions{
		Root:     dir,
		Ignores:  prebuiltTarballIgnores,
		MaxBytes: prebuiltMaxUncompressedBytes,
		Extra:    []tarballExtraFile{{Name: "server.js", Body: []byte("nope")}},
	})
	if err == nil {
		t.Fatalf("an extra that shadows a walked entry must be refused")
	}
	if !strings.Contains(err.Error(), "already carries an entry") {
		t.Fatalf("the refusal must say why: %v", err)
	}
}
