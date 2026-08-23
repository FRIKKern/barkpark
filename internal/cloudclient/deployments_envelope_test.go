package cloudclient

// deployments_envelope_test.go pins the dr-w14-s6 followup: the
// GET /v1/sites/:id/deployments envelope has a NAMED Go reader
// (deploymentsEnvelope), and the next_cursor it carries is not merely decoded
// but WALKED — a Go caller reaches the rows behind the 100-row cap, which is
// the whole reason W1 S2 built the cursor.
//
// `publish_clock` is deliberately not asserted anywhere here: dr-w26-s6
// DELETED that node from this route (the reader-less-instrument census's first
// deletion), so a decoder field for it would be a phantom. See the
// deploymentsEnvelope doc comment for the record.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// TestDeploymentsEnvelopeDecodesNamedShape: a real envelope body decodes
// through the named struct — deployments AND next_cursor both populated, and a
// null next_cursor stays distinguishable as "last window".
func TestDeploymentsEnvelopeDecodesNamedShape(t *testing.T) {
	body := `{"deployments":[{"id":"dep_1","status":"live"},{"id":"dep_2","status":"failed"}],"next_cursor":"cur-abc"}`
	var env deploymentsEnvelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(env.Deployments) != 2 || env.Deployments[0].ID != "dep_1" {
		t.Fatalf("deployments did not decode: %+v", env.Deployments)
	}
	if env.NextCursor == nil || *env.NextCursor != "cur-abc" {
		t.Fatalf("next_cursor did not decode: %+v", env.NextCursor)
	}

	var last deploymentsEnvelope
	if err := json.Unmarshal([]byte(`{"deployments":[],"next_cursor":null}`), &last); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if last.NextCursor != nil {
		t.Fatalf("a null next_cursor must decode to nil (last window), got %+v", last.NextCursor)
	}
}

// TestListDeploymentsAllWalksPastTheCap is the criterion's own sentence made
// executable: a Go caller walks past the 100-row cap using next_cursor and
// reaches row 101+. The fake serves two windows — 100 rows with a cursor, then
// 25 more without one — and requires the second request to carry
// ?before=<the cursor it sent>, so a walker that ignores the cursor (the old
// silence) cannot pass by accident.
func TestListDeploymentsAllWalksPastTheCap(t *testing.T) {
	pageRows := func(from, n int) string {
		rows := make([]string, 0, n)
		for i := 0; i < n; i++ {
			rows = append(rows, fmt.Sprintf(`{"id":"dep_%d","status":"live"}`, from+i))
		}
		return "[" + strings.Join(rows, ",") + "]"
	}
	requests := 0
	c := newFake(t, "sess", func(w http.ResponseWriter, r *http.Request) {
		requests++
		switch r.URL.Query().Get("before") {
		case "":
			_, _ = w.Write([]byte(`{"deployments":` + pageRows(1, 100) + `,"next_cursor":"cur-p2"}`))
		case "cur-p2":
			_, _ = w.Write([]byte(`{"deployments":` + pageRows(101, 25) + `,"next_cursor":null}`))
		default:
			t.Errorf("unexpected before=%q — the walker must pass back the server's own cursor", r.URL.Query().Get("before"))
			w.WriteHeader(http.StatusUnprocessableEntity)
		}
	})

	rows, err := c.ListDeploymentsAll(context.Background(), "site_1", 100, 0)
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if len(rows) != 125 {
		t.Fatalf("walked %d rows, want 125 — the walk must reach BEHIND the cap", len(rows))
	}
	if rows[100].ID != "dep_101" {
		t.Fatalf("row 101 = %q, want dep_101 — the rows behind the cap must arrive in ledger order", rows[100].ID)
	}
	if requests != 2 {
		t.Fatalf("made %d requests, want 2 (one per window)", requests)
	}
}

// TestListDeploymentsAllRefusesACursorLoop: a server that resends the same
// cursor would otherwise spin this walk forever — the walker names the bug and
// stops.
func TestListDeploymentsAllRefusesACursorLoop(t *testing.T) {
	c := newFake(t, "sess", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"deployments":[{"id":"dep_x","status":"live"}],"next_cursor":"same-cursor"}`))
	})
	_, err := c.ListDeploymentsAll(context.Background(), "site_1", 10, 0)
	if err == nil || !strings.Contains(err.Error(), "repeated cursor") {
		t.Fatalf("a repeated cursor must be a named refusal, got err=%v", err)
	}
}

// TestListDeploymentsAllHonoursMaxRows: the bound is a bound.
func TestListDeploymentsAllHonoursMaxRows(t *testing.T) {
	c := newFake(t, "sess", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"deployments":[{"id":"a","status":"live"},{"id":"b","status":"live"}],"next_cursor":"cur-next-` + fmt.Sprint(len(r.URL.Query().Get("before"))) + `"}`))
	})
	rows, err := c.ListDeploymentsAll(context.Background(), "site_1", 2, 3)
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("maxRows=3 returned %d rows", len(rows))
	}
}
