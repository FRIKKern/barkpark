package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The escape-hatch kit (task-9f726e783347b60e). `--manifest` / $BARKPARK_MANIFEST
// is the documented recovery path for an unreachable /v1/capabilities, and the
// obvious way to produce its input — `bp capabilities -o json > caps.json` —
// produced a file the loader rejected with an internal Go field name. Three
// arms, one per acceptance criterion:
//
//   - the named command actually writes a loadable file (round trip)
//   - the RENDERED view is refused by NAME, pointing at that command
//   - a manifest captured at a lower tier reports itself tier-limited, not a
//     credential failure

// TestCapabilitiesFullWritesALoadableManifest is criterion 0 end to end IN
// PROCESS: run the command the hint names (`bp capabilities --full -o json`),
// send its stdout to a file, and load that file back through the very function
// --manifest uses. Anything that breaks the round trip — a new manifest field
// without a json tag, a stray stdout line, a projection leaking into --full —
// reds here rather than in an operator's outage.
func TestCapabilitiesFullWritesALoadableManifest(t *testing.T) {
	resetManifestMemo()
	t.Cleanup(resetManifestMemo)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	g := globals{manifestPath: fullManifest, full: true}
	if code := runCapabilities(w, g, manifest.Context{}); code != exitOK {
		t.Fatalf("capabilities --full -o json exit = %d, want %d (stderr: %s)", code, exitOK, stderr.String())
	}

	captured := filepath.Join(t.TempDir(), "caps.json")
	if err := os.WriteFile(captured, stdout.Bytes(), 0o600); err != nil {
		t.Fatalf("write captured manifest: %v", err)
	}

	got, err := loadManifestFile(captured)
	if err != nil {
		t.Fatalf("`%s` wrote a file --manifest cannot load: %v", manifestCaptureCmd, err)
	}
	want, _ := loadTreeFrom(t, fullManifest)
	if len(got.Commands) != len(want.Commands) || len(got.Commands) == 0 {
		t.Fatalf("round-tripped manifest has %d commands, source has %d", len(got.Commands), len(want.Commands))
	}
	// A command is only usable if its route survived: the brief drops http
	// entirely, so this is the assertion that separates the two shapes.
	for i, c := range got.Commands {
		if c.HTTP.Method == "" || c.HTTP.PathTemplate == "" {
			t.Fatalf("round-tripped command %d (%s %s) lost its http block", i, c.Noun, c.Verb)
		}
	}
	if got.AuthTier != want.AuthTier {
		t.Errorf("round-tripped auth_tier = %q, want %q", got.AuthTier, want.AuthTier)
	}
}

// TestLoadManifestFileRefusesRenderedBriefView is criterion 1. The rendered
// brief is REFUSED, not adapted, because it carries no http block for any
// command — a manifest that loaded and then failed on every dispatch would be
// worse than a refusal. The refusal must say WHICH shape it got and name the
// command that writes the right one; before this change the operator got
// `parse manifest: json: unknown field "legend"`.
func TestLoadManifestFileRefusesRenderedBriefView(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)
	brief := marshalCompact(t, briefManifest(m))
	path := filepath.Join(t.TempDir(), "caps.json")
	if err := os.WriteFile(path, brief, 0o600); err != nil {
		t.Fatalf("write brief: %v", err)
	}

	_, err := loadManifestFile(path)
	if err == nil {
		t.Fatal("loading the rendered brief view succeeded; it carries no http block and cannot dispatch anything")
	}
	msg := err.Error()
	for _, want := range []string{
		"RENDERED",
		"bp capabilities -o json",
		manifestCaptureCmd,
		path,
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal missing %q:\n%s", want, msg)
		}
	}
	// It must NOT be the old internals-leaking parser error.
	if strings.Contains(msg, "unknown field") || strings.Contains(msg, "commandFields") {
		t.Errorf("refusal still names an internal Go field instead of the mistake:\n%s", msg)
	}
}

// TestLoadManifestFileAcceptsServerDocument is the negative guard for the
// sniff: a real capabilities document has no legend header and must go straight
// through. Without it, a discriminator that over-matched would refuse the ONE
// file the escape hatch exists to load.
func TestLoadManifestFileAcceptsServerDocument(t *testing.T) {
	if _, err := loadManifestFile(fullManifest); err != nil {
		t.Fatalf("server capabilities document was refused: %v", err)
	}
}

// TestBriefLegendKeyMatchesRender pins briefLegendKey to the key the brief
// actually emits. The const cannot live in the struct tag, so a rename of the
// tag alone would silently un-arm the sniff above and restore the old error.
func TestBriefLegendKeyMatchesRender(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(marshalCompact(t, briefManifest(m)), &doc); err != nil {
		t.Fatalf("brief is not JSON: %v", err)
	}
	if _, ok := doc[briefLegendKey]; !ok {
		t.Fatalf("brief has no %q key; renderedBriefView can no longer detect the rendered view (brief keys: %v)", briefLegendKey, briefTopKeys(doc))
	}
}

func briefTopKeys(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// TestSuggestUnknownNounReportsTierLimitedManifest is criterion 2. A manifest
// captured without a credential bakes auth_tier "none" and hides every command
// the caller is entitled to. The old copy read that as a CREDENTIAL failure and
// sent the operator to `barkpark login` — advice that cannot fix a stale
// capture however many times it succeeds. Under a file manifest the diagnosis
// must name the FILE, the CAPTURED tier, and the re-capture command.
func TestSuggestUnknownNounReportsTierLimitedManifest(t *testing.T) {
	tree := tierFilteredTree()
	const file = "/tmp/anon-caps.json"

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := suggestUnknownNoun(w, tree, "none", "task", tokenProvenance{}, file)
	if code != exitUsage {
		t.Errorf("tier-limited-manifest exit = %d, want %d", code, exitUsage)
	}
	human := stderr.String()
	for _, want := range []string{"TIER-LIMITED", "manifest FILE", file, "auth_tier=none", manifestCaptureCmd} {
		if !strings.Contains(human, want) {
			t.Errorf("tier-limited diagnosis missing %q:\n%s", want, human)
		}
	}
	// The whole point: it must not be mistaken for a credential problem.
	if strings.Contains(human, "barkpark login") {
		t.Errorf("tier-limited manifest must not advise re-logging in; the file is stale, the credential is not:\n%s", human)
	}

	// Machine output: an agent parsing the envelope learns the same fact, and
	// the hint is the re-capture command rather than a login.
	var mstdout, mstderr bytes.Buffer
	mw := newWriter(&mstdout, &mstderr)
	mw.output = "json"
	suggestUnknownNoun(mw, tree, "none", "task", tokenProvenance{}, file)
	env := mstdout.String()
	for _, want := range []string{`"hint"`, "TIER-LIMITED", file, manifestCaptureCmd} {
		if !strings.Contains(env, want) {
			t.Errorf("tier-limited json envelope missing %q:\n%s", want, env)
		}
	}
}

// TestSuggestUnknownNounCredentialPathUnchanged is the discrimination guard:
// with NO file override the tier-hidden refusal is still the credential one.
// Criterion 2 asks for the two to be DISTINCT, so proving the new branch fires
// is only half the claim.
func TestSuggestUnknownNounCredentialPathUnchanged(t *testing.T) {
	tree := tierFilteredTree()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	suggestUnknownNoun(w, tree, "none", "task", tokenProvenance{}, "")
	out := stderr.String()
	if !strings.Contains(out, "barkpark login") {
		t.Errorf("network-manifest tier refusal lost its credential remedy:\n%s", out)
	}
	if strings.Contains(out, "TIER-LIMITED") {
		t.Errorf("network-manifest tier refusal must not blame a manifest file:\n%s", out)
	}
}

// TestManifestFetchHintNamesTheCaptureCommand holds the hint honest: the row
// this kit closes is about a hint that named a workaround without naming the
// file. Whatever the wording, the acquisition failure must carry the ONE
// command that writes a loadable manifest.
func TestManifestFetchHintNamesTheCaptureCommand(t *testing.T) {
	resetManifestMemo()
	t.Cleanup(resetManifestMemo)

	// A server that is reachable but has no capabilities endpoint — the exact
	// pre-deploy condition the escape hatch exists for.
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")
	t.Setenv("BARKPARK_TOKEN", "t")
	_, err := loadManifestUncached(globals{server: "http://127.0.0.1:1"}, manifest.Context{Server: "http://127.0.0.1:1", Token: "t"})
	if err == nil {
		t.Fatal("expected the capabilities fetch to fail against a dead port")
	}
	if !strings.Contains(err.Error(), manifestCaptureCmd) {
		t.Errorf("acquisition hint does not name the command that writes a loadable manifest (%q):\n%s", manifestCaptureCmd, err.Error())
	}
}
