package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// multiVerbSearchManifest is a MULTI-VERB noun in the shape the live server
// declares — many verbs, not one. It exercises the GENERAL free-text
// correction: a real noun followed by an argument-shaped token gets a runnable
// suggestion and a REFUSAL (never a silent read through a verb the caller did
// not name).
//
// THE NOUN HERE IS `doc`, NOT `search`, AND THAT IS THE POINT. `search` used to
// take this same refusal path — which is exactly the defect
// task-c8e5f7f13385a1ea reports: `bp search "fork"` answered
// {"ok":false,"error":{"code":"usage",…}}, an envelope with no `documents` key
// that every results-reading caller saw as NOTHING FOUND. `search` now
// re-dispatches the phrase to its `query` verb (searchPhraseVerb, usage.go), and
// search_bare_phrase_test.go owns that contract. This file keeps the refusal
// path honest for every OTHER multi-verb noun, where "the token is a phrase" is
// a guess and not a fact.
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
  "nouns": [{"name": "doc", "summary": "Documents."}],
  "commands": [
    {"id":"doc.query","noun":"doc","verb":"query","summary":"q","http":{"method":"GET","path_template":"/v1/doc"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"doc.synonym-preview","noun":"doc","verb":"synonym-preview","summary":"p","http":{"method":"GET","path_template":"/v1/doc/synonym-preview"},"auth_tier":"none","args":[{"name":"q","required":true,"type":"string","summary":"q"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"doc.reindex","noun":"doc","verb":"reindex","summary":"r","http":{"method":"POST","path_template":"/v1/doc/reindex"},"auth_tier":"none","args":[],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
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

	out, code := captureExecuteCode(t, []string{"doc", "PDS crown proof"})

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
	if strings.Contains(out, `unknown command "doc"`) || strings.Contains(out, `unknown command \"doc\"`) {
		t.Errorf("real noun `doc` reported as unknown; got:\n%s", out)
	}
	if !strings.Contains(out, "barkpark doc query") {
		t.Errorf("output never names the runnable fix `barkpark doc query`; got:\n%s", out)
	}
	// The writing verb is never offered as a correction for a fat-fingered call.
	if strings.Contains(out, "did you mean `barkpark doc reindex") {
		t.Errorf("suggested a WRITING verb as the correction; got:\n%s", out)
	}
}

// TestFreeTextHintRidesTheJSONEnvelope pins the machine half: `-o json` renders
// only the error envelope (no usage block), so the runnable correction has to be
// in the envelope's own `hint` field, and the exit code still non-zero.
func TestFreeTextHintRidesTheJSONEnvelope(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", writeMultiVerbManifest(t))
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")

	out, code := captureExecuteCode(t, []string{"doc", "PDS crown proof", "-o", "json"})

	if code != exitUsage {
		t.Errorf("exit code = %d, want %d (exitUsage)", code, exitUsage)
	}
	if !strings.Contains(out, `"hint"`) || !strings.Contains(out, `barkpark doc query`) {
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

	out, code := captureExecuteCode(t, []string{"doc", "quer"})

	if code != exitUsage {
		t.Errorf("exit code = %d, want %d (exitUsage)", code, exitUsage)
	}
	if strings.Contains(out, "contains spaces") {
		t.Errorf("a single-token typo took the argument-shaped path; got:\n%s", out)
	}
	if !strings.Contains(out, "barkpark doc query") {
		t.Errorf("typo correction lost; got:\n%s", out)
	}
}

// TestFreeTextReadVerbsSkipsWritingAndMultiArgVerbs unit-pins the candidate
// rule itself, so a future verb added to a noun cannot quietly widen what the
// CLI offers to a caller who typed an argument where a verb belongs.
func TestFreeTextReadVerbsSkipsWritingAndMultiArgVerbs(t *testing.T) {
	m, _ := loadTreeFrom(t, writeMultiVerbManifest(t))
	n, ok := lookupNoun(m.Tree(), "doc")
	if !ok {
		t.Fatal("fixture has no `doc` noun")
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
