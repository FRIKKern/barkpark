package cli

import (
	"strings"
	"testing"
)

// THE HANDLE A SERVER-FAULT CREATE FAILURE OWES ITS CALLER.
//
// pds-bl-task-create-draft-at-rc0, criterion 4: "no create failure reports on
// an exit code alone". The three sibling criteria fixed the create SUCCESS
// receipt (PR #13606). This is the create FAILURE side.
//
// MECHANISM, not a retry count. A `bp task create` that faults server-side
// renders through mutateErrorMessage. The server's registered hint for
// `internal_error` (api/lib/barkpark/content/errors.ex @hints) is:
//
//	"Retry shortly; if it persists, report the request_id to the API operator."
//
// and the envelope carries that request_id (Errors.put_request_id/2 stamps it
// from Logger.metadata). mutateErrorMessage rendered the message, the details
// and the hint — and dropped request_id on the floor. So the remedy named an
// identifier the receipt withheld: the same unappealable-refusal shape this
// very function's own doc comment records for the dedup 409, reproduced on the
// 5xx arm. When the server declines to name the fault at all ("unknown error"),
// the request_id is the ONLY thing left that an operator can act on.
//
// This is the live shape, byte-for-byte, that internal/apiclient/retry_test.go
// records from guerrilla.
const liveCreateInternalErrorBody = `{"error":{"code":"internal_error",` +
	`"message":"unknown error (DBConnection.ConnectionError)",` +
	`"hint":"Retry shortly; if it persists, report the request_id to the API operator.",` +
	`"request_id":"GM5eMgixS765GScABWKi"}}`

// The bare one — the server named NOTHING. Everything the caller has is the id.
const bareCreateInternalErrorBody = `{"error":{"code":"internal_error",` +
	`"message":"unknown error",` +
	`"hint":"Retry shortly; if it persists, report the request_id to the API operator.",` +
	`"request_id":"Fq2LmT8xVb01aaaBCdEf"}}`

func TestCreateServerFaultCarriesTheRequestIDItsHintDemands(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		id   string
	}{
		{"named fault family", liveCreateInternalErrorBody, "GM5eMgixS765GScABWKi"},
		{"bare unknown error", bareCreateInternalErrorBody, "Fq2LmT8xVb01aaaBCdEf"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := mutateErrorMessage(500, []byte(tc.body))
			if !strings.Contains(got, "report the request_id") {
				t.Fatalf("precondition: the hint that names request_id was not rendered at all:\n%s", got)
			}
			if !strings.Contains(got, tc.id) {
				t.Errorf("the create failure tells the caller to report the request_id and withholds it — the remedy is unappealable:\n%s", got)
			}
		})
	}
}

// The 4xx refusals are already well-named (validation_failed names the field,
// duplicate_task names the ids). They must NOT grow a request_id line: it would
// be noise on a refusal the caller can already act on, and it is the 5xx — the
// one the operator has to be TOLD about — that owns this handle.
func TestClientRefusalsDoNotGrowARequestIDLine(t *testing.T) {
	body := `{"error":{"code":"validation_failed","message":"v",` +
		`"details":{"title":["is required"]},"request_id":"ZZnotwantedZZ"}}`
	got := mutateErrorMessage(422, []byte(body))
	if strings.Contains(got, "ZZnotwantedZZ") {
		t.Errorf("a 4xx refusal that already names its field grew a request_id line:\n%s", got)
	}
	if !strings.Contains(got, "title: is required") {
		t.Errorf("the 4xx refusal stopped naming its field:\n%s", got)
	}
}

// A 5xx with no request_id (an envelope the server stamped nothing onto) must
// stay exactly as terse as it was — no empty "request_id:" line.
func TestServerFaultWithoutARequestIDPrintsNoEmptyLine(t *testing.T) {
	got := mutateErrorMessage(500, []byte(`{"error":{"code":"internal_error","message":"unknown error"}}`))
	if strings.Contains(got, "request_id") {
		t.Errorf("printed a request_id line for an envelope that carries none:\n%s", got)
	}
}
