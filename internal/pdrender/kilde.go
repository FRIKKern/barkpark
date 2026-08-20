package pdrender

import (
	"regexp"
	"strings"
)

// ── kilde (source provenance — THE KILDE LAW) ────────────────────────────────
//
// Every figure datum carries a source ref — `commit:<sha>` | `paper:<slug>` |
// `task:<id>` | `https://…` — surfaced as a small dim «Kilde» line under the
// figure. A ref that does not parse renders NOTHING: a bad ref is not
// evidence. The parse mirrors parseSourceRef in the canonical JS emitter
// (js/packages/react/src/blocks/dataviz.ts) exactly: commit refs label as
// "commit:" + the first 7 hex, paper/task refs print raw, https refs strip the
// scheme and trailing slashes. The terminal never links out, so the https case
// degrades to the same plain provenance text as the rest — the label IS the
// datum. Shared by the jarl figure family (duel.go / lineage.go).

var (
	kildeCommitRe = regexp.MustCompile(`^commit:[0-9a-f]{7,40}$`)
	kildePaperRe  = regexp.MustCompile(`^paper:[a-z0-9][a-z0-9-]*$`)
	kildeTaskRe   = regexp.MustCompile(`^task:[A-Za-z0-9._-]+$`)
)

// parseSourceRefLabel returns the display label for a source ref, or "" when
// the ref does not parse (an invalid ref renders nothing).
func parseSourceRefLabel(ref string) string {
	switch {
	case kildeCommitRe.MatchString(ref):
		return "commit:" + ref[7:14] // the first 7 hex after "commit:" (≥7 guaranteed by the regex)
	case kildePaperRe.MatchString(ref), kildeTaskRe.MatchString(ref):
		return ref
	case strings.HasPrefix(ref, "https://") && len(ref) > 8:
		return strings.TrimRight(strings.TrimPrefix(ref, "https://"), "/")
	}
	return ""
}

// figureSourceLabels collects the deduped kilde labels for the datum-bearing
// items (per isDatum): each item takes its own `source`, else the block's
// sourceDefault; invalid refs drop; dedup is by RAW ref in first-use order
// (authored order, never sorted) — dataviz.ts figureRefs, verbatim law.
func figureSourceLabels(items []map[string]any, sourceDefault string, isDatum func(map[string]any) bool) []string {
	var labels []string
	seen := map[string]bool{}
	for _, it := range items {
		if !isDatum(it) {
			continue
		}
		ref := strings.TrimSpace(attrStr(it, "source"))
		if ref == "" {
			ref = sourceDefault
		}
		label := parseSourceRefLabel(ref)
		if label == "" || seen[ref] {
			continue
		}
		seen[ref] = true
		labels = append(labels, sanitizeText(label))
	}
	return labels
}

// kildeLines renders the dim provenance stamp — `Kilde: a` (one ref) /
// `Kilder: a · b` (several) — wrapped to w. Nil when there are no valid refs,
// so a ref-free figure is byte-identical to before the kilde law landed.
func kildeLines(labels []string, ctx RenderCtx, w int) []string {
	if len(labels) == 0 {
		return nil
	}
	word := "Kilde"
	if len(labels) > 1 {
		word = "Kilder"
	}
	return wrapLines(ctx.Theme.Dim.Render(word+": "+strings.Join(labels, " · ")), clampWidth(w))
}
