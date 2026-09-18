package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// drafts.task-115501e497e1485e — "a retrieval limit mistaken for a population".
//
// MEASURED ON guerrilla, 2026-09-17:
//
//	bp doc query task --filter 'zzzNotAField=xyz' --limit 5 -o json
//	{"count":0,"documents":[],"hasMore":false,"limit":5,"offset":0,...}   exit 0
//
// A field no document carries answers exactly like a real field that matched
// nothing. The FIRING arm below proves the guard turns that unqualified zero
// into "0 of N"; the QUIET arms prove it stays silent everywhere a notice would
// be noise or, worse, a second wrong reading of a non-answer.

func zeroRowQueryCmd() manifest.Command {
	return manifest.Command{
		Noun: "doc", Verb: "query", Paginated: true,
		HTTP:  manifest.HTTP{Method: "GET"},
		Flags: []manifest.Flag{{Name: "limit", Type: "int", Default: 100}},
	}
}

const zeroRowFilteredURL = "https://x/v1/data/query/production/task?filter=zzzNotAField%3Dxyz&limit=5"

func runZeroRowGuard(t *testing.T, rawURL, respBody string, probe func(string) ([]byte, bool)) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "table"
	warnIfZeroRowsUnderFilter(out, zeroRowQueryCmd(), rawURL, []byte(respBody), probe)
	if stdout.Len() != 0 {
		t.Fatalf("guard wrote to STDOUT, which must stay machine-readable: %q", stdout.String())
	}
	return stderr.String()
}

// ARM 1 — FIRES. This is the arm that reds if the guard is reverted: with the
// call site or the function removed, stderr is empty and every assertion here
// fails. Proved by deleting zero_row_denominator.go's body and re-running.
func TestZeroRowsUnderFilterPrintsTheDenominator(t *testing.T) {
	empty := `{"count":0,"documents":[],"hasMore":false,"limit":5,"offset":0}`

	t.Run("complete probe page states the denominator flat", func(t *testing.T) {
		var probed string
		got := runZeroRowGuard(t, zeroRowFilteredURL, empty, func(bare string) ([]byte, bool) {
			probed = bare
			return []byte(`{"documents":[{"_id":"a"},{"_id":"b"},{"_id":"c"}],"count":3}`), true
		})
		if strings.Contains(probed, "filter") {
			t.Fatalf("the probe must drop the filter clauses, else it re-asks the same question: %q", probed)
		}
		if !strings.Contains(probed, "limit=5") {
			t.Fatalf("the probe must keep every NON-filter param so it measures the same scope: %q", probed)
		}
		if !strings.Contains(got, "0 of 3 rows matched") {
			t.Fatalf("no denominator on stderr; got %q", got)
		}
		if !strings.Contains(got, "zzzNotAField") {
			t.Fatalf("the notice must name the filter clause it is about; got %q", got)
		}
		if strings.Contains(got, "at least") {
			t.Fatalf("has_more was absent, so the count is exact and must not be hedged; got %q", got)
		}
	})

	// THE GUARD MUST NOT COMMIT THE CLASS IT GUARDS: its own probe is one page.
	t.Run("probe page that promises more is reported as a floor", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, empty, func(string) ([]byte, bool) {
			return []byte(`{"documents":[{"_id":"a"},{"_id":"b"}],"page":{"limit":2,"has_more":true}}`), true
		})
		if !strings.Contains(got, "0 of at least 2 rows matched") {
			t.Fatalf("a capped probe page must be reported as a FLOOR, never as a population; got %q", got)
		}
	})

	t.Run("empty probe blames the collection, not the filter", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, empty, func(string) ([]byte, bool) {
			return []byte(`{"documents":[],"count":0}`), true
		})
		if !strings.Contains(got, "0 of 0 rows matched") {
			t.Fatalf("want the 0-of-0 reading; got %q", got)
		}
		if !strings.Contains(got, "about the collection, not about the filter") {
			t.Fatalf("the one case where a zero IS evidence must say so; got %q", got)
		}
	})

	// NEVER INVENT A DENOMINATOR. A probe that fails must widen the doubt.
	t.Run("failed probe refuses to state a denominator", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, empty, func(string) ([]byte, bool) {
			return nil, false
		})
		if !strings.Contains(got, "no denominator was established") {
			t.Fatalf("a failed probe must say the denominator is UNKNOWN; got %q", got)
		}
		if strings.Contains(got, "0 of 0") {
			t.Fatalf("a failed probe must never render as a measured zero; got %q", got)
		}
	})

	t.Run("probe body with no list key is not a zero", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, empty, func(string) ([]byte, bool) {
			return []byte(`{"ok":false,"error":{"code":"request_failed"}}`), true
		})
		if !strings.Contains(got, "no readable page") {
			t.Fatalf("an error-shaped probe body must not be counted as zero rows; got %q", got)
		}
	})

	// Every filter spelling of query-surface-limits.md §1 reaches the guard.
	t.Run("bracketed and repeated filter spellings all count", func(t *testing.T) {
		for _, raw := range []string{
			"https://x/q?filter%5B%5D=a%3D1&filter%5B%5D=b%3D2&limit=5",
			"https://x/q?filter%5Btitle%5D=Alpha&limit=5",
			"https://x/q?filter%5Bprice%5D%5Bgte%5D=10&limit=5",
		} {
			got := runZeroRowGuard(t, raw, empty, func(string) ([]byte, bool) {
				return []byte(`{"documents":[{"_id":"a"}]}`), true
			})
			if !strings.Contains(got, "0 of 1 rows matched") {
				t.Fatalf("spelling %q did not reach the guard; got %q", raw, got)
			}
		}
	})
}

// ARM 2 — STAYS QUIET. Each case is a read whose zero is either already
// explained elsewhere or not a zero at all. An instrument that cries truncation
// at every read is as useless as one that never does.
func TestZeroRowGuardStaysQuiet(t *testing.T) {
	probeShouldNotRun := func(t *testing.T) func(string) ([]byte, bool) {
		return func(bare string) ([]byte, bool) {
			t.Fatalf("the guard issued a network probe it had no cause to issue (%q)", bare)
			return nil, false
		}
	}

	t.Run("no filter on the url", func(t *testing.T) {
		got := runZeroRowGuard(t, "https://x/q?limit=5", `{"documents":[],"count":0}`, probeShouldNotRun(t))
		if got != "" {
			t.Fatalf("an unfiltered empty read has no ambiguity to report; got %q", got)
		}
	})

	t.Run("rows came back", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, `{"documents":[{"_id":"a"}],"count":1}`, probeShouldNotRun(t))
		if got != "" {
			t.Fatalf("a non-empty page is not this guard's business; got %q", got)
		}
	})

	// THE CRITICAL QUIET CASE. A body with no list key is a NON-ANSWER, not an
	// empty page — the `--limit 1000` paper read that answers `response exceeds
	// 67108864 bytes — refusing to parse a truncated body` at exit 1 has this
	// shape. Firing here would restate a loud refusal as a measured zero, which
	// is the very misreading this file exists to prevent.
	t.Run("error envelope is a non-answer, not an empty page", func(t *testing.T) {
		body := `{"ok":false,"error":{"code":"request_failed","message":"response exceeds 67108864 bytes — refusing to parse a truncated body"}}`
		got := runZeroRowGuard(t, zeroRowFilteredURL, body, probeShouldNotRun(t))
		if got != "" {
			t.Fatalf("a refusal must never be reported as zero rows; got %q", got)
		}
	})

	t.Run("unparseable body", func(t *testing.T) {
		got := runZeroRowGuard(t, zeroRowFilteredURL, `<!doctype html><html>proxy</html>`, probeShouldNotRun(t))
		if got != "" {
			t.Fatalf("a proxy page is not an empty result set; got %q", got)
		}
	})

	t.Run("write verb and non-paginated verb", func(t *testing.T) {
		empty := `{"documents":[],"count":0}`
		for _, cmd := range []manifest.Command{
			{Noun: "doc", Verb: "patch", Paginated: true, Writes: true},
			{Noun: "doc", Verb: "get", Paginated: false},
		} {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = "table"
			warnIfZeroRowsUnderFilter(out, cmd, zeroRowFilteredURL, []byte(empty), probeShouldNotRun(t))
			if stderr.Len() != 0 {
				t.Fatalf("%s %s should be exempt; got %q", cmd.Noun, cmd.Verb, stderr.String())
			}
		}
	})
}

// unfilteredURL's second return is the ONLY authority for "this read was
// filtered". A url it did not change must never be probed: re-asking the
// identical question is repetition wearing a control's badge.
func TestUnfilteredURLOnlyReportsARealChange(t *testing.T) {
	if _, ok := unfilteredURL("https://x/q?limit=5&filtered=yes"); ok {
		t.Fatal("`filtered` is not a filter clause; prefix matching would swallow it")
	}
	bare, ok := unfilteredURL(zeroRowFilteredURL)
	if !ok || strings.Contains(bare, "zzzNotAField") {
		t.Fatalf("filter clause survived the strip: ok=%v %q", ok, bare)
	}
}
