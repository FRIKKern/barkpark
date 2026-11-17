package cli

// task-dbee0d3a56ab4459. Since #26855 the server replays a 5xx for a write that
// COMMITTED, and marks it `Idempotency-Committed: true`. On the publish leg bp
// already knows the id, so a committed fault is a published task: print the
// receipt and exit 0, never "may have landed" (exit 9), never a discard.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// committedPublishDoor accepts the create and answers every publish with a 500
// marked committed (or not, when committed is false). It records mutation kinds.
func committedPublishDoor(t *testing.T, committed bool) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var kinds []string
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		var body struct {
			Mutations []map[string]json.RawMessage `json:"mutations"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		kind := "other"
		if len(body.Mutations) > 0 {
			for k := range body.Mutations[0] {
				kind = k
			}
		}
		mu.Lock()
		kinds = append(kinds, kind)
		mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		switch kind {
		case "create":
			_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-950","document":{"_id":"drafts.task-950","_draft":true}}]}`))
		case "publish":
			if committed {
				rw.Header().Set("Idempotency-Committed", "true")
			}
			rw.WriteHeader(http.StatusInternalServerError)
			_, _ = rw.Write([]byte(fault500))
		default:
			_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-950","operation":"discardDraft"}]}`))
		}
	}))
	t.Cleanup(ts.Close)
	return ts, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), kinds...)
	}
}

func runCommittedPublish(t *testing.T, committed bool, output string) (int, string, string, []string) {
	t.Helper()
	noResendSleep(t)
	ts, kinds := committedPublishDoor(t, committed)
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: output}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A publish that committed and answered 500", "--publish"))
	return code, so.String(), se.String(), kinds()
}

func TestTaskCreatePublishCommittedFaultIsAPublishedReceipt(t *testing.T) {
	code, so, se, kinds := runCommittedPublish(t, true, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (a committed publish landed)\nstdout=%s\nstderr=%s", code, so, se)
	}
	var receipt struct {
		ID      string `json:"id"`
		Status  string `json:"status"`
		OnBoard bool   `json:"on_board"`
	}
	if err := json.Unmarshal([]byte(so), &receipt); err != nil {
		t.Fatalf("stdout is not a receipt: %v\n%s", err, so)
	}
	if receipt.ID != "task-950" || receipt.Status != "published" || !receipt.OnBoard {
		t.Fatalf("receipt = %+v, want task-950 published on_board", receipt)
	}
	if sentDiscard(kinds) {
		t.Fatalf("discarded the draft of a publish that committed: %v", kinds)
	}
	if strings.Contains(se, "may have landed") {
		t.Fatalf("a committed publish is called may-have-landed:\n%s", se)
	}
}

func TestTaskCreatePublishCommittedFaultHumanSaysItLanded(t *testing.T) {
	code, so, se, _ := runCommittedPublish(t, true, "")
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK\nstdout=%s\nstderr=%s", code, so, se)
	}
	if !strings.Contains(so, "task-950") {
		t.Fatalf("the receipt does not name the id:\n%s", so)
	}
	if !strings.Contains(se, "COMMITTED") {
		t.Fatalf("stderr does not say the publish committed despite the fault:\n%s", se)
	}
}

// Pin: a 5xx WITHOUT the header is still ambiguous, exactly as before.
func TestTaskCreatePublishUnmarkedFaultIsStillAmbiguous(t *testing.T) {
	code, _, se, kinds := runCommittedPublish(t, false, "json")
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous\nstderr=%s", code, se)
	}
	if sentDiscard(kinds) {
		t.Fatalf("discarded after an ambiguous publish: %v", kinds)
	}
}
