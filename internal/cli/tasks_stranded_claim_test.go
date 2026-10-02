package cli

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// The fixtures below are the SHAPES measured on production on 2026-09-15 while
// discharging task-d790755a7eeac639, not invented ones. `stagedOpenEnvelope` is
// the `bp task stage <id> open --yes -o json` 2xx for a row claimed 40s earlier;
// `releasedEnvelope` is the same row's shape after `bp task release`, which is
// the one control that separates "a claim object withholds the row" (it does
// not) from "a live lease withholds it" (it does).

const strandedNow = "2026-09-15T10:15:00Z"

func at(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("bad fixture time %q: %v", s, err)
	}
	return v
}

func stagedOpenEnvelope(lifecycle string, claimFields string) []byte {
	return []byte(fmt.Sprintf(`{"ok":true,"doc":{"doc_id":"task-158eb79443171289","lifecycle_status":%q,"claim":{%s}}}`,
		lifecycle, claimFields))
}

// The live, stranded claim: worker set, no close stamp, lease still ahead of now.
const liveClaimFields = `"worker":"cli-r19-w14-probe","epoch":1,"ts_iso":"2026-09-15T10:14:16.570062Z","lease_expires_at":"2026-09-15T10:59:16Z","lease_seconds":2700`

// The released claim, byte-for-byte the measured shape: the claim OBJECT
// survives, the epoch survives and BUMPS, released_at/released_by appear, and
// `worker` is present-and-null. This row was in `bp task ready` in the very next
// read, 62s into its lease.
const releasedClaimFields = `"worker":null,"epoch":2,"ts_iso":"2026-09-15T10:15:56.954823Z","released_at":"2026-09-15T10:16:52.187913Z","released_by":"cli-r19-w14-probe"`

func TestStrandedClaimFires(t *testing.T) {
	now := at(t, strandedNow)
	s, ok := strandedClaimFrom(stagedOpenEnvelope("open", liveClaimFields), now)
	if !ok {
		t.Fatal("the measured staged-open live-lease envelope produced no notice — this is the state the whole file exists to name")
	}
	if s.DocID != "task-158eb79443171289" || s.Worker != "cli-r19-w14-probe" || s.Epoch != 1 {
		t.Fatalf("decoded the wrong identity: %+v", s)
	}
	lines := strandedClaimLines(s, now)
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %d: %v", len(lines), lines)
	}
	// 10:15:00Z -> 10:59:16Z is 2656s. A bound the caller cannot act on is the
	// defect; assert the NUMBER, not that a number is present.
	if !strings.Contains(lines[1], "window: 2656s") {
		t.Fatalf("bound line does not carry the measured seconds: %q", lines[1])
	}
	if !strings.Contains(lines[1], "2026-09-15T10:59:16Z") {
		t.Fatalf("bound line does not carry the server's own expiry: %q", lines[1])
	}
	// The remedy must be runnable as printed: id, worker, epoch, in order.
	if !strings.Contains(lines[2], "bp task release task-158eb79443171289 cli-r19-w14-probe 1") {
		t.Fatalf("remedy line is not a runnable command: %q", lines[2])
	}
	for _, want := range []string{"bp task pulse", "bp task ready"} {
		if !strings.Contains(lines[0], want) {
			t.Fatalf("headline names only one door, missing %q: %q", want, lines[0])
		}
	}
}

func TestStrandedClaimSilentCases(t *testing.T) {
	now := at(t, strandedNow)
	cases := []struct {
		name string
		body []byte
		why  string
	}{
		{
			name: "released row keeps the claim object and is ALREADY ready",
			body: stagedOpenEnvelope("open", releasedClaimFields),
			why:  "the discriminator is claim.worker's VALUE; keying on the claim object, its epoch or the `worker` KEY makes every released row a false positive",
		},
		{
			// SYNTHETIC, and labelled so. Today's server cannot emit it —
			// `with_lease_horizon/1` stamps an expiry only on a binary worker —
			// so this is the one fixture in the table that is not a measured
			// shape. It exists to give the worker guard a test that can fail,
			// and it is what reds if that guard ever weakens into a
			// claim-presence check.
			name: "released row with a stale horizon (synthetic forward guard)",
			body: stagedOpenEnvelope("open", `"worker":null,"epoch":2,"released_at":"2026-09-15T10:16:52Z","released_by":"cli-r19-w14-probe","lease_expires_at":"2026-09-15T10:59:16Z"`),
			why:  "a row whose claim.worker is null is claimable NOW — the server's ready gate admits it on a blank-worker test alone, whatever the horizon says",
		},
		{
			name: "in_progress is the normal held shape",
			body: stagedOpenEnvelope("in_progress", liveClaimFields),
			why:  "pulse renews an in_progress row and the queue is right to withhold it — there is no stranding to report",
		},
		{
			name: "closed claim",
			body: stagedOpenEnvelope("open", liveClaimFields+`,"closed_at":"2026-09-15T10:14:40Z","closed_by":"cli-r19-w14-probe"`),
			why:  "close leaves claim.worker behind on purpose and the ready gate admits such a row already",
		},
		{
			name: "lapsed lease",
			body: stagedOpenEnvelope("open", `"worker":"w","epoch":1,"lease_expires_at":"2026-09-15T10:14:59Z"`),
			why:  "a lapsed lease is already back in the queue; there is no window left to bound",
		},
		{
			name: "server too old to send lease_expires_at",
			body: stagedOpenEnvelope("open", `"worker":"w","epoch":1,"ts_iso":"2026-09-15T10:14:16Z"`),
			why:  "an expiry derived from a client-guessed TTL is the same defect wearing a fix's clothes — print nothing instead",
		},
		{
			name: "unclaimed row",
			body: []byte(`{"ok":true,"doc":{"doc_id":"task-x","lifecycle_status":"open","claim":null}}`),
			why:  "no claim, no stranding",
		},
		{
			name: "no doc at all",
			body: []byte(`{"ok":true,"docs":[{"doc_id":"task-x","lifecycle_status":"open"}]}`),
			why:  "list envelopes must not grow a per-row notice",
		},
		{
			name: "not json",
			body: []byte(`<html>`),
			why:  "a decode failure must be silent, never a notice about a row it could not read",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if s, ok := strandedClaimFrom(tc.body, now); ok {
				t.Fatalf("false positive %+v — %s", s, tc.why)
			}
		})
	}
}

// The {"result": …} wrapper is the second envelope shape the tasks endpoints can
// arrive in; leaseFromEnvelope walks both and so must this.
func TestStrandedClaimWalksResultWrapper(t *testing.T) {
	now := at(t, strandedNow)
	inner := string(stagedOpenEnvelope("open", liveClaimFields))
	if _, ok := strandedClaimFrom([]byte(`{"result":`+inner+`}`), now); !ok {
		t.Fatal("a stranded row inside a {\"result\": …} wrapper produced no notice")
	}
}

// `blocked` is a claimable status server-side (Validation.claimable_statuses/0),
// so a blocked row with a live claim is stranded on exactly the same two doors.
func TestStrandedClaimCoversBlocked(t *testing.T) {
	now := at(t, strandedNow)
	if _, ok := strandedClaimFrom(stagedOpenEnvelope("blocked", liveClaimFields), now); !ok {
		t.Fatal("a blocked row with a live claim was not reported; blocked is claimable and the ready queue carries it")
	}
}
