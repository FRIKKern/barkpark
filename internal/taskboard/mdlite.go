package taskboard

// mdlite.go — the minimal markdown → []pdrender.Block adapter (charter D16).
// ONE typography engine: task prose is rendered through the SAME pdrender
// registry that draws Papers, so a description reads typographically identical
// to a design doc for free (charter law: one rendering stack, no glamour, no
// goldmark). v1 covers exactly what the live task corpus uses — 149/150
// descriptions are plain prose — plus the four structures that do appear:
//
//   - paragraphs   — blank-line-separated runs of text (soft-wrapped source
//     lines join with a space; pdrender re-wraps to the reading measure)
//   - `- ` bullets — a run of dash-led lines becomes one unordered list block
//   - fenced code  — ```lang … ``` becomes a code block (language honored)
//   - ATX headings — #, ##, ### become heading levels 1–3 (deeper clamps to 3)
//
// EVERYTHING else degrades to a paragraph and NOTHING errors — a task
// description is user data, so a stray `> quote`, a `| table |`, a bare `#`
// with no space, or an unterminated fence must render as inert text, never
// panic. pdrender itself is NOT modified: blocks are constructed as plain
// literals ({Type, Attrs}) exactly as the wire decoder would produce.

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// MarkdownBlocks parses mdlite source into pdrender blocks. Empty or
// whitespace-only source returns nil (the caller renders nothing). It never
// returns an error and never panics — unrecognized lines become paragraph
// text.
func MarkdownBlocks(src string) []pdrender.Block {
	src = strings.ReplaceAll(src, "\r\n", "\n")
	src = strings.ReplaceAll(src, "\r", "\n")
	lines := strings.Split(src, "\n")

	var blocks []pdrender.Block
	var para []string // accumulating soft-wrapped paragraph lines

	flushPara := func() {
		if len(para) == 0 {
			return
		}
		text := strings.TrimSpace(strings.Join(para, " "))
		para = para[:0]
		if text != "" {
			blocks = append(blocks, paragraphBlock(text))
		}
	}

	i := 0
	for i < len(lines) {
		line := lines[i]
		trimmed := strings.TrimSpace(line)

		switch {
		case isFence(trimmed):
			// Fenced code: capture verbatim source lines (indentation matters,
			// so we keep the raw line, not the trimmed one) until the closing
			// fence or EOF. An unterminated fence runs to EOF — honest, never an
			// error.
			flushPara()
			lang := fenceLang(trimmed)
			i++
			var code []string
			for i < len(lines) && !isFence(strings.TrimSpace(lines[i])) {
				code = append(code, lines[i])
				i++
			}
			if i < len(lines) {
				i++ // consume the closing fence
			}
			blocks = append(blocks, codeBlock(strings.Join(code, "\n"), lang))

		case trimmed == "":
			flushPara()
			i++

		case atxLevel(trimmed) > 0:
			flushPara()
			lvl := atxLevel(trimmed)
			blocks = append(blocks, headingBlock(atxText(trimmed), lvl))
			i++

		case isBullet(line):
			// A contiguous run of `- ` lines is one list block. Each item is a
			// bare string (pdrender's itemNodes coerces it to an inline text
			// node); continuation/nesting is out of scope for v1.
			flushPara()
			var items []any
			for i < len(lines) && isBullet(lines[i]) {
				items = append(items, bulletText(lines[i]))
				i++
			}
			blocks = append(blocks, listBlock(items))

		default:
			para = append(para, trimmed)
			i++
		}
	}
	flushPara()
	return blocks
}

// isFence reports whether a trimmed line opens or closes a ``` code fence.
func isFence(trimmed string) bool { return strings.HasPrefix(trimmed, "```") }

// fenceLang extracts the info-string language after the opening ``` ("" when
// none), tolerating a leading tilde/space and a stray closing backtick run.
func fenceLang(trimmed string) string {
	return strings.TrimSpace(strings.Trim(strings.TrimPrefix(trimmed, "```"), "`"))
}

// isBullet reports whether a raw line is a `- ` bullet (leading indentation
// tolerated; the marker must be a dash followed by a space).
func isBullet(line string) bool {
	return strings.HasPrefix(strings.TrimLeft(line, " \t"), "- ")
}

// bulletText is the bullet's body: everything after the `- ` marker, trimmed.
func bulletText(line string) string {
	s := strings.TrimLeft(line, " \t")
	return strings.TrimSpace(strings.TrimPrefix(s, "- "))
}

// atxLevel returns the ATX heading level (1–3, deeper clamped to 3) for a
// trimmed line, or 0 when the line is not a valid `# text` heading. A heading
// requires 1–6 leading '#', a single following space, and non-empty text — so
// "#tag" (no space) and "# " (no text) degrade to paragraphs, honoring the
// never-lose-content rule.
func atxLevel(trimmed string) int {
	n := 0
	for n < len(trimmed) && trimmed[n] == '#' {
		n++
	}
	if n < 1 || n > 6 {
		return 0
	}
	if n >= len(trimmed) || trimmed[n] != ' ' {
		return 0
	}
	if strings.TrimSpace(trimmed[n+1:]) == "" {
		return 0
	}
	if n > 3 {
		n = 3
	}
	return n
}

// atxText is the heading text after its `#`-run and the single space.
func atxText(trimmed string) string {
	n := 0
	for n < len(trimmed) && trimmed[n] == '#' {
		n++
	}
	return strings.TrimSpace(trimmed[n:])
}

// ── block constructors ────────────────────────────────────────────────────
// These build the exact literal shapes pdrender's wire decoder would produce,
// so the same renderers (blocks.go / code.go) draw them. pdrender is never
// modified — the contract is the block map, not a new code path.

func paragraphBlock(text string) pdrender.Block {
	return pdrender.Block{Type: "paragraph", Attrs: map[string]any{"content": []any{text}}}
}

func headingBlock(text string, level int) pdrender.Block {
	return pdrender.Block{Type: "heading", Attrs: map[string]any{"text": text, "level": level}}
}

func listBlock(items []any) pdrender.Block {
	return pdrender.Block{Type: "list", Attrs: map[string]any{"ordered": false, "items": items}}
}

func codeBlock(source, lang string) pdrender.Block {
	attrs := map[string]any{"code": source}
	if lang != "" {
		attrs["language"] = lang
	}
	return pdrender.Block{Type: "code", Attrs: attrs}
}
