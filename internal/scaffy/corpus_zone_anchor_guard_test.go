package scaffy

// The console-tests zone payload must NAME the guard that enforces it
// (task-e4289e4c30bb6eff, deferred from cchi-w61 / PR #17700).
//
// WHY A TEST AND NOT A README LINE. cchi-w61 shipped the machine half —
// scripts/console-tdz-order-check.mjs's separately-named `ZONE ANCHOR ORDER`
// assertion, wired into console-harness.yml's path-escape job — and amended
// the ALREADY-PLANTED comment in cloud/priv/static/__app.test.mjs to say so.
// The TEMPLATE was left behind, so a FRESH plant of the zone still wrote the
// prose-only sentence: the one reader who most needs to know the rule is
// machine-checked — the person planting the zone into a new file — was the one
// reader not told. Restoring that by hand is exactly the kind of fix that rots
// back out silently, so the correspondence is asserted here instead.
//
// THE TWO ARMS. The positive arm reds if the guard's name or its postcondition
// leaves the template. The negative arm pins the claim to the RIGHT payload:
// a whole-file `strings.Contains` would stay green if the sentence landed in
// the app.js zones, which describe a different seam with no ordering rule at
// all — so those two payloads are asserted to stay silent about it.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// zoneAnchorGuardCmd is the postcondition the console-tests zone's prose
// promises. It is spelled ONCE, here, and both the template assertion and the
// tree-existence check read this same string — a guard whose expected value is
// derived from the thing it guards proves nothing.
const zoneAnchorGuardCmd = "node scripts/console-tdz-order-check.mjs cloud/priv/static/__app.test.mjs"

// zoneAnchorGuardScript is the repo-relative script zoneAnchorGuardCmd runs.
const zoneAnchorGuardScript = "scripts/console-tdz-order-check.mjs"

func parseConsoleHookZones(t *testing.T) *Command {
	t.Helper()
	path := filepath.Join(corpusDir, "ensure-console-hook-zones.scaffy")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	cmd, findings := Parse(filepath.Base(path), src)
	if cmd == nil {
		t.Fatalf("Parse returned nil command; findings: %v", findings)
	}
	return cmd
}

// payloadsByPath returns every InOp payload in cmd, grouped by target path, as
// one joined string per op. Reading the AST rather than the file bytes is what
// makes the negative arm below meaningful: it can tell WHICH payload carries a
// sentence, where a grep cannot.
func payloadsByPath(cmd *Command) map[string][]string {
	out := map[string][]string{}
	for _, op := range cmd.Ops {
		in, ok := op.(*InOp)
		if !ok || in.Payload == nil || in.Payload.Fenced == nil || in.Path == nil {
			continue
		}
		out[in.Path.Value] = append(out[in.Path.Value], strings.Join(in.Payload.Fenced.Lines, "\n"))
	}
	return out
}

func TestConsoleTestsZonePayloadNamesItsGuard(t *testing.T) {
	cmd := parseConsoleHookZones(t)
	byPath := payloadsByPath(cmd)

	const harness = "cloud/priv/static/__app.test.mjs"
	got := byPath[harness]
	if len(got) != 1 {
		t.Fatalf("want exactly 1 payload targeting %s, got %d — the op this test measures moved or split", harness, len(got))
	}
	payload := got[0]

	// Positive arm: the payload the plant WRITES must name the guard, the
	// assertion name it fails under, and the file the assertion lives in.
	for _, want := range []string{
		"ZONE ANCHOR ORDER",
		zoneAnchorGuardScript,
		"LAST top-level `await`",
	} {
		if !strings.Contains(payload, want) {
			t.Errorf("the console-tests zone payload does not mention %q — a fresh plant writes prose the reader cannot act on:\n%s", want, payload)
		}
	}

	// Negative arm: the two app.js zones describe seams with NO ordering rule
	// (declarations hoist; object keys are order-free). If the guard sentence
	// shows up there the positive arm above has stopped being site-specific.
	for _, p := range byPath["cloud/priv/static/app.js"] {
		if strings.Contains(p, "ZONE ANCHOR ORDER") {
			t.Errorf("an app.js zone payload names ZONE ANCHOR ORDER; that guard is about the harness tail only:\n%s", p)
		}
	}
}

func TestConsoleHookZonesAssertsTheZoneAnchorGuard(t *testing.T) {
	cmd := parseConsoleHookZones(t)

	found := false
	for _, a := range cmd.Asserts {
		if a.Kind == AssertCmd && a.Text == zoneAnchorGuardCmd {
			found = true
		}
	}
	if !found {
		var have []string
		for _, a := range cmd.Asserts {
			if a.Kind == AssertCmd {
				have = append(have, a.Text)
			}
		}
		t.Errorf("ensure-console-hook-zones carries no `ASSERT CMD %q`; its ASSERT CMDs are %q", zoneAnchorGuardCmd, have)
	}

	// A postcondition that names a script the tree does not have is a gate
	// that fails for the wrong reason on the first plant.
	if _, err := os.Stat(filepath.Join(repoRoot, zoneAnchorGuardScript)); err != nil {
		t.Errorf("the asserted guard %s is not in the tree: %v", zoneAnchorGuardScript, err)
	}
}
