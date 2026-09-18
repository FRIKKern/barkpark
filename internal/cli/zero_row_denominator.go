package cli

import (
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A ZERO-ROW PAGE UNDER A FILTER HAS TWO CAUSES AND ONE SPELLING.
//
// `bp doc query task --filter 'zzzNotAField=xyz'` answers
// `{"count":0,"documents":[],"hasMore":false,"limit":5,"offset":0}` at exit 0 —
// measured against guerrilla on 2026-09-17. That is byte-identical to the
// answer for a filter on a REAL field that genuinely matches nothing. A flat
// filter key naming a field no document carries is read as a JSONB path that
// resolves to NULL on every row (docs/contracts/query-surface-limits.md §2
// documents the same quiet behaviour for a path through a reference), so the
// server has nothing to refuse and returns an honest, well-formed, empty page.
//
// The caller then owns the whole inference, and the cheap one is wrong: a typo
// reads as "the class is empty". Every downstream count computed from that zero
// is internally consistent, which is what makes this family produce FINDINGS
// rather than errors.
//
// THE CLIENT CANNOT TELL THE TWO APART FROM THE RESPONSE — no field in the
// envelope distinguishes them. But it can stop reporting a total it never
// established. One extra request, issued ONLY on the zero-row-under-filter
// path, re-asks the SAME url with the filter clauses removed. That answer is
// the DENOMINATOR: it converts an unqualified "0" into "0 of N", which is a
// number a reader can act on, or into "0 of 0", which is the one case where the
// empty page really is about the collection and not about the filter.
//
// THE GUARD MUST NOT COMMIT THE CLASS IT GUARDS. The unfiltered probe is itself
// one page and may itself be capped, so N is reported as "at least N" whenever
// the server promises more rows, and no denominator at all is claimed when the
// probe does not come back readable. An instrument that invents its own
// denominator would be the same defect wearing a badge.

// filterClausesOf returns the filter query clauses carried by rawURL, in a
// stable order, rendered as `name=value`. Empty when the url carries none.
//
// Every spelling §1 of the query-surface contract accepts counts: the flat
// `filter=`, the repeated `filter[]=`, and the bracketed `filter[field]=` /
// `filter[field][op]=`. A name is a filter clause when it is exactly "filter"
// or opens "filter[" — matching on the prefix alone would also swallow a
// hypothetical `filtered=` param that has nothing to do with the read.
func filterClausesOf(rawURL string) []string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil
	}
	var clauses []string
	for name, values := range u.Query() {
		if !isFilterParamName(name) {
			continue
		}
		for _, v := range values {
			clauses = append(clauses, name+"="+v)
		}
	}
	sort.Strings(clauses)
	return clauses
}

// unfilteredURL returns rawURL with every filter clause removed, and whether
// any was removed. The second return is the ONLY authority for "this read was
// filtered" — a caller must never probe a url it did not actually change,
// because an unchanged url re-asks the identical question and its answer would
// be repetition dressed as a control.
func unfilteredURL(rawURL string) (string, bool) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", false
	}
	q := u.Query()
	removed := false
	for name := range q {
		if isFilterParamName(name) {
			q.Del(name)
			removed = true
		}
	}
	if !removed {
		return "", false
	}
	u.RawQuery = q.Encode()
	return u.String(), true
}

func isFilterParamName(name string) bool {
	return name == "filter" || strings.HasPrefix(name, "filter[")
}

// warnIfZeroRowsUnderFilter is the whole guard. probe issues the unfiltered
// request and returns its body; a false second return means the probe did not
// produce a usable answer, and the guard then refuses to state a denominator
// rather than guessing one.
//
// The notice is stderr-only, so `-o json` stdout stays machine-readable — the
// established shape for every page notice in run.go.
func warnIfZeroRowsUnderFilter(out *writer, cmd manifest.Command, rawURL string, respBody []byte, probe func(string) ([]byte, bool)) {
	if !cmd.Paginated || cmd.Writes {
		return
	}

	// THE LIST KEY, NOT THE ROW COUNT, IS THE PRECONDITION. A body carrying no
	// list key at all — an error envelope, a proxy page, a `null` payload — is
	// a NON-ANSWER, not an empty page, and `extractListRows` returns zero rows
	// for both. Discarding that key is how a refusal gets counted as "0 rows";
	// this guard would be manufacturing exactly the misreading it exists to
	// prevent if it fired on one. Those bodies are already refused upstream by
	// refuseUnreadableDefaultPage, and this returns rather than double-report.
	rows, key := extractListRows(unwrapResult(respBody))
	if key == "" || len(rows) != 0 {
		return
	}

	clauses := filterClausesOf(rawURL)
	if len(clauses) == 0 {
		return
	}
	bare, ok := unfilteredURL(rawURL)
	if !ok {
		return
	}

	shown := strings.Join(clauses, " ")

	body, ok := probe(bare)
	if !ok {
		out.userErr("0 rows matched %s — and the unfiltered probe of the same read did not answer, so no denominator was established; this zero is NOT evidence that the class is empty (a filter naming a field no document carries returns this same empty page)", shown)
		return
	}
	probeRows, probeKey := extractListRows(unwrapResult(body))
	if probeKey == "" {
		out.userErr("0 rows matched %s — and the unfiltered probe returned no readable page, so no denominator was established; this zero is NOT evidence that the class is empty (a filter naming a field no document carries returns this same empty page)", shown)
		return
	}

	total := len(probeRows)
	if total == 0 {
		out.userErr("0 of 0 rows matched %s — the unfiltered read of the same scope is empty too, so the empty page is about the collection, not about the filter", shown)
		return
	}

	// "at least" WHENEVER THE PROBE'S OWN PAGE MAY BE SHORT. The probe is one
	// page under the same limit as the read it explains, so its count is a
	// floor, not a population, exactly as often as any other single page is.
	qualified := fmt.Sprintf("%d", total)
	if pageHasMore(unwrapResult(body)) {
		qualified = fmt.Sprintf("at least %d", total)
	}
	out.userErr("0 of %s rows matched %s — the filter removed every row. A filter naming a field no document carries answers with this SAME empty page at exit 0 (docs/contracts/query-surface-limits.md §2), so confirm the field name before reading this zero as an empty class", qualified, shown)
}
