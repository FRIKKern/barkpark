package cli

// cloud_status_checked_at_test.go pins the `-o json` half of cch-w65-bl:
// `update_checked_at` is emitted only when the control plane actually recorded a
// check, the same tri-state idiom `autoupdate_enabled` and `commit_distance`
// follow three lines away in the same map literal.
//
// THE DEFECT, SHOWN NOT ASSERTED. On the pre-fix tree the key was in the
// always-present block as `r.BP.UpdateCheckedAt` (a plain string), so these three
// wire rows —
//
//	{"update_checked_at":"2026-09-15T09:17:05Z"}   a real check
//	{"update_checked_at":null}                     cch-w65-s2's honest "no check made"
//	{}                                             a control plane too old to say
//
// — rendered as a present key carrying "2026-09-15T09:17:05Z", "" and "". The
// last two were byte-identical, and neither could be told from a field a script
// was about to hand to time.Parse.

import (
	"encoding/json"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

func checkedAtWireRow(fragment string) cloudclient.Barkpark {
	base := `{"id":"i1","name":"n","slug":"n","host":"h","health_status":"unknown","agent_status":"offline","update_state":"unknown"`
	body := base + `}`
	if fragment != "" {
		body = base + `,"update_checked_at":` + fragment + `}`
	}
	var b cloudclient.Barkpark
	if err := json.Unmarshal([]byte(body), &b); err != nil {
		panic(err)
	}
	return b
}

func checkedAtProjection(t *testing.T, fragment string) (any, bool) {
	t.Helper()
	ranked := rankBarkparks([]cloudclient.Barkpark{checkedAtWireRow(fragment)})
	if len(ranked) != 1 {
		t.Fatalf("rankBarkparks returned %d rows, want 1", len(ranked))
	}
	v, present := rankedBarkparkRow(ranked[0])["update_checked_at"]
	return v, present
}

// TestUpdateCheckedAtEmittedOnlyWhenMeasured is the arm that FAILS if the emit
// site goes back to the always-present block: with `"update_checked_at":
// r.BP.UpdateCheckedAt` restored, the null and older-CP subtests report a present
// key and this reds naming the conflation.
func TestUpdateCheckedAtEmittedOnlyWhenMeasured(t *testing.T) {
	t.Run("a measured check is emitted verbatim", func(t *testing.T) {
		v, present := checkedAtProjection(t, `"2026-09-15T09:17:05.499647Z"`)
		if !present {
			t.Fatal("update_checked_at must be present when the plane recorded a check")
		}
		if v != "2026-09-15T09:17:05.499647Z" {
			t.Fatalf("update_checked_at = %v, want the plane's timestamp", v)
		}
	})

	t.Run("an explicit null omits the key (cch-w65-s2: no check was made)", func(t *testing.T) {
		v, present := checkedAtProjection(t, `null`)
		if present {
			t.Fatalf("update_checked_at = %#v, want the key ABSENT — the plane returned before a "+
				"request was built on one of the three unclocked rungs, so there is no check time; "+
				"emitting a value here forces a consumer to decide whether it is a timestamp", v)
		}
	})

	t.Run("an older control plane omits the key", func(t *testing.T) {
		v, present := checkedAtProjection(t, ``)
		if present {
			t.Fatalf("update_checked_at = %#v, want the key ABSENT for a plane that never emitted it", v)
		}
	})
}

// TestUpdateCheckedAtIsNotAParseableEmptyString is the discriminator between the
// pre-fix and post-fix trees stated as one assertion: a MEASURED row and an
// UNMEASURED row must not project the same shape. On the pre-fix tree both keys
// were present and the unmeasured one carried "", so a consumer that branched on
// presence — the branch the neighbouring tri-states exist to force — took the
// same path for both.
func TestUpdateCheckedAtIsNotAParseableEmptyString(t *testing.T) {
	_, measured := checkedAtProjection(t, `"2026-09-15T09:17:05.499647Z"`)
	nullValue, unclocked := checkedAtProjection(t, `null`)
	_, older := checkedAtProjection(t, ``)

	if measured == unclocked {
		t.Fatalf("a measured check and a never-checked box project the same key presence (%v) — "+
			"the unclocked row carries %#v, which a script reads as a field it can parse", measured, nullValue)
	}
	if unclocked != older {
		t.Fatalf("the two unmeasured causes must project alike (both absent): null=%v older=%v", unclocked, older)
	}
	// And the distinction the projection deliberately drops is still on the
	// struct, so nothing had to be re-fetched to get it back.
	if checkedAtWireRow(`null`).UpdateCheckedAtMissing == checkedAtWireRow(``).UpdateCheckedAtMissing {
		t.Fatal("UpdateCheckedAtMissing must still separate an explicit null from an omitted key")
	}
}
