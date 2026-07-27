package cli

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// These tests are the protective kit around the born-brief capabilities print
// (BRIEF-KEEP-LIST v1, capsbrief.go) — and the FIRST test coverage this stdout
// path has ever had. The kit, per the ctx-compression charter (decision 8):
//
//   - invoke-completeness: every command stays composable from the brief alone
//   - legend pin: the self-describing header is exactly the spec
//   - ratio tripwire: brief ≤ 32% of full bytes on the committed 142-command
//     fixture (ratios, never fixed bytes — the manifest grows)
//   - hostile synthetic: adversarial content stays valid, complete, deterministic
//   - --full identity: the opt-out is byte-identical to the pre-brief output

// marshalCompact renders v exactly like writer.renderJSON does (compact,
// HTML-escaping off, trailing newline), so byte comparisons in these tests
// measure the real stdout encoding.
func marshalCompact(t *testing.T, v any) []byte {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		t.Fatalf("encode: %v", err)
	}
	return buf.Bytes()
}

// decodeBrief marshals briefManifest(m) and decodes it back to a generic value,
// so assertions run against the JSON a consumer actually parses — not against
// Go-side structs that could drift from the emitted bytes.
func decodeBrief(t *testing.T, m *manifest.Manifest) map[string]any {
	t.Helper()
	raw := marshalCompact(t, briefManifest(m))
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("brief output is not valid JSON: %v", err)
	}
	return doc
}

// TestBriefManifestInvokeCompleteness enumerates EVERY command in the full
// fixture and asserts the brief carries everything needed to invoke it: noun,
// verb, summary, auth_tier, writes, every arg (name/type/required, in order),
// every flag (name/type, in order). A brief missing one field costs more than
// it saves — this is the acceptance test of the whole projection.
func TestBriefManifestInvokeCompleteness(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)
	doc := decodeBrief(t, m)

	// Top-level keep-list: identity + auth tier survive the projection.
	if got := doc["manifest_version"]; got != m.ManifestVersion {
		t.Errorf("manifest_version = %v, want %v", got, m.ManifestVersion)
	}
	if got := doc["auth_tier"]; got != m.AuthTier {
		t.Errorf("auth_tier = %v, want %v", got, m.AuthTier)
	}
	if got := doc["etag"]; got != m.ETag {
		t.Errorf("etag = %v, want %v", got, m.ETag)
	}
	server, _ := doc["server"].(map[string]any)
	if server == nil || server["name"] != m.Server.Name || server["base_url"] != m.Server.BaseURL {
		t.Errorf("server block = %v, want name=%q base_url=%q", doc["server"], m.Server.Name, m.Server.BaseURL)
	}

	tuples, _ := doc["commands"].([]any)
	if len(tuples) != len(m.Commands) {
		t.Fatalf("brief has %d command tuples, manifest has %d commands", len(tuples), len(m.Commands))
	}

	for i, c := range m.Commands {
		tuple, _ := tuples[i].([]any)
		if len(tuple) != 7 {
			t.Fatalf("command %s.%s: tuple arity %d, want 7 (legend.command)", c.Noun, c.Verb, len(tuple))
		}
		if tuple[0] != c.Noun || tuple[1] != c.Verb || tuple[2] != c.Summary || tuple[3] != c.AuthTier || tuple[4] != c.Writes {
			t.Errorf("command %s.%s: tuple head = %v, want [%q %q %q %q %v]",
				c.Noun, c.Verb, tuple[:5], c.Noun, c.Verb, c.Summary, c.AuthTier, c.Writes)
		}

		args, _ := tuple[5].([]any)
		if len(args) != len(c.Args) {
			t.Fatalf("command %s.%s: %d arg tuples, want %d", c.Noun, c.Verb, len(args), len(c.Args))
		}
		for j, a := range c.Args {
			at, _ := args[j].([]any)
			if len(at) != 3 || at[0] != a.Name || at[1] != a.Type || at[2] != a.Required {
				t.Errorf("command %s.%s arg[%d] = %v, want [%q %q %v]", c.Noun, c.Verb, j, args[j], a.Name, a.Type, a.Required)
			}
		}

		flags, _ := tuple[6].([]any)
		if len(flags) != len(c.Flags) {
			t.Fatalf("command %s.%s: %d flag tuples, want %d", c.Noun, c.Verb, len(flags), len(c.Flags))
		}
		for j, f := range c.Flags {
			ft, _ := flags[j].([]any)
			if len(ft) != 2 || ft[0] != f.Name || ft[1] != f.Type {
				t.Errorf("command %s.%s flag[%d] = %v, want [%q %q]", c.Noun, c.Verb, j, flags[j], f.Name, f.Type)
			}
		}
	}
}

// TestBriefManifestLegendPin pins the self-describing legend to EXACTLY the
// BRIEF-KEEP-LIST v1 spec. The legend is the consumer's decoder ring — any
// drift here (a reordered or renamed position) silently corrupts every tuple
// read, so the pin is exact, not fuzzy.
func TestBriefManifestLegendPin(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)
	doc := decodeBrief(t, m)

	want := map[string]any{
		"command": []any{"noun", "verb", "summary", "auth_tier", "writes", "args", "flags"},
		"arg":     []any{"name", "type", "required"},
		"flag":    []any{"name", "type"},
	}
	if !reflect.DeepEqual(doc["legend"], want) {
		t.Errorf("legend = %v, want %v", doc["legend"], want)
	}
}

// TestBriefManifestCutList proves the projection actually CUTS what the spec
// cuts: no per-command http/path_template, id, or views, and no nouns catalog,
// anywhere in the emitted document. Belt to the ratio tripwire's braces — a
// future field accidentally threaded into the tuples fails here by name.
func TestBriefManifestCutList(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)
	raw := string(marshalCompact(t, briefManifest(m)))

	for _, needle := range []string{`"nouns"`, `"path_template"`, `"http"`, `"mutation_op"`, `"default_output"`, `"paginated"`, `"views"`, `"repeatable"`} {
		if strings.Contains(raw, needle) {
			t.Errorf("brief output contains cut field %s", needle)
		}
	}
}

// TestBriefManifestRatioTripwire is the ratio law: brief ≤ 32% of full bytes on
// the committed 142-command fixture (charter decision 4 — targets are RATIOS,
// never fixed bytes, because the manifest grows). Both sides are measured in
// the writer's own compact stdout encoding, like-for-like. The probe line
// prints actual bytes + ratio so a CI run carries the evidence.
func TestBriefManifestRatioTripwire(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)

	fullBytes := len(marshalCompact(t, m))
	briefBytes := len(marshalCompact(t, briefManifest(m)))

	t.Logf("caps-brief probe: full=%d B brief=%d B ratio=%.2fx (%.1f%% of full)",
		fullBytes, briefBytes, float64(fullBytes)/float64(briefBytes), 100*float64(briefBytes)/float64(fullBytes))

	if briefBytes*100 > fullBytes*32 {
		t.Errorf("ratio tripwire: brief=%d B is %.1f%% of full=%d B, budget is 32%%",
			briefBytes, 100*float64(briefBytes)/float64(fullBytes), fullBytes)
	}
	if len(m.Commands) < 100 {
		t.Errorf("realistic fixture has only %d commands; the tripwire needs the full-size manifest (expected 100+)", len(m.Commands))
	}
}

// hostileManifest builds a synthetic manifest whose every string field carries
// encoding-hostile content: tabs, pipes, colons, newlines, quotes, backslashes,
// HTML, and a max-length run. Tuples-JSON was chosen over TSV exactly because
// its collision-freedom is STRUCTURAL, not data-dependent — this manifest is
// the proof burden.
func hostileManifest() *manifest.Manifest {
	nasty := "tab\there|pipe:colon\nnewline \"quote\" \\backslash <img> & 'tick' " + strings.Repeat("宽", 2000) + strings.Repeat("x", 4096)
	return &manifest.Manifest{
		ManifestVersion: "1",
		Server:          manifest.Server{Name: nasty, Version: "v\t|\n1", BaseURL: "http://host/with|pipe\tand\nnewline"},
		AuthTier:        "ad\tmin|x",
		ETag:            `W/"etag\twith|pipes:and\nnewlines"`,
		Commands: []manifest.Command{
			{
				Noun: nasty, Verb: "do\t|\n:", Summary: nasty, AuthTier: nasty, Writes: true,
				Args: []manifest.Arg{
					{Name: nasty, Type: "str\ting", Required: true},
					{Name: "plain", Type: nasty, Required: false},
				},
				Flags: []manifest.Flag{
					{Name: nasty, Type: "bo\nol"},
					{Name: "f|two", Type: nasty},
				},
			},
			{Noun: "empty", Verb: "cmd", Summary: "", AuthTier: "", Writes: false},
		},
	}
}

// TestBriefManifestHostileSynthetic renders the hostile manifest and asserts
// the brief stays (a) valid JSON, (b) invoke-complete — every hostile string
// round-trips byte-exact through the tuples, (c) deterministic — two renders
// are byte-identical.
func TestBriefManifestHostileSynthetic(t *testing.T) {
	m := hostileManifest()

	one := marshalCompact(t, briefManifest(m))
	two := marshalCompact(t, briefManifest(m))
	if !bytes.Equal(one, two) {
		t.Fatalf("hostile brief is not deterministic: two renders differ")
	}

	var doc map[string]any
	if err := json.Unmarshal(one, &doc); err != nil {
		t.Fatalf("hostile brief is not valid JSON: %v", err)
	}

	tuples, _ := doc["commands"].([]any)
	if len(tuples) != len(m.Commands) {
		t.Fatalf("hostile brief has %d tuples, want %d", len(tuples), len(m.Commands))
	}
	for i, c := range m.Commands {
		tuple, _ := tuples[i].([]any)
		if len(tuple) != 7 || tuple[0] != c.Noun || tuple[1] != c.Verb || tuple[2] != c.Summary || tuple[3] != c.AuthTier || tuple[4] != c.Writes {
			t.Errorf("hostile command %d did not round-trip: %v", i, tuple)
		}
		args, _ := tuple[5].([]any)
		for j, a := range c.Args {
			at, _ := args[j].([]any)
			if len(at) != 3 || at[0] != a.Name || at[1] != a.Type || at[2] != a.Required {
				t.Errorf("hostile arg %d/%d did not round-trip", i, j)
			}
		}
		flags, _ := tuple[6].([]any)
		for j, f := range c.Flags {
			ft, _ := flags[j].([]any)
			if len(ft) != 2 || ft[0] != f.Name || ft[1] != f.Type {
				t.Errorf("hostile flag %d/%d did not round-trip", i, j)
			}
		}
	}
}

// capsOut runs runCapabilities against the committed full fixture with the
// given output shape and --full state, returning stdout. The fixture path rides
// the --manifest override seam, so nothing dials a network.
func capsOut(t *testing.T, output string, full bool) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = output
	g := globals{manifestPath: fullManifest, full: full}
	if code := runCapabilities(w, g, manifest.Context{}); code != exitOK {
		t.Fatalf("runCapabilities exit=%d, stderr=%s", code, stderr.String())
	}
	return stdout.String()
}

// TestCapabilitiesFullByteIdentity is the opt-out identity proof: with --full,
// machine output is byte-for-byte today's full manifest marshal — nothing
// reordered, re-escaped, or re-indented. The projection must be impossible to
// observe under the escape hatch.
func TestCapabilitiesFullByteIdentity(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)

	got := capsOut(t, "json", true)
	want := string(marshalCompact(t, m)) // today's path: writer.renderJSON(m)
	if got != want {
		t.Errorf("--full json output is not byte-identical to the full marshal (got %d B, want %d B)", len(got), len(want))
	}
}

// TestCapabilitiesBornBrief asserts the machine default IS the brief: piped
// `bp capabilities -o json` emits BRIEF-KEEP-LIST v1 (legend + tuples), valid
// JSON, top-level auth_tier retained — and -o yaml rides the same projection.
func TestCapabilitiesBornBrief(t *testing.T) {
	m, _ := loadTreeFrom(t, fullManifest)

	got := capsOut(t, "json", false)
	want := string(marshalCompact(t, briefManifest(m)))
	if got != want {
		t.Errorf("machine default is not the brief projection (got %d B, want %d B)", len(got), len(want))
	}

	var doc map[string]any
	if err := json.Unmarshal([]byte(got), &doc); err != nil {
		t.Fatalf("born-brief output is not valid JSON: %v", err)
	}
	if doc["auth_tier"] != m.AuthTier {
		t.Errorf("born-brief auth_tier = %v, want %v", doc["auth_tier"], m.AuthTier)
	}
	if _, ok := doc["legend"]; !ok {
		t.Errorf("born-brief output missing legend")
	}

	yamlOut := capsOut(t, "yaml", false)
	if !strings.Contains(yamlOut, "legend:") {
		t.Errorf("yaml machine output is not brief (no legend header)")
	}
	if strings.Contains(yamlOut, "path_template") {
		t.Errorf("yaml machine output leaks the cut http block — not the brief projection")
	}
}

// TestCapabilitiesTableUntouched pins the human view out of the projection's
// blast radius: -o table renders the same summary with and without --full, and
// still carries the full-tree header lines.
func TestCapabilitiesTableUntouched(t *testing.T) {
	plain := capsOut(t, "table", false)
	full := capsOut(t, "table", true)
	if plain != full {
		t.Errorf("-o table differs between --full and default; the human view must be untouched")
	}
	for _, needle := range []string{"server:", "auth_tier:", "commands:"} {
		if !strings.Contains(plain, needle) {
			t.Errorf("-o table output missing %q header", needle)
		}
	}
}
