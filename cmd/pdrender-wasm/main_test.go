//go:build js && wasm

package main

import (
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
