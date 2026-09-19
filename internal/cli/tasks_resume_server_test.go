package cli

import (
	"encoding/json"
	"io/fs"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE SERVER ARM (task-7ac1b27605ef6060, criterion 3).
//
// Until this arm existed, `bp task resume` could only read the local
// BARKPARK_PRIMING_DIR file — which is exactly as durable as the machine the
// crashed agent ran on, and therefore useless in the one situation the verb
// exists for: a lapsed lease picked up from somewhere else. The ledger now
// carries the same manifest at content.claim.priming_start, and these tests are
// the arms that red if the reader stops consulting it, or consults it under a
// weaker standard of proof than it applies to the local file.

func resumeDocWithClaim(claim string) apiclient.Doc {
	var d apiclient.Doc
	if err := json.Unmarshal([]byte(`{"_id":"task-mine","_type":"task","claim":`+claim+`}`), &d); err != nil {
		panic(err)
	}
	return d
}

func resumeDocWithoutClaim() apiclient.Doc {
	var d apiclient.Doc
	if err := json.Unmarshal([]byte(`{"_id":"task-mine","_type":"task"}`), &d); err != nil {
		panic(err)
	}
	return d
}

func serverLive(primingStart []byte) resumeLive {
	return resumeLive{Read: true, Priming: json.RawMessage(primingStart)}
}

func absentIO() resumeIO {
	return resumeIO{readFile: func(string) ([]byte, error) { return nil, fs.ErrNotExist }}
}

// TestServerManifestIsPreferredOverTheLocalFile IS THE ARM. Every case has a
// believable LOCAL manifest sitting on disk, so a reader that ignores the
// ledger still produces a clean LOADED brief — and every case reds.
//
// MEASURED, not asserted: with the `if asked && srv.State != resumeNoRecord`
// branch deleted from pickResumeRecord, all three ledger cases fall through to
// the local file and this test reds while TestLocalFileStillAnswersWhenTheLedgerHasNothing
// (the control) stays quiet. Run output is in the PR body.
func TestServerManifestIsPreferredOverTheLocalFile(t *testing.T) {
	// The local file: honest, believable, and NOT what the brief must show
	// whenever the ledger holds a record of its own.
	localBytes, _ := honestManifestBytes(t, "task-mine", "w-LOCAL")
	localIO := fakeResumeIO(localBytes, nil)

	serverBytes, sm := honestManifestBytes(t, "task-mine", "w-SERVER")

	// A ledger manifest EDITED since the claim: digest left alone. It parses,
	// it names the right row, it carries the right schema — only the digest
	// arm catches it, and only if the server copy is judged at all.
	edited := sm
	edited.Worker = "w-IMPOSTOR"
	editedBytes, err := json.Marshal(edited)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}

	otherEnv, _ := fullyMeasuredEnv(t)
	otherBytes, err := json.Marshal(buildPrimingManifest(otherEnv, "task-SOMEONE-ELSE", "w9"))
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}

	cases := []struct {
		name       string
		priming    []byte
		wantState  resumeState
		wantWorker string // on a LOADED record
		wantFault  string
	}{
		{
			name:       "the ledger copy is what the brief rebuilds",
			priming:    serverBytes,
			wantState:  resumeLoaded,
			wantWorker: "w-SERVER",
		},
		{
			// THE ONE THAT MATTERS MOST. A corrupt ledger record must NOT be
			// papered over by a believable local file: the successor has to
			// learn that the durable copy lies.
			name:      "a corrupt ledger copy beats a believable local file",
			priming:   editedBytes,
			wantState: resumeUnreadable,
			wantFault: "hashes to",
		},
		{
			name:      "another row's manifest stored on this row",
			priming:   otherBytes,
			wantState: resumeUnreadable,
			wantFault: "another row's loadout",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec, ok := pickResumeRecord(localIO, serverLive(tc.priming), "/pd", "task-mine")
			if !ok {
				t.Fatalf("pickResumeRecord refused with both sources available")
			}
			if rec.State != tc.wantState {
				t.Fatalf("state = %v (fault %q, source %q), want %v", rec.State, rec.Fault, rec.Source, tc.wantState)
			}
			if rec.Source != serverPrimingSource {
				t.Fatalf("source = %q, want the ledger — the local file was preferred over a ledger record", rec.Source)
			}
			if tc.wantFault != "" && !strings.Contains(rec.Fault, tc.wantFault) {
				t.Fatalf("fault = %q, want it to contain %q", rec.Fault, tc.wantFault)
			}
			if tc.wantState == resumeUnreadable && rec.Manifest != nil {
				t.Fatalf("an unreadable ledger record handed back a manifest to render: %+v", rec.Manifest)
			}
			if tc.wantWorker != "" {
				if rec.Manifest == nil || rec.Manifest.Worker != tc.wantWorker {
					t.Fatalf("rebuilt loadout = %+v, want worker %q", rec.Manifest, tc.wantWorker)
				}
			}
		})
	}
}

// TestLocalFileStillAnswersWhenTheLedgerHasNothing is the QUIET CONTROL for the
// arm above: the fallback must survive the addition of the server arm. A row
// claimed before the wire half existed carries no priming_start, and its local
// manifest is still the whole record.
func TestLocalFileStillAnswersWhenTheLedgerHasNothing(t *testing.T) {
	localBytes, _ := honestManifestBytes(t, "task-mine", "w-LOCAL")

	rec, ok := pickResumeRecord(fakeResumeIO(localBytes, nil), resumeLive{Read: true}, "/pd", "task-mine")
	if !ok {
		t.Fatalf("pickResumeRecord refused with a readable local file")
	}
	if rec.State != resumeLoaded || rec.Manifest == nil || rec.Manifest.Worker != "w-LOCAL" {
		t.Fatalf("local fallback did not answer: state=%v rec=%+v", rec.State, rec.Manifest)
	}
	if rec.Source == serverPrimingSource {
		t.Fatalf("source = %q, but the ledger held nothing", rec.Source)
	}
}

// TestResumeRefusesWhenNEITHERSourceCouldBeLookedAt keeps the fourth thing —
// "could not look" — out of the three-absence vocabulary. An unread store plus
// no priming dir is not NO RECORD about the predecessor; it is a shell that
// cannot look, and the verb must refuse rather than render a brief.
func TestResumeRefusesWhenNEITHERSourceCouldBeLookedAt(t *testing.T) {
	if _, ok := pickResumeRecord(absentIO(), resumeLive{Fault: "the server is unreachable"}, "", "task-mine"); ok {
		t.Fatalf("an unread store with no priming dir produced a record — it must refuse")
	}
	// An unread store with a priming dir is NOT a refusal: the local file is
	// still a place that can be looked at, and its answer is honest.
	if _, ok := pickResumeRecord(absentIO(), resumeLive{Fault: "unreachable"}, "/pd", "task-mine"); !ok {
		t.Fatalf("an unread store refused even though a local dir was configured")
	}
	// A READ store that holds no manifest is a measured NO RECORD, not a
	// refusal, even with no priming dir — the ledger was asked and answered.
	rec, ok := pickResumeRecord(absentIO(), resumeLive{Read: true}, "", "task-mine")
	if !ok {
		t.Fatalf("a read store with no manifest refused instead of reporting NO RECORD")
	}
	if rec.State != resumeNoRecord || rec.Source != serverPrimingSource {
		t.Fatalf("state=%v source=%q, want NO RECORD from the ledger", rec.State, rec.Source)
	}
}

// TestClaimPrimingStartNeverJudgesTheStoredValue keeps the extraction and the
// verification apart. Every absence shape yields nil (NO RECORD), and anything
// present comes back RAW — including bytes that cannot possibly be a manifest,
// because deciding that is believeManifest's job and collapsing a corrupt
// record into an absent one is the exact failure direction c1 names.
func TestClaimPrimingStartNeverJudgesTheStoredValue(t *testing.T) {
	absent := []string{
		`{"worker":"w1","epoch":2}`, // a claim with no priming_start
		`null`,                      // a null claim object
		`"not an object"`,           // a claim that does not decode
		`{"priming_start":null}`,    // an explicit null
	}
	for _, body := range absent {
		d := resumeDocWithClaim(body)
		if got := claimPrimingStart(d); got != nil {
			t.Fatalf("claim %s yielded %q, want nil (NO RECORD)", body, got)
		}
	}
	if got := claimPrimingStart(resumeDocWithClaim(`{"priming_start":{"schema":9}}`)); string(got) != `{"schema":9}` {
		t.Fatalf("a present manifest came back as %q — it must be raw and unjudged", got)
	}
	// A doc with no claim object at all.
	if got := claimPrimingStart(resumeDocWithoutClaim()); got != nil {
		t.Fatalf("a claimless row yielded %q, want nil", got)
	}
}
