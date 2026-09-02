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
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Block is the decoded wire block: a type discriminator plus raw fields.
// pdrender owns this type so the package has no apiclient dependency. The
// caller decodes the JSON map into Attrs; the renderers read type-specific
// fields out of it. Recursive section/expandable containers populate Children;
// figure populates Child — mirroring Render.Compose.compose_block/2's recursion
// shape (compose.ex).
type Block struct {
	ID       string
	Type     string
	Attrs    map[string]any
	Children []Block // container children, falling back to legacy blocks
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

// TaskChip is the resolver return for a wikilink whose target is a TASK
// (lvw-t7, wire §4): the live status/priority/criteria state the inline
// renderer draws as `[<glyph> <status> · P<n> · <met>/<total>] <title>`.
// pdrender OWNS this type (import discipline forbids apiclient — the caller
// maps API/datastore fields in, exactly like Block). Zero-value semantics are
// the degrade path: an empty Status keeps only the neutral glyph, HasPriority
// false drops the P-segment (Priority 0 is VALID — the HIGHEST priority, so a
// bool flag, not a zero sentinel), and CriteriaTotal 0 OMITS the m/n segment
// entirely (never "0/0").
type TaskChip struct {
	Title         string // resolved task title (chip label; falls back to alias/children/target when empty)
	Status        string // lifecycle status ("open" | "in_progress" | "blocked" | "done" | "cancelled" | other)
	Priority      int    // 0..4, 0 HIGHEST — only meaningful when HasPriority
	HasPriority   bool
	CriteriaMet   int // acceptance_criteria entries with met == true
	CriteriaTotal int // total acceptance_criteria entries; 0 = absent → omit segment
}

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

	// RefResolver is the caller-supplied seam for field-reference: given a
	// referenced doc id and its refType, it returns the doc's TITLE for display.
	// Nil → field-reference falls back to the raw id (the no-fetch rendering of
	// the stored datum). Mirrors render.ex's injected :ref_resolver opt — the
	// renderer stays pure (no API/Repo dependency), the caller wires the lookup.
	RefResolver func(id, refType string) string

	// CodelistResolver is the v2 sibling of RefResolver, for the `codelist`
	// block: given the registry-backed (plugin, issue/codelistId, code) tuple it
	// returns the human-readable LABEL for display. Nil → codelist falls back to
	// the raw code (then "—" for an empty code). Mirrors render.ex's injected
	// :codelist_resolver opt (`fn plugin, codelist_id, code -> label end`) — the
	// renderer stays pure; the caller wires the registry lookup.
	CodelistResolver func(plugin, issue, code string) string

	// TaskResolver is the wikilink task-chip seam (lvw-t7, wire §4/§5): given a
	// wikilink's pinned docId (or its raw target when unpinned), it returns the
	// live *TaskChip when the target is a TASK, or nil for anything else —
	// nil keeps the ordinary wikilink rendering (title/alias link degrade).
	// Nil field → no chip anywhere (the plain-wikilink degrade; matches the
	// CodelistResolver nil convention). The renderer stays pure: the caller
	// maps API data into TaskChip (pdrender never imports apiclient) and every
	// resolver-returned string passes through sanitizeText before display.
	TaskResolver func(id string) *TaskChip

	// ValueResolver is the inline live-value seam (lvw-t1, wire §3/§5): given a
	// valueref's target doc_id slug and its top-level field name, it returns the
	// CURRENT canonical value as a display string. The EMPTY string means
	// unresolved → the node renders its pinned `fallback` literal (the
	// v2fields.go convention: "" = miss, degrade, never error). Nil field → every
	// valueref renders its fallback (the no-fetch degrade; matches the
	// CodelistResolver nil convention). The renderer stays pure — the caller
	// wires the lookup (batched/memoised, never one fetch per node) — and every
	// resolver-returned string passes through sanitizeText before display.
	ValueResolver func(target, field string) string

	// ImageResolver is the image-bytes seam (pdrender-terminal-images): given
	// an image block's `src` (relative /media path or absolute URL), it returns
	// the raw encoded bytes, or nil for a miss. Nil field / nil return → the
	// labeled "🖼 …" box degrade. The renderer stays pure (no HTTP) — the caller
	// wires the fetch (bp paper view wires an apiclient-backed fetcher), the
	// ValueResolver convention. Only consulted under a TrueColor profile; the
	// decoded picture renders as a scroll-safe half-block mosaic (imagemosaic.go).
	ImageResolver func(src string) []byte

	// V2AsJSON, when true, renders the four v2 nested field blocks
	// (composite/arrayOf/codelist/localizedText) as a raw JSON dump instead of
	// the flat labelled summary. It DEFAULTS to false — the flat summary is
	// strictly more readable than a JSON blob and the flattening logic already
	// mirrors Render.Compose.composite_scalar/1 (compose.ex). The flag exists only as a one-line
	// opt-out for a caller that wants to honor the TUI's documented "JSON dump"
	// constraint literally; the summary path is the recommended default.
	V2AsJSON bool
}

// WithWidth returns a copy of the ctx with a new target width.
func (c RenderCtx) WithWidth(w int) RenderCtx { c.Width = w; return c }

// Deeper returns a copy of the ctx one nesting level deeper.
func (c RenderCtx) Deeper() RenderCtx { c.Depth++; return c }

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
// width. Mark application mirrors Render.Inline.compose_inline/2 (inline.ex) exactly.
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
	return boundDisplayLines(rend.Render(b, ctx), ctx.Width)
}

// boundDisplayLines is the shared final display boundary for both direct Render
// callers and RenderDoc. Individual renderers still own their semantic layout;
// this backstop only touches lines that actually overflow, so already-bounded
// code/literal output remains byte-identical. ansi.Wrap preserves ANSI/OSC8
// sequences while measuring visible terminal cells.
func boundDisplayLines(lines []string, width int) []string {
	width = clampWidth(width)
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if ansi.StringWidth(line) <= width {
			out = append(out, line)
			continue
		}
		out = append(out, strings.Split(ansi.Wrap(line, width, " "), "\n")...)
	}
	return out
}

func hardBoundDisplayLines(lines []string, width int) []string {
	width = clampWidth(width)
	out := make([]string, 0, len(lines))
	for _, line := range boundDisplayLines(lines, width) {
		if ansi.StringWidth(line) > width {
			// ansi.Wrap v0.8 can leave punctuation-heavy prose one or two cells
			// over its limit. At the final document boundary there is no parent
			// layout left to degrade, so a grapheme-aware hard wrap is safe and
			// preserves every authored byte plus ANSI/OSC sequence.
			out = append(out, strings.Split(ansi.Hardwrap(line, width, false), "\n")...)
		} else {
			out = append(out, line)
		}
	}
	return out
}

// RenderDoc stacks every top-level block with one blank line between them,
// joined into a single string via lipgloss.JoinVertical. It numbers nothing:
// figure captions carry exactly what the author typed (see figureCaption).
func (r *Registry) RenderDoc(blocks []Block, ctx RenderCtx) string {
	if ctx.Theme.isZero() {
		ctx.Theme = r.theme
	}
	parts := make([]string, 0, len(blocks)*2)
	emitted := 0
	for i := 0; i < len(blocks); {
		var lines []string
		// Consecutive field blocks render as ONE aligned definition list — a dim
		// label column + value column — instead of a stack of two-line pairs.
		if isFieldGroupType(blocks[i].Type) {
			j := i + 1
			for j < len(blocks) && isFieldGroupType(blocks[j].Type) {
				j++
			}
			lines = renderFieldGroup(r, blocks[i:j], ctx)
			i = j
		} else {
			lines = r.Render(blocks[i], ctx)
			i++
		}
		if len(lines) == 0 {
			continue
		}
		if emitted > 0 {
			parts = append(parts, "") // rhythm: one blank line between visible blocks
		}
		parts = append(parts, lines...)
		emitted++
	}
	joined := lipgloss.JoinVertical(lipgloss.Left, parts...)
	return strings.Join(hardBoundDisplayLines(strings.Split(joined, "\n"), ctx.Width), "\n")
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
	// scaffy:add-block-type Tabs MARK:go-registry-tabs
	r.blocks["tabs"] = tabsRenderer{reg: r}
	// scaffy:add-block-type CodeTabs MARK:go-registry-code-tabs
	r.blocks["code-tabs"] = codeTabsRenderer{reg: r}
	// scaffy:add-block-type ApiEndpoint MARK:go-registry-api-endpoint
	r.blocks["api-endpoint"] = apiEndpointRenderer{}
	// scaffy:add-block-type Video MARK:go-registry-video
	r.blocks["video"] = videoRenderer{}
	// scaffy:add-block-type CriteriaProgress MARK:go-registry-criteria-progress
	r.blocks["criteria-progress"] = criteriaProgressRenderer{}
	// scaffy:add-block-type Equation MARK:go-registry-equation
	r.blocks["equation"] = equationRenderer{}
	// scaffy:add-block-type BarChart MARK:go-registry-bar-chart
	r.blocks["bar-chart"] = barChartRenderer{}
	// scaffy:add-block-type Expandable MARK:go-registry-expandable
	r.blocks["expandable"] = expandableRenderer{reg: r}
	// scaffy:add-block-type Footnote MARK:go-registry-footnote
	r.blocks["footnote"] = footnoteRenderer{}
	// scaffy:add-block-type Steps MARK:go-registry-steps
	r.blocks["steps"] = stepsRenderer{reg: r}
	// scaffy:add-block-type Toc MARK:go-registry-toc
	r.blocks["toc"] = tocRenderer{}
	// scaffy:add-block-type Blockquote MARK:go-registry-blockquote
	r.blocks["blockquote"] = blockquoteRenderer{ir: ir}
	// scaffy:add-block-type Filetree MARK:go-registry-filetree
	r.blocks["filetree"] = filetreeRenderer{}
	// scaffy:add-block-type Diff MARK:go-registry-diff
	r.blocks["diff"] = diffRenderer{}
	r.blocks["paragraph"] = paragraphRenderer{ir: ir}
	lr := listRenderer{ir: ir}
	r.blocks["list"] = lr
	// Authoring-drift aliases → list (mirrors compose.ex's alias choke point):
	// agents hand-typed TipTap-internal / snake / kebab spellings via raw mutate,
	// leaving 77 live prod blocks unrenderable. The unordered spellings reuse the
	// list renderer as-is; `numbered_list` forces ordered:true; `quote` maps to
	// blockquote. No stored-data migration — the alias fixes prod content on read.
	r.blocks["bulletList"] = lr
	r.blocks["bullet_list"] = lr
	r.blocks["bulleted-list"] = lr
	r.blocks["bulleted_list"] = lr
	r.blocks["numbered_list"] = orderedListRenderer{lr: lr}
	// `ordered-list` is the same renderer under a second spelling (charter D57) —
	// 2 live blocks. Their items are map-shaped (`{content:[…]}`), which itemNodes
	// DOES normalize (blocks.go, the `map[string]any` arm unwraps `content`, then
	// `text`), so both the numbers and the item text render. The blank-item defect
	// this comment used to describe (charter D38, task-993d136b0fbf2fd1) was fixed
	// in #8105; the canonical `list` and this alias behave identically.
	r.blocks["ordered-list"] = orderedListRenderer{lr: lr}
	// h-tag spellings → heading at the level the TYPE names (charter D57): 18 live
	// prod blocks unknown-boxed on every surface, SIX of them carrying no `level`
	// key. See headingAtLevel in blocks.go. Registered HERE with the other
	// authoring-drift aliases rather than beside `heading`, because
	// scaffy/commands/add-block-type.scaffy anchors on the heading registration
	// line verbatim — that line is load-bearing template bytes, not free text.
	r.blocks["h1"] = headingAtLevel{hr: headingRenderer{ir: ir}, level: 1}
	r.blocks["h2"] = headingAtLevel{hr: headingRenderer{ir: ir}, level: 2}
	r.blocks["h3"] = headingAtLevel{hr: headingRenderer{ir: ir}, level: 3}
	r.blocks["quote"] = blockquoteRenderer{ir: ir}
	r.blocks["callout"] = calloutRenderer{ir: ir}
	r.blocks["divider"] = dividerRenderer{}
	// section recurses through the registry, so it holds a back-reference.
	r.blocks["section"] = sectionRenderer{reg: r}

	// ── M1 rich + typographic + field blocks ──────────────────────────────────
	r.blocks["code"] = newCodeRenderer()
	r.blocks["table"] = tableRenderer{ir: ir}
	// figure recurses through the registry (its single Child), so it holds a
	// back-reference like section.
	r.blocks["figure"] = figureRenderer{reg: r}
	r.blocks["action"] = actionRenderer{}
	r.blocks["pullquote"] = pullquoteRenderer{ir: ir}
	r.blocks["embed"] = embedRenderer{}
	r.blocks["ingress"] = ingressRenderer{ir: ir}
	r.blocks["eyebrow"] = eyebrowRenderer{}
	r.blocks["byline"] = bylineRenderer{}

	// field-* leaf blocks.
	r.blocks["field-string"] = fieldTextRenderer{}
	r.blocks["field-slug"] = fieldTextRenderer{}
	r.blocks["field-text"] = fieldTextRenderer{}
	r.blocks["field-boolean"] = fieldBooleanRenderer{}
	r.blocks["field-select"] = fieldSelectRenderer{}
	r.blocks["field-datetime"] = fieldDatetimeRenderer{}
	r.blocks["field-color"] = fieldColorRenderer{}
	r.blocks["field-reference"] = fieldReferenceRenderer{}
	r.blocks["field-image"] = fieldImageRenderer{}
	r.blocks["field-number"] = fieldNumberRenderer{}

	// ── M2 hard blocks (honest, labeled, never-panic) ─────────────────────────
	// No terminal draws mermaid, plays a cast, or paints inline graphics in a
	// scroll viewport — each of these renders a clearly-labeled box stating its
	// ceiling rather than faking a capability it lacks.
	r.blocks["diagram"] = diagramRenderer{}
	r.blocks["asciicast"] = asciicastRenderer{}
	r.blocks["image"] = imageRenderer{}

	// v2 nested field blocks: flat labelled summary by default (V2AsJSON opt-out).
	r.blocks["composite"] = compositeRenderer{}
	r.blocks["arrayOf"] = arrayOfRenderer{}
	r.blocks["codelist"] = codelistRenderer{}
	r.blocks["localizedText"] = localizedTextRenderer{}

	// form / questionnaire (alias): render-only fieldsets, no input wiring.
	r.blocks["form"] = formRenderer{}
	r.blocks["questionnaire"] = formRenderer{}

	// PdSheet: bordered spreadsheet grid with optional per-column widths.
	r.blocks["PdSheet"] = sheetRenderer{ir: ir}
	// Raw paper "sheet" embed blocks ({"type":"sheet","snapshot":{…}}) render
	// through the same grid via the snapshot-lifting adapter (values only —
	// see sheet.go for the documented merge/style/width losses).
	r.blocks["sheet"] = sheetBlockRenderer{sr: sheetRenderer{ir: ir}}

	// ── composition widgets (note / stage / card) ─────────────────────────────
	// Terminal counterparts of the web/Studio composition widgets. note + stage
	// are leaf renderers; card recurses its slots through the registry, so it
	// holds a back-reference like section / figure.
	r.blocks["note"] = noteRenderer{}
	r.blocks["stage"] = stageRenderer{}
	r.blocks["card"] = cardRenderer{reg: r}

	// ── layout / container blocks (columns / terminal) ─────────────────────────
	// Both recurse arbitrary child blocks through the registry, so each holds a
	// back-reference like section/figure/card.
	r.blocks["columns"] = columnsRenderer{reg: r}
	r.blocks["terminal"] = terminalRenderer{reg: r}

	// ── grid / ladder blocks (notes / cards / pipeline / status-legend) ────────
	// Terminal counterparts of the web/Studio grid widgets. notes/pipeline reuse
	// the singular note/stage renderers on a synthesized child Block; cards draws
	// its own tone-tinted box; status-legend inlines the fixed status ladder.
	r.blocks["notes"] = notesRenderer{}
	r.blocks["cards"] = cardsRenderer{}
	r.blocks["pipeline"] = pipelineRenderer{}
	r.blocks["status-legend"] = statusLegendRenderer{}

	// ── task widgets (task-list / task-detail / task-board / roadmap) ──────────
	// Terminal counterparts of the web/Studio task widgets. All are pre-resolved
	// leaf renderers (snapshot/task literal data in Attrs, no fetch); they share
	// the status vocabulary (roleForStatus/glyphForRole) with status-legend and
	// degrade honestly when the resolved key is absent. `tasks` is the canonical
	// type, `task-list` its accepted alias (mirrors compose.ex).
	r.blocks["tasks"] = taskListRenderer{}
	r.blocks["task-list"] = taskListRenderer{}
	r.blocks["task-detail"] = taskDetailRenderer{}
	r.blocks["task-board"] = taskBoardRenderer{}
	r.blocks["roadmap"] = roadmapRenderer{}

	// ── TUI creative slate ────────────────────────────────────────────────────
	// heatmap: a row-major intensity grid drawn through the auto-degrading cell
	// primitive (shade ladder by default; lipgloss truecolor only under a
	// TrueColor profile — see heatmap.go). W1 of the slate; W2/W3 reuse the cell.
	r.blocks["heatmap"] = heatmapRenderer{}
	// stat: a single KPI cell (big-number, or a bullet-bar when `max` is set) with
	// an optional caption + eighth-block sparkline. `stats` (alias `stat-grid`) is
	// the plural KPI grid — N cells laid out N-up through the shared Flex solver
	// (no new width math). W2 of the slate; W3's chart reuses the sparkline (see
	// stat.go). The eighth-block sparkline is the reusable W2/W3 primitive.
	r.blocks["stat"] = statRenderer{}
	r.blocks["stats"] = statsRenderer{}
	r.blocks["stat-grid"] = statsRenderer{}
	// gauge-list: a ranked stack of proportion meters (▓/░, the statBar idiom).
	// COUNT mode buckets a verbatim task-list snapshot by worker/phase/status/
	// priority; SHARE mode draws author {label,value,note} rows. Snapshot-
	// authoritative (never reads `query`); the datum lives in the bar length +
	// the right-aligned digits, so it survives an ANSI strip at every profile.
	// The most Barkpark-native slate block (see gaugelist.go).
	r.blocks["gauge-list"] = gaugeListRenderer{}
	// chart: a braille step-line (or bar) plot of one or more numeric series,
	// rasterised through the braille.go 2×4 dot-canvas. It reuses W2's sparkline
	// normaliser (sparkNorm) for point scaling — honouring pinned axes.min/max,
	// clamping out-of-span — and W1's truecolor auto-degrade (per-series colour
	// only under a TrueColor profile; ANSI-plain braille otherwise, byte-stable).
	// W3 of the slate — the capstone (see chart.go).
	r.blocks["chart"] = chartRenderer{}
	// route: a sport track (encoded polyline in `polyline`) rasterised through
	// the same braille dot-canvas as chart — the terminal twin of the web SVG
	// track shape (data_viz.ex §route). Meta row + caption below the plot.
	r.blocks["route"] = routeRenderer{}
	// ── jarl figure family (duel / lineage) ───────────────────────────────────
	// duel: a two-arm comparison — legend header + `label  valueA vs valueB`
	// rows with the authored dim delta under each label (duel.go). lineage:
	// dated nodes in authored order — dim overline / bold title / value+unit /
	// wrapped body (lineage.go). Both carry the kilde provenance law (kilde.go):
	// datum-bearing entries stamp a dim "Kilde:" line; an invalid ref renders
	// nothing. Terminal twins of dataviz.ts's duel/lineage emitters.
	r.blocks["duel"] = duelRenderer{}
	r.blocks["lineage"] = lineageRenderer{}
	// paper-links: a curated set of related Papers — section title + one entry
	// per referenced paper (title link / description / reason / metadata). The
	// terminal twin of compose.ex paper_links_html and @barkpark/react's
	// paper-links emitter; see paperlinks.go for the resolution rules.
	r.blocks["paper-links"] = paperLinksRenderer{ir: ir}
	// dashboard: a tabbed CONTAINER that composes the slate leaf blocks (chart /
	// heatmap / stat-grid / gauge-list) into a Claude-Code-/usage-style cockpit —
	// authored tabs + a heavy ━ active rail, the active tab's children laid out as
	// a two-track grid through the shared Flex solver. It recurses child blocks
	// through the registry, so it holds a back-reference like section/columns/card.
	// The composition capstone of the slate (see dashboard.go); $span in a child
	// query rides INERT (a future Elixir resolver wave reads it, never pdrender).
	r.blocks["dashboard"] = dashboardRenderer{reg: r}

	// ── chat structural blocks (dual-surface tool/todo/thinking rows) ──────────
	// Terminal twins of Studio's bespoke chat tool-row HEEx (chat_tool_renderer.ex),
	// promoted to PortableDoc block types so the same row renders on BOTH surfaces
	// (Law 1). Server carries the precomputed diff lines / todo list / token count
	// on the block; pdrender never re-derives (see chat_blocks.go).
	r.blocks["chat-tool-diff"] = chatToolDiffRenderer{}
	r.blocks["chat-todo"] = chatTodoRenderer{}
	r.blocks["chat-thinking"] = chatThinkingRenderer{}
	// The three INTERACTIVE cards (charter D35): the block is the read-time VISUAL;
	// answerability rides the message envelope (internal/chat cardView), not here.
	r.blocks["chat-approval"] = chatApprovalRenderer{}
	r.blocks["chat-question"] = chatQuestionRenderer{}
	r.blocks["chat-plan"] = chatPlanRenderer{}
	return r
}
