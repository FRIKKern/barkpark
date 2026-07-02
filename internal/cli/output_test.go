package cli

import (
	"bytes"
	"fmt"
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

// Machine output must NOT HTML-escape <, >, and & — a headless CMS routinely
// carries HTML/markdown, and jq/gh/stripe emit the raw bytes. renderJSON's
// encoder sets SetEscapeHTML(false); the YAML quoter routes through jsonQuote,
// which does the same. Both -o json and -o yaml paths are pinned here.
func TestRenderJSONDoesNotHTMLEscape(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderJSON(map[string]any{"body": "<p>hi</p>", "note": "a & b"})

	out := buf.String()
	for _, want := range []string{"<p>hi</p>", "a & b"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected raw %q in JSON output, got:\n%s", want, out)
		}
	}
	// Go's HTML escaper would turn <, >, & into \u escapes; none may appear.
	for _, esc := range htmlEscapeSeqs() {
		if strings.Contains(out, esc) {
			t.Errorf("JSON output HTML-escaped to %q:\n%s", esc, out)
		}
	}
}

// htmlEscapeSeqs returns the \u forms Go's encoding/json emits for <, >, & when
// SetEscapeHTML is left on (e.g. <). Built at runtime so the source file
// carries no literal escape text. Machine output must contain none of these.
func htmlEscapeSeqs() []string {
	var seqs []string
	for _, r := range []rune{'<', '>', '&'} {
		seqs = append(seqs, fmt.Sprintf("\\u%04x", r))
	}
	return seqs
}

// The YAML quoter must emit raw <, >, and & inside its double-quoted scalars
// and keys, not the < / & escapes json.Marshal would produce. Both
// values here carry a YAML indicator char (`>` / `&`) so they are quoted.
func TestRenderYAMLDoesNotHTMLEscape(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderYAML(map[string]any{"<b>k</b>": "<p>hi</p>", "amp": "a & b"})

	out := buf.String()
	for _, want := range []string{"<p>hi</p>", "a & b", "<b>k</b>"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected raw %q in YAML output, got:\n%s", want, out)
		}
	}
	for _, esc := range htmlEscapeSeqs() {
		if strings.Contains(out, esc) {
			t.Errorf("YAML output HTML-escaped to %q:\n%s", esc, out)
		}
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

// An empty map/slice VALUE must render inline (`key: {}` / `- {}`), not as a
// `key:` header followed by a detached `{}` at column 0 — that reparses as
// `key: null` plus a stray root node (silent data loss on `bp … -o yaml`).
func TestRenderYAMLEmptyNestedContainersRenderInline(t *testing.T) {
	cases := []struct {
		name string
		in   map[string]any
		want string
	}{
		{"empty map value", map[string]any{"body": map[string]any{}}, "body: {}\n"},
		{"empty slice value", map[string]any{"tags": []any{}}, "tags: []\n"},
		{"empty map in list", map[string]any{"rows": []any{map[string]any{}}}, "rows:\n  - {}\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			w := newWriter(&buf, &buf)
			w.renderYAML(tc.in)
			if got := buf.String(); got != tc.want {
				t.Fatalf("renderYAML(%v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// A TOP-LEVEL empty container is correctly `{}` / `[]` on its own line (the
// nested-inline fix must not disturb the root case).
func TestRenderYAMLTopLevelEmptyContainer(t *testing.T) {
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	w.renderYAML(map[string]any{})
	if got := buf.String(); got != "{}\n" {
		t.Fatalf("top-level empty map = %q, want %q", got, "{}\n")
	}
}
