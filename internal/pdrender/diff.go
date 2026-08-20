package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── diff ─────────────────────────────────────────────────────────────────────
// The verbatim-unified-diff block (charter D75-D77). Contract: ONE `diff` text
// attr carrying a unified diff verbatim, parsed at RENDER time on every
// surface (never precomputed lines — that asymmetry stays chat-tool-diff's);
// optional `file` (header path) and `lang` metadata attrs.
//
// D76 reconciliation: DIFFERENTIATE the front-end, SHARE the row back-end.
// parseUnifiedDiff turns the text into the same {op,text} row shape the
// chat-tool-diff block carries, then this renderer feeds the EXISTING
// chat_blocks.go vocabulary — diffLineStyle, countDiffOp, diffOverflow,
// truncateANSI and the chatDiffBudget fold — with zero edits there. The +/-
// PREFIX is the semantic carrier (NoColor keeps it); color is never
// load-bearing. Long lines cell-truncate, never re-wrap (column alignment).
//
// D77: `@@` hunk headers render as dim context rows VERBATIM (the `-l,s +l,s`
// line numbers are load-bearing PR context); `---`/`+++`/`diff --git`/`index`
// metadata lines never count as +/- rows; each `+++` transition emits a bold
// path sub-header row (multi-file diffs = one header per file section).
// Empty text renders nothing (honest empty state — starter precedent).
type diffRenderer struct{}

func (diffRenderer) Render(b Block, ctx RenderCtx) []string {
	// Prefer the D75 `diff` attr; fall back to the starter-era `text` key so
	// round-1-born content degrades honestly instead of vanishing (the same
	// prefer-the-live-key discipline as chatDiffPath / attrStrFirst).
	text := attrStrFirst(b.Attrs, "diff", "text")
	if strings.TrimSpace(text) == "" {
		return nil
	}
	w := clampWidth(ctx.Width)
	pal := Resolve(ctx.Theme.themeID)
	addStyle := lipgloss.NewStyle().Foreground(pal.ToneOK)
	delStyle := lipgloss.NewStyle().Foreground(pal.ToneDanger)
	ctxStyle := ctx.Theme.Dim
	pathStyle := lipgloss.NewStyle().Bold(true).Foreground(pal.ChromeInk)

	rows := parseUnifiedDiff(text)

	// Header: optional bold `file` path + the colored +N −M tally — the same
	// header shape as chatToolDiffRenderer, tally computed from the parsed
	// rows via the shared counters.
	added := countDiffOp(rows, "+")
	removed := countDiffOp(rows, "-")
	tally := addStyle.Render("+"+itoa(added)) + " " + delStyle.Render("−"+itoa(removed))
	var out []string
	if file := sanitizeText(attrStr(b.Attrs, "file")); file != "" {
		out = append(out, truncateANSI(pathStyle.Render(file)+"  "+tally, w))
	} else {
		out = append(out, truncateANSI(tally, w))
	}

	// The diff body: one styled row per parsed line, budget-capped with the
	// honest overflow footnote (the shared chatDiffBudget — never a second
	// budget). parseUnifiedDiff emits no "gap" rows, so a straight break at
	// the budget is equivalent to the chat loop's skip-past-budget continue.
	shown := 0
	for _, r := range rows {
		rm, ok := r.(map[string]any)
		if !ok {
			continue
		}
		if shown >= chatDiffBudget {
			break
		}
		op := attrStr(rm, "op")
		txt := attrStr(rm, "text")
		if op == "file" {
			// Per-file bold path sub-header (D77's `+++` transition row).
			out = append(out, truncateANSI(pathStyle.Render(txt), w))
			shown++
			continue
		}
		// "+"/"-" rows style through the shared vocabulary; hunk headers
		// ("@") and context rows both fall through diffLineStyle's default
		// arm to the dim two-space-gutter context rendering.
		prefix, style := diffLineStyle(op, addStyle, delStyle, ctxStyle)
		out = append(out, truncateANSI(style.Render(prefix+txt), w))
		shown++
	}
	if over := diffOverflow(rows) - chatDiffBudget; over > 0 {
		out = append(out, ctxStyle.Render("… +"+itoa(over)+" more lines"))
	}
	return out
}

// parseUnifiedDiff parses verbatim unified-diff text into the chat-tool-diff
// row shape — []any of {op,text} maps — so the shared chat_blocks.go counters
// (countDiffOp, diffOverflow) consume it unmodified. Ops emitted:
//
//	"+" / "-"  — add/remove rows, the leading op char stripped into the op
//	" "        — context rows (leading space gutter stripped, alignment-safe)
//	"@"        — `@@` hunk headers, kept VERBATIM (D77 line numbers)
//	"file"     — the bold per-file path sub-header minted on `+++` transitions
//
// `diff --git`/`index`/mode/rename metadata lines are folded away entirely;
// `--- ` remembers the old path so a deletion's `+++ /dev/null` still gets an
// honest header. Anything unrecognized degrades to a context row — the parser
// never invents content and never drops a body line.
func parseUnifiedDiff(text string) []any {
	var rows []any
	lastFrom := "" // most recent `--- ` path, the /dev/null fallback
	for _, raw := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		line := sanitizeCodeText(raw)
		switch {
		case strings.HasPrefix(line, "diff --git"),
			strings.HasPrefix(line, "index "),
			strings.HasPrefix(line, "old mode"),
			strings.HasPrefix(line, "new mode"),
			strings.HasPrefix(line, "new file mode"),
			strings.HasPrefix(line, "deleted file mode"),
			strings.HasPrefix(line, "similarity index"),
			strings.HasPrefix(line, "rename from"),
			strings.HasPrefix(line, "rename to"),
			strings.HasPrefix(line, "Binary files"):
			// Metadata — never a row (D77).
		case strings.HasPrefix(line, "--- "):
			lastFrom = diffHeaderPath(line[4:])
		case strings.HasPrefix(line, "+++ "):
			path := diffHeaderPath(line[4:])
			if path == "" {
				path = lastFrom
			}
			if path != "" {
				rows = append(rows, map[string]any{"op": "file", "text": path})
			}
		case strings.HasPrefix(line, "@@"):
			rows = append(rows, map[string]any{"op": "@", "text": line})
		case strings.HasPrefix(line, "+"):
			rows = append(rows, map[string]any{"op": "+", "text": line[1:]})
		case strings.HasPrefix(line, "-"):
			rows = append(rows, map[string]any{"op": "-", "text": line[1:]})
		default:
			rows = append(rows, map[string]any{"op": " ", "text": strings.TrimPrefix(line, " ")})
		}
	}
	return rows
}

// diffHeaderPath normalizes a `---`/`+++` header path: the git a/ b/ prefixes
// drop, `/dev/null` folds to "" (the caller substitutes the honest old path).
func diffHeaderPath(p string) string {
	p = strings.TrimSpace(p)
	if p == "/dev/null" {
		return ""
	}
	p = strings.TrimPrefix(p, "a/")
	p = strings.TrimPrefix(p, "b/")
	return p
}
