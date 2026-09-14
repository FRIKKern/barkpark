package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-6aa3843b86748e38 — "a capped page reads like a complete result", the
// half of that row which survived its filer's own correction.
//
// THE DEFECT, measured live on c42fde07c against guerrilla at 2026-09-14T21:46Z:
//
//	bp task ls --limit 1000  -> stderr: "result page filled your --limit of 1000
//	                            exactly; more may be available"        (warned)
//	bp task ls --limit 2000  -> stderr: <0 bytes>, exit 0              (SILENT)
//
// while the --limit 2000 envelope itself said limit:1000, returned:1000,
// has_more:true, next_offset:1000. The server was honest; the CLI threw the
// envelope away and inferred completeness from `len(rows) < requestedLimit`.
// Because GET /v1/tasks clamps at 1000, an over-cap request ALWAYS produces a
// short-looking page, so the guard's row-count premise is false for exactly
// the requests that need it — and "raise --limit", the remedy the guard's own
// message recommends, is the action that disables the guard.
//
// WHY THESE FIXTURES CANNOT PASS VACUOUSLY. Every subtest asserts on the
// PRESENCE or ABSENCE of a specific substring, and an empty/garbled fixture
// would make the absence assertions pass for free. So each fixture is first
// run through the very readers the guard uses (extractListRows,
// pageEffectiveLimit) and the test FAILS if the payload does not parse into
// the rows and page block it claims to carry. A fixture that stops reaching
// the code under test reds here rather than reporting zero violations.
func TestOverCapLimitIsAnnounced(t *testing.T) {
	taskLs := manifest.Command{
		Noun: "task", Verb: "ls", Paginated: true,
		HTTP: manifest.HTTP{Method: "GET"},
		Flags: []manifest.Flag{
			{Name: "limit", Type: "int", Default: 100},
			{Name: "offset", Type: "int", Default: 0},
		},
	}

	// page builds the envelope GET /v1/tasks actually returns: `served` rows
	// under `docs`, and a page block whose `limit` is the EFFECTIVE limit
	// after the server's clamp.
	page := func(served, effectiveLimit int, hasMore bool) []byte {
		rows := make([]json.RawMessage, served)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"doc_id":"task-%d"}`, i))
		}
		var next any
		if hasMore {
			next = served
		}
		body, err := json.Marshal(map[string]any{
			"ok":   true,
			"docs": rows,
			"page": map[string]any{
				"limit": effectiveLimit, "offset": 0,
				"returned": served, "has_more": hasMore, "next_offset": next,
			},
		})
		if err != nil {
			t.Fatalf("fixture did not marshal: %v", err)
		}
		return body
	}

	// THE ANTI-VACUITY GATE. Proves the fixture reaches the guard's own
	// readers before any subtest trusts a silence.
	mustParse := func(t *testing.T, body []byte, wantRows, wantLimit int) {
		t.Helper()
		rows, key := extractListRows(unwrapResult(body))
		if len(rows) != wantRows {
			t.Fatalf("fixture unreadable: extractListRows got %d rows under %q, want %d — the subtest below would have asserted on a payload the guard never parsed", len(rows), key, wantRows)
		}
		got, ok := pageEffectiveLimit(unwrapResult(body))
		if !ok || got != wantLimit {
			t.Fatalf("fixture unreadable: pageEffectiveLimit = (%d,%v), want (%d,true)", got, ok, wantLimit)
		}
	}

	run := func(t *testing.T, g globals, body []byte) string {
		t.Helper()
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"
		warnIfDefaultPageMayBeTruncated(out, g, taskLs, body)
		if stdout.Len() != 0 {
			t.Errorf("the notice must ride stderr only; stdout=%q", stdout.String())
		}
		return stderr.String()
	}

	// RED BEFORE THE FIX. This is the measured case: asked 2000, served the
	// 1000-row cap, server says there is more.
	t.Run("an over-cap --limit names both numbers and the continuation", func(t *testing.T) {
		body := page(1000, 1000, true)
		mustParse(t, body, 1000, 1000)

		got := run(t, globals{limit: 2000, limitSet: true}, body)

		if got == "" {
			t.Fatalf("SILENT on a clamped page: asked 2000, served 1000, has_more true — this is the defect task-6aa3843b86748e38 names")
		}
		// c1: what was ASKED alongside what was SERVED.
		if !strings.Contains(got, "2000") {
			t.Errorf("notice does not state what was ASKED (2000); got %q", got)
		}
		if !strings.Contains(got, "1000") {
			t.Errorf("notice does not state what was SERVED (1000); got %q", got)
		}
		if !strings.Contains(got, "--all") && !strings.Contains(got, "--offset") {
			t.Errorf("notice names no remedy; got %q", got)
		}
	})

	// c3, FIRST CONTROL — the instrument must still report the NEGATIVE case.
	// A genuinely complete page: the caller's limit was honoured in full and
	// the server reports nothing beyond it.
	t.Run("an honoured --limit on a complete page stays silent", func(t *testing.T) {
		body := page(933, 2000, false)
		mustParse(t, body, 933, 2000)

		if got := run(t, globals{limit: 2000, limitSet: true}, body); got != "" {
			t.Fatalf("a complete page must read complete; got %q", got)
		}
	})

	// c3, SECOND CONTROL — a clamp is not by itself incompleteness. When the
	// population is smaller than the cap the page IS whole, so the reduction
	// is named but no continuation is promised. A fix that shouted
	// "more may be available" here would be the same defect reversed.
	t.Run("a clamp over a small population reports the reduction, not a continuation", func(t *testing.T) {
		body := page(933, 1000, false)
		mustParse(t, body, 933, 1000)

		got := run(t, globals{limit: 2000, limitSet: true}, body)

		if got == "" {
			t.Fatalf("the caller's 2000 was reduced to 1000 and was never told; got silence")
		}
		if !strings.Contains(got, "complete") {
			t.Errorf("a whole page must be described as whole; got %q", got)
		}
		if strings.Contains(got, "more rows remain") {
			t.Errorf("promised a continuation the server did not offer; got %q", got)
		}
	})

	// The guard has always been suppressed under --all, which IS the remedy
	// it recommends. A clamp must not reintroduce the nag.
	t.Run("--all suppresses the over-cap notice too", func(t *testing.T) {
		body := page(1000, 1000, true)
		mustParse(t, body, 1000, 1000)

		if got := run(t, globals{limit: 2000, limitSet: true, all: true}, body); got != "" {
			t.Errorf("--all must not warn; got %q", got)
		}
	})

	// An envelope with no page block is the pre-existing world (and several of
	// the 19 limit-bearing commands answer that way). The clamp check must
	// abstain there and leave the row-count heuristic exactly as it was,
	// rather than inventing a reduction from a limit it never read.
	t.Run("no page block falls back to the row-count heuristic", func(t *testing.T) {
		body := []byte(`{"docs":[{"doc_id":"1"},{"doc_id":"2"},{"doc_id":"3"}]}`)
		if _, ok := pageEffectiveLimit(unwrapResult(body)); ok {
			t.Fatalf("control broken: this fixture must carry NO readable page block")
		}

		// Exactly-full against the explicit limit — the old message, unchanged.
		if got := run(t, globals{limit: 3, limitSet: true}, body); !strings.Contains(got, "filled your --limit of 3 exactly") {
			t.Errorf("row-count heuristic regressed; got %q", got)
		}
		// Short page, no envelope evidence — still silent.
		if got := run(t, globals{limit: 9, limitSet: true}, body); got != "" {
			t.Errorf("no page block and a short page must stay silent; got %q", got)
		}
	})
}
