package pdrender

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── field-* leaf blocks ─────────────────────────────────────────────────────
// Mirrors the field-* compose clauses in render.ex. Each renders as a LABELLED
// box: a bold label line (Theme.FieldLabel) followed by the value. All the
// scalar field types funnel through fieldRow; field-color and field-reference
// carry extra logic (a real swatch, an injected resolver).

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
