package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── form / questionnaire (alias) ────────────────────────────────────────────
// RENDER-ONLY, no input wiring — matching the HTML render-only contract (the
// `_raw` form_html clause emits <fieldset>s with NO <script>, action, or submit;
// the interactive layer is a later phase). `questionnaire` is a pure ALIAS of
// `form` (both register to formRenderer); they differ only by the `kind`
// discriminator the model carries. We render one bordered fieldset per question:
// the prompt (bold) + dim rationale/recommendation context + a STATIC control
// representation of the answer affordance (radio glyphs / checkboxes / a scale /
// a text placeholder). A reader sees the form's SHAPE; answering is out of scope
// for a read-only viewer, exactly like the web side.
type formRenderer struct{}

func (formRenderer) Render(b Block, ctx RenderCtx) []string {
	questions := attrSlice(b.Attrs, "questions")

	var out []string
	for i, q := range questions {
		qm, ok := q.(map[string]any)
		if !ok {
			continue
		}
		if i > 0 {
			out = append(out, "") // rhythm: a blank line between fieldsets
		}
		out = append(out, formQuestion(qm, ctx)...)
	}
	if len(out) == 0 {
		// An empty form still renders honestly rather than vanishing.
		return boxLines(ctx.Theme.Dim.Render("(empty form)"), ctx)
	}
	return out
}

// formQuestion renders ONE question as a bordered fieldset: a bold prompt, dim
// rationale + "Recommendation: …" lines (only when present), then the static
// control. The whole fieldset sits in the shared rounded box.
func formQuestion(q map[string]any, ctx RenderCtx) []string {
	inner := innerWidth(ctx)

	var sb strings.Builder
	prompt := attrStr(q, "prompt")
	sb.WriteString(strings.Join(wrapLines(ctx.Theme.Body.Bold(true).Render(prompt), inner), "\n"))

	if rationale := attrStr(q, "rationale"); rationale != "" {
		sb.WriteString("\n")
		sb.WriteString(strings.Join(wrapLines(ctx.Theme.Dim.Render(rationale), inner), "\n"))
	}
	if rec := attrStr(q, "recommendation"); rec != "" {
		sb.WriteString("\n")
		sb.WriteString(strings.Join(wrapLines(ctx.Theme.Dim.Render("Recommendation: "+rec), inner), "\n"))
	}

	sb.WriteString("\n")
	sb.WriteString(formControl(q, ctx))

	return boxLines(sb.String(), ctx)
}

// formControl returns the STATIC control representation for a question, keyed by
// its `type` — the terminal stand-in for the live <input>/<textarea> markup:
//
//	yesno / single → "( ) Yes  ( ) No"  radio glyphs
//	multi          → "[ ] A   [ ] B"    checkbox glyphs
//	scale          → "1 2 3 4 5"        the min..max ladder
//	text (default) → "[ … ]"            textarea placeholder
//
// Unknown types degrade to the text placeholder (render-only, never crash),
// mirroring form_control_html's catch-all clause.
func formControl(q map[string]any, ctx RenderCtx) string {
	dim := ctx.Theme.Dim
	switch attrStr(q, "type") {
	case "yesno":
		return radioGlyphs([]string{"Yes", "No"}, dim)

	case "single":
		opts := strSlice(attrSlice(q, "options"))
		if len(opts) == 0 {
			return radioGlyphs([]string{"Yes", "No"}, dim)
		}
		return radioGlyphs(opts, dim)

	case "multi":
		opts := strSlice(attrSlice(q, "options"))
		if len(opts) == 0 {
			return checkboxGlyphs([]string{"Option"}, dim)
		}
		return checkboxGlyphs(opts, dim)

	case "scale":
		return scaleLadder(q, dim)

	case "text":
		return dim.Render("[ … ]")

	default:
		// Unknown → text placeholder (render-only, never panic).
		return dim.Render("[ … ]")
	}
}

// radioGlyphs renders "( ) Label" cells joined by two spaces — the unchecked
// radio representation.
func radioGlyphs(labels []string, style lipgloss.Style) string {
	cells := make([]string, 0, len(labels))
	for _, l := range labels {
		cells = append(cells, style.Render("( ) "+l))
	}
	return strings.Join(cells, "  ")
}

// checkboxGlyphs renders "[ ] Label" cells joined by two spaces — the unchecked
// checkbox representation.
func checkboxGlyphs(labels []string, style lipgloss.Style) string {
	cells := make([]string, 0, len(labels))
	for _, l := range labels {
		cells = append(cells, style.Render("[ ] "+l))
	}
	return strings.Join(cells, "  ")
}

// scaleLadder renders "min … max" as a space-separated integer ladder from the
// question's `scale.{min,max}` (defaults 1..5, mirroring form_control_html).
func scaleLadder(q map[string]any, style lipgloss.Style) string {
	min, max := 1, 5
	if scale, ok := q["scale"].(map[string]any); ok {
		min = attrInt(scale, "min", 1)
		max = attrInt(scale, "max", 5)
	}
	if max < min {
		return style.Render("[ … ]")
	}
	nums := make([]string, 0, max-min+1)
	for n := min; n <= max; n++ {
		nums = append(nums, itoa(n))
	}
	return style.Render(strings.Join(nums, " "))
}

// strSlice coerces a decoded JSON array to a []string (each element stringified),
// the port of `Enum.map(&to_string/1)` on a question's options.
func strSlice(items []any) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, toStr(it))
	}
	return out
}
