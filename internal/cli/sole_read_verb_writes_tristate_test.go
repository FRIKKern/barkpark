package cli

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// This file pins the GO half of a two-sided defect.
//
// GO HALF (this file, task pds-bl-manifest-writes-fails-open):
// manifest.Command.Writes is a plain bool, so an OMITTED `writes` key decodes to
// Go's false zero value and soleReadVerb — the gate that auto-re-dispatches a
// bare `bp <noun> <free text>` to a single-verb noun — read UNKNOWN as SAFE and
// AUTO-RAN the verb. The fix makes the flag a tri-state
// (manifest.Command.WritesDeclared + NonWriting) and makes the gate fail CLOSED.
//
// SERVER HALF (task pds-bl-plugin-cli-command-writes-fails-open, PR #15588 on
// api/): the Elixir manifest builder could emit a plugin command with no
// `writes` key at all. NEITHER HALF CLOSES THE OTHER — the server fix stops one
// producer of writes-less commands; this fix makes every bp safe against every
// producer, including servers older than that fix. Do not stamp one row on the
// other's evidence.

// tristateManifest renders a minimal, strict-decodable manifest whose single
// noun `probe` declares exactly ONE verb `look`. writesKey controls the arm:
// "" omits the `writes` key entirely, "false"/"true" declare it.
func tristateManifest(t *testing.T, writesKey string) *manifest.Tree {
	t.Helper()
	writesLine := ""
	if writesKey != "" {
		writesLine = fmt.Sprintf(`"writes": %s,`, writesKey)
	}
	body := fmt.Sprintf(`{
	  "manifest_version": "1",
	  "server": {"name":"barkpark","version":"0.1.0","base_url":"https://example.invalid","api_version":"1","min_cli":"1.0.0"},
	  "auth_tier": "admin",
	  "generated_at": "2026-09-03T00:00:00Z",
	  "etag": "W/\"caps-tristate\"",
	  "nouns": [{"name":"probe","summary":"A one-verb noun."}],
	  "commands": [{
	    "id": "probe.look",
	    "noun": "probe",
	    "verb": "look",
	    "summary": "One verb, free-text arg.",
	    "http": {"method":"GET","path_template":"/v1/probe"},
	    "auth_tier": "none",
	    "args": [{"name":"q","required":true,"type":"string","summary":"The phrase."}],
	    "flags": [],
	    %s
	    "batch": false,
	    "paginated": false,
	    "dry_run": false,
	    "default_output": "table"
	  }]
	}`, writesLine)
	// Guard the fixture itself: the omit arm must really omit the key, and the
	// declared arms must really carry it — otherwise this whole test is vacuous.
	var probe struct {
		Commands []map[string]json.RawMessage `json:"commands"`
	}
	if err := json.Unmarshal([]byte(body), &probe); err != nil {
		t.Fatalf("fixture is not valid JSON: %v", err)
	}
	_, present := probe.Commands[0]["writes"]
	if present != (writesKey != "") {
		t.Fatalf("fixture arm %q: writes key present = %v; the test would prove nothing", writesKey, present)
	}
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse tri-state manifest (arm %q): %v", writesKey, err)
	}
	return m.Tree()
}

// TestSoleReadVerbRequiresDeclaredNonWriting is the row's proof obligation: an
// UNDECLARED `writes` key must NOT be inferable (the pre-fix code auto-ran it),
// while a DECLARED `"writes": false` still is (so the fix is not "never infer")
// and a DECLARED `"writes": true` still is not.
func TestSoleReadVerbRequiresDeclaredNonWriting(t *testing.T) {
	for _, tc := range []struct {
		name         string
		writes       string
		wantInferred bool
	}{
		{"writes key OMITTED — unknown, must fail CLOSED", "", false},
		{"writes declared false — still inferred", "false", true},
		{"writes declared true — suggested, never run", "true", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tree := tristateManifest(t, tc.writes)
			n, ok := lookupNoun(tree, "probe")
			if !ok {
				t.Fatal("probe noun missing from the tri-state manifest")
			}
			if len(n.Verbs) != 1 {
				t.Fatalf("probe declares %d verbs; the sole-verb rule needs exactly 1", len(n.Verbs))
			}
			sole, inferable := soleReadVerb(n, "PDS crown proof")
			if inferable != tc.wantInferred {
				t.Fatalf("soleReadVerb(probe, free text) inferable = %v, want %v (writes arm %q)",
					inferable, tc.wantInferred, tc.writes)
			}
			if inferable && sole.Verb != "look" {
				t.Fatalf("inferred verb = %q, want look", sole.Verb)
			}
		})
	}
}

// TestManifestWritesTriStateDecode pins the representation the gate rests on:
// the decoder distinguishes UNDECLARED from a declared false, and the JSON wire
// shape is unchanged (no `writes_declared` key is read or required).
func TestManifestWritesTriStateDecode(t *testing.T) {
	for _, tc := range []struct {
		arm              string
		wantWrites       bool
		wantDeclared     bool
		wantNonWritingIs bool
	}{
		{"", false, false, false},
		{"false", false, true, true},
		{"true", true, true, false},
	} {
		tree := tristateManifest(t, tc.arm)
		n, _ := lookupNoun(tree, "probe")
		c := n.Verbs[0]
		if c.Writes != tc.wantWrites || c.WritesDeclared != tc.wantDeclared || c.NonWriting() != tc.wantNonWritingIs {
			t.Errorf("arm %q: Writes=%v WritesDeclared=%v NonWriting=%v; want %v/%v/%v",
				tc.arm, c.Writes, c.WritesDeclared, c.NonWriting(),
				tc.wantWrites, tc.wantDeclared, tc.wantNonWritingIs)
		}
	}
}
