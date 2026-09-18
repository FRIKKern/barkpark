package cli

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// ssw9-bl-node-prebuilt — the `--prebuilt` runtime guard asks a PREDICATE, not a
// list.
//
// THE DEFECT THIS FILE RETIRES. prebuiltStaticOnlyRefusal used to fire on
// `siteIsNode`, which enumerates the OPEN side: runtime targets containing
// "node", plus kinds "node" and "container". That set is complete only against
// the control plane AS OF THIS COMMIT (`Barkpark.Registry.Site`: `@kinds ~w(
// container static node)`). A fourth kind, or a non-static runtime target that
// does not spell "node", answers false — and a false here is not a warning, it
// is a nonced mint burned, a tree packed, and an artifact uploaded that nothing
// on the box will ever serve. The guard now asks the CLOSED question ("did the
// control plane say static?"), so a runtime this binary has never heard of is
// refused by default.
//
// THE ARMS. The specimens below are RED-WHEN-REVERTED: restore the old
// `siteIsNode`-only condition and every one of them deploys instead of erroring
// (the two hit counters are the assertion, not the exit code alone). The quiet
// arms under them are what stops the fix from degenerating into "refuse
// everything": a static site and a control plane that declares NOTHING both
// still mint, pack and upload exactly as before.

// prebuiltRuntimeSpecimen is one control-plane answer and the field that should
// refuse it.
type prebuiltRuntimeSpecimen struct {
	name          string
	kind          string
	runtimeTarget string
	wantInRefusal string
}

// TestPrebuiltRefusesARuntimeThisBinaryHasNeverHeardOf is the RED arm on the
// axis no list can cover: values that exist in NEITHER the CLI's node list nor
// the server's current `@kinds`. Under the old guard each of these was waved
// straight through to the mint.
func TestPrebuiltRefusesARuntimeThisBinaryHasNeverHeardOf(t *testing.T) {
	specimens := []prebuiltRuntimeSpecimen{
		{"kind the server has not declared yet", "bun", "", `"bun"`},
		{"a python runtime", "python", "", `"python"`},
		{"runtime target that does not spell node", "", "bun-slot", `"bun-slot"`},
		{"runtime target for a wasm edge runtime", "", "wasm-edge", `"wasm-edge"`},
		// The kind says static but the box reports a target that is not the
		// symlink swap — the target is the SERVED truth and must win.
		{"static kind, non-static served target", "static", "deno-slot", `"deno-slot"`},
	}
	if len(specimens) < 5 {
		t.Fatalf("floor guard: this arm is worthless below 5 specimens, have %d", len(specimens))
	}
	for _, sp := range specimens {
		t.Run(sp.name, func(t *testing.T) {
			stdout, stderr, code, cp := runPrebuiltAgainstRuntime(t, sp.kind, sp.runtimeTarget)
			if code == exitOK {
				t.Fatalf("kind=%q runtime_target=%q must not accept --prebuilt\nstdout:%s\nstderr:%s", sp.kind, sp.runtimeTarget, stdout, stderr)
			}
			if cp.deployHits != 0 || cp.artifactHits != 0 {
				t.Fatalf("the refusal must land BEFORE the nonced mint and the pack (deploy=%d artifact=%d)", cp.deployHits, cp.artifactHits)
			}
			all := stdout + stderr
			for _, want := range []string{sp.wantInRefusal, "static-only", "no deployment was minted"} {
				if !strings.Contains(all, want) {
					t.Fatalf("the refusal must carry %q so the operator sees WHICH field refused:\n%s", want, all)
				}
			}
		})
	}
}

// TestPrebuiltRefusesEveryNonStaticKindTheServerDeclares WALKS the control
// plane's own kind vocabulary and enrols each member, rather than restating a
// copy of it here. `Barkpark.Registry.Site` is the door every site row passes
// through, so a kind added there is a kind `--prebuilt` will meet; enrolling
// from the source means the new member arrives in this test on the commit that
// adds it, not on the commit someone remembers to.
//
// The floor guard is the point: if the regexp stops matching (file moved,
// attribute renamed) this test FAILS loudly instead of silently enrolling zero
// kinds and printing a green.
func TestPrebuiltRefusesEveryNonStaticKindTheServerDeclares(t *testing.T) {
	kinds := serverSiteKinds(t)
	if len(kinds) < 3 {
		t.Fatalf("floor guard: read %d kinds from the registry, want >= 3 — the enrolment source has moved and this test was about to measure nothing: %v", len(kinds), kinds)
	}
	var sawStatic bool
	for _, k := range kinds {
		if k == "static" {
			sawStatic = true
		}
	}
	if !sawStatic {
		t.Fatalf("floor guard: %q is not among the kinds read (%v) — the guard's ALLOWED value is missing, so every enrolment below would pass for the wrong reason", "static", kinds)
	}
	// NODE IS NO LONGER ENROLLED HERE, and the exclusion is a fact about the
	// box: deploy/site-deploy-node.sh carries a PLAN_MODE=prebuilt arm, so the
	// node kinds ("node", and "container" — the server's enum for it) have an
	// engine to hand bytes to. What this test still measures is the axis it was
	// built for: a kind the server declares that NO engine serves.
	enrolled := 0
	for _, k := range kinds {
		if k == "static" || siteIsNode(k, "") {
			continue
		}
		enrolled++
		t.Run(k, func(t *testing.T) {
			stdout, stderr, code, cp := runPrebuiltAgainstRuntime(t, k, "")
			if code == exitOK {
				t.Fatalf("kind %q is not static and must be refused --prebuilt\nstdout:%s\nstderr:%s", k, stdout, stderr)
			}
			if cp.deployHits != 0 || cp.artifactHits != 0 {
				t.Fatalf("kind %q: nothing may be minted or packed (deploy=%d artifact=%d)", k, cp.deployHits, cp.artifactHits)
			}
		})
	}
	// The exclusions above are two of three known kinds, so without this the
	// day the registry holds only static + node this test would print a green
	// having enrolled nobody. It is allowed to enrol zero — it must SAY so.
	if enrolled == 0 {
		t.Logf("NOTICE: every kind the registry declares (%v) is either static or served by the node engine — this arm enrolled nothing and measured nothing", kinds)
	}
}

// TestPrebuiltNodeRefusalIsRetiredAndItsCLAUSEIsSilent records the retirement at
// the level this file owns: the PREDICATE.
//
// The refusal it replaces was never "we have not got round to it" — the ruling
// of record (2026-09-02) said HEALTH certifies the INJECTION (bp-build-id
// reaches the served page out of the slot env this deploy writes, never out of
// the uploaded bytes) and told the lane to declare a node ABI instead. Both
// halves now exist: the engine's PLAN_MODE=prebuilt arm refuses an ABI mismatch
// before STAGE, and the packer emits .bp-node-abi. So the clause goes quiet for
// node while staying loud for everything with no engine.
//
// This is the predicate-level RED-WHEN-REVERTED arm: restore the node arm of
// prebuiltUnservableClause and the first two cases below fail.
func TestPrebuiltNodeRefusalIsRetiredAndItsCLAUSEIsSilent(t *testing.T) {
	for _, tc := range []struct {
		name, kind, target string
	}{
		{"node by target", "node", "node-slot"},
		{"container, the server's node enum", "container", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if clause := prebuiltUnservableClause(tc.kind, tc.target); clause != "" {
				t.Fatalf("node has an engine arm now; the clause must be silent, got %q", clause)
			}
		})
	}
	// The QUIET arm of the retirement: the sentence itself must be gone from the
	// binary, not merely unreached on one path.
	if clause := prebuiltUnservableClause("bun", ""); !strings.Contains(clause, "bun") {
		t.Fatalf("a kind with no engine must still be refused by name, got %q", clause)
	}
	if strings.Contains(prebuiltUnservableClause("bun", ""), "node/SSR") {
		t.Fatalf("the retired node sentence is still being printed for other runtimes")
	}
}

// TestPrebuiltSaysNothingAboutARuntimeTheControlPlaneDidNotDeclare is the QUIET
// arm that a refuse-by-default predicate most needs. A control plane that sends
// neither `kind` nor `runtime_target` has told the CLI NOTHING, and refusing on
// no information would break every site served by a box that predates those
// fields. It must mint, pack and upload exactly as before.
func TestPrebuiltSaysNothingAboutARuntimeTheControlPlaneDidNotDeclare(t *testing.T) {
	stdout, stderr, code, cp := runPrebuiltAgainstRuntime(t, "", "")
	if code != exitOK {
		t.Fatalf("a site that declares no kind and no runtime_target must still deploy --prebuilt: exit=%d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 1 || cp.artifactHits != 1 {
		t.Fatalf("it must mint once and upload once (deploy=%d artifact=%d)", cp.deployHits, cp.artifactHits)
	}
	if strings.Contains(stdout+stderr, "static-only") {
		t.Fatalf("no runtime refusal may be printed when the control plane declared no runtime:\n%s%s", stdout, stderr)
	}
}

// TestPrebuiltAcceptsTheStaticTargetHoweverItIsSpelled is the second quiet arm:
// the static vocabulary tolerates punctuation drift the same way
// cloudclient.RuntimeTargetIsNode tolerates it on the other side, so a control
// plane spelling the target with underscores is not refused for its typography.
func TestPrebuiltAcceptsTheStaticTargetHoweverItIsSpelled(t *testing.T) {
	for _, target := range []string{"static-symlink-swap", "static_symlink_swap", "STATIC-SYMLINK-SWAP"} {
		t.Run(target, func(t *testing.T) {
			stdout, stderr, code, cp := runPrebuiltAgainstRuntime(t, "static", target)
			if code != exitOK {
				t.Fatalf("target %q is the static symlink swap and must deploy: exit=%d\nstdout:%s\nstderr:%s", target, code, stdout, stderr)
			}
			if cp.deployHits != 1 || cp.artifactHits != 1 {
				t.Fatalf("target %q must mint once and upload once (deploy=%d artifact=%d)", target, cp.deployHits, cp.artifactHits)
			}
		})
	}
}

// runPrebuiltAgainstRuntime drives `bp cloud site deploy <site> --prebuilt <dir>`
// against a control plane that answers with the given kind / runtime_target and
// is otherwise fully ARMED FOR SUCCESS: opted in, a mint that matches the
// fixture's build id, an upload that agrees on the digest, and a poll that goes
// live. Nothing but the runtime guard can be what refuses.
func runPrebuiltAgainstRuntime(t *testing.T, kind, runtimeTarget string) (string, string, int, *siteCP) {
	t.Helper()
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	site := `{"id":"` + testSiteID + `","name":"app","slug":"app","framework":"nextjs","prebuilt_enabled":true`
	if kind != "" {
		site += `,"kind":"` + kind + `"`
	}
	if runtimeTarget != "" {
		site += `,"runtime_target":"` + runtimeTarget + `"`
	}
	site += `}`

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":` + site + `}`}
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactRespFn = func(sha string, n int) fakeResp {
		return fakeResp{201, `{"artifact_sha256":"` + sha + `","bytes":` + itoa(n) + `}`}
	}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/app/"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	return stdout, stderr, code, cp
}

// serverSiteKindsRe matches `@kinds ~w(container static node)` in the registry
// schema. Anchored on the attribute name so a sibling `~w(...)` list (there are
// several: frameworks, scale modes) cannot be read as the kinds by accident.
var serverSiteKindsRe = regexp.MustCompile(`(?m)^\s*@kinds\s+~w\(([^)]*)\)`)

// serverSiteKinds reads the control plane's OWN kind vocabulary. It returns the
// members; the CALLER owns the floor guard, because "how few is too few" is a
// statement about the test that enrols them, not about the parse.
func serverSiteKinds(t *testing.T) []string {
	t.Helper()
	path := filepath.Join("..", "..", "cloud", "lib", "barkpark_cloud", "registry", "site.ex")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("cannot read the kind vocabulary at %s: %v — the enrolment source moved; re-point this test rather than deleting it", path, err)
	}
	m := serverSiteKindsRe.FindSubmatch(b)
	if m == nil {
		t.Fatalf("no `@kinds ~w(...)` in %s — the attribute was renamed; re-point this test rather than letting it enrol nothing", path)
	}
	return strings.Fields(string(m[1]))
}
