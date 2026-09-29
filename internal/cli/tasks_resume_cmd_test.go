package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// fakeResumeIO hands loadResumeRecord exactly the bytes a test names, or the
// error it names. THE INJECTION IS THE POINT: the failures rehydration exists
// to catch are reads that SUCCEED and return bytes nobody should believe —
// another row's manifest, a future schema, a file edited since the claim. os
// cannot be asked to produce those on demand, so a test built on a real temp
// dir can only ever exercise the happy path, and would stay green with the
// verification arms deleted. That is not a hypothesis: it is what PR #19114
// measured on the WRITE side of this same file pair.
func fakeResumeIO(b []byte, err error) resumeIO {
	return resumeIO{readFile: func(string) ([]byte, error) {
		if err != nil {
			return nil, err
		}
		return b, nil
	}}
}

// honestManifestBytes is the CONTROL fixture: a manifest produced by the
// writer's own builder and serialized the way writePrimingManifestIO serializes
// it. If rehydration rejects this, the reader is broken in the other direction.
func honestManifestBytes(t *testing.T, docID, worker string) ([]byte, PrimingManifest) {
	t.Helper()
	env, _ := fullyMeasuredEnv(t)
	m := buildPrimingManifest(env, docID, worker)
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return append(b, '\n'), m
}

// TestResumeRehydrationRedsWhenRemoved is THE ARM. Every case below is a read
// that SUCCEEDS and returns believable-looking bytes; each is caught only by one
// of loadResumeRecord's verification steps (schema / doc id / digest) or by its
// not-exist split. Delete any of those steps and the matching case reports
// LOADED and this test reds.
//
// MEASURED, not asserted: with the digest check removed, the "edited since the
// claim" case returns LOADED; with the doc-id check removed, "another row's
// manifest" returns LOADED; with the schema check removed, "a future schema"
// returns LOADED. Run output is in the PR body.
func TestResumeRehydrationRedsWhenRemoved(t *testing.T) {
	honest, hm := honestManifestBytes(t, "task-mine", "w-dead")

	// A manifest EDITED since the claim: the worker field is rewritten and the
	// digest left alone, exactly what a hand-edit or a partial overwrite looks
	// like. It parses, it names the right row, it carries the right schema.
	edited := hm
	edited.Worker = "w-IMPOSTOR"
	editedBytes, err := json.Marshal(edited)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}

	// Another row's manifest, internally perfect.
	otherEnv, _ := fullyMeasuredEnv(t)
	other := buildPrimingManifest(otherEnv, "task-SOMEONE-ELSE", "w9")
	otherBytes, err := json.Marshal(other)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}

	// A manifest from a FUTURE build. Self-consistent, correctly digested,
	// right row — and this build does not know what its fields mean.
	future := hm
	future.Schema = primingSchema + 1
	future.Digest = primingDigest(future)
	futureBytes, err := json.Marshal(future)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}

	cases := []struct {
		name      string
		bytes     []byte
		err       error
		wantState resumeState
		wantFault string
	}{
		{
			name:      "CONTROL: an honest manifest rehydrates",
			bytes:     honest,
			wantState: resumeLoaded,
		},
		{
			name:      "edited since the claim — digest no longer describes the bytes",
			bytes:     editedBytes,
			wantState: resumeUnreadable,
			wantFault: "hashes to",
		},
		{
			name:      "another row's manifest sitting at this row's path",
			bytes:     otherBytes,
			wantState: resumeUnreadable,
			wantFault: "another row's loadout",
		},
		{
			name:      "a schema this build does not understand",
			bytes:     futureBytes,
			wantState: resumeUnreadable,
			wantFault: "refusing to interpret",
		},
		{
			name:      "bytes that are not JSON at all",
			bytes:     []byte("{\"schema\":1,\"doc_"),
			wantState: resumeUnreadable,
			wantFault: "does not parse",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := loadResumeRecord(fakeResumeIO(tc.bytes, tc.err), "/pd", "task-mine")
			if rec.State != tc.wantState {
				t.Fatalf("state = %v (fault %q), want %v", rec.State, rec.Fault, tc.wantState)
			}
			if tc.wantFault != "" && !strings.Contains(rec.Fault, tc.wantFault) {
				t.Fatalf("fault = %q, want it to contain %q", rec.Fault, tc.wantFault)
			}
			if tc.wantState == resumeLoaded {
				if rec.Fault != "" {
					t.Fatalf("the control carries a fault: %q", rec.Fault)
				}
				if rec.Manifest == nil || rec.Manifest.Worker != "w-dead" {
					t.Fatalf("control did not rehydrate the loadout: %+v", rec.Manifest)
				}
			}
			// An UNREADABLE record must never hand a caller a manifest to
			// render: that is precisely how a corrupt record gets believed.
			if tc.wantState == resumeUnreadable && rec.Manifest != nil {
				t.Fatalf("an unreadable record handed back a manifest to render: %+v", rec.Manifest)
			}
		})
	}
}

// TestResumeDistinguishesThreeAbsences drives the three nothings apart. They
// are three different facts about a predecessor and the whole value of the verb
// is that it never collapses them.
func TestResumeDistinguishesThreeAbsences(t *testing.T) {
	// SILENT: parses, re-digests clean, measures nothing. Built the way an
	// unprimed claim actually produces one — no env, no git.
	silentEnv := fakePrimingEnv(nil, nil, nil, nil)
	silent := buildPrimingManifest(silentEnv, "task-mine", "w-dead")
	silentBytes, err := json.Marshal(silent)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if silent.Primed != nil {
		t.Fatalf("precondition: an unmeasured manifest must roll up to nil, got %v", *silent.Primed)
	}

	cases := []struct {
		name  string
		io    resumeIO
		want  resumeState
		fault string
	}{
		{
			// NO RECORD — nothing was ever written for this row.
			name: "no manifest names this row",
			io:   fakeResumeIO(nil, fmt.Errorf("open /pd/x: %w", fs.ErrNotExist)),
			want: resumeNoRecord,
		},
		{
			// UNREADABLE — a file is there and the filesystem answered badly.
			// The distinction from the case above is the WHOLE contract: this
			// one is a measured failure.
			name:  "a manifest exists and cannot be read",
			io:    fakeResumeIO(nil, errors.New("permission denied")),
			want:  resumeUnreadable,
			fault: "exists and could not be read",
		},
		{
			name: "a manifest loaded and measures nothing",
			io:   fakeResumeIO(silentBytes, nil),
			want: resumeSilent,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := loadResumeRecord(tc.io, "/pd", "task-mine")
			if rec.State != tc.want {
				t.Fatalf("state = %v (fault %q), want %v", rec.State, rec.Fault, tc.want)
			}
			if tc.fault != "" && !strings.Contains(rec.Fault, tc.fault) {
				t.Fatalf("fault = %q, want it to contain %q", rec.Fault, tc.fault)
			}
		})
	}

	// And the three must not merely differ internally — they must READ
	// differently to the successor, who only ever sees the brief.
	seen := map[string]bool{}
	for _, tc := range cases {
		out, buf := resumeTestWriter()
		renderCrashBrief(out, "task-mine", "w-new", loadResumeRecord(tc.io, "/pd", "task-mine"), resumeLive{Read: true})
		body := buf.String()
		if seen[body] {
			t.Fatalf("%s renders identically to an earlier absence — the brief collapses them", tc.name)
		}
		seen[body] = true
	}
}

// TestSilentIsNotTriggeredByAPartialLoadout guards the conjunction: ONE
// measured field is a thin answer, not silence. Flipping manifestIsSilent to a
// disjunction reds here.
func TestSilentIsNotTriggeredByAPartialLoadout(t *testing.T) {
	env := fakePrimingEnv(map[string]string{"BARKPARK_AGENT_MODEL": "opus-5"}, nil, nil, nil)
	m := buildPrimingManifest(env, "task-mine", "w-dead")
	if manifestIsSilent(m) {
		t.Fatalf("a manifest carrying model=opus-5 reported as SILENT: %+v", m)
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if rec := loadResumeRecord(fakeResumeIO(b, nil), "/pd", "task-mine"); rec.State != resumeLoaded {
		t.Fatalf("state = %v, want LOADED", rec.State)
	}
}

// TestBriefNeverRendersAnUnreadStoreAsNoHolder is the live half's three-state
// arm. A store that did not answer must not be rendered as a row nobody holds.
func TestBriefNeverRendersAnUnreadStoreAsNoHolder(t *testing.T) {
	rec := resumeRecord{Path: "/pd/x", State: resumeNoRecord}

	out, buf := resumeTestWriter()
	renderCrashBrief(out, "task-mine", "w-new", rec, resumeLive{Fault: "the server is unreachable"})
	unread := buf.String()
	if !strings.Contains(unread, "UNMEASURED — the store could not be read") {
		t.Fatalf("an unread store did not render as UNMEASURED:\n%s", unread)
	}
	if strings.Contains(unread, "NO claim object") {
		t.Fatalf("an unread store rendered as a row with no claim:\n%s", unread)
	}

	out2, buf2 := resumeTestWriter()
	renderCrashBrief(out2, "task-mine", "w-new", rec, resumeLive{Read: true, Lifecycle: "open"})
	vacant := buf2.String()
	if !strings.Contains(vacant, "NO claim object") {
		t.Fatalf("a read store with no claim did not say so:\n%s", vacant)
	}
	if unread == vacant {
		t.Fatalf("an unread store and an unclaimed row render identically")
	}

	out3, buf3 := resumeTestWriter()
	renderCrashBrief(out3, "task-mine", "w-new", rec, resumeLive{
		Read:      true,
		Lifecycle: "in_progress",
		Claim:     apiclient.ClaimInfo{Present: true, Worker: "w-dead", Epoch: 4},
	})
	held := buf3.String()
	for _, want := range []string{"worker=w-dead", "epoch=4", "You are NOT the holder"} {
		if !strings.Contains(held, want) {
			t.Fatalf("brief is missing %q:\n%s", want, held)
		}
	}
}

// TestCrashBriefAlwaysCarriesTheReviewInstruction — the row's whole purpose is
// that a successor REVIEWS before continuing, in every state including the ones
// where there is nothing to review.
func TestCrashBriefAlwaysCarriesTheReviewInstruction(t *testing.T) {
	honest, _ := honestManifestBytes(t, "task-mine", "w-dead")
	for _, io := range []resumeIO{
		fakeResumeIO(nil, fmt.Errorf("x: %w", fs.ErrNotExist)),
		fakeResumeIO(nil, errors.New("permission denied")),
		fakeResumeIO(honest, nil),
	} {
		out, buf := resumeTestWriter()
		renderCrashBrief(out, "task-mine", "w-new", loadResumeRecord(io, "/pd", "task-mine"), resumeLive{Read: true})
		body := buf.String()
		for _, want := range []string{"REVIEW, DO NOT RESUME BLIND", "bp task claim task-mine w-new"} {
			if !strings.Contains(body, want) {
				t.Fatalf("brief is missing %q:\n%s", want, body)
			}
		}
	}
}

// TestLoadedBriefKeepsUnmeasuredDistinctFromEmpty — a nil field must never
// render as a blank, on the terminal any more than on the wire.
func TestLoadedBriefKeepsUnmeasuredDistinctFromEmpty(t *testing.T) {
	env := fakePrimingEnv(
		map[string]string{"BARKPARK_AGENT_MODEL": "opus-5", "BARKPARK_PRIMERS": "/p/gone.md"},
		nil, // /p/gone.md is LISTED and unreadable — a measured priming failure
		map[string]string{"rev-parse --show-toplevel": "/work/wt\n"},
		nil,
	)
	m := buildPrimingManifest(env, "task-mine", "w-dead")
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	out, buf := resumeTestWriter()
	renderCrashBrief(out, "task-mine", "w-new", loadResumeRecord(fakeResumeIO(b, nil), "/pd", "task-mine"), resumeLive{Read: true})
	body := buf.String()
	for _, want := range []string{
		"effort=UNMEASURED", // env var unset
		"head=UNMEASURED",   // git did not answer
		"dirty_tree=UNMEASURED",
		"primed=UNMEASURED", // the nil rule dominates
		"NOT READABLE at claim time",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("brief is missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "effort= ") || strings.Contains(body, "head= ") {
		t.Fatalf("an unmeasured field rendered as a blank:\n%s", body)
	}
}

// resumeTestWriter captures only stdout, which is where the brief goes.
func resumeTestWriter() (*writer, *bytes.Buffer) {
	out, stdout, _ := newTestWriter()
	return out, stdout
}
