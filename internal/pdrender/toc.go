package pdrender

import (
	"strconv"
	"strings"
)

// ── toc ──────────────────────────────────────────────────────────────────────
// Mirrors compose_block(toc) (compose.ex): a static, author-supplied outline.
// `items` is a flat list of `{text, level, anchor}` — never derived by walking
// sibling blocks. compose_block/2 (and this Render method) dispatch ONE block
// at a time; there is no document-wide context at this layer to auto-collect
// headings from (see the compose.ex toc clause for the full rationale). Growing
// real heading-derived auto-population is a separate, later change that would
// need a document-level compose pass, not a single block's clause.
//
// `depth` caps how many RELATIVE levels are shown, counted from the shallowest
// level present among items (default 2). `numbered` prefixes each shown item
// with a hierarchical counter (1, 1.1, 1.2, 2, …). `sticky` is a View-only
// viewport affordance with no terminal analogue (ignored here). Anchors have
// no terminal analogue either (no clickable links in a plain ANSI stream) —
// only the label renders, indented by relative depth. Empty/missing items
// renders nothing (honest empty state).
type tocRenderer struct{}

type tocItem struct {
	text  string
	level int
}

func tocItems(raw any) []tocItem {
	list, _ := raw.([]any)
	out := make([]tocItem, 0, len(list))
	for _, it := range list {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		text := sanitizeText(attrStr(m, "text"))
		if text == "" {
			continue
		}
		out = append(out, tocItem{text: text, level: attrInt(m, "level", 1)})
	}
	return out
}

func (tocRenderer) Render(b Block, ctx RenderCtx) []string {
	items := tocItems(b.Attrs["items"])
	if len(items) == 0 {
		return nil
	}
	depth := attrInt(b.Attrs, "depth", 2)
	if depth < 1 {
		depth = 1
	}
	numbered := attrBool(b.Attrs, "numbered")

	minLevel := items[0].level
	for _, it := range items {
		if it.level < minLevel {
			minLevel = it.level
		}
	}

	w := clampWidth(ctx.Width)
	dim := ctx.Theme.Dim
	counters := make([]int, depth+1)
	var out []string
	for _, it := range items {
		rel := it.level - minLevel + 1
		if rel > depth {
			continue
		}
		prefix := "•"
		if numbered {
			counters[rel]++
			for lvl := rel + 1; lvl < len(counters); lvl++ {
				counters[lvl] = 0
			}
			parts := make([]string, 0, rel)
			for lvl := 1; lvl <= rel; lvl++ {
				parts = append(parts, strconv.Itoa(counters[lvl]))
			}
			prefix = strings.Join(parts, ".")
		}
		indent := strings.Repeat("  ", rel-1)
		line := indent + dim.Render(prefix+" ") + it.text
		out = append(out, truncateANSI(line, w))
	}
	return out
}
