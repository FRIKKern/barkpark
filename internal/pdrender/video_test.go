package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestVideoRenderer proves the video block renders a labeled box naming the
// src THROUGH the registry — one assertion covering both the renderer and
// its DefaultRegistry registration.
func TestVideoRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "video", Attrs: map[string]any{"src": "https://ex.com/demo.mp4"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "Video") || !strings.Contains(got, "https://ex.com/demo.mp4") {
		t.Fatalf("video render missing label or src, got %q", got)
	}
}

// TestVideoRendererCaptionCount pins the caption-track-count suffix.
func TestVideoRendererCaptionCount(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "video", Attrs: map[string]any{
		"src": "https://ex.com/demo.mp4",
		"captions": []any{
			map[string]any{"lang": "en", "src": "https://ex.com/en.vtt"},
			map[string]any{"lang": "no", "src": "https://ex.com/no.vtt"},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "2 caption tracks") {
		t.Fatalf("video render missing caption count, got %q", got)
	}
}

// TestVideoRendererEmptyIsSilent pins the honest empty state: a video block
// with no src contributes zero lines.
func TestVideoRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "video", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty video should render nothing, got %d lines", len(lines))
	}
}
