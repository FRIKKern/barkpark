//go:build js && wasm

// pdrender-wasm — the REAL Go pdrender, compiled to WebAssembly so the browser
// reader can render a PortableDoc to its faithful terminal (TUI) form. This is
// the exact same `internal/pdrender` code `bp paper view` runs; there is no
// second/imitation renderer. It exposes one JS global:
//
//	bpRenderTUI(blocksJSON string, width int, mode string, themeID string) -> htmlString
//
// mode is the light/dark switch ("dark" default); themeID is the optional theme
// identity (which emitted skin — "evergreen" default). The two are orthogonal.
//
// The render produces ANSI (SGR), which we convert to self-contained HTML
// (colored <span>s inside a <pre>) here in Go so the caller gets a
// ready-to-inject fragment with the true colors pdrender emits.
package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"syscall/js"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

func renderTUI(_ js.Value, args []js.Value) any {
	if len(args) < 1 {
		return "<pre>bpRenderTUI: missing required blocksJSON argument</pre>"
	}
	blocksJSON := args[0].String()
	width := 92
	if len(args) > 1 && args[1].Type() == js.TypeNumber && args[1].Int() > 0 {
		width = args[1].Int()
	}
	// arg[2] is the light/dark MODE (the JS "theme" arg — a documented mode/theme
	// name collision, D30); arg[3] is the optional theme IDENTITY (which emitted
	// skin — "evergreen" today, empty → evergreen via pdrender.Resolve).
	mode := "dark"
	if len(args) > 2 && args[2].Type() == js.TypeString {
		mode = args[2].String()
	}
	themeID := pdrender.DefaultTheme
	if len(args) > 3 && args[3].Type() == js.TypeString && args[3].String() != "" {
		themeID = args[3].String()
	}

	lipgloss.SetColorProfile(termenv.TrueColor)

	blocks, err := pdrender.Decode([]byte(blocksJSON))
	if err != nil {
		return "<pre>decode error: " + htmlEscape(err.Error()) + "</pre>"
	}
	theme := pdrender.ThemeFor(themeID, mode)
	ctx := pdrender.RenderCtx{Width: width, Theme: theme, Profile: pdrender.TrueColor}
	ansi := pdrender.DefaultRegistry(theme).RenderDoc(blocks, ctx)
	return ansiToHTML(ansi)
}

// ── ANSI (SGR + OSC-8) → HTML ────────────────────────────────────────────────

var (
	sgrRe  = regexp.MustCompile(`\x1b\[([0-9;]*)m`)
	osc8Re = regexp.MustCompile(`\x1b\]8;[^;]*;[^\x1b\x07]*(?:\x1b\\|\x07)`)
)

type sgrState struct {
	fg, bg     string
	bold, ital bool
	under      bool
}

func (s sgrState) style() string {
	var b strings.Builder
	if s.fg != "" {
		b.WriteString("color:" + s.fg + ";")
	}
	if s.bg != "" {
		b.WriteString("background:" + s.bg + ";")
	}
	if s.bold {
		b.WriteString("font-weight:700;")
	}
	if s.ital {
		b.WriteString("font-style:italic;")
	}
	if s.under {
		b.WriteString("text-decoration:underline;")
	}
	return b.String()
}

func ansiToHTML(s string) string {
	// Strip OSC-8 hyperlink wrappers, keeping the visible label text.
	s = osc8Re.ReplaceAllString(s, "")

	var out strings.Builder
	out.WriteString(`<pre class="bp-tui-pre">`)
	var st sgrState
	open := false
	closeSpan := func() {
		if open {
			out.WriteString("</span>")
			open = false
		}
	}
	openSpan := func() {
		style := st.style()
		if style != "" {
			out.WriteString(`<span style="` + style + `">`)
			open = true
		}
	}

	idx := sgrRe.FindAllStringSubmatchIndex(s, -1)
	last := 0
	for _, m := range idx {
		out.WriteString(htmlEscape(s[last:m[0]]))
		params := s[m[2]:m[3]]
		last = m[1]
		closeSpan()
		applySGR(&st, params)
		openSpan()
	}
	out.WriteString(htmlEscape(s[last:]))
	closeSpan()
	out.WriteString("</pre>")
	return out.String()
}

func applySGR(st *sgrState, params string) {
	if params == "" || params == "0" {
		*st = sgrState{}
		return
	}
	codes := strings.Split(params, ";")
	for i := 0; i < len(codes); i++ {
		n, _ := strconv.Atoi(codes[i])
		switch {
		case n == 0:
			*st = sgrState{}
		case n == 1:
			st.bold = true
		case n == 3:
			st.ital = true
		case n == 4:
			st.under = true
		case n == 22:
			st.bold = false
		case n == 23:
			st.ital = false
		case n == 24:
			st.under = false
		case n == 39:
			st.fg = ""
		case n == 49:
			st.bg = ""
		case n >= 30 && n <= 37:
			st.fg = basic16[n-30]
		case n >= 90 && n <= 97:
			st.fg = basic16[8+(n-90)]
		case n >= 40 && n <= 47:
			st.bg = basic16[n-40]
		case n >= 100 && n <= 107:
			st.bg = basic16[8+(n-100)]
		case n == 38 || n == 48:
			if i+1 < len(codes) {
				mode, _ := strconv.Atoi(codes[i+1])
				if mode == 2 && i+4 < len(codes) {
					r, _ := strconv.Atoi(codes[i+2])
					g, _ := strconv.Atoi(codes[i+3])
					bb, _ := strconv.Atoi(codes[i+4])
					col := fmt.Sprintf("#%02x%02x%02x", r, g, bb)
					if n == 38 {
						st.fg = col
					} else {
						st.bg = col
					}
					i += 4
				} else if mode == 5 && i+2 < len(codes) {
					col := xterm256(codes[i+2])
					if n == 38 {
						st.fg = col
					} else {
						st.bg = col
					}
					i += 2
				}
			}
		}
	}
}

var basic16 = [16]string{
	"#1c1c1c", "#d64545", "#4fae63", "#c8a13a", "#4a8fd6", "#a86fd6", "#3fb6b6", "#c8d3cc",
	"#6b7972", "#f08a80", "#5fcf9c", "#e0b65f", "#8ab4e8", "#c9a6f0", "#7fd6d6", "#eaf3ee",
}

// xterm256Fallback is returned for any input outside the valid 0..255 xterm
// colour range (including non-numeric input) rather than indexing out of
// bounds — this is the WASM bridge's declared-untrusted ANSI entrypoint, so
// it must be safe on its own terms.
const xterm256Fallback = "#000000"

func xterm256(s string) string {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 || n > 255 {
		return xterm256Fallback
	}
	if n < 16 {
		return basic16[n]
	}
	if n >= 232 {
		g := 8 + (n-232)*10
		return fmt.Sprintf("#%02x%02x%02x", g, g, g)
	}
	n -= 16
	r := (n / 36) % 6
	gg := (n / 6) % 6
	b := n % 6
	conv := func(v int) int {
		if v == 0 {
			return 0
		}
		return 55 + v*40
	}
	return fmt.Sprintf("#%02x%02x%02x", conv(r), conv(gg), conv(b))
}

func htmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

func main() {
	js.Global().Set("bpRenderTUI", js.FuncOf(renderTUI))
	select {}
}
