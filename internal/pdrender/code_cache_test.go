package pdrender

import (
	"fmt"
	"testing"
)

// The code memo cache must stay bounded: a long-running TUI rendering many
// distinct code blocks would otherwise grow it without limit (memory leak).
func TestCodeCacheIsBounded(t *testing.T) {
	cr := newCodeRenderer()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: ANSI256}

	// Render well past the cap with distinct sources so every call is a miss.
	for i := 0; i < maxCodeCacheEntries*3; i++ {
		b := Block{Type: "code", Attrs: map[string]any{
			"code":     fmt.Sprintf("echo %d", i),
			"language": "bash",
		}}
		cr.Render(b, ctx)
	}

	if got := len(cr.cache); got > maxCodeCacheEntries {
		t.Errorf("code cache grew to %d entries, want ≤ %d (unbounded)", got, maxCodeCacheEntries)
	}
	if cr.misses < maxCodeCacheEntries {
		t.Errorf("expected many cache misses on distinct sources, got %d", cr.misses)
	}
}

// A repeated render of the same block stays a cache HIT (the cap must not
// evict the hot working set in the common case).
func TestCodeCacheHitsOnRepeat(t *testing.T) {
	cr := newCodeRenderer()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: ANSI256}
	b := Block{Type: "code", Attrs: map[string]any{"code": "echo hi", "language": "bash"}}

	cr.Render(b, ctx)
	before := cr.misses
	for i := 0; i < 10; i++ {
		cr.Render(b, ctx)
	}
	if cr.misses != before {
		t.Errorf("repeated identical render should hit the cache; misses went %d → %d", before, cr.misses)
	}
	if cr.hits < 10 {
		t.Errorf("expected ≥10 cache hits on repeat, got %d", cr.hits)
	}
}
