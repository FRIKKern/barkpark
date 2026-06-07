package pdrender

import (
	"encoding/json"
	"sort"
	"strings"
)

// ── v2 nested field blocks ──────────────────────────────────────────────────
// composite / arrayOf / codelist / localizedText carry their field CONFIG inline
// alongside a structured `value`. The project's TUI constraint says these render
// as a JSON dump; pdrender HONORS that as an opt-out (ctx.V2AsJSON) but DEFAULTS
// to the model's flat labelled summary — strictly more readable than a JSON blob,
// and the flattening logic mirrors render.ex's composite_scalar exactly. Each
// renders as a labelled box like the field-* leaf blocks (bold label line via
// Theme.FieldLabel, then the summary rows).

// compositeScalar flattens a decoded JSON sub-value to ONE display string —
// the direct port of render.ex's composite_scalar/1: nil → "—", bool → Yes/No,
// numbers/strings pass through, lists join with ", ", maps render as
// "k: v, …" (keys sorted for determinism). Recurses for nested containers.
func compositeScalar(v any) string {
	switch x := v.(type) {
	case nil:
		return "—"
	case bool:
		if x {
			return "Yes"
		}
		return "No"
	case string:
		return x
	case []any:
		parts := make([]string, 0, len(x))
		for _, el := range x {
			parts = append(parts, compositeScalar(el))
		}
		return strings.Join(parts, ", ")
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys) // deterministic order (JSON maps are unordered)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, k+": "+compositeScalar(x[k]))
		}
		return strings.Join(parts, ", ")
	default:
		// numbers (float64/int) and any Stringer fall through to toStr, which
		// prints integers without a trailing ".0" — matching to_string/1.
		return toStr(v)
	}
}

// getInValue reads a value out of a decoded-JSON map by string key — the port of
// render.ex's get_in_value/2. Missing key / non-map → nil.
func getInValue(m any, key string) any {
	mm, ok := m.(map[string]any)
	if !ok {
		return nil
	}
	return mm[key]
}

// v2box renders a labelled box: the bold field label line followed by the given
// summary rows, each wrapped to width. The shared shape for composite / arrayOf
// / localizedText (the multi-row v2 types). When ctx.V2AsJSON is set the caller
// short-circuits to v2JSONDump instead.
func v2box(label string, rows []string, ctx RenderCtx) []string {
	out := []string{ctx.Theme.FieldLabel.Render(label)}
	if len(rows) == 0 {
		rows = []string{"—"}
	}
	for _, row := range rows {
		out = append(out, wrapLines(ctx.Theme.Body.Render(row), ctx.Width)...)
	}
	return out
}

// v2JSONDump is the opt-out path (ctx.V2AsJSON): the bold label line followed by
// the block's `value` pretty-printed as JSON, each line dim. This is the literal
// TUI "JSON dump" constraint; it is NOT the default (the flat summary is).
func v2JSONDump(label string, value any, ctx RenderCtx) []string {
	out := []string{ctx.Theme.FieldLabel.Render(label)}
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		raw = []byte(toStr(value))
	}
	for _, line := range strings.Split(string(raw), "\n") {
		out = append(out, wrapLines(ctx.Theme.Dim.Render(line), ctx.Width)...)
	}
	return out
}

// composite → one "<subfield-title>: <scalar>" row per declared subfield.
type compositeRenderer struct{}

func (compositeRenderer) Render(b Block, ctx RenderCtx) []string {
	label := attrStr(b.Attrs, "label")
	if ctx.V2AsJSON {
		return v2JSONDump(label, b.Attrs["value"], ctx)
	}

	value := b.Attrs["value"]
	rows := make([]string, 0)
	for _, sub := range attrSlice(b.Attrs, "fields") {
		sm, ok := sub.(map[string]any)
		if !ok {
			continue
		}
		name := attrStr(sm, "name")
		subLabel := attrStrDefault(sm, "title", name)
		rows = append(rows, subLabel+": "+compositeScalar(getInValue(value, name)))
	}
	return v2box(label, rows, ctx)
}

// arrayOf → "N. <scalar>" per element; empty → a single "—" row.
type arrayOfRenderer struct{}

func (arrayOfRenderer) Render(b Block, ctx RenderCtx) []string {
	label := attrStr(b.Attrs, "label")
	if ctx.V2AsJSON {
		return v2JSONDump(label, b.Attrs["value"], ctx)
	}

	elements := attrSlice(b.Attrs, "value")
	rows := make([]string, 0, len(elements))
	for i, el := range elements {
		rows = append(rows, itoa(i+1)+". "+compositeScalar(el))
	}
	return v2box(label, rows, ctx) // empty → v2box supplies the "—" row
}

// codelist → the resolved human LABEL via the injected CodelistResolver
// (plugin, issue/codelistId, code), else the raw code, else "—" for an empty
// value. Renders as a single-value labelled box, mirroring field-reference.
type codelistRenderer struct{}

func (cl codelistRenderer) Render(b Block, ctx RenderCtx) []string {
	code := strings.TrimSpace(attrStr(b.Attrs, "value"))
	label := attrStr(b.Attrs, "label")
	plugin := attrStr(b.Attrs, "plugin")
	// The issue/version key is `codelistId` in the model (e.g. an ONIX issue).
	issue := attrStrDefault(b.Attrs, "codelistId", attrStr(b.Attrs, "issue"))

	var display string
	switch {
	case code == "":
		display = "—"
	case ctx.CodelistResolver != nil:
		if resolved := strings.TrimSpace(ctx.CodelistResolver(plugin, issue, code)); resolved != "" {
			display = resolved
		} else {
			display = code
		}
	default:
		display = code
	}

	out := []string{ctx.Theme.FieldLabel.Render(label)}
	return append(out, wrapLines(ctx.Theme.Body.Render(display), ctx.Width)...)
}

// localizedText → "<lang>: <text>" per declared language.
type localizedTextRenderer struct{}

func (localizedTextRenderer) Render(b Block, ctx RenderCtx) []string {
	label := attrStr(b.Attrs, "label")
	if ctx.V2AsJSON {
		return v2JSONDump(label, b.Attrs["value"], ctx)
	}

	value := b.Attrs["value"]
	rows := make([]string, 0)
	for _, lng := range attrSlice(b.Attrs, "languages") {
		lang := toStr(lng)
		rows = append(rows, lang+": "+compositeScalar(getInValue(value, lang)))
	}
	return v2box(label, rows, ctx)
}
