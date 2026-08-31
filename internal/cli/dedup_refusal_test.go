package cli

import (
	"strings"
	"testing"
)

// duplicateTaskBody is the EXACT 409 envelope the server builds for a
// duplicate task: api/lib/barkpark/content/errors.ex build/1 for
// {:duplicate_task, payload} sets details to Map.take(payload, [:similar,
// :advise]), and api/lib/barkpark/tasks/dedup.ex present/1 shapes each row as
// {id, similarity, relation, lifecycle_status}. So `details` is a map whose
// values are LISTS OF OBJECTS.
const duplicateTaskBody = `{"error":{"code":"duplicate_task",` +
	`"message":"this task looks like an existing one — claim/extend it, or pass distinct_from: [\"<id>\"] to confirm it is different",` +
	`"hint":"This task duplicates an existing one. Claim or extend the named task, or pass distinct_from with its id to confirm yours is genuinely different.",` +
	`"details":{"similar":[{"id":"task-abc123","similarity":0.91,"relation":"same_surface","lifecycle_status":"open"},` +
	`{"id":"task-def456","similarity":0.88,"relation":"sibling","lifecycle_status":"in_progress"}],"advise":[]}}}`

// THE BUG: mutateErrorMessage typed `details` as map[string][]string — a guess
// about validation_failed's shape. encoding/json rejects the WHOLE document on
// any field mismatch, so this 409 failed to unmarshal, fell through to the
// raw-body fallback, and was clamped at 200 runes — cutting the body mid-`hint`,
// which is exactly where the id the refusal demands lives. The refusal told the
// caller to pass distinct_from: ["<id>"] while withholding the id.
func TestDuplicateTaskRefusalIsAppealable(t *testing.T) {
	got := mutateErrorMessage(409, []byte(duplicateTaskBody))

	if strings.Contains(got, "…") {
		t.Errorf("the refusal is truncated — its remedy is unreadable:\n%s", got)
	}
	// The whole point: the ids the refusal instructs the caller to pass.
	for _, id := range []string{"task-abc123", "task-def456"} {
		if !strings.Contains(got, id) {
			t.Errorf("refusal withholds the matched id %s that its own remedy requires:\n%s", id, got)
		}
	}
	// The server's hint must survive intact, to its final character.
	if !strings.Contains(got, "confirm yours is genuinely different.") {
		t.Errorf("the server hint was dropped or cut short:\n%s", got)
	}
	if !strings.Contains(got, "distinct_from") {
		t.Errorf("lost the actionable instruction:\n%s", got)
	}
	// The candidate's standing is what tells the caller whether to claim it or
	// argue with it.
	if !strings.Contains(got, "0.91") || !strings.Contains(got, "open") {
		t.Errorf("candidate rows dropped their similarity/lifecycle:\n%s", got)
	}
}

// The regression that CAUSED it, pinned on its own: one unexpected `details`
// shape must never discard the fields the decoder CAN read.
func TestUnexpectedDetailsShapeDoesNotDiscardTheEnvelope(t *testing.T) {
	shapes := []struct {
		name    string
		details string
	}{
		{"list of objects", `{"similar":[{"id":"task-x"}]}`},
		{"map of strings", `{"title":"is required"}`},
		{"bare list", `["a","b"]`},
		{"scalar", `"nope"`},
		{"number", `7`},
		{"null", `null`},
		{"nested", `{"a":{"b":{"c":1}}}`},
	}
	for _, s := range shapes {
		t.Run(s.name, func(t *testing.T) {
			body := `{"error":{"code":"some_code","message":"the real message","details":` + s.details + `}}`
			got := mutateErrorMessage(422, []byte(body))
			if !strings.Contains(got, "the real message") {
				t.Errorf("details %s discarded the message the decoder could read:\n%s", s.details, got)
			}
			if strings.Contains(got, `{"error"`) {
				t.Errorf("details %s dropped a readable envelope to the raw-body fallback:\n%s", s.details, got)
			}
		})
	}
}

// The field→reasons rendering validation_failed relies on must not regress.
func TestValidationDetailsStillRender(t *testing.T) {
	body := `{"error":{"code":"validation_failed","message":"validation failed","details":{"title":["is required"],"kind":["is required","must be a string"]}}}`
	got := mutateErrorMessage(422, []byte(body))
	if !strings.Contains(got, "validation failed") {
		t.Errorf("lost the message:\n%s", got)
	}
	// Sorted, so the output is deterministic over the map.
	if !strings.Contains(got, "kind: is required; must be a string · title: is required") {
		t.Errorf("field reasons lost their sorted joined form:\n%s", got)
	}
}

// A server hint is the sentence that says what to DO. It was never read at
// all, so every hinted refusal on this path arrived with its remedy stripped.
func TestServerHintReachesTheCaller(t *testing.T) {
	body := `{"error":{"code":"not_ready","message":"the task is not claimable","hint":"re-claim with your own worker id to renew the lease"}}`
	got := mutateErrorMessage(409, []byte(body))
	if !strings.Contains(got, "re-claim with your own worker id") {
		t.Errorf("the server hint never reached the caller:\n%s", got)
	}
}

// An unknown body is the only diagnosis left, so it must arrive whole. The old
// 200-rune clamp cut it mid-sentence precisely when it mattered most.
func TestUnknownBodyIsNotTruncated(t *testing.T) {
	long := `<html><body>` + strings.Repeat("proxy failure detail ", 40) + `</body></html>`
	got := mutateErrorMessage(502, []byte(long))
	if strings.Contains(got, "…") {
		t.Errorf("unknown body was truncated:\n%s", got)
	}
	if !strings.Contains(got, "</html>") {
		t.Errorf("unknown body lost its tail — the clamp is still there:\n%s", got)
	}
}

// An id-less candidate row earns no line: naming the id is the entire purpose.
func TestCandidateWithoutAnIDRendersNothing(t *testing.T) {
	body := `{"error":{"code":"duplicate_task","message":"dupe","details":{"similar":[{"similarity":0.9}]}}}`
	got := mutateErrorMessage(409, []byte(body))
	if strings.Contains(got, "matches ") {
		t.Errorf("rendered a candidate line for a row with no id:\n%s", got)
	}
	if strings.Contains(got, "distinct_from") {
		t.Errorf("advertised distinct_from with no id to pass — the exact bug, re-made:\n%s", got)
	}
}

// The candidates get exactly ONE rendering. apierr.Summary() appends the
// generic details view, which for a dedup refusal is the whole candidate array
// as compact JSON — printing that AND the readable id-leading lines buries the
// ids in the very noise they were extracted from. Caught when the shared parser
// replaced this path's private decoder, and pinned so consolidation cannot
// quietly re-introduce it.
func TestDedupRefusalRendersCandidatesOnce(t *testing.T) {
	got := mutateErrorMessage(409, []byte(duplicateTaskBody))
	if strings.Contains(got, `[{"id":"task-abc123"`) || strings.Contains(got, "similar: [") {
		t.Errorf("the raw candidate blob is printed alongside the parsed lines:\n%s", got)
	}
	if n := strings.Count(got, "task-abc123"); n != 1 {
		t.Errorf("task-abc123 appears %d times, want exactly 1:\n%s", n, got)
	}
	// A refusal with NO candidates keeps the full generic details rendering —
	// there is no second view, so the details ARE the detail.
	plain := mutateErrorMessage(422, []byte(`{"error":{"code":"validation_failed","message":"v","details":{"title":["is required"]}}}`))
	if !strings.Contains(plain, "title: is required") {
		t.Errorf("a non-dedup refusal lost its details rendering:\n%s", plain)
	}
}
