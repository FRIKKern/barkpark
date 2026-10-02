package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Desk-TUI close-guard claim-liveness pins (task-6d7b68c7c0e7e8cc).
//
// closeTask's guard used to be apiclient.Doc.ClaimEpoch's bool. A RELEASED row
// KEEPS its epoch, so the guard passed on a row nobody held and the close
// POSTed that retained epoch — which the SERVER ACCEPTS, because close.ex's
// fence only compares the number and the number still matches. MEASURED on
// guerrilla, both arms: the same close on a deliberately wrong epoch was
// refused `fenced_off`, and on the retained epoch 2 it landed
// (lifecycle_status=done). The guard is the only thing standing between a
// released row and an accidental close.
//
// The claim objects below are VERBATIM server output, produced by claiming and
// then releasing a real row through `bp task claim` / `bp task release`.

const deskReleasedClaim = `{
  "epoch": 2,
  "released_at": "2026-09-15T08:49:36.925818Z",
  "released_by": "probe-r19w7",
  "ts_iso": "2026-09-15T08:49:23.603626Z",
  "work_digest": "10ed0509bd041c7f",
  "work_field_digests": {"title": "e43f51a1d2557b5b"},
  "worker": null
}`

const deskLiveClaim = `{
  "epoch": 1,
  "lease_expires_at": "2026-09-15T09:39:27.618048Z",
  "lease_seconds": 2700,
  "ts_iso": "2026-09-15T08:54:27.618048Z",
  "work_digest": "3748a7a4222d04cf",
  "work_field_digests": {"title": "08ca520b17fb61ae"},
  "worker": "probe-r19w7"
}`

func deskDocWithClaim(id, claimJSON string) *Doc {
	return &Doc{ID: id, Extra: map[string]json.RawMessage{"claim": json.RawMessage(claimJSON)}}
}

// closeProbe drives closeTask against a recording server. closeTask's SUCCESS
// path calls refreshDocViews, which dereferences the package-level TUI
// structure a headless test never builds — so the panic is recovered and
// reported separately. It happens strictly AFTER the close POST, so it never
// masks what we assert: `posted` is the whole question.
type closeProbe struct {
	posted   bool
	path     string
	body     string
	status   string
	statusIs bool
	panicked bool
}

func driveClose(t *testing.T, doc *Doc) closeProbe {
	t.Helper()
	var p closeProbe
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		p.posted, p.path, p.body = true, r.URL.Path, string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	m := model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"}), workerID: "probe-r19w7"}
	func() {
		defer func() {
			if r := recover(); r != nil {
				p.panicked = true
			}
		}()
		m.closeTask(doc)
	}()
	p.status, p.statusIs = m.status, m.statusErr
	return p
}

// PRECONDITION CONTROL: the released fixture must look claimed to everything
// EXCEPT the worker value, or this test pins nothing.
func TestDeskReleasedFixtureLooksClaimedExceptForTheWorkerValue(t *testing.T) {
	info := deskDocWithClaim("task-75feee3462657b3e", deskReleasedClaim).ClaimInfo()
	if !info.Present || info.Epoch != 2 || info.ReleasedAt == "" {
		t.Fatalf("released fixture must be Present with a RETAINED epoch and a released_at, got %+v", info)
	}
	if info.Worker != "" {
		t.Fatalf("a released row's worker decodes to empty, got %q", info.Worker)
	}
	if epoch, ok := deskDocWithClaim("x", deskReleasedClaim).ClaimEpoch(); !ok || epoch != 2 {
		t.Fatalf("ClaimEpoch must STILL return the retained epoch with ok=true — that is the trap this row documents, "+
			"and the epoch is load-bearing for the next claim; got epoch=%d ok=%v", epoch, ok)
	}
}

// THE DEFECT. Reverting closeTask's guard to `epoch, ok := doc.ClaimEpoch(); if !ok`
// REDS THIS TEST BY NAME on the released-row fixture, quoting the close POST it
// let through.
func TestCloseTaskRefusesAReleasedRowAndSendsNothing(t *testing.T) {
	p := driveClose(t, deskDocWithClaim("task-75feee3462657b3e", deskReleasedClaim))

	if p.posted {
		t.Errorf("MISCLASSIFIED RELEASED ROW — task-75feee3462657b3e was claimed then RELEASED through the real verbs "+
			"(claim is {worker: null, epoch: 2, released_at: 2026-09-15T08:49:36.925818Z}), yet the close guard passed it "+
			"and POSTed %s %s. The server ACCEPTS that retained epoch; this guard is the only thing that stops it",
			p.path, p.body)
	}
	if !p.statusIs {
		t.Errorf("a refused close must render as an error status, got statusErr=%v msg=%q", p.statusIs, p.status)
	}
	if !strings.Contains(p.status, "released at 2026-09-15T08:49:36.925818Z") {
		t.Errorf("the refusal must NAME the release — released and never-claimed used to be indistinguishable; got %q", p.status)
	}
	if !strings.Contains(p.status, "claim first (c)") {
		t.Errorf("the refusal must still say what to do; got %q", p.status)
	}
}

// THE SECOND ARM. A guard that refuses EVERYTHING passes the test above and is
// a worse bug than the one it replaces. Deleting ClaimInfo.Live's worker-value
// read (returning false unconditionally) REDS THIS.
func TestCloseTaskOnAGenuinelyLiveClaimStillPostsTheFencingEpoch(t *testing.T) {
	p := driveClose(t, deskDocWithClaim("task-ac96e3a252d2cebd", deskLiveClaim))

	if !p.posted {
		t.Fatalf("a GENUINELY LIVE claim (worker=probe-r19w7, captured while held) must still close; status=%q", p.status)
	}
	if !strings.HasSuffix(p.path, "/v1/tasks/task-ac96e3a252d2cebd/close") {
		t.Errorf("close must hit the flat close endpoint, got %q", p.path)
	}
	if !strings.Contains(p.body, `"observed_epoch":1`) {
		t.Errorf("the close must echo the claim's fencing epoch — the epoch value is still what the fence compares; got %s", p.body)
	}
	if strings.Contains(p.status, "claim first") {
		t.Errorf("a live claim must not be refused; got %q", p.status)
	}
}

// A never-claimed row keeps the original copy byte-for-byte.
func TestCloseTaskNeverClaimedRowKeepsTheOriginalCopy(t *testing.T) {
	p := driveClose(t, &Doc{ID: "task-never"})
	if p.posted {
		t.Fatalf("a row with no claim object must not be closed")
	}
	if p.status != "not claimed — claim first (c)" {
		t.Errorf("never-claimed copy must stay byte-identical, got %q", p.status)
	}
}
