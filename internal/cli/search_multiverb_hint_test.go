package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// multiVerbSearchManifest is `search` AS THE LIVE SERVER DECLARES IT — many
// verbs, not one. This fixture is the whole point of the row.
//
// The pre-existing regression test (TestExecuteRealNounFreeTextInfersSoleVerb)
// pins the free-text correction against docs/cli/fixtures/full-manifest.json,
// whose `search` noun declares a SINGLE verb (`query`). That makes it green and
// UNREACHABLE from production: the real manifest declares thirteen verbs for
// `search`, so both `soleReadVerb`'s auto-run and `noVerbMsg`'s single-verb
// did-you-mean arm are structurally dead in the field, and `bp search "<phrase>"`
// answered with a bare verb list carrying no runnable fix.
//
// The three verbs below reproduce the live shape in miniature:
//   - query           non-writing, one required string arg  → the correction
//   - synonym-preview non-writing, one required string arg  → a second candidate,
//     so the suggestion must NOT pretend to be the only answer
//   - reindex         WRITING                               → never suggested
const multiVerbSearchManifest = `{
  "manifest_version": "1",
  "server": {"name": "t", "version": "0", "base_url": "http://127.0.0.1:1"},
  "auth_tier": "none",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "search", "summary": "Full-text search over documents."}],
  "commands": [
    {"id":"search.query","noun":"search","verb":"query","summary":"q","http":{"method":"GET","path_template":"/v1/search"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"search.synonym-preview","noun":"search","verb":"synonym-preview","summary":"p","http":{"method":"GET","path_template":"/v1/search/synonym-preview"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"search.reindex","noun":"search","verb":"reindex","summary":"r","http":{"method":"POST","path_template":"/v1/search/reindex"},"auth_tier":"none","args":[],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

func writeMultiVerbManifest(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "multiverb-manifest.json")
	if err := os.WriteFile(p, []byte(multiVerbSearchManifest), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return p
}

// TestFreeTextOnMultiVerbNounNamesRunnableFix is the non-vacuous half of the
// coverage. It asserts BOTH arms that made the original failure invisible:
// the message must name a runnable corrected command, AND the exit code must
// stay non-zero (a script reading only the code is the caller this defect cost).
func TestFreeTextOnMultiVerbNounNamesRunnableFix(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", writeMultiVerbManifest(t))
	// A closed port: the message is under test, not any HTTP round trip.
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")

	out, code := captureExecuteCode(t, []string{"search", "PDS crown proof"})

	// GUARD AGAINST A VACUOUS RUN: if the fixture ever collapses to one verb this
	// test silently becomes a duplicate of the single-verb path it exists to
	// complement, so prove the multi-verb branch is the one being exercised.
	if !strings.Contains(out, "synonym-preview") {
		t.Fatalf("fixture did not load as a MULTI-verb noun (no sibling verb in output); got:\n%s", out)
	}

	if code == exitOK {
		t.Errorf("exit code = %d (exitOK); a refused invocation must never exit 0 — that is the half a script cannot see", code)
	}
	if code != exitUsage {
		t.Errorf("exit code = %d, want %d (exitUsage)", code, exitUsage)
	}
	if strings.Contains(out, `unknown command "search"`) || strings.Contains(out, `unknown command \"search\"`) {
		t.Errorf("real noun `search` reported as unknown; got:\n%s", out)
	}
	if !strings.Contains(out, "barkpark search query") {
		t.Errorf("output never names the runnable fix `barkpark search query`; got:\n%s", out)
	}
	// The writing verb is never offered as a correction for a fat-fingered call.
	if strings.Contains(out, "did you mean `barkpark search reindex") {
		t.Errorf("suggested a WRITING verb as the correction; got:\n%s", out)
	}
}

// TestFreeTextHintRidesTheJSONEnvelope pins the machine half: `-o json` renders
// only the error envelope (no usage block), so the runnable correction has to be
// in the envelope's own `hint` field, and the exit code still non-zero.
func TestFreeTextHintRidesTheJSONEnvelope(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", writeMultiVerbManifest(t))
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")

	out, code := captureExecuteCode(t, []string{"search", "PDS crown proof", "-o", "json"})

	if code != exitUsage {
		t.Errorf("exit code = %d, want %d (exitUsage)", code, exitUsage)
	}
	if !strings.Contains(out, `"hint"`) || !strings.Contains(out, `barkpark search query`) {
		t.Errorf("json envelope carries no runnable hint; got:\n%s", out)
	}
	// The envelope must not look like a successful, empty search.
	if strings.Contains(out, `"documents"`) {
		t.Errorf("refusal envelope carries a documents key; got:\n%s", out)
	}
}

// TestMistypedVerbOnMultiVerbNounStillCorrectsTheVerb is the negative control:
// a SINGLE token that is a near-typo of a real verb is a mistyped VERB, not an
// argument, and must keep its Levenshtein correction rather than being handed
// the free-text suggestion.
func TestMistypedVerbOnMultiVerbNounStillCorrectsTheVerb(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", writeMultiVerbManifest(t))
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")

	out, code := captureExecuteCode(t, []string{"search", "quer"})

	if code != exitUsage {
		t.Errorf("exit code = %d, want %d (exitUsage)", code, exitUsage)
	}
	if strings.Contains(out, "contains spaces") {
		t.Errorf("a single-token typo took the argument-shaped path; got:\n%s", out)
	}
	if !strings.Contains(out, "barkpark search query") {
		t.Errorf("typo correction lost; got:\n%s", out)
	}
}

// TestFreeTextReadVerbsSkipsWritingAndMultiArgVerbs unit-pins the candidate
// rule itself, so a future verb added to a noun cannot quietly widen what the
// CLI offers to a caller who typed an argument where a verb belongs.
func TestFreeTextReadVerbsSkipsWritingAndMultiArgVerbs(t *testing.T) {
	m, _ := loadTreeFrom(t, writeMultiVerbManifest(t))
	n, ok := lookupNoun(m.Tree(), "search")
	if !ok {
		t.Fatal("fixture has no `search` noun")
	}
	got := freeTextReadVerbs(n)
	var names []string
	for _, c := range got {
		names = append(names, c.Verb)
	}
	want := "query,synonym-preview"
	if strings.Join(names, ",") != want {
		t.Errorf("freeTextReadVerbs = %v, want %s (manifest order, non-writing, one required string arg)", names, want)
	}
}

// TestArgShapedTokenIsAboutWhitespaceOnly keeps the trigger a structural fact
// about the token rather than a guess about intent.
func TestArgShapedTokenIsAboutWhitespaceOnly(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want bool
	}{
		{"PDS crown proof", true},
		{"two words", true},
		{"query", false},
		{"", false},
		{"synonym-preview", false},
		{"--flag", false},
	} {
		if got := argShapedToken(tc.in); got != tc.want {
			t.Errorf("argShapedToken(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}
