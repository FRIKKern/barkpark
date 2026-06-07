// Package pdrender renders Bulldocs portable-doc block trees to ANSI terminal
// output — "INK for portable-docs". It is the terminal counterpart to the
// Phoenix-side HTML renderer (api/lib/barkpark/portable_doc/render.ex): the
// same {version, blocks[]} document, walked to width-aware, styled lines via
// lipgloss instead of HTML.
//
// IMPORT DISCIPLINE: this package imports ONLY lipgloss + x/ansi + the stdlib.
// It MUST NOT import barkpark's main/TUI model or internal/apiclient — that
// keeps the extraction seam clean (internal/pdrender → a standalone module is
// a `git mv` away). The Theme comes in as a struct built by the caller; Blocks
// come in as pdrender-owned Go types decoded from the wire by the caller.
package pdrender

import (
	"github.com/charmbracelet/lipgloss"
)

// Block is the decoded wire block: a type discriminator plus raw fields.
// pdrender owns this type so the package has no apiclient dependency. The
// caller decodes the JSON map into Attrs; the renderers read type-specific
// fields out of it. Only `section` populates Children; only `figure`
// populates Child — mirroring compose_block/2's recursion shape in render.ex.
type Block struct {
	ID       string
	Type     string
	Attrs    map[string]any
	Children []Block // section.blocks
	Child    *Block  // figure.child
}

// Profile is the terminal color/capability profile. It gates OSC 8 hyperlinks
// and (later) the chroma formatter choice. It flows DOWN through RenderCtx.
type Profile int

const (
	// NoColor strips all color (the safe floor for dumb terminals / pipes).
	NoColor Profile = iota
	// ANSI16 is the 16-color (4-bit) palette.
	ANSI16
	// ANSI256 is the 256-color (8-bit) palette.
	ANSI256
	// TrueColor is 24-bit RGB. OSC 8 hyperlinks are assumed available here.
	TrueColor
)

// supportsHyperlinks reports whether OSC 8 clickable links should be emitted.
// We gate on >= ANSI256 as a pragmatic proxy for "a modern terminal"; lower
// profiles fall back to a dim " (href)" suffix.
func (p Profile) supportsHyperlinks() bool { return p >= ANSI256 }

// MinWidth is the graceful-degradation floor. When a container's inner width
// would drop below this, the container stops subtracting its chrome (drops the
// box / bar / indent) and renders flat. Mirrors the TUI's minEditorWidth idea.
const MinWidth = 20

// RenderCtx carries everything pushed DOWN the tree. It is immutable per call;
// nested renderers derive a narrower ctx (WithWidth) or a deeper one (Deeper)
// for their children. This is the immediate-mode discipline that replaces
// INK's constraint solver — the parent hands the child its width, the child
// owns its own wrapping.
type RenderCtx struct {
	Width   int     // hard target column count this block must fit
	Theme   Theme   // palette + pre-built lipgloss styles
	Depth   int     // nesting depth (section recursion); drives indent/rule weight
	Profile Profile // color/capability profile

	// figureN is a shared mutable counter for "Figure N." captions across a
	// whole document render. A pointer so the increment is visible to sibling
	// figures rendered later in the same RenderDoc pass.
	figureN *int
}

// WithWidth returns a copy of the ctx with a new target width.
func (c RenderCtx) WithWidth(w int) RenderCtx { c.Width = w; return c }

// Deeper returns a copy of the ctx one nesting level deeper.
func (c RenderCtx) Deeper() RenderCtx { c.Depth++; return c }

// nextFigure returns the next figure number, allocating the shared counter
// lazily so a ctx built by hand (e.g. in a test) still works.
func (c *RenderCtx) nextFigure() int {
	if c.figureN == nil {
		n := 0
		c.figureN = &n
	}
	*c.figureN++
	return *c.figureN
}

// Renderer is the per-block-type unit. It returns lines laid out to fit
// ctx.Width columns, ANSI-styled, ready for lipgloss.JoinVertical. Height is
// implicit in the slice length. Returning []string (not one joined string)
// lets the caller control inter-block spacing and lets a viewport slice
// cleanly.
type Renderer interface {
	Render(b Block, ctx RenderCtx) []string
}

// InlineRenderer walks a run of inline nodes into ONE styled string (no
// wrapping). The block renderer then word-wraps that string to its known
// width. Mark application mirrors compose_inline/2 in render.ex exactly.
type InlineRenderer struct {
	theme Theme
}

// Registry maps block types to renderers and holds the shared inline renderer
// plus a fallback for unknown types. It is the composition root: DefaultRegistry
// wires all M0 renderers, and the recursing renderers (section, figure) hold a
// back-reference so arbitrary nesting works without a retained tree.
type Registry struct {
	blocks   map[string]Renderer
	inline   InlineRenderer
	fallback Renderer
	theme    Theme
}

// Render dispatches a single block to its registered renderer, falling back to
// the unknown-type box when the type is unhandled (graceful degradation — a
// forward-compatible document never crashes the reader, unlike render.ex which
// raises ArgumentError).
func (r *Registry) Render(b Block, ctx RenderCtx) []string {
	rend, ok := r.blocks[b.Type]
	if !ok {
		rend = r.fallback
	}
	return rend.Render(b, ctx)
}

// RenderDoc stacks every top-level block with one blank line between them,
// joined into a single string via lipgloss.JoinVertical. A shared figure
// counter is seeded here so "Figure N." numbering is document-global.
func (r *Registry) RenderDoc(blocks []Block, ctx RenderCtx) string {
	figN := 0
	ctx.figureN = &figN
	if ctx.Theme.isZero() {
		ctx.Theme = r.theme
	}
	parts := make([]string, 0, len(blocks)*2)
	for i, b := range blocks {
		if i > 0 {
			parts = append(parts, "") // rhythm: a blank line between blocks
		}
		parts = append(parts, r.Render(b, ctx)...)
	}
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

// Inline is a thin pass-through so callers (and the demo) can render a run of
// inline nodes without reaching into the unexported field.
func (r *Registry) Inline(nodes []any, ctx RenderCtx) string {
	return r.inline.Inline(nodes, ctx)
}

// DefaultRegistry wires every M0 block renderer against the given theme. Later
// milestones add one entry per new block type — the INK-like ergonomic.
func DefaultRegistry(theme Theme) *Registry {
	r := &Registry{
		blocks:   map[string]Renderer{},
		inline:   InlineRenderer{theme: theme},
		fallback: fallbackRenderer{},
		theme:    theme,
	}
	ir := r.inline
	r.blocks["heading"] = headingRenderer{ir: ir}
	r.blocks["paragraph"] = paragraphRenderer{ir: ir}
	r.blocks["list"] = listRenderer{ir: ir}
	r.blocks["callout"] = calloutRenderer{ir: ir}
	r.blocks["divider"] = dividerRenderer{}
	// section recurses through the registry, so it holds a back-reference.
	r.blocks["section"] = sectionRenderer{reg: r}
	return r
}
