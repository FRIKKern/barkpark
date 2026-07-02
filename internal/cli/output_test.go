package cli

import (
	"bytes"
	"strings"
	"testing"
)

// renderYAML must quote a map key that carries YAML indicator chars, or the
// output is malformed. A key "a: b" mapped to 5 must render as the quoted
// `"a: b": 5`, never the bare `a: b: 5` (which parses as nested mappings).
func TestRenderYAMLQuotesProblematicKey(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderYAML(map[string]any{"a: b": float64(5)})

	out := buf.String()
	if !strings.Contains(out, `"a: b": 5`) {
		t.Fatalf("expected quoted key %q in output, got:\n%s", `"a: b": 5`, out)
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "a: b: 5" {
			t.Fatalf("output contains malformed unquoted key line %q:\n%s", "a: b: 5", out)
		}
	}
}

// A plain key stays unquoted so the common case is untouched.
func TestRenderYAMLLeavesPlainKeyUnquoted(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderYAML(map[string]any{"count": float64(3)})

	if got := strings.TrimSpace(buf.String()); got != "count: 3" {
		t.Fatalf("expected %q, got %q", "count: 3", got)
	}
}

// The float branch's int shortcut must not fire for magnitudes that overflow
// int64; such values fall through to %g rather than wrapping to garbage.
func TestScalarYAMLLargeFloatNoOverflow(t *testing.T) {
	got := scalarYAML(1e19) // > math.MaxInt64
	if strings.HasPrefix(got, "-") {
		t.Fatalf("large float wrapped to a negative int: %q", got)
	}
}

// The Norway problem: a STRING whose text reads as a YAML bool/null/number must
// be double-quoted so a machine consumer (yq) reads it back as the string it is,
// not a silently re-typed scalar. Genuine bool/float values stay bare.
func TestRenderYAMLQuotesTypeAmbiguousStrings(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderYAML(map[string]any{
		"a": "true",
		"b": "0755",
		"c": "null",
		"d": "123",
		"e": "no",
	})
	out := buf.String()
	for _, want := range []string{`a: "true"`, `b: "0755"`, `c: "null"`, `d: "123"`, `e: "no"`} {
		if !strings.Contains(out, want) {
			t.Errorf("expected quoted %q in output, got:\n%s", want, out)
		}
	}
	// A genuine string that is NOT type-ambiguous stays bare.
	if got := scalarYAML("hello"); got != "hello" {
		t.Errorf("plain string should stay bare, got %q", got)
	}
	// Genuine scalars keep their bare form — quoting is a string-only concern.
	if got := scalarYAML(true); got != "true" {
		t.Errorf("bool true should stay bare, got %q", got)
	}
	if got := scalarYAML(float64(123)); got != "123" {
		t.Errorf("float64 123 should stay bare, got %q", got)
	}
}
