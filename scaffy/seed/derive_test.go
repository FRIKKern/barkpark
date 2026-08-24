package main

// Coverage for the DERIVATION half of scaffy/seed — weightedTags, deriveAll and
// serverURL — separate from main_test.go, which covers the fetch and the drift
// comparison.
//
// WHY THIS MATTERS MORE THAN ORDINARY UNIT TESTS. The drift gate's hermetic
// self-test builds its fixture BY RUNNING `go run ./scaffy/seed --out`, i.e.
// from the very code under test, then asserts the checker agrees with it. That
// proves the COMPARISON works; it cannot prove the DERIVATION is right. If
// derive regressed identically on both sides — say weightedTags started
// emitting the wrong strengths — the fixture would carry the same wrong values
// as the payloads, both self-test arms would pass, the real audit compares only
// sha256(source) (untouched by such a bug), and the gate would go GREEN on a
// genuine regression. These tests assert the derivation against SPELLED-OUT
// expectations instead of against itself.
//
// FILE SPLIT IS DELIBERATE: main_test.go arrives on a different branch, so
// every helper here carries a distinct name. Two test files that each defined a
// `sha256hex` would compile fine on their own branches and break the package
// the moment both landed — green separately, broken together.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// corpusCommandsDir is the real corpus, relative to this package directory.
const corpusCommandsDir = "../commands"

// stageCorpusCopies copies n real corpus files into a fresh temp dir and
// returns it. Using REAL files means the fixtures are guaranteed to satisfy
// scaffy.ValidateFile — a hand-authored .scaffy would be testing my guess at
// the validator, not the deriver.
func stageCorpusCopies(t *testing.T, names ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, n := range names {
		src, err := os.ReadFile(filepath.Join(corpusCommandsDir, n))
		if err != nil {
			t.Fatalf("reading corpus fixture %s: %v", n, err)
		}
		if err := os.WriteFile(filepath.Join(dir, n), src, 0o644); err != nil {
			t.Fatalf("staging %s: %v", n, err)
		}
	}
	return dir
}

// ── weightedTags: the E3 publish-wall contract ───────────────────────────────

func TestWeightedTagsDescendingLadder(t *testing.T) {
	got, err := weightedTags("f.scaffy", "alpha, beta, gamma")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 tags, got %d", len(got))
	}
	// Strengths are spelled out, not recomputed from the formula under test.
	wantStrength := []int{90, 80, 70}
	wantTag := []string{"alpha", "beta", "gamma"}
	for i := range got {
		if got[i].Tag != wantTag[i] {
			t.Errorf("tag %d: got %q want %q", i, got[i].Tag, wantTag[i])
		}
		if got[i].Strength != wantStrength[i] {
			t.Errorf("tag %d (%s): strength %d want %d", i, got[i].Tag, got[i].Strength, wantStrength[i])
		}
		if got[i].Rationale == "" {
			t.Errorf("tag %d (%s): empty rationale — the publish wall requires one", i, got[i].Tag)
		}
	}
}

func TestWeightedTagsStrengthsAreDistinct(t *testing.T) {
	got, err := weightedTags("f.scaffy", "a, b, c, d, e")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	seen := map[int]string{}
	for _, w := range got {
		if prev, dup := seen[w.Strength]; dup {
			t.Fatalf("strength %d used by both %q and %q — the publish wall requires distinct strengths",
				w.Strength, prev, w.Tag)
		}
		seen[w.Strength] = w.Tag
	}
}

func TestWeightedTagsTrimsWhitespace(t *testing.T) {
	got, err := weightedTags("f.scaffy", "  spaced  ,\tnext\t")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got[0].Tag != "spaced" || got[1].Tag != "next" {
		t.Fatalf("expected trimmed names, got %q and %q", got[0].Tag, got[1].Tag)
	}
}

func TestWeightedTagsRefusals(t *testing.T) {
	for _, tc := range []struct {
		name, raw, wantSubstr string
	}{
		{"empty entry", "a,,b", "is empty"},
		{"trailing comma", "a,b,", "is empty"},
		{"duplicate tag", "dup, other, dup", "repeats"},
		{"all whitespace", "   ", "is empty"},
		{"ten tags exhausts the ladder", "a,b,c,d,e,f,g,h,i,j", "strengths exhausted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := weightedTags("f.scaffy", tc.raw)
			if err == nil {
				t.Fatalf("expected a refusal for %q", tc.raw)
			}
			if !strings.Contains(err.Error(), tc.wantSubstr) {
				t.Fatalf("error should mention %q, got: %v", tc.wantSubstr, err)
			}
		})
	}
}

// Nine tags is the last legal ladder rung (90..10); ten exhausts it. Pinned
// because the boundary is one off-by-one away from silently emitting a
// zero-or-negative strength.
func TestWeightedTagsNineIsTheLastLegalRung(t *testing.T) {
	got, err := weightedTags("f.scaffy", "a,b,c,d,e,f,g,h,i")
	if err != nil {
		t.Fatalf("nine tags must be legal, got: %v", err)
	}
	if len(got) != 9 {
		t.Fatalf("expected 9 tags, got %d", len(got))
	}
	if last := got[8].Strength; last != 10 {
		t.Fatalf("ninth strength should be 10, got %d", last)
	}
}

// ── deriveAll: emptiness and the D46 uniqueness tripwire ─────────────────────

// An empty corpus must ERROR. A deriver that returns zero payloads without
// complaint would let `--check` compare nothing against the served catalog and
// call it agreement — the "gate satisfiable by emptiness" shape.
func TestDeriveAllRefusesAnEmptyCorpus(t *testing.T) {
	dir := t.TempDir()
	_, err := deriveAll(dir)
	if err == nil {
		t.Fatal("an empty corpus MUST error, never derive zero payloads successfully")
	}
	if !strings.Contains(err.Error(), "no .scaffy files") {
		t.Fatalf("error should name the empty corpus, got: %v", err)
	}
}

func TestDeriveAllRefusesADirectoryThatDoesNotExist(t *testing.T) {
	if _, err := deriveAll(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("a missing corpus directory MUST error")
	}
}

// D46: two files deriving the same domain--concept--variant id must be caught.
// A duplicate id would silently collapse two commands into one served document.
func TestDeriveAllCatchesDuplicateIDs(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy")
	src, err := os.ReadFile(filepath.Join(dir, "add-oban-worker.scaffy"))
	if err != nil {
		t.Fatal(err)
	}
	// Same content under a second filename -> same derived _id.
	if err := os.WriteFile(filepath.Join(dir, "zz-copy.scaffy"), src, 0o644); err != nil {
		t.Fatal(err)
	}

	_, err = deriveAll(dir)
	if err == nil {
		t.Fatal("two files deriving the same _id MUST error (D46 uniqueness)")
	}
	if !strings.Contains(err.Error(), "collides") {
		t.Fatalf("error should name the collision, got: %v", err)
	}
}

// The happy path, asserted on fields the drift comparison never checks — the
// point being that these are seeded and then never verified again.
func TestDeriveAllProducesAFullyPopulatedPayload(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy")
	got, err := deriveAll(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 payload, got %d", len(got))
	}
	p := got[0]
	if p.ID != "barkpark--oban-worker--cron" {
		t.Errorf("_id: got %q want %q", p.ID, "barkpark--oban-worker--cron")
	}
	for _, f := range []struct{ name, val string }{
		{"title", p.Title}, {"description", p.Description}, {"concept", p.Concept},
		{"variant", p.Variant}, {"domain", p.Domain}, {"direction", p.Direction},
		{"source", p.Source}, {"file", p.File},
	} {
		if strings.TrimSpace(f.val) == "" {
			t.Errorf("%s is empty — a hole must be an error, never a silently-empty field", f.name)
		}
	}
	if len(p.Tags) == 0 {
		t.Error("tags are empty — the publish wall would refuse this document")
	}
	// The id is assembled from three header fields; assert the composition
	// rather than trusting the single equality above.
	if want := p.Domain + "--" + p.Concept + "--" + p.Variant; p.ID != want {
		t.Errorf("_id %q is not domain--concept--variant (%q)", p.ID, want)
	}
}

// A malformed .scaffy must stop the whole run, not be skipped. Seeding a
// partial corpus would look like MISSING rows on the served side.
//
// THIS ASSERTS WHICH ARM REFUSED, not merely that something did. An earlier
// version checked only `err != nil` and it did NOT catch a deriveAll that
// skipped validation findings: with the validation arm disabled, derive() still
// failed a few lines later on the missing headers, so the test passed for a
// reason it never named. Pinning the validation arm's own message is what makes
// the assertion mean what its name claims.
func TestDeriveAllRefusesTheWholeRunOnOneInvalidFile(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy")
	if err := os.WriteFile(filepath.Join(dir, "broken.scaffy"), []byte("this is not a scaffy file\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := deriveAll(dir)
	if err == nil {
		t.Fatal("one invalid file MUST fail the whole derivation, never be skipped")
	}
	if !strings.Contains(err.Error(), "validation findings") {
		t.Fatalf("the VALIDATION arm must be what refuses (so a bypassed validator is caught, "+
			"rather than derive() failing later for its own reasons); got: %v", err)
	}
}

// ── serverURL: the seam the gate's hermetic self-test depends on ─────────────

func TestServerURLFallsBackToTheDefaultHost(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // exists, but holds no config
	if got := serverURL(); got != defaultServer {
		t.Fatalf("with no config the host must be %q, got %q", defaultServer, got)
	}
}

// The drift workflow's self-test overrides the host through exactly this seam.
// If it stopped being honoured, the self-test would silently start auditing
// PRODUCTION instead of its fixture and could never be INCONCLUSIVE-free.
func TestServerURLHonoursTheConfigOverride(t *testing.T) {
	xdg := t.TempDir()
	if err := os.MkdirAll(filepath.Join(xdg, "barkpark"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xdg, "barkpark", "config.json"),
		[]byte(`{"server":"http://127.0.0.1:8765"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", xdg)
	if got := serverURL(); got != "http://127.0.0.1:8765" {
		t.Fatalf("config override not honoured: got %q", got)
	}
}

func TestServerURLTrimsATrailingSlash(t *testing.T) {
	xdg := t.TempDir()
	if err := os.MkdirAll(filepath.Join(xdg, "barkpark"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xdg, "barkpark", "config.json"),
		[]byte(`{"server":"http://example.test/"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", xdg)
	if got := serverURL(); got != "http://example.test" {
		t.Fatalf("trailing slash not trimmed: got %q — the fetch URL would carry a double slash", got)
	}
}

// A malformed or empty config must fall back, not crash and not yield "".
func TestServerURLFallsBackOnAnUnusableConfig(t *testing.T) {
	for _, tc := range []struct{ name, body string }{
		{"malformed json", `{not json`},
		{"empty server field", `{"server":""}`},
		{"whitespace server field", `{"server":"   "}`},
		{"no server key", `{"other":1}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			xdg := t.TempDir()
			if err := os.MkdirAll(filepath.Join(xdg, "barkpark"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(xdg, "barkpark", "config.json"), []byte(tc.body), 0o644); err != nil {
				t.Fatal(err)
			}
			t.Setenv("XDG_CONFIG_HOME", xdg)
			if got := serverURL(); got != defaultServer {
				t.Fatalf("expected fallback to %q, got %q", defaultServer, got)
			}
		})
	}
}

// ── sha8: the drift table's short digest ─────────────────────────────────────

func TestSha8RendersAMissingSideAsADash(t *testing.T) {
	if got := sha8(""); got != "-" {
		t.Fatalf("an absent digest must render as a dash, got %q", got)
	}
	if got := sha8("abcdef0123456789"); got != "abcdef01" {
		t.Fatalf("expected the first 8 chars, got %q", got)
	}
	if got := sha8("abc"); got != "abc" {
		t.Fatalf("a short digest must pass through, got %q", got)
	}
}

// ── run(): the --out emitter, and the filename contract repair.sh depends on ──

// THE CROSS-COMPONENT CONTRACT NOTHING ELSE CHECKS. scaffy/seed/repair.sh
// resolves each drifted command's payload as "$PAYLOAD_DIR/$id.json". That
// filename is produced HERE, and no test on either side pins the agreement — a
// rename in run() would surface only as repair.sh refusing every id with "has
// no derived payload", at the moment of an actual production repair.
func TestRunEmitsOneFilePerIDUsingTheNameRepairResolves(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy", "add-plugin.scaffy")
	out := filepath.Join(t.TempDir(), "payloads")

	if err := run(dir, out); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	payloads, err := deriveAll(dir)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(payloads) {
		t.Fatalf("expected %d emitted files, got %d", len(payloads), len(entries))
	}
	for _, p := range payloads {
		// Exactly the path repair.sh builds.
		want := filepath.Join(out, p.ID+".json")
		if _, err := os.Stat(want); err != nil {
			t.Fatalf("repair.sh resolves $PAYLOAD_DIR/$id.json; %s is missing: %v", want, err)
		}
	}
}

// A local filesystem path must never reach production content. payload.File
// carries `json:"-"` for exactly this reason, and the repair arm posts the
// emitted body VERBATIM inside createOrReplace — so a leak here would be
// published, not merely written to disk.
func TestRunDoesNotEmitTheLocalFilePath(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy")
	out := filepath.Join(t.TempDir(), "payloads")
	if err := run(dir, out); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(out, "barkpark--oban-worker--cron.json"))
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("emitted payload is not valid JSON: %v", err)
	}
	for _, banned := range []string{"File", "file", "-"} {
		if _, present := body[banned]; present {
			t.Fatalf("emitted payload carries %q — a local path must never reach published content:\n%s", banned, raw)
		}
	}
	if strings.Contains(string(raw), ".scaffy") {
		// The SOURCE legitimately contains the file's text, but the path itself
		// should not appear as a value outside it; catch an accidental re-add.
		if strings.Contains(string(raw), dir) {
			t.Fatalf("emitted payload leaks the staging directory path %q", dir)
		}
	}

	// The nine body fields the document model needs must all be present.
	for _, k := range []string{"_id", "title", "description", "concept", "variant", "domain", "direction", "tags", "source"} {
		if _, ok := body[k]; !ok {
			t.Errorf("emitted payload is missing %q", k)
		}
	}
}

func TestRunCreatesTheOutputDirectory(t *testing.T) {
	dir := stageCorpusCopies(t, "add-oban-worker.scaffy")
	out := filepath.Join(t.TempDir(), "deep", "nested", "payloads")
	if err := run(dir, out); err != nil {
		t.Fatalf("run must create its output directory: %v", err)
	}
	if _, err := os.Stat(out); err != nil {
		t.Fatalf("output directory not created: %v", err)
	}
}

// A refusal upstream must emit NOTHING. A partial emit would leave a stale,
// inconsistent payload set that a later repair would happily post.
func TestRunEmitsNothingWhenDerivationRefuses(t *testing.T) {
	empty := t.TempDir()
	out := filepath.Join(t.TempDir(), "payloads")
	if err := run(empty, out); err == nil {
		t.Fatal("run over an empty corpus MUST error")
	}
	if _, err := os.Stat(out); err == nil {
		t.Fatal("run must not create an output directory when derivation refused — a partial emit is worse than none")
	}
}
