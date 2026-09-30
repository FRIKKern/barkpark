package cli

import (
	"bytes"
	"strings"
	"testing"
)

// Stranger walk (2026-09-30): `bp webhook create <url> <name>` printed a bare
// "ok" — the server answers {"webhook": {"id": …, …}}, the minimal harvest only
// looked at top-level keys, and the id every later webhook verb needs was never
// shown. A body that is exactly one KNOWN resource wrapper is read one level
// deep; a nested verdict ({"delivery": {...}}) keeps its bare "ok".
func TestRenderMinimalReadsTheIDOfASingleWrappedObject(t *testing.T) {
	render := func(body string) string {
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "minimal"
		renderMinimal(w, []byte(body))
		return strings.TrimSpace(stdout.String())
	}

	if got := render(`{"webhook":{"id":"d638942a","name":"t4","url":"http://x/hook","active":true}}`); got != "id: d638942a" {
		t.Fatalf("webhook create receipt = %q, want the wrapped id", got)
	}

	// Unchanged shapes: a top-level id still wins, a bare ok stays ok, and a
	// multi-key body is not treated as a wrapper.
	if got := render(`{"id":"top","webhook":{"id":"inner"}}`); got != "id: top" {
		t.Fatalf("top-level id = %q, want id: top", got)
	}
	if got := render(`{"ok":true}`); got != "ok" {
		t.Fatalf("bare ok = %q, want ok", got)
	}
	if got := render(`{"a":{"id":"x"},"b":{"id":"y"}}`); got != "ok" {
		t.Fatalf("a two-key body must not be read as a wrapper; got %q", got)
	}
	if got := render(`{"delivery":{"id":"d1","status":"delivered"}}`); got != "ok" {
		t.Fatalf("a nested verdict is not a resource wrapper; got %q", got)
	}
}
