package cli

import (
	"bytes"
	"encoding/json"
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

// renderRaw is the -o json passthrough (task get / paper / cloud / tinker all
// route through it). Its contract: stdout is ALWAYS valid JSON. Regression for
// bp-json-escape-emit-bug — the old not-JSON branch dumped bytes verbatim, so a
// payload carrying an unescaped backslash sequence (a stamped `awk '/<\/style>/'`
// gate command is the canonical trigger) reached `jq` as an "Invalid escape" and
// broke every downstream pipeline. Mutation proof: the input here is deliberately
// INVALID JSON (a bare `\x`, an escape json.Unmarshal rejects); reverting the fix
// to `fmt.Fprintln(w.stdout, string(b))` re-emits those bytes verbatim and this
// test goes RED because stdout no longer parses. valuesJSON asserts stdout is
// strictly valid JSON AND that the original bytes round-trip recoverably.
func TestRenderRawInvalidJSONStaysParseable(t *testing.T) {
	// A JSON object whose string value carries `\x` — NOT a legal JSON escape,
	// so json.Unmarshal rejects the whole document and renderRaw takes the
	// not-JSON branch. This is exactly the byte shape a raw-interpolated
	// backslash evidence string produced.
	bad := []byte(`{"evidence": "awk '/<\x/style>/' end"}`)

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.renderRaw(bad)

	// stdout MUST be valid JSON — the whole contract. Parse it strictly; a
	// verbatim dump of `bad` fails here (the mutation-red condition).
	var got any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("renderRaw emitted invalid JSON on stdout (contract broken): %v\nstdout:\n%s", err, stdout.String())
	}

	// The raw bytes must round-trip: re-encoding as a JSON string means the
	// decoded value is the original payload verbatim, nothing lost.
	s, ok := got.(string)
	if !ok {
		t.Fatalf("expected a JSON string wrapping the raw payload, got %T: %v", got, got)
	}
	if s != string(bad) {
		t.Fatalf("raw payload not recoverable: got %q, want %q", s, string(bad))
	}

	// The anomaly is surfaced to the human on stderr, never swallowed.
	if !strings.Contains(stderr.String(), "not valid JSON") {
		t.Errorf("expected a stderr warning about the non-JSON body, got:\n%s", stderr.String())
	}
	// And stdout must NOT carry the naked invalid escape a verbatim dump would.
	if strings.Contains(stdout.String(), `\x`) && !strings.Contains(stdout.String(), `\\x`) {
		t.Errorf("stdout carries an unescaped \\x (verbatim dump leaked through):\n%s", stdout.String())
	}
}

// The happy path is untouched: valid JSON bytes re-encode compact and identical
// in value, taking the Unmarshal-succeeds branch (no stderr warning).
func TestRenderRawValidJSONRoundTrips(t *testing.T) {
	in := []byte(`{"a": 1, "note": "back\\slash and quote \" ok"}`)
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.renderRaw(in)

	var got, want any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("valid input produced invalid stdout: %v\n%s", err, stdout.String())
	}
	if err := json.Unmarshal(in, &want); err != nil {
		t.Fatalf("test input is not valid JSON: %v", err)
	}
	if fmt.Sprintf("%v", got) != fmt.Sprintf("%v", want) {
		t.Fatalf("valid JSON not preserved: got %v, want %v", got, want)
	}
	if stderr.Len() != 0 {
		t.Errorf("valid JSON should not warn on stderr, got: %s", stderr.String())
	}
}
