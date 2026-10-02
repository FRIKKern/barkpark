package cli

// cloud_status_suspended_at_test.go is the READER half of
// task-85c531c2adbf0dff. The decode half lives in
// internal/cloudclient/barkpark_suspended_at_test.go; this file proves the rest
// of the chain — that `bp cloud status` actually SAYS the day, and says the
// absence of one out loud instead of inventing a date.
//
// EVERY FIXTURE STARTS AS THE PRODUCER'S BYTES, decoded through
// `cloudclient.Barkpark` rather than hand-built as a Go struct, because the
// defect this slice closes was never in the render. The key was emitted by
// `barkpark_json/6` from cch-w54-bl onward, the struct declared no tag for it,
// `json.Unmarshal` dropped it, and a hand-built struct literal would have
// papered straight over that. Revert `json:"suspended_at"` to `json:"-"` and
// these fixtures go nil and the arms below red.
//
// WHY THE DASH IS ASSERTED AND NOT JUST THE DAY: the console shipped the
// opposite and it was the whole reason cch-w54-bl exists.
// `suspendedCardBannerHtml` had no suspension day, so it fell through to a
// helper computed off `sub.current_period_end` — the NEXT renewal — and painted
// a FUTURE date as a past-tense suspension day. A field with no reader is
// invisible; one whose absence is papered over by a wrong value is a
// silent-failure defect. So an unmeasured stamp must render as something that
// cannot be mistaken for a calendar fact.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// suspendedWireRow decodes one fleet-payload row the way `bp cloud status` does
// — through the real wire type, off the producer's own spelling — and ranks it.
// Host is set and nothing is in-flight or failed, so the decision-15 ladder puts
// every fixture here on the `suspended` rung, which is the arm under test.
func suspendedWireRow(t *testing.T, body string) rankedBarkpark {
	t.Helper()
	var b cloudclient.Barkpark
	if err := json.Unmarshal([]byte(body), &b); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	ranked := rankBarkparks([]cloudclient.Barkpark{b})
	if len(ranked) != 1 {
		t.Fatalf("rankBarkparks returned %d rows, want 1", len(ranked))
	}
	if ranked[0].Status != "suspended" {
		t.Fatalf("PRECONDITION FAILED: fixture ranked %q, not `suspended` — this "+
			"test's assertions are about the suspended arm of attentionDetail and "+
			"measure nothing on any other rung: %s", ranked[0].Status, body)
	}
	return ranked[0]
}

const suspendedStampedWire = `{"id":"bp-susp","name":"acme","slug":"acme",` +
	`"host":"1.2.3.4","health_status":"ok","agent_status":"ok",` +
	`"suspended":true,"suspended_reason":"billing: card declined",` +
	`"suspended_at":"2026-09-01T12:34:56.000000Z"}`

// TestCloudStatusSuspendedDetailCarriesTheDay is the RED-WHEN-REVERTED arm.
// Drop the `json:"suspended_at"` tag from cloudclient.Barkpark, or take the
// "since" clause back out of suspendedDetail, and this fails: the DETAIL cell
// goes back to naming the cause with no day behind it.
func TestCloudStatusSuspendedDetailCarriesTheDay(t *testing.T) {
	r := suspendedWireRow(t, suspendedStampedWire)

	if !strings.Contains(r.Detail, "since 2026-09-01") {
		t.Fatalf("detail = %q, want a `since 2026-09-01` clause — the control "+
			"plane sent suspended_at and `bp cloud status` must say SINCE WHEN, "+
			"which is the gap task-85c531c2adbf0dff closes", r.Detail)
	}
	// The DAY, not the instant: the operator question is "since when", to the
	// day, and a microsecond stamp in a table cell is noise.
	if strings.Contains(r.Detail, "12:34:56") {
		t.Fatalf("detail = %q — render the DAY, not the raw utc_datetime_usec", r.Detail)
	}
	// The reason it replaces must still be there. A "since" clause that ATE the
	// cause would be a regression dressed as a fix.
	if !strings.Contains(r.Detail, "billing: card declined") {
		t.Fatalf("detail = %q lost the suspension reason", r.Detail)
	}

	// And the same stamp reaches `-o json`, verbatim rather than shortened: a
	// script wants the instant the plane recorded, the table wants the day.
	row := rankedBarkparkRow(r)
	got, ok := row["suspended_at"]
	if !ok {
		t.Fatalf("`bp cloud status -o json` carried no suspended_at key for a "+
			"stamped suspension: %+v", row)
	}
	if got != "2026-09-01T12:34:56.000000Z" {
		t.Fatalf("suspended_at = %v, want the plane's stamp verbatim", got)
	}
}

// TestCloudStatusSuspendedWithoutStampSaysSoOutLoud is the QUIET arm: an absent
// stamp must render as an explicit em dash and must emit NO JSON key. It passes
// on nothing that existed before this slice — before it, there was no clause and
// no key at all — so it is here to pin the SHAPE of the absence, which is the
// half the console got wrong.
//
// Three fixtures, because the plane can leave the key in three states that all
// mean the same thing to a reader: an explicit null, a pre-cch-w54-bl row that
// carries no such key, and an empty string the plane actually sent.
//
// NOT VACUOUS. Each subtest asserts a NEIGHBOURING key (`suspended`) arrived on
// the same envelope and the fixture actually ranked `suspended`, so a mutation
// that broke decoding, ranking, or the row builder outright would red here
// rather than sliding through as a satisfying "key absent".
func TestCloudStatusSuspendedWithoutStampSaysSoOutLoud(t *testing.T) {
	cases := map[string]string{
		"explicit null — the plane has no stamp for this box": `{"id":"bp-null",` +
			`"name":"acme","host":"1.2.3.4","suspended":true,` +
			`"suspended_reason":"billing: card declined","suspended_at":null}`,
		"a pre-cch-w54-bl plane that carries no such key": `{"id":"bp-old",` +
			`"name":"acme","host":"1.2.3.4","suspended":true,` +
			`"suspended_reason":"billing: card declined"}`,
		"an empty string is no day to print": `{"id":"bp-empty",` +
			`"name":"acme","host":"1.2.3.4","suspended":true,` +
			`"suspended_reason":"billing: card declined","suspended_at":""}`,
	}

	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			r := suspendedWireRow(t, body)

			if !strings.Contains(r.Detail, "since —") {
				t.Fatalf("detail = %q, want an explicit `since —` — an unmeasured "+
					"suspension day must look like nothing else on the line. The "+
					"console's own bug here was substituting the next RENEWAL day "+
					"for a missing stamp and painting a FUTURE date as a past-tense "+
					"suspension", r.Detail)
			}
			// The two shapes a missing stamp must NEVER take.
			if strings.Contains(r.Detail, "0001-01-01") || strings.Contains(r.Detail, "1970-01-01") {
				t.Fatalf("detail = %q rendered a ZERO-VALUE date for a stamp the "+
					"plane never sent — a lie with a calendar behind it", r.Detail)
			}

			row := rankedBarkparkRow(r)
			if got, ok := row["suspended_at"]; ok {
				t.Fatalf("a row with no suspension stamp must emit NO suspended_at "+
					"key, got %v — %q and \"the plane sent no day\" are different "+
					"sentences: %+v", got, got, row)
			}
			// THE CONTROL, per subtest. An absence assertion proves nothing unless
			// the row it read was actually populated: a broken decode, a broken
			// ranker, or a row builder that lost its literal would all produce a
			// clean "key absent" and a green test that measured nothing. The
			// fixture sets `suspended: true`, so assert THAT arrived.
			if got := row["suspended"]; got != true {
				t.Fatalf("CONTROL FAILED: the row this test reads its absence out of "+
					"is not carrying the keys the fixture sent (suspended = %v), so "+
					"the \"key absent\" verdict above measured nothing: %+v", got, row)
			}
		})
	}
}

// TestCloudStatusLiveBoxAcquiresNoSuspensionStamp is the other direction: the
// overwhelming majority of the fleet is NOT suspended, and none of this may
// leak onto those rows. `unsuspend_barkpark/1` and the bulk resume clear
// suspended/suspended_reason/suspended_at together, so a resumed box carries no
// stale stamp — and even one that somehow did must not have it rendered, because
// the DETAIL cell's "since" clause is a sentence about a CURRENT suspension.
func TestCloudStatusLiveBoxAcquiresNoSuspensionStamp(t *testing.T) {
	var b cloudclient.Barkpark
	if err := json.Unmarshal([]byte(`{"id":"bp-live","name":"acme",`+
		`"host":"1.2.3.4","health_status":"ok","agent_status":"ok",`+
		`"suspended":false,"suspended_reason":null,`+
		`"suspended_at":"2026-09-01T12:34:56.000000Z"}`), &b); err != nil {
		t.Fatalf("decode: %v", err)
	}
	r := rankBarkparks([]cloudclient.Barkpark{b})[0]
	if r.Status == "suspended" {
		t.Fatalf("PRECONDITION FAILED: a box with suspended=false ranked %q", r.Status)
	}
	if strings.Contains(r.Detail, "since ") {
		t.Fatalf("detail = %q — a live box must carry no suspension clause even "+
			"when a stale stamp rides its row", r.Detail)
	}

	// THE CONTROL. The stamp DID decode onto this row, so the assertion above is
	// about the render suppressing it, not about the field being empty.
	if b.SuspendedAt == nil {
		t.Fatal("CONTROL FAILED: the fixture's suspended_at did not decode, so " +
			"the suppression assertion above measured nothing")
	}
}
