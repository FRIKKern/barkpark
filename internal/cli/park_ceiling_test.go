package cli

// park_ceiling_test.go — the protective kit around `bp park`'s CLI-side
// ceiling and its mandatory summary.
//
// The defect class these tests exist to exclude is the one this campaign keeps
// filing: a ceiling PRESENT in the code and never exercised on a real oversized
// payload. So the refusal arm below builds an ACTUAL >2 MB body and runs it
// through the real buildBody path — not a unit call on the predicate with a
// synthetic length.

import (
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// parkCmd mirrors the capabilities entry the `park` plugin must serve: a write
// whose required positional IS the summary, plus a
// --file flag carrying the blob. Declared here for the same reason
// setKeyPatchCmd is: buildBody is the half of the contract that lives in this
// repo, and it must already be correct on the day the manifest adds the verb.
func parkCmd() manifest.Command {
	return manifest.Command{
		ID: "park.park", Noun: "park", Verb: "park", Writes: true,
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/plugins/park"},
		Args: []manifest.Arg{
			{Name: "summary", Required: true, Type: "string"},
		},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "set", Type: "string", Repeatable: true},
		},
	}
}

// parkBodyOfSize returns a JSON object literal of EXACTLY n bytes, padding a
// single `payload` string field. The exact length is what makes the boundary
// arms below meaningful: an approximate size cannot tell "at the ceiling" from
// "one byte over".
func parkBodyOfSize(t *testing.T, n int) string {
	t.Helper()
	const envelope = `{"payload":""}`
	if n < len(envelope) {
		t.Fatalf("parkBodyOfSize(%d): below the %d-byte envelope", n, len(envelope))
	}
	return `{"payload":"` + strings.Repeat("x", n-len(envelope)) + `"}`
}

// parkAssembledSize runs a park of the given raw --file payload through the
// real body assembly and returns the size of the body that would go over the
// wire. It is used to calibrate the boundary arms: the assembled body is not
// the file verbatim (the required `summary` arg merges into it), so a test that
// assumed it was would be measuring the wrong number.
func parkAssembledSize(t *testing.T, rawBytes int) int {
	t.Helper()
	cmd := parkCmd()
	cmd.Noun = "sizing-probe" // off the ceiling, so calibration is never refused
	body, _, _, err := buildBody(cmd,
		map[string][]string{"file": {writeJSONFile(t, parkBodyOfSize(t, rawBytes))}},
		map[string]string{"summary": parkProbeSummary})
	if err != nil {
		t.Fatalf("calibration assembly of a %d-byte payload failed: %v", rawBytes, err)
	}
	return len(body)
}

// parkProbeSummary is held constant across calibration and measurement: the
// summary merges into the body, so a different string would shift the size the
// calibration is solving for.
const parkProbeSummary = "a parked transcript"

// TestParkPayloadOverCeilingIsRefused is the REFUSAL arm, driven by a real
// oversized blob — an actual >2 MB payload through the real buildBody path, not
// a unit call on the predicate with a synthetic length.
//
// REVERT ARM: delete the checkParkPayloadCeiling call from
// buildBodyWithStdinOwnership and this reds — buildBody returns a nil error and
// hands back the whole over-ceiling body to be pushed over the wire.
func TestParkPayloadOverCeilingIsRefused(t *testing.T) {
	raw := parkPayloadCeilingBytes + 1
	path := writeJSONFile(t, parkBodyOfSize(t, raw))

	body, _, _, err := buildBody(parkCmd(),
		map[string][]string{"file": {path}},
		map[string]string{"summary": parkProbeSummary})
	if err == nil {
		t.Fatalf("park with a %d-byte payload was ACCEPTED (body %d bytes); want a refusal", raw, len(body))
	}
	if body != nil {
		t.Errorf("refused park still returned a %d-byte body; want nil", len(body))
	}
	// The refusal must be actionable: it names the measured size and the ceiling.
	assembled := parkAssembledSize(t, raw)
	for _, want := range []string{fmt.Sprintf("is %d bytes", assembled), fmt.Sprintf("%d-byte", parkPayloadCeilingBytes)} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal %q does not name %q", err, want)
		}
	}
}

// TestParkPayloadAtCeilingIsAccepted is the QUIET arm, and it pins the failure
// direction that would hurt most: a guard refusing what the server accepts. A
// body of EXACTLY the ceiling goes through. The raw payload is solved for from
// a calibration run so "exactly" means exactly.
func TestParkPayloadAtCeilingIsAccepted(t *testing.T) {
	const probe = 1024
	overhead := parkAssembledSize(t, probe) - probe
	raw := parkPayloadCeilingBytes - overhead

	body, _, _, err := buildBody(parkCmd(),
		map[string][]string{"file": {writeJSONFile(t, parkBodyOfSize(t, raw))}},
		map[string]string{"summary": parkProbeSummary})
	if err != nil {
		t.Fatalf("park assembling to exactly %d bytes was refused: %v", parkPayloadCeilingBytes, err)
	}
	if len(body) != parkPayloadCeilingBytes {
		t.Fatalf("calibration missed: body = %d bytes, want exactly the %d-byte ceiling", len(body), parkPayloadCeilingBytes)
	}
}

// TestParkPayloadOneByteOverCeilingIsRefused is the other side of the same
// boundary: one byte past what the previous test proved is accepted. Together
// they pin the comparison as strictly greater-than.
//
// REVERT ARM: flip `len(body) <= parkPayloadCeilingBytes` to `<` in
// checkParkPayloadCeiling and TestParkPayloadAtCeilingIsAccepted reds; flip it
// to `<= parkPayloadCeilingBytes+1` and THIS one reds.
func TestParkPayloadOneByteOverCeilingIsRefused(t *testing.T) {
	const probe = 1024
	overhead := parkAssembledSize(t, probe) - probe
	raw := parkPayloadCeilingBytes - overhead + 1

	_, _, _, err := buildBody(parkCmd(),
		map[string][]string{"file": {writeJSONFile(t, parkBodyOfSize(t, raw))}},
		map[string]string{"summary": parkProbeSummary})
	if err == nil {
		t.Fatalf("park assembling to %d bytes (one over the ceiling) was accepted", parkPayloadCeilingBytes+1)
	}
	if !strings.Contains(err.Error(), fmt.Sprintf("is %d bytes", parkPayloadCeilingBytes+1)) {
		t.Errorf("refusal %q does not name the one-byte overshoot", err)
	}
}

// TestOversizedBodyOnAnotherNounIsUnaffected is the CONTROL: the ceiling is
// scoped to `park`, so an equally oversized body on any other write is still
// assembled and sent. Without it, a passing refusal arm could equally well be
// reporting a blanket body limit across every manifest verb — a change this row
// does not carry.
func TestOversizedBodyOnAnotherNounIsUnaffected(t *testing.T) {
	raw := parkPayloadCeilingBytes + 1
	path := writeJSONFile(t, parkBodyOfSize(t, raw))

	notPark := parkCmd()
	notPark.ID, notPark.Noun = "doc.create", "doc"

	body, _, _, err := buildBody(notPark,
		map[string][]string{"file": {path}},
		map[string]string{"summary": parkProbeSummary})
	if err != nil {
		t.Fatalf("a %d-byte body on noun %q was refused: %v — the ceiling leaked past `park`", raw, notPark.Noun, err)
	}
	if len(body) <= parkPayloadCeilingBytes {
		t.Errorf("control body = %d bytes, want more than the %d-byte ceiling (it must actually be oversized)", len(body), parkPayloadCeilingBytes)
	}
}

// TestParkWithoutSummaryIsRefused pins the SECOND ratified constraint: a park
// with no summary never reaches the server. No park-specific code backs this —
// bindArgs already refuses a missing required positional — and that is the
// point: the plugin gets mandatory summaries from the CLI for free the moment
// its capabilities entry declares `arg("summary", true, …)`, and this test is
// the tripwire that fires if that enforcement is ever relaxed.
//
// REVERT ARM: drop the `else if arg.Required` branch in bindArgs and this reds
// with a nil error — the park ships with no summary at all.
func TestParkWithoutSummaryIsRefused(t *testing.T) {
	for _, tc := range []struct {
		name string
		pos  []string
	}{
		{"absent", nil},
		{"empty string", []string{""}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := bindArgs(parkCmd(), tc.pos)
			if err == nil {
				t.Fatalf("park with a %s summary was accepted; want a refusal", tc.name)
			}
			if !strings.Contains(err.Error(), "summary") {
				t.Errorf("refusal %q does not name the missing <summary>", err)
			}
		})
	}
}
