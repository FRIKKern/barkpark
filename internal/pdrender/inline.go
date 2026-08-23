package pdrender

import (
	"fmt"
	"strings"
)

// Inline renders a run of inline nodes to ONE styled ANSI string (no wrapping).
// It is a faithful port of compose_inline/2 + apply_marks/3 in render.ex:
//
//   - text (+ marks bold/italic/underline/strike/code/link) — marks applied
//     RIGHT-TO-LEFT so the FIRST mark in the list ends up OUTERMOST (matches
//     ProseMirror's serializer order, and the Elixir Enum.reverse |> reduce).
//   - strong / em — recurse into children, wrap bold / italic.
//   - code — a leaf inline chip (subtle bg + the theme's InlineCode style).
//   - link — NON-recursive: a link nested in a link flattens to plain text.
//   - bare strings / numbers — coerced to a text node (compose_inline tolerance).
//
// The block renderer then word-wraps the returned string to its known width.
func (ir InlineRenderer) Inline(nodes []any, ctx RenderCtx) string {
	var b strings.Builder
	for _, n := range nodes {
		b.WriteString(ir.node(n, ctx, false))
	}
	return b.String()
}

// node renders a single inline node. insideLink tracks whether we are already
// within a link so a nested link can flatten (the model keeps links
// non-recursive).
func (ir InlineRenderer) node(n any, ctx RenderCtx, insideLink bool) string {
	switch v := n.(type) {
	case string:
		// Bare string → a text node with no marks.
		return sanitizeDisplayText(v)
	case float64, int, int64, bool:
		return toStr(v)
	case fmt.Stringer:
		return v.String()
	case map[string]any:
		return ir.typed(v, ctx, insideLink)
	default:
		return ""
	}
}

// typed dispatches a map-shaped inline node by its "type" discriminator.
func (ir InlineRenderer) typed(n map[string]any, ctx RenderCtx, insideLink bool) string {
	switch attrStr(n, "type") {
	case "text":
		marks := attrSlice(n, "marks")
		// Dual-read "value" || legacy "text": raw mutate writers persisted text
		// leaves keyed {"type":"text","text":…}; the Hollow predicate counts both
		// spellings as content, so the renderers must agree or such a paper reads
		// as structure with zero prose. Mirrors compose_inline in the Elixir twin
		// (render/inline.ex).
		value := sanitizeDisplayText(attrStrFirst(n, "value", "text"))
		if hasCodeMark(marks) {
			value = sanitizeText(attrStrFirst(n, "value", "text"))
		}
		if len(marks) == 0 {
			return value
		}
		return ir.applyMarks(value, marks, ctx, insideLink)

	case "strong":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("bold").Render(inner)

	case "em":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("italic").Render(inner)

	case "underline":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("underline").Render(inner)

	case "strikethrough", "strike", "s":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("strikethrough").Render(inner)

	case "code":
		return ir.theme.InlineCode.Render(sanitizeText(attrStr(n, "value")))

	case "link":
		// Children are rendered with insideLink=true so a nested link flattens.
		inner := ir.children(n, ctx, true)
		if insideLink {
			// Nested link → plain (already-styled) text, no new link chrome.
			return inner
		}
		return ir.renderLink(attrStr(n, "href"), inner, ctx)

	case "wikilink":
		// Task-chip branch (lvw-t7, wire §4): when the injected TaskResolver
		// recognises the target as a TASK, render the live status chip.
		// Nil-check first (the v2fields.go CodelistResolver pattern) — a nil
		// resolver or a nil chip keeps the plain-wikilink degrade below.
		if ctx.TaskResolver != nil {
			if id := wikilinkResolveID(n); id != "" {
				if chip := ctx.TaskResolver(id); chip != nil {
					return ir.renderTaskChip(chip, n, ctx, insideLink)
				}
			}
		}
		// Plain internal link — no href yet. Render the label in the link
		// style, with the ordered fallback alias → children → target (wire §4
		// amended — a chip-shaped node ships alias + children:[], which
		// previously rendered as an empty string).
		return ir.theme.Link.Render(ir.wikilinkLabel(n, ctx, insideLink))

	case "blockref":
		// Leaf — the "^anchor" pointer token, dimmed.
		return ir.theme.Dim.Render("^" + attrStr(n, "anchor"))

	case "tag":
		// Leaf — the "#name" token, link-styled.
		return ir.theme.Link.Render("#" + attrStr(n, "name"))

	case "valueref":
		// Inline live value (lvw-t1, wire §3/§6): the injected ValueResolver
		// returns the CURRENT canonical value for (target, field); an empty
		// string — or a nil resolver — degrades to the node's pinned `fallback`
		// literal. The node's children (the D6 dual-written fallback subtree
		// for OLD binaries) are IGNORED here; `as`/`label` are RESERVED and
		// never interpreted. Every displayed string passes through sanitizeText
		// so a hostile canonical value (raw ESC bytes) renders inert. NEVER
		// errors, NEVER blanks by design (a well-formed node pins `fallback`).
		return ir.theme.Body.Render(ir.valuerefText(n, ctx))

	default:
		// Unknown inline type → render its children if any, else nothing.
		// (compose_inline raises here; we degrade gracefully like the block path.)
		if _, ok := n["children"]; ok {
			return ir.children(n, ctx, insideLink)
		}
		return ""
	}
}

// children renders an inline node's "children" array in order.
func (ir InlineRenderer) children(n map[string]any, ctx RenderCtx, insideLink bool) string {
	var b strings.Builder
	for _, c := range attrSlice(n, "children") {
		b.WriteString(ir.node(c, ctx, insideLink))
	}
	return b.String()
}

// valuerefText picks the visible string for a valueref: the resolver's
// non-empty return wins ("" = unresolved, the v2fields.go miss convention),
// else the pinned `fallback` literal. Both paths sanitize — the canonical
// value is document/tenant-controlled data and must not carry terminal
// control bytes into the reader.
func (ir InlineRenderer) valuerefText(n map[string]any, ctx RenderCtx) string {
	target := strings.TrimSpace(attrStr(n, "target"))
	field := strings.TrimSpace(attrStr(n, "field"))
	// Wire §3: `field` is a single TOP-LEVEL name — a dot-path (incl. the
	// `content.` prefix) is a wire violation and never reaches the resolver,
	// so a resolver and the server's visibility gate can never disagree on
	// which top segment is being read (defense in depth; the CLI resolver
	// guards too).
	if ctx.ValueResolver != nil && target != "" && field != "" && !strings.Contains(field, ".") {
		if v := sanitizeText(strings.TrimSpace(ctx.ValueResolver(target, field))); v != "" {
			return v
		}
	}
	return sanitizeText(attrStr(n, "fallback"))
}

// wikilinkResolveID picks the id handed to TaskResolver: the picker-stamped
// docId pin wins (JS spelling first, snake_case tolerated), then the raw
// target (a typed-not-picked wikilink resolves by title/id server-side — the
// caller's map decides what it recognises).
func wikilinkResolveID(n map[string]any) string {
	if id := strings.TrimSpace(attrStr(n, "docId")); id != "" {
		return id
	}
	if id := strings.TrimSpace(attrStr(n, "doc_id")); id != "" {
		return id
	}
	return strings.TrimSpace(attrStr(n, "target"))
}

// wikilinkLabel is the visible wikilink label: ordered fallback alias →
// children → target (wire §4 amended). Alias/target are resolver-adjacent
// strings and pass through sanitizeText; children render through the normal
// node path (text leaves sanitize themselves).
func (ir InlineRenderer) wikilinkLabel(n map[string]any, ctx RenderCtx, insideLink bool) string {
	if alias := sanitizeText(strings.TrimSpace(attrStr(n, "alias"))); alias != "" {
		return alias
	}
	if inner := ir.children(n, ctx, insideLink); inner != "" {
		return inner
	}
	return sanitizeText(strings.TrimSpace(attrStr(n, "target")))
}

// renderTaskChip draws the live task chip (lvw-t7, wire §4):
// `[<glyph> <status> · P<n> · <met>/<total>] <title>`. Segments degrade
// independently: empty status keeps only the neutral glyph, HasPriority false
// drops the P-segment (0 is a VALID priority — the HIGHEST), CriteriaTotal 0
// omits the m/n segment (never "0/0"). ALL resolver-returned strings pass
// through sanitizeText. Never raises, never blanks — an empty title falls back
// to the alias/children/target label.
func (ir InlineRenderer) renderTaskChip(chip *TaskChip, n map[string]any, ctx RenderCtx, insideLink bool) string {
	status := sanitizeText(strings.TrimSpace(chip.Status))

	segs := make([]string, 0, 3)
	if status != "" {
		segs = append(segs, taskStatusGlyph(status)+" "+status)
	} else {
		segs = append(segs, taskStatusGlyph(status))
	}
	if chip.HasPriority && chip.Priority >= 0 {
		segs = append(segs, fmt.Sprintf("P%d", chip.Priority))
	}
	if chip.CriteriaTotal > 0 {
		segs = append(segs, fmt.Sprintf("%d/%d", chip.CriteriaMet, chip.CriteriaTotal))
	}

	title := sanitizeText(strings.TrimSpace(chip.Title))
	if title == "" {
		title = ir.wikilinkLabel(n, ctx, insideLink)
	}

	chipText := "[" + strings.Join(segs, " · ") + "]"
	return ir.theme.Dim.Render(chipText) + " " + ir.theme.Link.Render(title)
}

// taskStatusGlyph maps a task lifecycle status to its chip glyph. For the known
// lifecycle statuses it DELEGATES to the status-manifest-gated vocabulary in
// gridblocks.go (glyphForRole ∘ roleForStatus — the UNSTYLED accessor, because
// the chip is already Dim-wrapped at renderTaskChip; glyphForStatus pre-applies
// color and would double-style). This kills the last hardcoded glyph fork so the
// in-body chip and the adjacent task board speak ONE status language (D100).
//
// The known-status guard is MANDATORY: roleForStatus maps any UNRECOGNIZED
// status onto role "open" (glyph ○) in its default clause, so an unconditional
// delegate would silently collapse the unknown-status sentinel. Everything
// outside the known set keeps the neutral ▸ pointer.
func taskStatusGlyph(status string) string {
	switch status {
	case "open", "ready", "in_progress", "blocked", "done", "closed", "cancelled", "considering", "researching":
		return glyphForRole(roleForStatus(status))
	default:
		return "▸"
	}
}

// applyMarks folds a ProseMirror-style mark list RIGHT-TO-LEFT around a text
// leaf, so the first mark in the list is the OUTERMOST wrapper. Direct port of
// apply_marks/3 + apply_mark/3 in render.ex.
//
// In a terminal we cannot nest <span> tags; instead each mark contributes its
// styling attribute to a single lipgloss.Style, accumulated, then applied once.
// The link mark is the exception — it wraps the styled text in OSC 8 chrome (or
// a dim suffix), and it is non-recursive, so once a link mark is seen the
// remaining (outer) marks still style the visible text but cannot re-link it.
func (ir InlineRenderer) applyMarks(value string, marks []any, ctx RenderCtx, insideLink bool) string {
	style := ir.theme.Body
	codeChip := false
	var linkHref string
	hasLink := false

	// Walk marks right-to-left so the first mark wins on conflicts and lands
	// as the conceptual outermost wrapper. For flat lipgloss styling the order
	// only matters for the link decision, which we resolve below.
	for i := len(marks) - 1; i >= 0; i-- {
		mt := markType(marks[i])
		switch mt {
		case "bold", "strong":
			style = style.Bold(true)
		case "italic", "em":
			style = style.Italic(true)
		case "underline":
			style = style.Underline(true)
		case "strike", "s", "strikethrough":
			style = style.Strikethrough(true)
		case "code":
			// code is leaf-only in render.ex; if it is the innermost mark we
			// switch to the InlineCode chip. Outer marks still apply on top.
			codeChip = true
		case "link":
			if !insideLink {
				hasLink = true
				linkHref = markHref(marks[i])
			}
		}
	}

	var rendered string
	if codeChip {
		// The chip style carries its own bg; layer the accumulated emphasis on
		// top by rendering the chip first, then re-styling is not additive in
		// lipgloss, so we apply InlineCode merged with the emphasis flags.
		rendered = ir.theme.inlineCodeWith(style).Render(value)
	} else {
		rendered = style.Render(value)
	}

	if hasLink {
		return ir.renderLink(linkHref, rendered, ctx)
	}
	return rendered
}

// renderLink wraps already-styled text in the link presentation: underline +
// link color, plus an OSC 8 hyperlink when the profile supports it, else a dim
// " (href)" suffix so the URL is still reachable on a dumb terminal.
func (ir InlineRenderer) renderLink(href, text string, ctx RenderCtx) string {
	href = sanitizeURL(strings.TrimSpace(href))
	styled := ir.theme.Link.Render(text)
	if href == "" {
		return styled
	}
	if ctx.Profile.supportsHyperlinks() {
		// OSC 8: \x1b]8;;<href>\x1b\\<text>\x1b]8;;\x1b\\
		return "\x1b]8;;" + href + "\x1b\\" + styled + "\x1b]8;;\x1b\\"
	}
	return styled + ir.theme.Dim.Render(" ("+href+")")
}

// displayHTMLEntities is intentionally finite and single-pass. Ordering ampersand
// first means "&amp;amp;" becomes the literal "&amp;", never "&" in the same call.
var displayHTMLEntities = strings.NewReplacer(
	"&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`,
	"&#39;", "'", "&apos;", "'", "&nbsp;", " ", "&mdash;", "—", "&ndash;", "–",
)

func sanitizeDisplayText(s string) string {
	return sanitizeText(displayHTMLEntities.Replace(s))
}

func hasCodeMark(marks []any) bool {
	for _, mark := range marks {
		if markType(mark) == "code" {
			return true
		}
	}
	return false
}

// allowedURLScheme is the set of URI schemes safe to hand a terminal's OSC 8
// open handler, mirroring @allowed_scheme in the Elixir render twin
// (portable_doc/render/util.ex).
var allowedURLScheme = map[string]bool{
	"http": true, "https": true, "mailto": true, "tel": true,
}

// sanitizeURL cleans a document-controlled URL before it is spliced into an
// OSC 8 hyperlink. It (a) strips terminal control bytes (C0 controls + DEL) so
// a href/src can't close or hijack the OSC 8 sequence (an embedded ST/BEL/CSI
// byte would otherwise emit raw escapes into the reader's terminal), then
// (b) enforces a scheme allowlist so a `javascript:`, `file:`, `data:` or other
// custom-scheme URI can't become a clickable link the OS open handler follows.
// A URL whose scheme is not http/https/mailto/tel (case-insensitive), or which
// is protocol-relative (`//host`), is dropped (returns ""). Schemeless URLs
// (relative paths like `/papers/x`, anchors like `#foo`) pass through unchanged.
// Stripping control bytes first also defeats the `\tjavascript:` bypass, since
// the leading tab is removed before the scheme is read. The OSC 8 spec forbids
// control chars in the URI, so well-formed allowed URLs are byte-unaffected.
func sanitizeURL(s string) string {
	if strings.IndexFunc(s, isCtrlRune) >= 0 {
		s = strings.Map(func(r rune) rune {
			if isCtrlRune(r) {
				return -1
			}
			return r
		}, s)
	}
	// Protocol-relative (`//host`, or browser-normalized `/\host`) escapes the
	// scheme allowlist into an off-site navigation — drop it, per util.ex.
	if len(s) >= 2 && s[0] == '/' && (s[1] == '/' || s[1] == '\\') {
		return ""
	}
	if scheme := urlScheme(s); scheme != "" && !allowedURLScheme[strings.ToLower(scheme)] {
		return ""
	}
	return s
}

// urlScheme returns the leading URI scheme — the run before the first ':',
// matching ^[a-zA-Z][a-zA-Z0-9+.-]* — or "" when the string carries no scheme
// (a relative path or anchor).
func urlScheme(s string) string {
	if len(s) == 0 || !isASCIILetter(s[0]) {
		return ""
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if c == ':' {
			return s[:i]
		}
		if !isASCIILetter(c) && !(c >= '0' && c <= '9') && c != '+' && c != '.' && c != '-' {
			return ""
		}
	}
	return ""
}

func isASCIILetter(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isCtrlRune(r rune) bool {
	return r < 0x20 || r == 0x7f
}

// sanitizeCodeText is sanitizeText for a SOURCE line: it strips the same
// escape-class control bytes but PRESERVES the horizontal tab (0x09) so code
// indentation survives — a tab is display-safe; only the escape-class C0 bytes
// can hijack the terminal.
func sanitizeCodeText(s string) string {
	if strings.IndexFunc(s, isCtrlNonTab) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		if isCtrlNonTab(r) {
			return -1
		}
		return r
	}, s)
}

func isCtrlNonTab(r rune) bool {
	return r != '\t' && isCtrlRune(r)
}

// sanitizeCodeSource is sanitizeCodeText for a WHOLE multi-line source: it
// additionally preserves the newline (0x0A) so line structure survives when the
// full block is sanitized in one pass (the chroma Tokenise input). Feeding the
// whole source through sanitizeCodeText would strip the newlines and collapse
// every multi-line code block to a single line.
func sanitizeCodeSource(s string) string {
	if strings.IndexFunc(s, isCtrlNonTabNL) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		if isCtrlNonTabNL(r) {
			return -1
		}
		return r
	}, s)
}

func isCtrlNonTabNL(r rune) bool {
	return r != '\t' && r != '\n' && isCtrlRune(r)
}

// sanitizeText strips terminal control bytes (C0 controls + DEL) from
// document-controlled display text so an embedded escape (e.g. an alt of
// "\x1b[2J") can't repaint or hijack the reader's terminal when the text is
// spliced into a lipgloss Render (which styles but does not strip escapes).
func sanitizeText(s string) string {
	if strings.IndexFunc(s, isCtrlRune) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		if isCtrlRune(r) {
			return -1
		}
		return r
	}, s)
}

// markType reads a mark's "type", tolerating a bare string mark.
func markType(m any) string {
	switch v := m.(type) {
	case string:
		return v
	case map[string]any:
		return attrStr(v, "type")
	default:
		return ""
	}
}

// markHref reads a link mark's href from either `attrs.href` (ProseMirror
// shape) or a top-level `href` — exactly the `get_in(mark, ["attrs","href"]) ||
// Map.get(mark, "href")` fallback in apply_mark/3.
func markHref(m any) string {
	mm, ok := m.(map[string]any)
	if !ok {
		return ""
	}
	if attrs, ok := mm["attrs"].(map[string]any); ok {
		if h := attrStr(attrs, "href"); h != "" {
			return h
		}
	}
	return attrStr(mm, "href")
}
