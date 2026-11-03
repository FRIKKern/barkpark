//go:build js && wasm

package main

import (
	"regexp"
	"strings"
	"syscall/js"
	"testing"
)

// TestRenderTUI_NoArgs guards the bpRenderTUI JS global against a panic when
// called with zero arguments. renderTUI is the module's only js.FuncOf entry
// point (see main()); an uncaught panic inside it terminates the whole Go
// wasm runtime, forcing the reader page to do a full reload. Before the fix,
// args[0].String() ran unguarded and this test would panic instead of
// returning an error string.
func TestRenderTUI_NoArgs(t *testing.T) {
	got := renderTUI(js.Undefined(), nil)

	html, ok := got.(string)
	if !ok {
		t.Fatalf("renderTUI(no args) returned %T, want string", got)
	}
	if !strings.Contains(html, "<pre>") {
		t.Fatalf("renderTUI(no args) = %q, want an error <pre> string", html)
	}
}

// TestRenderTUI_EmptyArgs covers the equivalent case where JS passes an
// empty (non-nil) args slice, which behaves the same as nil.
func TestRenderTUI_EmptyArgs(t *testing.T) {
	got := renderTUI(js.Undefined(), []js.Value{})

	html, ok := got.(string)
	if !ok {
		t.Fatalf("renderTUI(empty args) returned %T, want string", got)
	}
	if !strings.Contains(html, "<pre>") {
		t.Fatalf("renderTUI(empty args) = %q, want an error <pre> string", html)
	}
}

func TestRenderTUI_MarkedLinkHasNoANSIBytes(t *testing.T) {
	doc := `{"blocks":[{"type":"paragraph","content":[{"type":"text","value":"a marked link","marks":[{"type":"link","href":"https://example.com"},{"type":"bold"}]}]}]}`
	html := renderTUI(js.Undefined(), []js.Value{js.ValueOf(doc), js.ValueOf(100), js.ValueOf("light")}).(string)
	text := regexp.MustCompile(`<[^>]+>`).ReplaceAllString(html, "")
	if strings.ContainsRune(html, '\x1b') || text != "a marked link" {
		t.Fatalf("marked link must render intact without escape bytes: %q", html)
	}
	if !strings.Contains(html, "font-weight:700") || !strings.Contains(html, "text-decoration:underline") {
		t.Fatalf("marked link must keep emphasis and underline: %q", html)
	}
}
