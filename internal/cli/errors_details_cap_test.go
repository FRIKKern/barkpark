package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// THE MEASUREMENT THIS FILE PINS (pds-w33-bl-detail-lines-uncapped).
//
// `details` is server-controlled and at least two emitters are unbounded by
// construction:
//
//   - api/lib/barkpark/content/errors.ex:672/:701 answer a bad filter with
//     `details: %{filter: raw}` — the caller's filter echoed VERBATIM. Driven
//     against guerrilla.barkpark.cloud on 2026-09-11, `bp doc query task
//     --filter <9000 z's> -o table` printed a 9,010-byte `filter: …` line on
//     stderr. The message line beside it stopped at 4,271 bytes, because
//     Elixir's inspect/1 caps at its 4,096-rune :printable_limit — the server
//     bounds its own prose and not its details.
//   - api/lib/barkpark/content/papers/block_ops.ex structure_refusal_details
//     answers `invalid_paper_structure` with one message per offending block
//     under a single "blocks" key (its own comment cites a 105-block Paper), so
//     the generic renderer prints the whole compact-JSON array on ONE line.
//
// capBody has capped the OTHER server-controlled opaque path in errors.go at
// 200 runes since it was written ("so a multi-KB HTML page never spews to
// stderr"); these are the same bytes arriving through a different key.

// bigDetailsBody is the SHAPE of the measured live refusal — same code, same
// key, same verbatim echo — at the byte count that was actually observed.
func bigDetailsBody(filterLen int) string {
	payload := map[string]any{"error": map[string]any{
		"code":    "invalid_filter",
		"message": "malformed filter",
		"details": map[string]any{"filter": strings.Repeat("z", filterLen)},
	}}
	b, err := json.Marshal(payload)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// DETECTOR. On origin/main the human `filter:` line is as long as the server's
// echo (9,010 bytes for the measured 9,000-byte filter); with the cap it is
// bounded by maxOpaqueRunes plus the elision.
func TestHumanDetailLineIsCappedForBothHumanShapes(t *testing.T) {
	const filterLen = 9000

	for _, shape := range []string{"table", "minimal"} {
		t.Run(shape, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = shape

			renderError(w, classifyError(400, []byte(bigDetailsBody(filterLen))))

			var detail string
			for _, line := range strings.Split(stderr.String(), "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "filter:") {
					detail = line
				}
			}
			if detail == "" {
				t.Fatalf("no `filter:` detail line on stderr:\n%s", stderr.String())
			}
			// 64 is generous headroom for the two-space indent, the "filter: "
			// key and the elision suffix — far below the 9,010 bytes main prints.
			if len(detail) > maxOpaqueRunes+64 {
				t.Fatalf("detail line is %d bytes, want <= %d: the server's %d-byte echo is reaching stderr uncapped",
					len(detail), maxOpaqueRunes+64, filterLen)
			}
			if !strings.Contains(detail, "-o json for the full details") {
				t.Fatalf("truncated line does not redirect the reader to the machine shape: %q", detail)
			}
			if !strings.Contains(detail, "filter: zzz") {
				t.Fatalf("the kept prefix lost the key or the value: %q", detail)
			}
		})
	}
}

// The cap must be TOTAL: every per-code renderer in detailLinesForCode routes
// through it, not just the generic fallback. unknown_tag / duplicate_of /
// resource_conflict / validation_failed each have their own line builder, and
// each takes server-controlled strings.
func TestEveryPerCodeRendererIsCapped(t *testing.T) {
	huge := strings.Repeat("q", 4000)

	cases := []struct{ code, details string }{
		{"unknown_tag", fmt.Sprintf(`{"unknown":[%q],"suggestions":{%q:[%q]}}`, huge, huge, huge)},
		{"duplicate_of", fmt.Sprintf(`{"duplicate_of":"doc-1","similar":[%q],"advise":%q}`, huge, huge)},
		{"resource_conflict", fmt.Sprintf(`{"resource":%q,"holder":%q}`, huge, huge)},
		{"validation_failed", fmt.Sprintf(`{"title":[%q]}`, huge)},
		{"duplicate_task", fmt.Sprintf(`{"similar":[%q]}`, huge)},
		{"invalid_paper_structure", fmt.Sprintf(`{"blocks":[%q]}`, huge)},
	}

	for _, tc := range cases {
		t.Run(tc.code, func(t *testing.T) {
			lines := detailLinesForCode(tc.code, json.RawMessage(tc.details))
			if len(lines) == 0 {
				t.Fatalf("no lines rendered for %s", tc.code)
			}
			for i, line := range lines {
				if len([]rune(line)) > maxOpaqueRunes+64 {
					t.Fatalf("%s line %d is %d runes, want <= %d (uncapped renderer)",
						tc.code, i, len([]rune(line)), maxOpaqueRunes+64)
				}
			}
		})
	}
}

// THE FENCE. -o json and -o yaml are the machine channel: a consumer WANTS the
// whole payload and a truncated one would hand jq an invalid document. The cap
// must not touch a single byte there.
func TestMachineShapesStayByteVerbatimUnderTheCap(t *testing.T) {
	const filterLen = 9000
	want := strings.Repeat("z", filterLen)

	t.Run("json", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "json"

		renderError(w, classifyError(400, []byte(bigDetailsBody(filterLen))))

		var env struct {
			Error struct {
				Details map[string]string `json:"details"`
			} `json:"error"`
		}
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("stdout is not parseable JSON (%v)", err)
		}
		if got := env.Error.Details["filter"]; got != want {
			t.Fatalf("json details.filter is %d bytes, want the verbatim %d", len(got), len(want))
		}
	})

	t.Run("yaml", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "yaml"

		renderError(w, classifyError(400, []byte(bigDetailsBody(filterLen))))

		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("yaml envelope no longer carries the verbatim %d-byte filter value", len(want))
		}
	})
}

// The overwhelming majority of payloads are a field name, a rule or an id. Those
// must be byte-identical to before the cap — a cap that rewrites short lines
// would be a regression dressed as a fix.
func TestShortDetailLinesAreByteIdentical(t *testing.T) {
	for _, body := range []string{
		liveInvalidFilterBody,
		`{"error":{"code":"validation_failed","message":"bad","details":{"title":["can't be blank"]}}}`,
		`{"error":{"code":"unknown_tag","message":"bad","details":{"unknown":["clii"],"suggestions":{"clii":["cli"]}}}}`,
		`{"error":{"code":"duplicate_of","message":"bad","details":{"duplicate_of":"doc-1","advise":"claim it"}}}`,
	} {
		ae := classifyError(422, []byte(body))
		for _, line := range detailLinesForCode(ae.code, ae.details) {
			if line != capDetailLine(line) {
				t.Fatalf("short line was rewritten by the cap: %q", line)
			}
			if strings.Contains(line, "…") {
				t.Fatalf("short line picked up an elision: %q", line)
			}
		}
	}
}

// capBody's 200-rune budget and the details cap are ONE policy, not two
// coincidences: the hoisted constant is what makes that true, and this pins it
// so a later edit cannot silently split them.
func TestCapBodyAndDetailCapShareOneBudget(t *testing.T) {
	if got := capBody(bytes.Repeat([]byte("x"), 10_000)); len([]rune(got)) != maxOpaqueRunes+1 {
		t.Fatalf("capBody kept %d runes, want %d + the ellipsis", len([]rune(got)), maxOpaqueRunes)
	}
	if got := capDetailLine(strings.Repeat("x", 10_000)); !strings.HasPrefix(got, strings.Repeat("x", maxOpaqueRunes)) {
		t.Fatalf("capDetailLine kept a different prefix length than capBody")
	}
}
