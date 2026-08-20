package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// The server has always SENT `details` — the per-code payload that names WHICH
// filter, field or rule it refused (docs/cli/error-exit-table.md :15/:97/:117/
// :153 declare it wire contract and instruct the CLI to print it). The CLI ate
// every byte of it, because the canon struct in classifyError did not declare
// the key and encoding/json drops what it cannot map. These tests are the
// ratchet: delete `Details` from that struct (or stop threading it into
// apiError) and every one of them goes red.

// liveInvalidFilterBody is the VERBATIM 400 body observed on the wire from a
// real `?filter[zzzgarbage]` request — insertion-ordered, exactly as the server
// emits it. Key order matters: bp's own map-marshalled envelope is ALPHABETICAL,
// which is what proved public issue #4938 was observing the CLI and not the
// server.
const liveInvalidFilterBody = `{"error":{"code":"invalid_filter","message":"unknown filter operator","hint":"see docs/api-v1.md","details":{"filter":"zzzgarbage"},"request_id":"req-abc"}}`

func TestClassifyErrorKeepsDetailsRaw(t *testing.T) {
	ae := classifyError(400, []byte(liveInvalidFilterBody))

	if ae.code != "invalid_filter" {
		t.Fatalf("code = %q, want invalid_filter", ae.code)
	}
	if got, want := string(ae.details), `{"filter":"zzzgarbage"}`; got != want {
		t.Fatalf("details = %q, want %q", got, want)
	}
	// The exit ladder is the contract spine and must not move.
	if ae.exit != exitUsage {
		t.Fatalf("exit = %d, want %d (exit codes are unchanged by this feature)", ae.exit, exitUsage)
	}
}

// A heterogeneous details payload must survive WHOLE. A typed decode (the
// mutateErrorMessage bug) fits map[string][]string and fails the unmarshal on
// every other shape, losing the payload entirely.
func TestClassifyErrorKeepsHeterogeneousDetailShapes(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{
			"validation_failed map of lists",
			`{"error":{"code":"validation_failed","message":"invalid","details":{"title":["can't be blank"]}}}`,
			`{"title":["can't be blank"]}`,
		},
		{
			"label_spine object of scalars",
			`{"error":{"code":"validation_failed","message":"bad label","details":{"field":"tags","rule":"label_spine","fix":"use 2 tags","index":1}}}`,
			`{"field":"tags","rule":"label_spine","fix":"use 2 tags","index":1}`,
		},
		{
			"duplicate_task nested list",
			`{"error":{"code":"duplicate_id","message":"dupe","details":{"similar":[{"id":"t-1","score":0.9}]}}}`,
			`{"similar":[{"id":"t-1","score":0.9}]}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ae := classifyError(422, []byte(tc.body))
			if got := string(ae.details); got != tc.want {
				t.Fatalf("details = %q, want %q", got, tc.want)
			}
		})
	}
}

// Absent, null and empty details all stay nil, so the ~60 detail-less call sites
// emit byte-identical envelopes.
func TestClassifyErrorEmptyDetailsStaysNil(t *testing.T) {
	for _, body := range []string{
		`{"error":{"code":"not_found","message":"gone"}}`,
		`{"error":{"code":"not_found","message":"gone","details":null}}`,
		`{"error":{"code":"not_found","message":"gone","details":{}}}`,
		`{"error":{"code":"not_found","message":"gone","details":[]}}`,
	} {
		if ae := classifyError(404, []byte(body)); ae.details != nil {
			t.Fatalf("body %s: details = %q, want nil", body, string(ae.details))
		}
	}
}

func TestRenderErrorJSONCarriesDetails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	renderError(w, classifyError(400, []byte(liveInvalidFilterBody)))

	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string            `json:"code"`
			Details map[string]string `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not parseable JSON (%v):\n%s", err, stdout.String())
	}
	if env.OK {
		t.Fatalf("ok = true, want false")
	}
	if env.Error.Details["filter"] != "zzzgarbage" {
		t.Fatalf("details.filter = %q, want zzzgarbage; stdout:\n%s", env.Error.Details["filter"], stdout.String())
	}
}

func TestRenderErrorYAMLCarriesDetails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	renderError(w, classifyError(400, []byte(liveInvalidFilterBody)))

	got := stdout.String()
	if !strings.Contains(got, "details:") || !strings.Contains(got, "zzzgarbage") {
		t.Fatalf("yaml envelope missing details:\n%s", got)
	}
}

// table and minimal are the human shapes: renderErrorEnvelope emits nothing on
// stdout there, so details has to reach the reader on stderr — sorted, and ABOVE
// the hint (the specific fact before the generic advice).
func TestRenderErrorHumanShapesPrintSortedDetailsAboveHint(t *testing.T) {
	for _, shape := range []string{"table", "minimal"} {
		t.Run(shape, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = shape

			body := `{"error":{"code":"validation_failed","message":"invalid label","hint":"fix the tags","details":{"rule":"label_spine","field":"tags","index":1,"similar":["a","b"]}}}`
			renderError(w, classifyError(422, []byte(body)))

			got := stderr.String()
			for _, want := range []string{
				"  field: tags",
				"  index: 1",
				"  rule: label_spine",
				`  similar: ["a","b"]`,
				"  hint: fix the tags",
			} {
				if !strings.Contains(got, want+"\n") {
					t.Fatalf("stderr missing line %q:\n%s", want, got)
				}
			}
			// Sorted, and every detail line above the hint.
			order := []string{"  field:", "  index:", "  rule:", "  similar:", "  hint:"}
			at := -1
			for _, tok := range order {
				i := strings.Index(got, tok)
				if i <= at {
					t.Fatalf("line %q out of order (want sorted keys above the hint):\n%s", tok, got)
				}
				at = i
			}
			if stdout.Len() != 0 {
				t.Fatalf("%s shape wrote to stdout:\n%s", shape, stdout.String())
			}
		})
	}
}

// A details that is not an object still reaches the human, on one line.
func TestRenderErrorHumanNonObjectDetails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	renderError(w, classifyError(422, []byte(`{"error":{"code":"validation_failed","message":"bad","details":["a","b"]}}`)))

	if got := stderr.String(); !strings.Contains(got, `  details: ["a","b"]`) {
		t.Fatalf("stderr missing the non-object details line:\n%s", got)
	}
}

// A malformed details payload must never make -o json stdout unparseable: it is
// dropped, not forwarded.
func TestRenderErrorMalformedDetailsDropped(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	ae := apiError{exit: exitValidation, code: "validation_failed", message: "bad", details: json.RawMessage(`{not json`)}
	renderError(w, ae)

	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not parseable JSON (%v):\n%s", err, stdout.String())
	}
	if _, ok := env["error"].(map[string]any)["details"]; ok {
		t.Fatalf("malformed details leaked into the envelope:\n%s", stdout.String())
	}
}

// The delegation must be byte-identical for the ~60 detail-less call sites:
// renderErrorEnvelope and renderErrorEnvelopeDetailed(…, nil) produce the same
// bytes, and neither emits a `details` key.
func TestRenderErrorEnvelopeDelegationIsByteIdentical(t *testing.T) {
	for _, shape := range []string{"json", "yaml", "table", "minimal"} {
		var aOut, aErr, bOut, bErr bytes.Buffer
		a := newWriter(&aOut, &aErr)
		a.output = shape
		b := newWriter(&bOut, &bErr)
		b.output = shape

		gotA := renderErrorEnvelope(a, "usage", "boom", "req-1", "try --help")
		gotB := renderErrorEnvelopeDetailed(b, "usage", "boom", "req-1", "try --help", nil)

		if gotA != gotB {
			t.Fatalf("%s: handled = %v vs %v", shape, gotA, gotB)
		}
		if aOut.String() != bOut.String() || aErr.String() != bErr.String() {
			t.Fatalf("%s: delegation drifted\nplain: %q / %q\ndetailed: %q / %q", shape, aOut.String(), aErr.String(), bOut.String(), bErr.String())
		}
		if strings.Contains(aOut.String(), "details") {
			t.Fatalf("%s: detail-less call site emitted a details key:\n%s", shape, aOut.String())
		}
	}
}

// Exit codes are untouched by this feature — quoted for two distinct codes,
// with and without a details payload.
func TestDetailsDoNotChangeExitCodes(t *testing.T) {
	cases := []struct {
		body string
		want int
	}{
		{`{"error":{"code":"invalid_filter","message":"nope"}}`, exitUsage},
		{liveInvalidFilterBody, exitUsage},
		{`{"error":{"code":"validation_failed","message":"nope"}}`, exitValidation},
		{`{"error":{"code":"validation_failed","message":"nope","details":{"title":["can't be blank"]}}}`, exitValidation},
	}
	for _, tc := range cases {
		if got := classifyError(422, []byte(tc.body)).exit; got != tc.want {
			t.Fatalf("exit = %d, want %d for %s", got, tc.want, tc.body)
		}
	}
}
