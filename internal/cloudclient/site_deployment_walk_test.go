package cloudclient

// dr-w17-bl-per-site-cost-needs-paging — the bounded keyset walk over
// GET /v1/sites/:id/deployments, and the bound it must report.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// TestWalkSpawnSiteDeploymentsBudgetIsDerivedNotHoped pins the round-trip plan.
// The budget is what a caller spends of someone's rate limit, so it is derived
// from the SERVER's real page cap rather than from whatever `limit` the caller
// typed: a budget computed against 500 would promise a quarter of the trips it
// actually costs.
func TestWalkSpawnSiteDeploymentsBudgetIsDerivedNotHoped(t *testing.T) {
	for _, tc := range []struct {
		rows, pageSize   int
		wantSize, wantPg int
	}{
		{20, 0, 20, 1},    // the status default: one trip.
		{200, 0, 200, 1},  // exactly the server cap: still one.
		{201, 0, 200, 2},  // one row over: two.
		{1000, 0, 200, 5}, // the CLI ceiling.
		{50, 500, 50, 1},  // a page size past the cap is clamped to the cap, then to rows.
		{0, 0, 1, 1},      // a nonsense row count still yields a spendable budget.
	} {
		b := NewSiteDeploymentWalkBudget(tc.rows, tc.pageSize)
		if b.PageSize != tc.wantSize || b.MaxPages != tc.wantPg {
			t.Errorf("NewSiteDeploymentWalkBudget(%d,%d) = size %d pages %d, want size %d pages %d",
				tc.rows, tc.pageSize, b.PageSize, b.MaxPages, tc.wantSize, tc.wantPg)
		}
	}
}

// TestWalkSpawnSiteDeploymentsFollowsCursorAndStopsAtItsBudget is the walk proof
// AND the truncation proof. A ledger that never ends is the adversarial case: the
// only thing that stops the walk is the budget, and the only thing that keeps the
// result quotable is that it says so.
func TestWalkSpawnSiteDeploymentsFollowsCursorAndStopsAtItsBudget(t *testing.T) {
	var queries []string
	c := newFake(t, "tok", func(w http.ResponseWriter, r *http.Request) {
		queries = append(queries, r.URL.RawQuery)
		n := len(queries)
		w.Header().Set("Content-Type", "application/json")
		// Two rows per window and ALWAYS another cursor — the ledger never ends.
		fmt.Fprintf(w, `{"deployments":[{"id":"d%da","status":"deferred"},{"id":"d%db","status":"live"}],"next_cursor":"cur-%d"}`, n, n, n)
	})

	walk, err := c.WalkSpawnSiteDeployments(context.Background(), "site-1", NewSiteDeploymentWalkBudget(600, 0))
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if walk.Pages != 3 || len(queries) != 3 {
		t.Fatalf("a 600-row budget at 200/page is 3 round trips, made %d (%v)", walk.Pages, queries)
	}
	if !strings.Contains(queries[1], "before=cur-1") || !strings.Contains(queries[2], "before=cur-2") {
		t.Fatalf("the walk must follow next_cursor, sent %v", queries)
	}
	if len(walk.Deployments) != 6 {
		t.Fatalf("the walk must accumulate every page, got %d rows", len(walk.Deployments))
	}
	// THE ASSERTION WITH TEETH. The server still had a cursor to give, so this
	// count is a FLOOR — and the caller can find that out from the return value
	// rather than from the shape of the number.
	if !walk.Truncated || walk.StoppedBy != "pages" {
		t.Fatalf("a budget-terminated walk must report truncated/pages, got %v/%q", walk.Truncated, walk.StoppedBy)
	}
}

// TestWalkSpawnSiteDeploymentsReportsAnExhaustedLedger — the OTHER direction,
// and the one a control makes necessary: a walk that always said "truncated"
// would pass the test above while making every count unquotable. When the server
// stops sending a cursor, what the walk holds IS the site's history, and it must
// say so.
func TestWalkSpawnSiteDeploymentsReportsAnExhaustedLedger(t *testing.T) {
	hits := 0
	c := newFake(t, "tok", func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		if hits == 1 {
			fmt.Fprint(w, `{"deployments":[{"id":"d1","status":"live"}],"next_cursor":"cur-1"}`)
			return
		}
		fmt.Fprint(w, `{"deployments":[{"id":"d2","status":"deferred"}],"next_cursor":null}`)
	})
	walk, err := c.WalkSpawnSiteDeployments(context.Background(), "site-1", NewSiteDeploymentWalkBudget(600, 0))
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if walk.Truncated || walk.StoppedBy != "exhausted" {
		t.Fatalf("a null next_cursor means the ledger ended, got truncated=%v stopped_by=%q", walk.Truncated, walk.StoppedBy)
	}
	if walk.Pages != 2 || len(walk.Deployments) != 2 {
		t.Fatalf("pages=%d rows=%d, want 2/2", walk.Pages, len(walk.Deployments))
	}
	// It spent 2 of a budgeted 3: the budget is a ceiling, never a quota to burn.
	if walk.Budget.MaxPages != 3 {
		t.Fatalf("budget = %d, want 3", walk.Budget.MaxPages)
	}
}

// TestWalkSpawnSiteDeploymentsStopsAtTheRowTarget — the third bound. A page
// bigger than the rows still wanted is trimmed, and the trim is reported as a
// row-target stop, not as an exhausted ledger.
func TestWalkSpawnSiteDeploymentsStopsAtTheRowTarget(t *testing.T) {
	c := newFake(t, "tok", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"deployments":[{"id":"a"},{"id":"b"},{"id":"c"}],"next_cursor":"cur"}`)
	})
	walk, err := c.WalkSpawnSiteDeployments(context.Background(), "site-1", SiteDeploymentWalkBudget{Rows: 2, PageSize: 3, MaxPages: 4})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	if len(walk.Deployments) != 2 {
		t.Fatalf("the row target must trim the last page, got %d", len(walk.Deployments))
	}
	if !walk.Truncated || walk.StoppedBy != "rows" {
		t.Fatalf("got truncated=%v stopped_by=%q, want true/rows", walk.Truncated, walk.StoppedBy)
	}
}

// TestWalkSpawnSiteDeploymentsRefusesARepeatedCursor — a server bug must not
// become an unbounded client request stream. The budget already bounds it, but a
// loop that silently re-reads page one and reports 600 rows of duplicates is a
// worse outcome than an error.
func TestWalkSpawnSiteDeploymentsRefusesARepeatedCursor(t *testing.T) {
	c := newFake(t, "tok", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"deployments":[{"id":"a"}],"next_cursor":"same"}`)
	})
	_, err := c.WalkSpawnSiteDeployments(context.Background(), "site-1", NewSiteDeploymentWalkBudget(600, 0))
	if err == nil || !strings.Contains(err.Error(), "repeated cursor") {
		t.Fatalf("a repeated cursor must be an error, got %v", err)
	}
}
