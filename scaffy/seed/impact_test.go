package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// repoRoot is the module root relative to this package's test working
// directory (go test runs each package in its own source dir).
const repoRoot = "../.."

// corpusDir is the real corpus, addressed from this package's test cwd.
const corpusDir = "../commands"

// TestDeriverPkgRelIsThisPackage guards the one path in impact.go that cannot
// be computed at runtime. A binary does not know where its source lived, so
// deriverPkgRel is written down — and this test asserts it still points at the
// package that actually defines deriveAll. Move this program and the test reds
// rather than the closure silently walking the wrong entry point.
func TestDeriverPkgRelIsThisPackage(t *testing.T) {
	src, err := os.ReadFile(filepath.Join(repoRoot, deriverPkgRel, "main.go"))
	if err != nil {
		t.Fatalf("deriverPkgRel %q does not hold main.go: %v", deriverPkgRel, err)
	}
	if !bytes.Contains(src, []byte("func deriveAll(")) {
		t.Fatalf("deriverPkgRel %q holds a main.go that does not define deriveAll — the import closure would start from the wrong package", deriverPkgRel)
	}
}

// TestReadPathsAreDerivedFromSource checks the predicate against the real repo:
// the corpus glob comes from the same two identifiers deriveAll globs, and the
// closure finds internal/scaffy without anybody naming it.
func TestReadPathsAreDerivedFromSource(t *testing.T) {
	rp, err := deriverReadPaths(repoRoot, corpusDir)
	if err != nil {
		t.Fatalf("deriverReadPaths: %v", err)
	}
	if want := "../commands/*.scaffy"; rp.corpusGlob != want {
		t.Errorf("corpusGlob = %q, want %q", rp.corpusGlob, want)
	}
	// POSITIVE CONTROL: the closure must actually find something. An empty
	// pkgDirs would make every deriver-change assertion below vacuously quiet,
	// and an empty read is never evidence until the key set is printed.
	t.Logf("closure pkgDirs = %v", rp.pkgDirs)
	if len(rp.pkgDirs) == 0 {
		t.Fatal("closure returned ZERO packages — every deriver assertion downstream would be vacuous")
	}
	for _, want := range []string{"scaffy/seed", "internal/scaffy"} {
		found := false
		for _, d := range rp.pkgDirs {
			if d == want {
				found = true
			}
		}
		if !found {
			t.Errorf("closure %v does not contain %q", rp.pkgDirs, want)
		}
	}
}

// TestClosureIsAPredicateNotASnapshot is the load-bearing proof for "derive the
// path set, do not hand-list it". It builds a synthetic module whose entry
// package imports a package NOBODY IN THIS REPO HAS EVER NAMED, and asserts the
// closure picks it up — with zero edits to impact.go. A hand-written list
// cannot pass this test; that is the whole difference.
func TestClosureIsAPredicateNotASnapshot(t *testing.T) {
	root := t.TempDir()
	write := func(rel, body string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("go.mod", "module example.com/synth\n\ngo 1.25.0\n")
	write("scaffy/seed/main.go", "package main\n\nimport (\n\t\"example.com/synth/internal/brandnew\"\n)\n\nfunc main() { _ = brandnew.X }\n")
	// A SECOND hop, so the test proves transitivity and not just direct imports.
	write("internal/brandnew/a.go", "package brandnew\n\nimport \"example.com/synth/internal/deeper\"\n\nvar X = deeper.Y\n")
	write("internal/deeper/b.go", "package deeper\n\nvar Y = 1\n")
	// A test file importing a package that must NOT enter the closure: a test's
	// imports are not part of derivation.
	write("scaffy/seed/main_test.go", "package main\n\nimport _ \"example.com/synth/internal/onlyfortests\"\n")
	write("internal/onlyfortests/c.go", "package onlyfortests\n")

	got, err := firstPartyClosure(root, "example.com/synth", "example.com/synth/scaffy/seed")
	if err != nil {
		t.Fatalf("firstPartyClosure: %v", err)
	}
	t.Logf("synthetic closure = %v", got)
	want := []string{"internal/brandnew", "internal/deeper", "scaffy/seed"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("closure = %v, want %v", got, want)
	}
}

// TestIntersectPredicate covers the file-level half of the read-path decision.
func TestIntersectPredicate(t *testing.T) {
	rp := readPaths{
		corpusGlob: "scaffy/commands/*.scaffy",
		pkgDirs:    []string{"internal/scaffy", "scaffy/seed"},
	}
	cases := []struct {
		name            string
		changed         []string
		corpus, deriver int
	}{
		{"one corpus file", []string{"scaffy/commands/add-cli-verb.scaffy"}, 1, 0},
		{"deriver source", []string{"internal/scaffy/parse.go"}, 0, 1},
		{"deriver test file does not count", []string{"internal/scaffy/parse_test.go"}, 0, 0},
		{"nested under corpus dir is not globbed", []string{"scaffy/commands/sub/x.scaffy"}, 0, 0},
		{"unrelated paths", []string{"README.md", "api/lib/barkpark/router.ex", "js/sdk/src/index.ts"}, 0, 0},
		{"package outside the closure", []string{"internal/cli/scaffy_cmd.go"}, 0, 0},
		{"mixed", []string{"README.md", "scaffy/commands/add-plugin.scaffy", "internal/scaffy/lint.go"}, 1, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := rp.intersect(tc.changed)
			if len(got.corpus) != tc.corpus || len(got.deriver) != tc.deriver {
				t.Fatalf("intersect(%v) = corpus %v, deriver %v; want %d/%d",
					tc.changed, got.corpus, got.deriver, tc.corpus, tc.deriver)
			}
		})
	}
}

// servedEnvelope renders the exact envelope guerrilla serves for a payload set.
func servedEnvelope(t *testing.T, payloads []*payload) map[string]any {
	t.Helper()
	docs := make([]map[string]any, 0, len(payloads))
	for _, p := range payloads {
		docs = append(docs, map[string]any{
			"_id": p.ID, "title": p.Title, "description": p.Description,
			"concept": p.Concept, "variant": p.Variant, "domain": p.Domain,
			"direction": p.Direction, "tags": p.Tags, "source": p.Source,
		})
	}
	return map[string]any{"result": map[string]any{"documents": docs}}
}

// fixtureServer serves one envelope and points serverURL() at itself.
func fixtureServer(t *testing.T, env map[string]any) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(env)
	}))
	t.Cleanup(srv.Close)
	pointSeedAt(t, srv.URL)
	return srv
}

// pointSeedAt makes serverURL() resolve to host for this test only, via the
// same XDG config seam the workflow's hermetic self-test uses.
func pointSeedAt(t *testing.T, host string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "barkpark"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"server":%q}`, host)
	if err := os.WriteFile(filepath.Join(dir, "barkpark", "config.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", dir)
}

func changedFile(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "changed.txt")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func runImpactFor(t *testing.T, changedPath string) (int, string, string) {
	t.Helper()
	var out, errBuf bytes.Buffer
	code := runImpact(&out, &errBuf, repoRoot, corpusDir, changedPath)
	return code, out.String(), errBuf.String()
}

// corpusPayloads derives the real corpus once per test.
func corpusPayloads(t *testing.T) []*payload {
	t.Helper()
	p, err := deriveAll(corpusDir)
	if err != nil {
		t.Fatalf("deriveAll(%s): %v", corpusDir, err)
	}
	if len(p) == 0 {
		t.Fatal("derived ZERO payloads — every assertion below would be vacuous")
	}
	return p
}

// ── c0 MUTATION ARM, SECOND HALF ────────────────────────────────────────────
// A PR that touches nothing the deriver reads must surface NOTHING. This is the
// half that decides whether the notice survives a week: an all-clear on every
// PR is noise, and noise gets filtered.
func TestNoticeIsSilentOnAPRThatTouchesNoReadPath(t *testing.T) {
	// THE CONTROL IS A CATALOG THAT IS GENUINELY DRIFTED, not an empty one. An
	// empty catalog would red this test through the CANNOT READ door, which
	// proves nothing about the predicate; a catalog serving all 22 documents
	// with one of them stale means the ONLY thing keeping this run quiet is the
	// read-path intersection. Delete the predicate and this test renders a
	// DRIFT notice on a PR that touched a markdown file.
	payloads := corpusPayloads(t)
	env := servedEnvelope(t, payloads)
	env["result"].(map[string]any)["documents"].([]map[string]any)[0]["source"] = "STALE SERVED BYTES"
	fixtureServer(t, env)

	code, stdout, stderr := runImpactFor(t, changedFile(t,
		"README.md",
		"api/lib/barkpark/content/mutations.ex",
		"internal/cli/scaffy_cmd.go", // NOT in the deriver's import closure
		"internal/scaffy/parse_test.go",
		"docs/cards/cli.md",
	))
	if code != impactQuiet {
		t.Fatalf("exit = %d, want %d (QUIET)\nstdout:\n%s", code, impactQuiet, stdout)
	}
	if stdout != "" {
		t.Fatalf("a PR touching no read path SURFACED something:\n%s", stdout)
	}
	t.Logf("stderr (not a rendered surface): %s", strings.TrimSpace(stderr))
}

// ── c0 MUTATION ARM, FIRST HALF ─────────────────────────────────────────────
// A PR touching ONE command surfaces exactly that command — not the other 21,
// and not a pre-existing drift the author did not cause.
func TestNoticeNamesExactlyTheTouchedCommand(t *testing.T) {
	payloads := corpusPayloads(t)
	target := payloads[0]
	other := payloads[1]

	// Serve a catalog where the TOUCHED command has drifted AND an untouched
	// one has drifted too (pre-existing). Only the touched one may be billed.
	env := servedEnvelope(t, payloads)
	docs := env["result"].(map[string]any)["documents"].([]map[string]any)
	for _, d := range docs {
		if d["_id"] == target.ID || d["_id"] == other.ID {
			d["source"] = "STALE SERVED BYTES"
		}
	}
	fixtureServer(t, env)

	code, stdout, _ := runImpactFor(t, changedFile(t, "README.md", filepath.ToSlash(target.File)))
	if code != impactNotice {
		t.Fatalf("exit = %d, want %d (NOTICE)\nstdout:\n%s", code, impactNotice, stdout)
	}
	if !strings.Contains(stdout, target.ID) {
		t.Fatalf("notice does not name the touched command %q:\n%s", target.ID, stdout)
	}
	if strings.Contains(stdout, other.ID) {
		t.Fatalf("notice billed the UNTOUCHED, pre-existing drift %q to this PR:\n%s", other.ID, stdout)
	}
	if !strings.Contains(stdout, "NOT BILLED TO THIS PR") {
		t.Fatalf("pre-existing drift was neither billed nor disclosed:\n%s", stdout)
	}
	// It must say who can discharge it.
	for _, want := range []string{"WHO CAN DISCHARGE IT", "repair = true", "BARKPARK_SEED_TOKEN"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("notice is missing %q:\n%s", want, stdout)
		}
	}
	// And it must name the field that will diverge.
	if !strings.Contains(stdout, "source") {
		t.Errorf("notice does not name the divergent field:\n%s", stdout)
	}
}

// A deriver change moves metadata with every corpus byte untouched. The notice
// must still fire: that class is what made the post-merge gate blind once.
func TestNoticeFiresOnADeriverChangeWithNoCorpusEdit(t *testing.T) {
	payloads := corpusPayloads(t)
	env := servedEnvelope(t, payloads)
	docs := env["result"].(map[string]any)["documents"].([]map[string]any)
	docs[0]["direction"] = "wrong-direction" // source identical, metadata moved
	fixtureServer(t, env)

	code, stdout, _ := runImpactFor(t, changedFile(t, "internal/scaffy/parse.go"))
	if code != impactNotice {
		t.Fatalf("exit = %d, want %d (NOTICE)\nstdout:\n%s", code, impactNotice, stdout)
	}
	if !strings.Contains(stdout, payloads[0].ID) || !strings.Contains(stdout, "direction") {
		t.Fatalf("notice did not name the metadata-only drift:\n%s", stdout)
	}
	if !strings.Contains(stdout, "internal/scaffy/parse.go") {
		t.Fatalf("notice did not say WHICH deriver file put every command in scope:\n%s", stdout)
	}
}

// ── c1: IN SYNC must not fire ───────────────────────────────────────────────
// The diff touches a read path, the catalog is read, and the head tree still
// matches it. Nothing may be rendered — a notice that fires on an in-sync
// catalog is the cry-wolf that kills the signal.
func TestNoNoticeWhenTheCatalogIsAlreadyInSync(t *testing.T) {
	payloads := corpusPayloads(t)
	fixtureServer(t, servedEnvelope(t, payloads))

	code, stdout, stderr := runImpactFor(t, changedFile(t, filepath.ToSlash(payloads[0].File), "internal/scaffy/lint.go"))
	if code != impactQuiet {
		t.Fatalf("exit = %d, want %d (QUIET on an in-sync catalog)\nstdout:\n%s", code, impactQuiet, stdout)
	}
	if stdout != "" {
		t.Fatalf("fired on an IN-SYNC catalog:\n%s", stdout)
	}
	if !strings.Contains(stderr, "head tree matches") {
		t.Errorf("stderr did not record that the catalog was actually READ: %q", stderr)
	}
}

// ── c1 MUTATION ARM: unreachable host ───────────────────────────────────────
// Point it at a host nothing answers on. It must say CANNOT READ, take a
// distinct exit code, and must NOT render as a clean bill of health.
func TestUnreachableHostSaysCannotReadAndIsDistinguishableFromInSync(t *testing.T) {
	// Shrink the retry so the test does not sleep 1.5s (these are vars for
	// exactly this reason — see fetchAttempts' comment).
	oldA, oldB := fetchAttempts, fetchBackoff
	fetchAttempts, fetchBackoff = 2, time.Millisecond
	t.Cleanup(func() { fetchAttempts, fetchBackoff = oldA, oldB })

	// A server that existed and is now closed: the port refuses connections.
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := dead.URL
	dead.Close()
	pointSeedAt(t, url)

	payloads := corpusPayloads(t)
	code, stdout, _ := runImpactFor(t, changedFile(t, filepath.ToSlash(payloads[0].File)))

	if code != impactCannotRead {
		t.Fatalf("exit = %d, want %d (CANNOT READ)\nstdout:\n%s", code, impactCannotRead, stdout)
	}
	if !strings.HasPrefix(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ") {
		t.Fatalf("unreachable host did not render as CANNOT READ:\n%s", stdout)
	}
	// THE DISTINGUISHABILITY ASSERTION IS ANCHORED ON THE VERDICT LINE, NOT ON
	// SUBSTRINGS ANYWHERE IN THE OUTPUT. The first draft of this test grepped
	// stdout for "no drift" and reddened on the CANNOT READ block's own prose —
	// which contains that phrase in order to REFUSE it. A retraction quotes
	// what it retracts, so a bare substring search cannot tell the claim from
	// its denial. The verdict is line 1 and the DRIFT banner is its own token.
	verdict := strings.SplitN(stdout, "\n", 2)[0]
	if verdict != "SCAFFY CATALOG IMPACT: CANNOT READ" {
		t.Errorf("verdict line = %q, want the CANNOT READ verdict", verdict)
	}
	if strings.Contains(stdout, "SCAFFY CATALOG IMPACT: DRIFT") || strings.Contains(stdout, "FIELDS THAT WILL DIVERGE") {
		t.Errorf("an unreachable host rendered a DRIFT notice:\n%s", stdout)
	}
	// And no MATCH/in-sync table line: the --check table's clean verdict must
	// never appear on a run that could not fetch anything.
	if strings.Contains(stdout, "MATCH — catalog in sync") {
		t.Errorf("an unreachable host rendered the in-sync verdict:\n%s", stdout)
	}
	// And it must differ from the QUIET path in BOTH channels, not just prose.
	if code == impactQuiet || code == impactNotice {
		t.Errorf("CANNOT READ shares an exit code with another verdict")
	}
	t.Logf("CANNOT READ rendered:\n%s", stdout)
}

// ── c1: a served catalog that answers with ZERO documents ───────────────────
// A zero from an empty page looks exactly like a real zero. Comparing 22 local
// commands against nothing would print 22 MISSING rows — a huge confident
// notice built on a read that told us nothing. It must take CANNOT READ.
func TestZeroServedDocumentsIsCannotReadNotTwentyTwoMissing(t *testing.T) {
	fixtureServer(t, map[string]any{"result": map[string]any{"documents": []any{}}})
	payloads := corpusPayloads(t)

	code, stdout, _ := runImpactFor(t, changedFile(t, filepath.ToSlash(payloads[0].File)))
	if code != impactCannotRead {
		t.Fatalf("exit = %d, want %d (CANNOT READ)\nstdout:\n%s", code, impactCannotRead, stdout)
	}
	if !strings.Contains(stdout, "ZERO command documents") {
		t.Fatalf("zero served docs did not name itself:\n%s", stdout)
	}
	// Not a substring test on the word MISSING — the CANNOT READ prose names
	// that outcome in order to say it is REFUSING it, and grepping for a word
	// that looks like a verdict is how a count goes wrong. Assert the DRIFT
	// notice surface was never rendered at all.
	if strings.Contains(stdout, "SCAFFY CATALOG IMPACT: DRIFT") || strings.Contains(stdout, "FIELDS THAT WILL DIVERGE") {
		t.Fatalf("zero served docs rendered a DRIFT notice — a claim this read cannot support:\n%s", stdout)
	}
}

// ── c1: a deriver that produces zero commands ───────────────────────────────
func TestZeroDerivedCommandsIsCannotRead(t *testing.T) {
	fixtureServer(t, servedEnvelope(t, corpusPayloads(t)))
	empty := t.TempDir() // no .scaffy files at all

	var out, errBuf bytes.Buffer
	code := runImpact(&out, &errBuf, repoRoot, empty, changedFile(t, "internal/scaffy/parse.go"))
	if code != impactCannotRead {
		t.Fatalf("exit = %d, want %d (CANNOT READ)\nstdout:\n%s", code, impactCannotRead, out.String())
	}
	if !strings.Contains(out.String(), "CANNOT READ") {
		t.Fatalf("an empty corpus did not render CANNOT READ:\n%s", out.String())
	}
}

// ── The over-attribution guard, found by running the real thing ─────────────
// main's served catalog currently carries four SOURCE-ONLY drifts nobody
// re-seeded. This PR touches only scaffy/seed/*.go. The first version of
// buildNotice billed all four to it, because "a deriver change puts every
// command in scope" was true of derived metadata and false of `source`:
// `derive` copies the raw file bytes verbatim, so no derivation change can
// move that field. Handing an author four commands they did not touch is the
// same signal-death as firing on every PR, arriving by a different door.
func TestADeriverChangeIsNotBilledForSourceOnlyDrift(t *testing.T) {
	payloads := corpusPayloads(t)
	env := servedEnvelope(t, payloads)
	docs := env["result"].(map[string]any)["documents"].([]map[string]any)
	docs[0]["source"] = "STALE SERVED BYTES" // source-only: a corpus/re-seed fact
	docs[1]["source"] = "ALSO STALE"
	fixtureServer(t, env)

	code, stdout, stderr := runImpactFor(t, changedFile(t, "internal/scaffy/parse.go"))
	if code != impactQuiet {
		t.Fatalf("a deriver-only diff was billed for source-only drift: exit = %d, want %d\n%s", code, impactQuiet, stdout)
	}
	if stdout != "" {
		t.Fatalf("a deriver-only diff surfaced source-only drift:\n%s", stdout)
	}
	// CONTROL, and it must differ from the subject: the SAME catalog with a
	// METADATA divergence added must fire, or the test above is only proving
	// that the fixture never drifts.
	docs[2]["direction"] = "wrong-direction"
	fixtureServer(t, env)
	code, stdout, _ = runImpactFor(t, changedFile(t, "internal/scaffy/parse.go"))
	if code != impactNotice {
		t.Fatalf("control failed: a metadata divergence under a deriver change did NOT fire (exit %d)\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "direction") {
		t.Fatalf("control fired but did not name the metadata field:\n%s", stdout)
	}
	// And it must still not bill the two source-only rows.
	if strings.Contains(stdout, payloads[0].ID) || strings.Contains(stdout, payloads[1].ID) {
		t.Fatalf("control billed the source-only rows to a deriver change:\n%s", stdout)
	}
	if !strings.Contains(stdout, "NOT BILLED TO THIS PR") {
		t.Fatalf("the two source-only rows were neither billed nor disclosed:\n%s", stdout)
	}
	_ = stderr
}
