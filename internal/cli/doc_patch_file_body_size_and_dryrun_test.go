package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// task-0e765e3e21fa8e52 — THE TWO ARMS doc_patch_file_body_e2e_test.go STILL OWED.
//
// That file proved the ROUTING: a nested body read from a file lands under
// patch.set and --set still merges on top. Two things its criterion named were
// left uncovered, and this file is exactly those two and nothing else.
//
//  1. SIZE. Its fixture, theNestedBody, is 174 bytes and says so itself
//     ("Kept small enough to read"). The original defect was a payload too
//     large and too nested to ride --set on a command line, so the size IS the
//     reported symptom. A sub-kilobyte body cannot tell "the file path works"
//     apart from "the file path works at the size that forced the fallback".
//
//  2. DRY RUN. The served manifest slice carries dry_run:false and no test
//     exercised `doc.patch --file --dry-run` at all.
//
// WHAT SIZE DOES AND DOES NOT BUY — read off run.go, not assumed. There is NO
// size-dependent branch anywhere in the client: the --file arm is a plain
// os.ReadFile + json.Unmarshal (internal/cli/run.go:assembleBody, which
// buildBody reaches through buildBodyWithStdinOwnership) and nothing downstream
// reads len(body). So a multi-kilobyte fixture does not unlock a different
// BRANCH, and any comment claiming it does would be false. What it buys is
// measurable and is what these arms assert:
//
//   - A whole-payload DEEP EQUALITY round-trip across a real HTTP transport at
//     a size where a truncating or re-buffering edit is possible at all. The
//     174-byte arms check two keys by name and a 2-element array; that shape of
//     assertion survives a body clipped at 4 KiB. This one does not — see the
//     discriminating control in the header comment on the size arm below.
//   - A RECORDED byte count (t.Logf, plus asserted floors) rather than a prose
//     claim about the size, which is what the row asked for.
//
// FENCE: internal/cli/ only, additive — this file adds no production code and
// edits no existing test.
// ---------------------------------------------------------------------------

// largeBodyMinBytes is the floor the multi-kilobyte fixture must clear. 8 KiB is
// ~47x theNestedBody and comfortably past the 4 KiB clip the discriminating
// control below uses, so the control cannot pass by the fixture being small.
const largeBodyMinBytes = 8192

// largeBodyMinDepth stops a future edit from satisfying the byte floor with one
// enormous FLAT string. The original payload's problem was nesting as much as
// length, so the fixture must stay deep as well as large.
const largeBodyMinDepth = 6

// buildLargeNestedBody renders the multi-kilobyte, deeply nested patch body and
// returns both its exact bytes and the object those bytes decode to. Generated
// rather than pasted so the size is deterministic, reproducible, and reported by
// the test itself instead of drifting as someone edits a literal.
//
// The shape is a PortableDoc-like block list — the real payload class that
// forced the raw-HTTP fallback: arrays of objects containing arrays of objects
// containing arrays, which --set cannot express at all except as one giant
// `key:=<json>` command-line argument.
func buildLargeNestedBody(t *testing.T) ([]byte, map[string]any) {
	t.Helper()

	blocks := make([]any, 0, 48)
	for i := 0; i < 48; i++ {
		spans := make([]any, 0, 3)
		for j := 0; j < 3; j++ {
			spans = append(spans, map[string]any{
				"type":  "span",
				"text":  fmt.Sprintf("block %02d span %d — a sentence long enough that the payload grows past a command line", i, j),
				"marks": []any{map[string]any{"type": "emphasis", "attrs": map[string]any{"level": j}}},
			})
		}
		blocks = append(blocks, map[string]any{
			"type":    "paragraph",
			"key":     fmt.Sprintf("b%02d", i),
			"content": spans,
		})
	}

	body := map[string]any{
		"title":  "patched from a file at multi-kilobyte size",
		"blocks": blocks,
	}

	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal large fixture: %v", err)
	}

	// Re-decode rather than reuse `body`: the wire comparison must be against
	// what the BYTES mean (numbers as float64, etc.), not against the Go values
	// that happened to produce them. Comparing against `body` would make the
	// deep-equality assertion fail for a reason that is not the defect.
	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("re-decode large fixture: %v", err)
	}
	return raw, parsed
}

// jsonDepth is the nesting depth of a decoded JSON value, leaves at depth 1.
func jsonDepth(v any) int {
	switch t := v.(type) {
	case map[string]any:
		deepest := 0
		for _, child := range t {
			if d := jsonDepth(child); d > deepest {
				deepest = d
			}
		}
		return deepest + 1
	case []any:
		deepest := 0
		for _, child := range t {
			if d := jsonDepth(child); d > deepest {
				deepest = d
			}
		}
		return deepest + 1
	default:
		return 1
	}
}

// runWithGlobals is h.run with the caller's globals — h.run hardcodes
// globals{}, which can never reach the --dry-run branch. Added here rather than
// by editing the e2e file so that file's arms are byte-identical to what they
// were when they were reviewed.
func (h *filePatchHarness) runWithGlobals(g globals, output string, noun, verb string, tail ...string) (int, string, string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup(noun, verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no %s %s", noun, verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	// Mirror what applyGlobals does for a real `-o json`: set the writer's mode
	// AND mark it explicit, so resolveOutputForCommand does not override it with
	// doc.patch's minimal default.
	if output != "" {
		g.output = output
		g.outputSet = true
		w.output = output
	}
	code := runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// TestDocPatchFileBodyAtMultiKilobyteRoundTripsExactly is the SIZE arm.
//
// It asserts the whole multi-kilobyte body arrives under patch.set BYTE-MEANING
// IDENTICAL — reflect.DeepEqual against the decoded fixture — rather than
// spot-checking two keys, and it RECORDS the measured sizes with t.Logf so the
// evidence carries numbers instead of adjectives.
//
// DISCRIMINATING CONTROL (run by hand, reproduced in the PR body): in run.go's
// --file arm, after the os.ReadFile, insert
//
//	if len(raw) > 4096 { raw = raw[:4096] }
//
// Every arm in doc_patch_file_body_e2e_test.go stays GREEN — their fixture is
// 174 bytes, so the clip never fires on them. This arm reds. That is the exact
// gap the row filed: a sub-kilobyte fixture cannot see a defect that only
// exists at size.
func TestDocPatchFileBodyAtMultiKilobyteRoundTripsExactly(t *testing.T) {
	raw, want := buildLargeNestedBody(t)

	// ---- the fixture's own measurements, recorded not described -------------
	depth := jsonDepth(want)
	blocksJSON, err := json.Marshal(want["blocks"])
	if err != nil {
		t.Fatalf("marshal blocks for the --set comparison: %v", err)
	}
	setArg := "blocks:=" + string(blocksJSON)

	t.Logf("FIXTURE BYTES: %d", len(raw))
	t.Logf("FIXTURE JSON DEPTH: %d", depth)
	t.Logf("theNestedBody BYTES (the small fixture this arm exists to exceed): %d", len(theNestedBody))
	t.Logf("EQUIVALENT SINGLE --set ARGUMENT BYTES (blocks:=<json>): %d", len(setArg))

	if len(raw) < largeBodyMinBytes {
		t.Fatalf("fixture is %d bytes, want >= %d — this arm exists to test the flag AT SIZE; "+
			"below the floor it is just a slower copy of TestDocPatchFileBodyNestsUnderSet",
			len(raw), largeBodyMinBytes)
	}
	if depth < largeBodyMinDepth {
		t.Fatalf("fixture depth is %d, want >= %d — a large FLAT body does not reproduce the "+
			"payload class that forced the fallback", depth, largeBodyMinDepth)
	}
	if len(raw) <= len(theNestedBody)*8 {
		t.Fatalf("fixture (%d B) is not meaningfully larger than theNestedBody (%d B)",
			len(raw), len(theNestedBody))
	}

	// ---- the round trip -----------------------------------------------------
	h := newFilePatchHarness(t, true)
	code, _, stderr := h.run("doc", "patch", "task", thePatchedRow, "--file", writeBody(t, string(raw)))
	if code != exitOK {
		t.Fatalf("exit = %d, stderr=%s — the multi-kilobyte smoke never reached the wire", code, stderr)
	}

	t.Logf("WIRE BODY BYTES (what the fake instance received): %d", len(h.sent[0]))
	if len(h.sent[0]) < len(raw) {
		t.Errorf("the wire body (%d B) is SMALLER than the fixture (%d B) — something between "+
			"os.ReadFile and the transport dropped bytes", len(h.sent[0]), len(raw))
	}

	patch := h.mutation("patch")
	set, ok := patch["set"].(map[string]any)
	if !ok {
		t.Fatalf("patch.set is not an object: %#v", patch["set"])
	}

	// The whole payload, not a sample of it. This is the assertion the 233-byte
	// arms cannot make meaningfully and the one a truncating edit reds.
	if !reflect.DeepEqual(set, want) {
		gotBlocks, _ := set["blocks"].([]any)
		wantBlocks, _ := want["blocks"].([]any)
		t.Fatalf("patch.set is not the fixture: got %d blocks, want %d; got keys %v, want keys %v — "+
			"a multi-kilobyte body did not survive the file -> set routing intact",
			len(gotBlocks), len(wantBlocks), fixtureKeys(set), fixtureKeys(want))
	}

	// Both directions, as the small arm does: nothing leaked up beside `set`.
	for key := range want {
		if _, sibling := patch[key]; sibling {
			t.Errorf("%q is a SIBLING of patch.set at multi-kilobyte size", key)
		}
	}
}

// fixtureKeys is a stable key list for failure messages only.
func fixtureKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// TestDocPatchFileDryRunBuildsTheRequestAndDoesNotSendIt is the DRY-RUN arm.
//
// It asserts BOTH halves the row named:
//
//	BUILT     — the previewed request carries the method, the resolved mutate
//	            URL, and a body whose patch.set is the whole multi-kilobyte
//	            fixture. A dry run that printed nothing, or that printed a body
//	            with an empty set, would fail here.
//	NOT SENT  — the fake instance recorded ZERO mutations.
//
// POSITIVE CONTROL, and the reason this arm cannot pass by never reaching the
// wire: the control runs on the SAME harness instance, against the SAME running
// httptest server, with the SAME arguments, differing only in globals.dryRun.
// After it, that same recorder holds exactly one mutation. So "zero mutations"
// during the dry run is a property of the dry run, not of a harness that never
// observes sends at all. A separate harness would leave that alternative open.
//
// RED PROOF (run by hand, reproduced in the PR body): delete the
// `if g.dryRun { return dryRun(...) }` branch in runCommand (run.go ~621). The
// NOT-SENT assertion reds with 1 mutation recorded where 0 was required, and
// every other test in this package stays green.
func TestDocPatchFileDryRunBuildsTheRequestAndDoesNotSendIt(t *testing.T) {
	raw, want := buildLargeNestedBody(t)
	path := writeBody(t, string(raw))

	h := newFilePatchHarness(t, true)

	// ---- the dry run --------------------------------------------------------
	code, stdout, stderr := h.runWithGlobals(globals{dryRun: true}, "json",
		"doc", "patch", "task", thePatchedRow, "--file", path)
	if code != exitOK {
		t.Fatalf("dry-run exit = %d, want %d; stderr=%s", code, exitOK, stderr)
	}

	// NOT SENT.
	if len(h.sent) != 0 {
		t.Fatalf("--dry-run SENT %d mutation(s) — a dry run must build the request and stop: %v",
			len(h.sent), h.sent)
	}

	// It announced itself as a client-side preview, so a caller cannot mistake
	// it for a server-side validate-only.
	if !strings.Contains(stderr, "dry-run") {
		t.Errorf("dry-run printed no preview notice on stderr: %q", stderr)
	}

	// BUILT. -o json makes the preview one parseable document.
	var preview struct {
		Method string          `json:"method"`
		URL    string          `json:"url"`
		Body   json.RawMessage `json:"body"`
	}
	if err := json.Unmarshal([]byte(stdout), &preview); err != nil {
		t.Fatalf("dry-run preview is not JSON: %v\nstdout=%s", err, stdout)
	}
	if preview.Method != "POST" {
		t.Errorf("preview method = %q, want POST", preview.Method)
	}
	if !strings.Contains(preview.URL, "/v1/data/mutate/") {
		t.Errorf("preview url = %q, want the resolved mutate path", preview.URL)
	}
	if len(preview.Body) == 0 {
		t.Fatalf("dry-run previewed NO body — it did not build the request, it skipped it. stdout=%s", stdout)
	}
	t.Logf("DRY-RUN PREVIEWED BODY BYTES: %d (fixture %d B)", len(preview.Body), len(raw))

	var env struct {
		Mutations []struct {
			Patch map[string]any `json:"patch"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(preview.Body, &env); err != nil {
		t.Fatalf("previewed body is not a mutation envelope: %v\nbody=%s", err, preview.Body)
	}
	if len(env.Mutations) != 1 {
		t.Fatalf("previewed body has %d mutations, want 1: %s", len(env.Mutations), preview.Body)
	}
	set, ok := env.Mutations[0].Patch["set"].(map[string]any)
	if !ok {
		t.Fatalf("previewed patch.set is not an object: %#v", env.Mutations[0].Patch["set"])
	}
	if !reflect.DeepEqual(set, want) {
		t.Fatalf("the dry run previewed a body that is NOT the fixture — a preview that does not "+
			"match what a real send would carry is worse than no preview. got keys %v, want keys %v",
			fixtureKeys(set), fixtureKeys(want))
	}

	// ---- POSITIVE CONTROL: same harness, same server, same args, wet --------
	code, _, stderr = h.runWithGlobals(globals{}, "json",
		"doc", "patch", "task", thePatchedRow, "--file", path)
	if code != exitOK {
		t.Fatalf("control (no --dry-run) exit = %d, stderr=%s", code, stderr)
	}
	if len(h.sent) != 1 {
		t.Fatalf("POSITIVE CONTROL FAILED: the same harness recorded %d mutations for a real send, "+
			"want 1. The zero above therefore measured nothing — this harness does not observe "+
			"sends at all.", len(h.sent))
	}
	t.Logf("POSITIVE CONTROL: the same recorder saw %d mutation on the wet run (%d bytes)",
		len(h.sent), len(h.sent[0]))
}
