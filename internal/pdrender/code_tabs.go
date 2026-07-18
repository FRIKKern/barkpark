package pdrender

import "strings"

// ── code-tabs (B077) ─────────────────────────────────────────────────────
// Mirrors compose_block(code-tabs) (compose.ex): one snippet per language,
// tab-switched in the browser via I1 (framework-free DOM-scan) hydration.
// pdrender is a one-shot static render with no click affordance, so it
// takes the honest degrade: every tab's snippet stacked, each under a bold
// label heading, reusing the registered `code` renderer (chroma
// highlighting + memoization) for the panel body — a synced switcher is a
// browser-only capability, not a terminal-render one. Empty `tabs` renders
// nothing (honest empty state).
type codeTabsRenderer struct{ reg *Registry }

func (ctr codeTabsRenderer) Render(b Block, ctx RenderCtx) []string {
	tabs := codeTabEntries(b.Attrs)
	if len(tabs) == 0 {
		return nil
	}

	var out []string
	for i, t := range tabs {
		if i > 0 {
			out = append(out, "")
		}
		out = append(out, ctx.Theme.FieldLabel.Render(t.label))
		snippet := Block{Type: "code", Attrs: map[string]any{"code": t.value, "language": t.language}}
		out = append(out, ctr.reg.Render(snippet, ctx)...)
	}
	return out
}

// codeTabEntry is one authored tab: its display label plus the language/
// value pair fed to the `code` renderer.
type codeTabEntry struct {
	label    string
	language string
	value    string
}

// codeTabEntries reads the `tabs` array off a code-tabs block. Each entry
// is a {label, language, value} object; non-object entries are skipped. A
// blank label becomes a dim "·" placeholder (mirrors dashboardTabs) so the
// stack never carries an unlabeled panel.
func codeTabEntries(m map[string]any) []codeTabEntry {
	raw := attrSlice(m, "tabs")
	if raw == nil {
		return nil
	}
	out := make([]codeTabEntry, 0, len(raw))
	for _, el := range raw {
		obj, ok := el.(map[string]any)
		if !ok {
			continue
		}
		label := sanitizeText(strings.TrimSpace(attrStr(obj, "label")))
		if label == "" {
			label = "·"
		}
		out = append(out, codeTabEntry{
			label:    label,
			language: attrStr(obj, "language"),
			value:    attrStrFirst(obj, "value", "code"),
		})
	}
	return out
}
