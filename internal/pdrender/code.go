package pdrender

import (
	"crypto/sha256"
	"encoding/binary"
	"strings"
	"sync"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	"github.com/alecthomas/chroma/v2/lexers"
	"github.com/alecthomas/chroma/v2/styles"
	"github.com/charmbracelet/x/ansi"
)

// ── code ───────────────────────────────────────────────────────────────────
// Mirrors compose_block(code, :article): one syntax-highlighted block wrapped
// in lipgloss chrome (a left accent bar + an optional lang header line). Unlike
// the prose renderers this goes through chroma DIRECTLY (not glamour) for full
// control over the chrome.
//
// The portable-doc `code` block has NO `lang` field, so we let chroma's
// lexers.Analyse(source) guess the language; on a miss we fall back to the
// plaintext lexer (lexers.Get("text")). The chroma style name is theme-driven
// (Theme.ChromaStyle: "github" light / "monokai"|"dracula" dark). The FORMATTER
// is chosen by ctx.Profile so the emitted SGR escapes match the terminal's
// capability:
//
//	TrueColor → terminal16m   ANSI256 → terminal256
//	ANSI16    → terminal16     NoColor → noop (plain text, no escapes)
//
// VIEWPORT ANSI-BLEED (bubbles #527): a too-rich escape the terminal can't slice
// cleanly leaks color across lines when a viewport cuts a styled line mid-run.
// We therefore prefer terminal256 unless TrueColor is *certain* — see
// formatterName below — which keeps escapes to the well-behaved indexed family.
//
// WIDTH: code lines are NOT word-wrapped (wrapping source corrupts it). Long
// lines are left-truncated to the inner width with a trailing "…" so they never
// overflow ctx.Width and bleed into the next viewport column. (Horizontal scroll
// is a viewport-level concern deferred past M1.)
//
// MEMOIZATION: Render is keyed by (contentHash, width, themeID, profile) in a
// small per-renderer cache — the manual equivalent of React skipping an
// unchanged subtree. A hit returns the cached lines verbatim.
type codeRenderer struct {
	mu     sync.Mutex
	cache  map[codeKey][]string
	misses int // instrumentation: counts cache MISSES (actual chroma runs)
	hits   int // instrumentation: counts cache HITS
}

func newCodeRenderer() *codeRenderer {
	return &codeRenderer{cache: map[codeKey][]string{}}
}

// maxCodeCacheEntries bounds the memo cache so a long-running TUI session
// rendering many distinct code blocks (across papers, widths, themes) can't grow
// it without limit. Clear-on-full is enough for a render cache: the visible
// working set re-populates on the next frame, and the common case — re-rendering
// the same viewport — never approaches the cap.
const maxCodeCacheEntries = 512

// codeKey is the memo key: a content hash plus the render-affecting axes. Both
// the theme IDENTITY and the light/dark MODE are keyed (ts-w4c): the chroma style
// AND the resolved palette differ per (theme, mode), so two themes at the same
// mode — or one theme in two modes — must not share a cached render.
type codeKey struct {
	hash    uint64
	width   int
	themeID string
	mode    string
	profile Profile
}

func (cr *codeRenderer) Render(b Block, ctx RenderCtx) []string {
	// Field-name reconciliation (verified against live Bulldocs JSON): code
	// blocks emit their source under EITHER `code` (the newer shape, e.g.
	// {"type":"code","code":"…","language":"bash"}) OR `value` (the legacy/
	// flat-mode shape render.ex's compose_block reads). Prefer the live `code`
	// key, fall back to `value`; likewise `language`||`lang`. Without this dual
	// read a real `code`-shaped block renders as an EMPTY accent bar.
	source := attrStrFirst(b.Attrs, "code", "value")
	lang := attrStrFirst(b.Attrs, "language", "lang") // usually absent; tolerated.

	// A blank or whitespace-only source renders NOTHING — no lines, no accent
	// bar. This mirrors the Elixir composer since #14806 (a sourceless code
	// block composes to nothing, not an empty box); before this guard the Go
	// readers painted a lone "▌" where the web rendered nothing, a View/TUI
	// parity break on the same block (task-841c27ea82903f48). Checked before
	// the cache key so the empty case never occupies a slot. Re-expressed
	// through the shared blankAttr leaf reader (blank.go) when the four other
	// media guards landed, exactly as compose.ex re-expressed
	// `blank_code_source?/1` through `blank_field?/2` in #14991 — one definition
	// of blank, applied to code's documented dual-read (`code`||`value`).
	// Behaviour-identical for every string/nil case; a non-stringish (map) value
	// now reads as blank, which is what compose.ex has always said.
	if blankAttr(b.Attrs, "code") && blankAttr(b.Attrs, "value") {
		return nil
	}

	key := codeKey{
		hash:    hashStrings(source, lang),
		width:   ctx.Width,
		themeID: ctx.Theme.themeID, // theme identity (ts-w4c)
		mode:    ctx.Theme.name,    // Theme.name holds the light/dark mode
		profile: ctx.Profile,
	}

	cr.mu.Lock()
	if lines, ok := cr.cache[key]; ok {
		cr.hits++
		cr.mu.Unlock()
		return lines
	}
	cr.misses++
	cr.mu.Unlock()

	lines := cr.render(source, lang, ctx)

	cr.mu.Lock()
	if len(cr.cache) >= maxCodeCacheEntries {
		cr.cache = make(map[codeKey][]string, maxCodeCacheEntries)
	}
	cr.cache[key] = lines
	cr.mu.Unlock()
	return lines
}

// render is the un-memoized body: lex → highlight → chrome.
func (cr *codeRenderer) render(source, lang string, ctx RenderCtx) []string {
	const chrome = 2 // "▌ " bar (2)
	inner := ctx.Width - chrome
	if inner < MinWidth {
		// Drop the bar; render highlighted lines flat at full width.
		return cr.highlight(source, lang, ctx, ctx.Width)
	}

	highlighted := cr.highlight(source, lang, ctx, inner)

	bar := ctx.Theme.CodeBar.Render("▌")
	out := make([]string, 0, len(highlighted)+1)

	// Optional lang header line: only when we can name a language. Analyse may
	// pick one even though the block carried none.
	if name := cr.lexerName(source, lang); name != "" && name != "plaintext" {
		header := ctx.Theme.Dim.Render(strings.ToUpper(name))
		out = append(out, bar+" "+header)
	}
	for _, line := range highlighted {
		out = append(out, bar+" "+line)
	}
	return out
}

// highlight runs chroma and returns the highlighted source as per-line strings,
// each left-truncated to width so nothing overflows. NoColor profile short-
// circuits to plain truncated source (no chroma escapes at all).
func (cr *codeRenderer) highlight(source, lang string, ctx RenderCtx, width int) []string {
	rawLines := strings.Split(strings.TrimRight(source, "\n"), "\n")

	if ctx.Profile == NoColor {
		// Plain, un-highlighted path: no chroma SGR to preserve, so strip any
		// author escape-class control bytes from each source line before it hits
		// the terminal. Tabs survive (sanitizeCodeText) so indentation is kept.
		out := make([]string, len(rawLines))
		for i, l := range rawLines {
			out[i] = truncateANSI(sanitizeCodeText(l), width)
		}
		return out
	}

	// Coalesce merges adjacent same-type tokens so the formatter emits fewer,
	// longer SGR runs — fewer escapes to mangle when a viewport slices a line
	// (the ANSI-bleed concern, bubbles #527).
	lexer := chroma.Coalesce(cr.lexer(source, lang))
	style := styles.Get(ctx.Theme.ChromaStyle)
	if style == nil {
		style = styles.Fallback
	}
	formatter := formatters.Get(formatterName(ctx.Profile))

	// Sanitize the source before lexing so no author escape-class control byte
	// survives into the highlighted output — chroma's SGR is added AFTER
	// tokenisation, so stripping input escapes cannot corrupt highlighting. Tabs
	// and newlines survive (sanitizeCodeSource) so indentation AND line structure
	// are preserved — sanitizeCodeText here would strip the newlines and collapse
	// the block to one line.
	iterator, err := lexer.Tokenise(nil, sanitizeCodeSource(source))
	if err != nil {
		// Tokenise failed → plain truncated source.
		out := make([]string, len(rawLines))
		for i, l := range rawLines {
			out[i] = truncateANSI(sanitizeCodeText(l), width)
		}
		return out
	}

	var buf strings.Builder
	if err := formatter.Format(&buf, style, iterator); err != nil {
		out := make([]string, len(rawLines))
		for i, l := range rawLines {
			out[i] = truncateANSI(sanitizeCodeText(l), width)
		}
		return out
	}

	hl := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
	for i, l := range hl {
		hl[i] = truncateANSI(l, width)
	}
	return hl
}

// lexer picks the chroma lexer: an explicit lang if present, else Analyse on the
// source, else the plaintext fallback. Never nil.
func (cr *codeRenderer) lexer(source, lang string) chroma.Lexer {
	if lang != "" {
		if l := lexers.Get(lang); l != nil {
			return l
		}
	}
	if l := lexers.Analyse(source); l != nil {
		return l
	}
	if l := lexers.Get("text"); l != nil {
		return l
	}
	return lexers.Fallback
}

// lexerName returns the human-facing language name for the header line (or ""
// when nothing better than plaintext was inferred).
func (cr *codeRenderer) lexerName(source, lang string) string {
	l := cr.lexer(source, lang)
	if l == nil {
		return ""
	}
	cfg := l.Config()
	if cfg == nil {
		return ""
	}
	return strings.ToLower(cfg.Name)
}

// formatterName maps a profile to a chroma formatter registry name. Per the
// ANSI-bleed note we keep to the indexed (terminal256/16) family for the common
// case; terminal16m (truecolor) only when the profile is explicitly TrueColor.
func formatterName(p Profile) string {
	switch p {
	case TrueColor:
		return "terminal16m"
	case ANSI256:
		return "terminal256"
	case ANSI16:
		return "terminal16"
	default:
		return "noop"
	}
}

// truncateANSI left-truncates an ANSI-styled line to width display cells,
// appending a dim "…" when it overflows. ansi.Truncate counts visible cells, not
// escape bytes, and leaves SGR state balanced.
func truncateANSI(s string, width int) string {
	if width < 1 {
		width = 1
	}
	if ansi.StringWidth(s) <= width {
		return s
	}
	return ansi.Truncate(s, width, "…")
}

// hashStrings is a tiny FNV-ish content hash over the code parts, used as the
// memo key's content axis. SHA-256 folded to 64 bits — collision-free enough for
// a render cache and stable across runs.
func hashStrings(parts ...string) uint64 {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0}) // separator so ("ab","c") ≠ ("a","bc")
	}
	sum := h.Sum(nil)
	return binary.BigEndian.Uint64(sum[:8])
}
