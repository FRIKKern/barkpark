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

// TestCodeCacheKeyedByThemeAndMode is the ts-w4c regression guard: the memo key
// must include BOTH the theme identity AND the light/dark mode, so a code block
// rendered under two different themes (or one theme in two modes) never serves a
// stale cross-theme cache entry. Two distinct theme ids at the SAME mode must
// each MISS (two cache entries); the same (theme, mode) must HIT.
func TestCodeCacheKeyedByThemeAndMode(t *testing.T) {
	cr := newCodeRenderer()
	b := Block{Type: "code", Attrs: map[string]any{"code": "echo hi", "language": "bash"}}

	// Two theme identities at the same (dark) mode. "midnight" is not emitted, so
	// its palette resolves to evergreen — the rendered bytes match — but the memo
	// key must still differentiate on themeID, or the second theme would silently
	// serve the first theme's cached render once real skins diverge.
	evergreenDark := RenderCtx{Width: 80, Theme: ThemeFor("evergreen", "dark"), Profile: ANSI256}
	midnightDark := RenderCtx{Width: 80, Theme: ThemeFor("midnight", "dark"), Profile: ANSI256}

	cr.Render(b, evergreenDark) // miss #1
	cr.Render(b, midnightDark)  // miss #2 — different themeID, must NOT collide
	if cr.misses != 2 {
		t.Fatalf("two theme ids at the same mode should each miss; misses = %d, want 2", cr.misses)
	}
	if len(cr.cache) != 2 {
		t.Fatalf("two theme ids at the same mode should hold 2 cache entries, got %d", len(cr.cache))
	}

	// Same (theme, mode) is a HIT — the key is not over-partitioned.
	beforeHits := cr.hits
	cr.Render(b, evergreenDark)
	if cr.hits != beforeHits+1 {
		t.Errorf("re-render of the same (theme, mode) should hit; hits %d → %d", beforeHits, cr.hits)
	}

	// The SAME theme id in a different MODE must also miss (mode is keyed too).
	cr.Render(b, RenderCtx{Width: 80, Theme: ThemeFor("evergreen", "light"), Profile: ANSI256})
	if cr.misses != 3 {
		t.Errorf("a second mode of the same theme should miss; misses = %d, want 3", cr.misses)
	}
}
