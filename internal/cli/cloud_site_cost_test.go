package cli

// dr-w17-bl-per-site-cost-needs-paging — the per-site deploy COST and the walk
// that makes it quotable.
//
// THE DEFECT THESE PIN. `bp cloud site status` read ONE page and printed a
// census over it. GET /v1/sites/:id/deployments caps a window at 200 rows and
// hands back a `next_cursor`, so "3.57 attempts per live deploy" measured on a
// site's newest 200 rows is a PAGE-LOCAL number — and the old return value could
// not distinguish it from that site's actual cost. Every test here asks one of
// three questions: does the walk follow the cursor, does it STOP at its stated
// budget AND SAY SO, and does every rendered figure name the window it is over.

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// siteCostRow builds one deployment row for the fake list route.
func siteCostRow(id, status, inserted, becameLive string) string {
	live := "null"
	if becameLive != "" {
		live = `"` + becameLive + `"`
	}
	return fmt.Sprintf(`{"id":%q,"status":%q,"inserted_at":%q,"became_live_at":%s}`, id, status, inserted, live)
}

// TestSiteStatusWalkFollowsTheCursorAndSaysWhereItStopped is the paging proof.
// Three assertions, and the third is the one with teeth: request 2 must carry
// the `before=` request 1 handed back (the walk really walked), the walk must
// stop at its round-trip budget rather than crawling the ledger, and the
// rendered line must SAY the budget ended the read. A walk that stops silently
// is the page-local-number defect wearing a bigger number.
func TestSiteStatusWalkFollowsTheCursorAndSaysWhereItStopped(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","current_deployment":{"id":"d1","status":"live","stage":"RETIRE"}}}`}

	// Three pages of 2, each still offering a cursor — i.e. the ledger NEVER
	// ends. A budget-less walk against this fake would loop until the fake ran
	// out of sequence entries; the bound is the only thing that stops it.
	page := func(a, b, cursor string) fakeResp {
		return fakeResp{200, `{"deployments":[` + a + `,` + b + `],"next_cursor":"` + cursor + `"}`}
	}
	cp.listSeq = []fakeResp{
		page(siteCostRow("d1", "live", "2026-08-07T10:00:00Z", "2026-08-07T10:00:30Z"), siteCostRow("d2", "deferred", "2026-08-07T09:00:00Z", ""), "cur-1"),
		page(siteCostRow("d3", "deferred", "2026-08-07T08:00:00Z", ""), siteCostRow("d4", "live", "2026-08-07T07:00:00Z", "2026-08-07T07:01:00Z"), "cur-2"),
		page(siteCostRow("d5", "deferred", "2026-08-07T06:00:00Z", ""), siteCostRow("d6", "failed", "2026-08-07T05:00:00Z", ""), "cur-3"),
	}
	cp.serve()

	// --window 4 at 4 rows a request is a ONE-trip budget; the server answers 2
	// rows a page, so the row target is never reached and the ROUND-TRIP budget
	// is what ends the read. That is the bound this surface must be able to name.
	stdout, stderr, code := runSite(t, "table", "status", testSiteID, "--window", "4")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if cp.listHits != 1 {
		t.Fatalf("--window 4 budgets ceil(4/4) = 1 round trip, spent %d: %v", cp.listHits, cp.listQueries)
	}
	if !strings.Contains(cp.listQueries[0], "limit=4") {
		t.Fatalf("the first request must ask for the window it budgeted, got %q", cp.listQueries[0])
	}
	if !strings.Contains(stdout, "read in 1 of a budgeted 1 round trips") {
		t.Fatalf("the rendered line must state the round-trip budget:\n%s", stdout)
	}
	if !strings.Contains(stdout, "ROUND-TRIP BUDGET ended this read") {
		t.Fatalf("a walk stopped by its budget must SAY the budget stopped it, not imply the ledger ended:\n%s", stdout)
	}

	// Now widen it: 6 rows at a page size of 6 is still one budgeted trip, so
	// prove the CURSOR is followed by giving the walk a budget it can spend.
	cp.listHits = 0
	cp.listQueries = nil
	stdout, _, code = runSite(t, "table", "status", testSiteID, "--window", "600")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if cp.listHits != 3 {
		t.Fatalf("--window 600 budgets ceil(600/200) = 3 round trips, spent %d: %v", cp.listHits, cp.listQueries)
	}
	// THE WALK PROOF: request 2 carries the cursor request 1 returned, request 3
	// the cursor request 2 returned. Anything else is three reads of page one.
	if !strings.Contains(cp.listQueries[1], "before=cur-1") {
		t.Fatalf("request 2 must follow request 1's next_cursor, got %q", cp.listQueries[1])
	}
	if !strings.Contains(cp.listQueries[2], "before=cur-2") {
		t.Fatalf("request 3 must follow request 2's next_cursor, got %q", cp.listQueries[2])
	}
	if !strings.Contains(stdout, "6 attempts read") {
		t.Fatalf("the walk must accumulate every page it read:\n%s", stdout)
	}
	if !strings.Contains(stdout, "read in 3 of a budgeted 3 round trips") {
		t.Fatalf("the line must name the trips SPENT and the trips BUDGETED:\n%s", stdout)
	}
}

// TestSiteStatusCostNamesItsWindowAndIsNotARate is the c0 + c1 proof: the cost
// figures are rendered as COST beside the outcome, each naming the window it was
// taken over, and the word "rate" appears only in the sentence that disowns it.
func TestSiteStatusCostNamesItsWindowAndIsNotARate(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","current_deployment":{"id":"d1","status":"live","stage":"RETIRE"}}}`}
	// 8 attempts, 2 of them live: 4.00 attempts per live, over a window that ends.
	rows := []string{
		siteCostRow("d1", "live", "2026-08-07T10:00:00Z", "2026-08-07T10:00:20Z"),
		siteCostRow("d2", "deferred", "2026-08-07T09:50:00Z", ""),
		siteCostRow("d3", "deferred", "2026-08-07T09:40:00Z", ""),
		siteCostRow("d4", "deferred", "2026-08-07T09:30:00Z", ""),
		siteCostRow("d5", "live", "2026-08-07T09:00:00Z", "2026-08-07T09:02:00Z"),
		siteCostRow("d6", "deferred", "2026-08-07T08:50:00Z", ""),
		siteCostRow("d7", "failed", "2026-08-07T08:40:00Z", ""),
		siteCostRow("d8", "deferred", "2026-08-07T01:00:00Z", ""),
	}
	cp.listResp = fakeResp{200, `{"deployments":[` + strings.Join(rows, ",") + `],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	for _, want := range []string{
		// c1: the figure, as a cost, with its own denominator.
		"4.00 attempts per live deploy — 8 attempts / 2 live",
		// c0: it names the window it was taken over. THIS is the assertion the
		// mutation proof flips: drop it and the same 4.00 reads as a site total.
		"over the 8 attempts read (2026-08-07T01:00:00Z → 2026-08-07T10:00:00Z)",
		"minutes to live: median",
		"over 2 of 2 live rows in that window",
		// c1: never folded into a reliability rate, and the copy says why.
		"a COST, never a reliability rate",
		// c1: the 8-day series, so nobody re-quotes D252's ~3.2 as the shape.
		"8.58 / 7.81 / 8.17 / 7.66 / 6.51 / 7.02 / 3.90 / 3.71",
		`The charter's "~3.2" is not reproduced anywhere in it`,
		// c0: the ledger ENDED here, and the line says so rather than hedging.
		"the server had no page behind this one",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the cost block must carry %q:\n%s", want, stdout)
		}
	}
	// c2: both halves of the deferral fact, in one breath.
	for _, want := range []string{
		"terminal for the ROW, usually transient for the SITE",
		"a deferred row is TERMINAL",
		"of 2,124 deferred rows, 0 ever set became_live_at",
		"1,837 (86.5%)",
		`never "no site is stranded"`,
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the deferral framing must carry %q:\n%s", want, stdout)
		}
	}
	// D220: the cost lives on the TYPED TABLE path. `-o json` stays a passthrough
	// of the rows and the window census — a script must not be able to pick the
	// prose-qualified figure up and re-quote it bare.
	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	if strings.Contains(jstdout, "attempts_per_live") || strings.Contains(jstdout, "attempts per live") {
		t.Fatalf("the cost figure must not ride the machine envelope (D220):\n%s", jstdout)
	}
	// What the machine channel DOES gain is the walk's bound — the one key a
	// script must read before quoting attempts_read as anything.
	for _, want := range []string{`"truncated":false`, `"stopped_by":"exhausted"`, `"pages_read":1`} {
		if !strings.Contains(jstdout, want) {
			t.Fatalf("the machine window must carry %s:\n%s", want, jstdout)
		}
	}
}

// TestSiteCostRefusesARatioWithNoLiveRow — a window with nothing live has an
// UNBOUNDED cost per live deploy, and 0.00 is the most flattering possible lie
// about it. The refusal is the assertion.
func TestSiteCostRefusesARatioWithNoLiveRow(t *testing.T) {
	c, ok := siteWindowCost([]cloudclient.SiteDeployment{
		{ID: "d1", Status: "deferred", InsertedAt: "2026-08-07T10:00:00Z"},
		{ID: "d2", Status: "failed", InsertedAt: "2026-08-07T09:00:00Z"},
	})
	if !ok {
		t.Fatal("a non-empty window is measurable")
	}
	if c.HaveRatio {
		t.Fatalf("no live row means no attempts-per-live, got %.2f", c.AttemptsPerLive)
	}
	if c.AttemptsPerLive != 0 || c.Lives != 0 {
		t.Fatalf("nothing may be imputed: %+v", c)
	}
	var buf bytes.Buffer
	out := newWriter(&buf, &buf)
	renderSiteCost(out, siteWindow{Rows: 2, PageLimit: 20, Pages: 1, PageBudget: 1, PageSize: 20, StoppedBy: "exhausted"}, c)
	if !strings.Contains(buf.String(), "NO LIVE ROW in the 2 attempts read") {
		t.Fatalf("the refusal must be printed as a refusal:\n%s", buf.String())
	}
	if strings.Contains(buf.String(), "0.00 attempts per live") {
		t.Fatalf("a zero cost per live deploy is the lie this arm exists to stop:\n%s", buf.String())
	}
}

// TestSiteDeferralClearanceCensorsTheYoungEdge — a deferred row less than an
// hour old at the newest edge of the window has not FAILED to clear; its hour has
// not elapsed inside the data we hold. Counting it as "not cleared" manufactures
// pessimism at exactly the edge a status call always looks at.
func TestSiteDeferralClearanceCensorsTheYoungEdge(t *testing.T) {
	// d1 is the newest row and is deferred: nothing newer exists to clear it.
	// d3 deferred at 08:00 and d2 went live at 08:10 — cleared.
	// d5 deferred at 05:00 with no live inside its hour — genuinely not cleared.
	ledger := []cloudclient.SiteDeployment{
		{ID: "d1", Status: "deferred", InsertedAt: "2026-08-07T10:00:00Z"},
		{ID: "d2", Status: "live", InsertedAt: "2026-08-07T08:10:00Z", BecameLiveAt: "2026-08-07T08:10:30Z"},
		{ID: "d3", Status: "deferred", InsertedAt: "2026-08-07T08:00:00Z"},
		{ID: "d5", Status: "deferred", InsertedAt: "2026-08-07T05:00:00Z"},
	}
	deferred, cleared, censored, ok := siteDeferralClearance(ledger)
	if !ok {
		t.Fatal("a window with deferrals is measurable")
	}
	if deferred != 3 || cleared != 1 || censored != 1 {
		t.Fatalf("deferred=%d cleared=%d censored=%d, want 3/1/1 — d1 is censored (its hour has not elapsed in this window), d3 cleared, d5 did not", deferred, cleared, censored)
	}
	// A window with no deferral at all prints nothing: framing a fact the
	// reader's own data does not exhibit is noise.
	if _, _, _, ok := siteDeferralClearance([]cloudclient.SiteDeployment{{ID: "d1", Status: "live", InsertedAt: "2026-08-07T10:00:00Z"}}); ok {
		t.Fatal("no deferral in the window means no framing block")
	}
}

// TestSiteStatusWindowFlagRefusesRatherThanClamps — a --window past the ceiling
// is an error naming the ceiling, never a silent clamp. A clamp would print a
// cost figure over a window the caller did not ask for and would never learn about.
func TestSiteStatusWindowFlagRefusesRatherThanClamps(t *testing.T) {
	cp := newSiteCP(t)
	cp.serve()
	for _, tc := range []struct{ arg, want string }{
		{"0", "wants a positive number"},
		{"nope", "wants a positive number"},
		{"1001", "exceeds the 1000-attempt ceiling"},
	} {
		_, stderr, code := runSite(t, "table", "status", testSiteID, "--window", tc.arg)
		if code != exitUsage {
			t.Fatalf("--window %s exit=%d want %d", tc.arg, code, exitUsage)
		}
		if !strings.Contains(stderr, tc.want) {
			t.Fatalf("--window %s must say %q, got:\n%s", tc.arg, tc.want, stderr)
		}
	}
	if cp.listHits != 0 {
		t.Fatalf("a refused --window must make NO network call, made %d", cp.listHits)
	}
}

// TestSiteStatusDefaultWindowIsStillOneRoundTrip — the N+1 guard. `bp sites`
// already pays extra round trips per site; a cost walk added on top is an N+1
// unless the DEFAULT stays exactly the read this verb has always done.
func TestSiteStatusDefaultWindowIsStillOneRoundTrip(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro"}}`}
	cp.listResp = fakeResp{200, `{"deployments":[` + siteCostRow("d1", "live", "2026-08-07T10:00:00Z", "2026-08-07T10:00:20Z") + `],"next_cursor":"cur-1"}`}
	cp.serve()
	if _, _, code := runSite(t, "table", "status", testSiteID); code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if cp.listHits != 1 {
		t.Fatalf("the default window must cost ONE round trip, cost %d: %v", cp.listHits, cp.listQueries)
	}
	if !strings.Contains(cp.listQueries[0], fmt.Sprintf("limit=%d", siteStatusLedgerPage)) {
		t.Fatalf("the default must ask for the page it always asked for, got %q", cp.listQueries[0])
	}
}
