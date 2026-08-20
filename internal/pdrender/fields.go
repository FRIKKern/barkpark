package pdrender

import (
	"regexp"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── field-* leaf blocks ─────────────────────────────────────────────────────
// Mirrors the field-* compose clauses in render.ex. Each renders as a LABELLED
// box: a bold label line (Theme.FieldLabel) followed by the value. All the
// scalar field types funnel through fieldRow; field-color and field-reference
// carry extra logic (a real swatch, an injected resolver).
//
// Standalone, a field is that two-line label/value pair. But a RUN of fields —
// the common case (a doc's metadata) — reads far better as an ALIGNED
// definition list: a dim label column and a value column, values lined up,
// continuations indented. RenderDoc collapses consecutive field blocks into one
// renderFieldGroup so the density-with-craft P9 bar holds for metadata too,
// reusing each field's own value logic verbatim (see renderFieldGroup).

// fieldGroupTypes are the block types RenderDoc gathers into an aligned
// definition list when they appear consecutively. The field-* leaves plus the
// composite/arrayOf/localizedText structured fields — every type whose renderer
// emits a label line followed by its value.
var fieldGroupTypes = map[string]bool{
	"field-string": true, "field-slug": true, "field-text": true,
	"field-boolean": true, "field-select": true, "field-datetime": true,
	"field-color": true, "field-reference": true, "field-image": true,
	"field-number": true,
	"composite":    true, "arrayOf": true, "localizedText": true,
	"codelist": true, // label + resolved code→label; same definition-list shape
}

// isFieldGroupType reports whether a block joins an aligned field group.
func isFieldGroupType(t string) bool { return fieldGroupTypes[t] }

// renderFieldGroup lays a run of consecutive field blocks as an ALIGNED
// definition list: a dim label column (width = the widest label, capped to
// [8, min(24, width/2)]) and a value column that wraps in the remaining width,
// with continuation lines indented to the value column. It reuses each field's
// OWN value logic — the block is rendered at the value width and its label line
// (line 0) dropped, so the swatch, select-option, resolver, boolean, datetime
// and image behaviours are untouched; only the layout changes. A field with no
// value renders label-only. This is the density fix for metadata runs that the
// per-field two-line stack left ragged.
func renderFieldGroup(r *Registry, blocks []Block, ctx RenderCtx) []string {
	labels := make([]string, len(blocks))
	labelW := 0
	for i, b := range blocks {
		l := sanitizeText(attrStr(b.Attrs, "label"))
		labels[i] = l
		if w := lipgloss.Width(l); w > labelW {
			labelW = w
		}
	}
	maxLabel := ctx.Width / 2
	if maxLabel > 24 {
		maxLabel = 24
	}
	if labelW > maxLabel {
		labelW = maxLabel
	}
	if labelW < 8 {
		labelW = 8
	}
	const gap = 2
	valueW := clampWidth(ctx.Width - labelW - gap)
	indent := strings.Repeat(" ", labelW+gap)

	out := make([]string, 0, len(blocks)*2)
	for i, b := range blocks {
		full := r.Render(b, ctx.WithWidth(valueW))
		labelCol := ctx.Theme.Dim.Render(padOrTruncate(labels[i], labelW))
		var value []string
		if len(full) > 1 {
			value = full[1:] // drop the field's own label line; keep its value
		}
		if len(value) == 0 {
			out = append(out, labelCol)
			continue
		}
		out = append(out, labelCol+strings.Repeat(" ", gap)+value[0])
		for _, vl := range value[1:] {
			out = append(out, indent+vl)
		}
	}
	return out
}

// fieldRow builds the two-line labelled box: bold label, then the value text,
// wrapped to width. The shared shape for every scalar field-* type.
func fieldRow(b Block, value string, ctx RenderCtx) []string {
	label := attrStr(b.Attrs, "label")
	out := []string{ctx.Theme.FieldLabel.Render(sanitizeText(label))}
	out = append(out, wrapLines(value, ctx.Width)...)
	return out
}

// field-string / field-slug / field-text → raw value text.
type fieldTextRenderer struct{}

func (fieldTextRenderer) Render(b Block, ctx RenderCtx) []string {
	return fieldRow(b, sanitizeText(attrStr(b.Attrs, "value")), ctx)
}

// field-boolean → "Yes" / "No". The value may arrive as a real bool or as a
// string ("true"/"false") depending on the producer — coerce both.
type fieldBooleanRenderer struct{}

func (fieldBooleanRenderer) Render(b Block, ctx RenderCtx) []string {
	return fieldRow(b, yesNo(b.Attrs["value"]), ctx)
}

// yesNo coerces a bool-or-string value to "Yes"/"No" (mirrors `value == true`).
func yesNo(v any) string {
	switch x := v.(type) {
	case bool:
		if x {
			return "Yes"
		}
		return "No"
	case string:
		if strings.EqualFold(strings.TrimSpace(x), "true") {
			return "Yes"
		}
		return "No"
	default:
		return "No"
	}
}

// field-select → the matched option's label by value, else the raw value.
type fieldSelectRenderer struct{}

func (fieldSelectRenderer) Render(b Block, ctx RenderCtx) []string {
	value := sanitizeText(attrStr(b.Attrs, "value"))
	label := value
	for _, opt := range attrSlice(b.Attrs, "options") {
		om, ok := opt.(map[string]any)
		if !ok {
			continue
		}
		if attrStr(om, "value") == value {
			label = sanitizeText(attrStrDefault(om, "label", attrStr(om, "value")))
			break
		}
	}
	return fieldRow(b, label, ctx)
}

// field-datetime → the datetime-local string with the 'T' replaced by a space
// ("2026-05-24T10:00" → "2026-05-24 10:00").
type fieldDatetimeRenderer struct{}

func (fieldDatetimeRenderer) Render(b Block, ctx RenderCtx) []string {
	return fieldRow(b, strings.Replace(sanitizeText(attrStr(b.Attrs, "value")), "T", " ", 1), ctx)
}

// hexRe matches a strict #rgb / #rrggbb literal — the ONLY values allowed to
// drive a real terminal background swatch (matches safe_hex/1 in render.ex).
var hexRe = regexp.MustCompile(`^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$`)

// field-color → a REAL terminal swatch (a 2-cell background block in the given
// hex) beside the hex text, but ONLY for a strict #rgb/#rrggbb value; an
// arbitrary string gets no swatch (so a hostile value can't inject anything).
type fieldColorRenderer struct{}

func (fieldColorRenderer) Render(b Block, ctx RenderCtx) []string {
	hex := attrStr(b.Attrs, "value")
	label := attrStr(b.Attrs, "label")

	var valueLine string
	if hexRe.MatchString(hex) {
		swatch := lipgloss.NewStyle().Background(lipgloss.Color(hex)).Render("  ")
		valueLine = swatch + " " + ctx.Theme.Body.Render(hex)
	} else {
		valueLine = ctx.Theme.Body.Render(sanitizeText(hex))
	}
	return []string{ctx.Theme.FieldLabel.Render(sanitizeText(label)), valueLine}
}

// field-reference → the resolved doc TITLE via an INJECTED resolver
// (ctx.RefResolver, caller-supplied), else the raw id, else "—" for an empty
// value. Mirrors resolve_ref_title/2 + the field-reference compose clause.
type fieldReferenceRenderer struct{}

func (fieldReferenceRenderer) Render(b Block, ctx RenderCtx) []string {
	value := sanitizeText(attrStr(b.Attrs, "value"))
	refType := attrStr(b.Attrs, "refType")

	var display string
	switch {
	case value == "":
		display = "—"
	case ctx.RefResolver != nil:
		if title := sanitizeText(strings.TrimSpace(ctx.RefResolver(value, refType))); title != "" {
			display = title
		} else {
			display = value
		}
	default:
		display = value
	}
	return fieldRow(b, display, ctx)
}

// field-image → a placeholder: "🖼 <alt or url>" when a value is set, else
// "No image". (Graphics protocols smear in a scroll viewport — real sixel/kitty
// is deferred past M1, matching the spec.)
type fieldImageRenderer struct{}

func (fieldImageRenderer) Render(b Block, ctx RenderCtx) []string {
	value := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "value")))
	label := attrStr(b.Attrs, "label")

	var valueLine string
	if value == "" {
		valueLine = ctx.Theme.Dim.Render("No image")
	} else {
		valueLine = ctx.Theme.Body.Render("🖼 " + value)
	}
	out := []string{ctx.Theme.FieldLabel.Render(sanitizeText(label))}
	return append(out, wrapLines(valueLine, ctx.Width)...)
}

// field-number (B085) → the numeric `value` formatted with `strconv`'s
// minimal-digits 'f' verb (5 → "5", 19.99 → "19.99", never exponent
// notation), plus an optional trailing `unit`. An absent/uncoercible value
// renders "—" (the field-reference empty-value precedent) — `min`/`max`/
// `step` are Edit-mode control bounds (E4a, out of View's scope) and are
// never read here.
type fieldNumberRenderer struct{}

func (fieldNumberRenderer) Render(b Block, ctx RenderCtx) []string {
	unit := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "unit")))

	f, ok := toFloat(b.Attrs["value"])
	var value string
	switch {
	case !ok:
		value = "—"
	case unit == "":
		value = formatFieldNumber(f)
	default:
		value = formatFieldNumber(f) + " " + unit
	}
	return fieldRow(b, value, ctx)
}

func formatFieldNumber(f float64) string {
	return strconv.FormatFloat(f, 'f', -1, 64)
}
