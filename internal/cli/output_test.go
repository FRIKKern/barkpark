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
