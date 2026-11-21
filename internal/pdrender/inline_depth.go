package pdrender

import "strings"

// Inline nesting past the depth limit (task-11bbe4b4ae8c85f4). The rule every
// Barkpark reader shares (render/inline_depth.ex, js/packages/react inline.tsx,
// apps/mobile inlines.tsx, the editor's inline-depth.js):
//
//   - A wrapper (a node holding children, or a bare list) is drawn while its
//     inline depth is under maxNestDepth (100). A text leaf at depth d with k
//     marks draws all of them when d + k <= maxNestDepth.
//   - A wrapper at depth maxNestDepth or deeper is not drawn. The words under it
//     are, flat and in order, then one space and the notice. A text leaf with
//     more marks than fit draws the marks that fit, then the notice.
//   - The words are read by a loop, never by recursion, down to inline depth
//     maxWordDepth (1000). Words deeper than that are not read; the notice still
//     follows, so a document of any depth draws without a crash.
const maxWordDepth = 1000

// isInlineWrapper reports whether an inline node holds other inline nodes: a
// bare list, or a node with a `children` key.
func isInlineWrapper(n any) bool {
	switch v := n.(type) {
	case []any:
		return true
	case map[string]any:
		_, ok := v["children"]
		return ok
	}
	return false
}

// cutInline is a wrapper past the depth limit: its words, then the notice.
func cutInline(n any, depth int) string {
	if words := sanitizeDisplayText(inlineWords(n, depth)); words != "" {
		return words + " " + nestedTooDeep
	}
	return nestedTooDeep
}

// inlineWords reads the words under an inline node, in order, with a loop.
// depth is the node's own inline depth; nothing at or past maxWordDepth is read.
func inlineWords(n any, depth int) string {
	type frame struct {
		node  any
		depth int
	}
	var b strings.Builder
	stack := []frame{{n, depth}}
	for len(stack) > 0 {
		f := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if f.depth >= maxWordDepth {
			continue
		}
		var kids []any
		switch v := f.node.(type) {
		case string:
			b.WriteString(v)
		case float64, int, int64, bool:
			b.WriteString(toStr(v))
		case []any:
			kids = v
		case map[string]any:
			if c, ok := v["children"]; ok {
				kids, _ = c.([]any)
			} else {
				b.WriteString(attrStrFirst(v, "value", "text"))
			}
		}
		for i := len(kids) - 1; i >= 0; i-- {
			stack = append(stack, frame{kids[i], f.depth + 1})
		}
	}
	return b.String()
}
