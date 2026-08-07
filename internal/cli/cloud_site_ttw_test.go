package cli

// cloud_site_ttw_test.go pins the TIME-TO-WEB sentence — the deploy-reliability
// epic's founding line, and the first place any Barkpark surface prints how LONG
// a deploy took rather than only what it ended as.
//
// The three things under test are the three ways this line could lie:
//   - it could IMPUTE a clock it does not have (an empty became_live_at parsed as
//     the zero instant, or a 0 in the JSON envelope reading as "instant");
//   - it could CENSOR the bad news (drop the "still waiting" clause and print a
//     serene finished number while a revision is stuck);
//   - it could MISNAME its clock (say "after you made it" when t0 is the control
//     plane's inserted_at, which is measured to understate the human-felt wait).
//
// Two of those get MUTATION proofs — a test is only a guard if breaking the code
// reds it — and the mutation instructions are written into the test bodies.

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// ttwClock is the fixed "now" every censored-wait assertion here measures against.
var ttwClock = time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)

func ttwFreeze(t *testing.T) {
	t.Helper()
	orig := siteClock
	siteClock = func() time.Time { return ttwClock }
	t.Cleanup(func() { siteClock = orig })
}

func ttwStamp(d time.Duration) string {
	return ttwClock.Add(-d).Format(time.RFC3339)
}

// --- the formatter ------------------------------------------------------------

// TestSiteShortDurIsNotTheCensusFormatter pins the reason this function had to
// exist: package cli's only duration renderer floors at whole minutes, so a
// 265-second publish printed "4 minutes" and a 20-second one printed "0 minutes".
func TestSiteShortDurIsNotTheCensusFormatter(t *testing.T) {
	const d = 265 * time.Second
	short, census := siteShortDur(d), deployCensusWidth(d)
	if short == census {
		t.Fatalf("siteShortDur must not collapse to the census renderer: both printed %q", short)
	}
	if short != "4m25s" || census != "4 minutes" {
		t.Fatalf("siteShortDur(265s)=%q deployCensusWidth(265s)=%q — want \"4m25s\" and \"4 minutes\"", short, census)
	}
	// Two units, across the ladder — and never a bare "0 minutes" for a real wait.
	for _, tc := range []struct {
		in   time.Duration
		want string
	}{
		{20 * time.Second, "20s"},
		{9*time.Minute + 5*time.Second, "9m05s"},
		{2*time.Hour + 39*time.Minute, "2h39m"},
		{3*24*time.Hour + 4*time.Hour, "3d04h"},
	} {
		if got := siteShortDur(tc.in); got != tc.want {
			t.Fatalf("siteShortDur(%s)=%q want %q", tc.in, got, tc.want)
		}
	}
}

// --- the refusals -------------------------------------------------------------

// TestSiteTimeToWebRefusesRatherThanImputes is the no-imputation guard.
//
// MUTATION PROOF (criterion 3): make siteTimeToWeb return (0, true) on a missing
// stamp — i.e. replace the `if !lok || !iok { return 0, false }` arm with
// `return 0, true` — and this test plus
// TestSiteDeploymentMapOmitsTimeToWebOnANonLiveRow both RED.
func TestSiteTimeToWebRefusesRatherThanImputes(t *testing.T) {
	live := "2026-08-07T10:04:25Z"
	ins := "2026-08-07T10:00:00Z"

	if got, ok := siteTimeToWeb(cloudclient.SiteDeployment{BecameLiveAt: live, InsertedAt: ins}); !ok || got != 265*time.Second {
		t.Fatalf("a well-stamped row must measure: got=%s ok=%v", got, ok)
	}
	for _, tc := range []struct {
		name string
		d    cloudclient.SiteDeployment
	}{
		// Absence is a BARE "" on this struct (not a nil pointer), and the zero
		// instant minus 2026 is a time-to-web of ~2026 years.
		{"never went live", cloudclient.SiteDeployment{BecameLiveAt: "", InsertedAt: ins}},
		{"no inserted_at", cloudclient.SiteDeployment{BecameLiveAt: live, InsertedAt: ""}},
		{"unparseable live stamp", cloudclient.SiteDeployment{BecameLiveAt: "yesterday", InsertedAt: ins}},
		{"unparseable inserted stamp", cloudclient.SiteDeployment{BecameLiveAt: live, InsertedAt: "soon"}},
		// Clock skew / a repointed row: a negative gap is not a fast deploy.
		{"live before inserted", cloudclient.SiteDeployment{BecameLiveAt: ins, InsertedAt: live}},
	} {
		if got, ok := siteTimeToWeb(tc.d); ok {
			t.Fatalf("%s: siteTimeToWeb must refuse, got %s", tc.name, got)
		} else if got != 0 {
			t.Fatalf("%s: a refusal must carry no duration, got %s", tc.name, got)
		}
	}
}

// TestSiteDeploymentMapOmitsTimeToWebOnANonLiveRow: the JSON twin of the refusal.
// ABSENT, never 0 — a zero here reads as "went live instantly", the most
// flattering lie this envelope could tell.
func TestSiteDeploymentMapOmitsTimeToWebOnANonLiveRow(t *testing.T) {
	queued := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-queued", Status: "queued", InsertedAt: "2026-08-07T10:00:00Z",
	})
	if _, present := queued["time_to_web_seconds"]; present {
		t.Fatalf("a queued row must carry NO time_to_web_seconds, got %v", queued["time_to_web_seconds"])
	}
	if queued["inserted_at"] != "2026-08-07T10:00:00Z" {
		t.Fatalf("inserted_at must reach the envelope, got %v", queued["inserted_at"])
	}
	if _, present := queued["became_live_at"]; present {
		t.Fatalf("an empty became_live_at must be omitted, got %v", queued["became_live_at"])
	}

	lived := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-live", Status: "live",
		InsertedAt: "2026-08-07T10:00:00Z", BecameLiveAt: "2026-08-07T10:04:25Z",
	})
	if lived["time_to_web_seconds"] != int64(265) {
		t.Fatalf("a live row must carry its measured seconds, got %v", lived["time_to_web_seconds"])
	}
	if lived["became_live_at"] != "2026-08-07T10:04:25Z" {
		t.Fatalf("became_live_at must reach the envelope, got %v", lived["became_live_at"])
	}
}

// --- the sentence -------------------------------------------------------------

// TestSiteTimeToWebLineNamesItsClock pins the exact string. Two failures it
// guards, both found by a verifier rather than by taste:
//
//	(a) t0 is the CONTROL PLANE's inserted_at, not the human's publish (measured
//	    4.8x understatement at 24h) — so the copy must not say "after you made it";
//	(b) a rollback repoints current_deployment_id at an OLDER row without
//	    restamping became_live_at, so "your last publish" would name a build the
//	    user never published last — the wording is POINTER-scoped instead.
func TestSiteTimeToWebLineNamesItsClock(t *testing.T) {
	ttwFreeze(t)
	dep := &cloudclient.SiteDeployment{
		ID: "dep-1", Status: "live",
		InsertedAt: "2026-08-07T10:00:00Z", BecameLiveAt: "2026-08-07T10:04:25Z",
	}
	got := siteTimeToWebLine(dep, nil)
	const want = "the build you are being served went live 4m25s after the control plane picked it up (publishes are debounced up to 60s)"
	if got != want {
		t.Fatalf("time-to-web sentence drifted:\n got %q\nwant %q", got, want)
	}
	if strings.Contains(got, "after you made it") || strings.Contains(strings.ToLower(got), "your last publish") {
		t.Fatalf("the sentence must not claim the human's clock: %q", got)
	}
	// No stamps => no sentence. Silence is the honest shape of "we do not know".
	if line := siteTimeToWebLine(&cloudclient.SiteDeployment{ID: "dep-2", Status: "queued"}, nil); line != "" {
		t.Fatalf("an unstampable row must produce no sentence, got %q", line)
	}
}

// TestSiteTimeToWebLineReportsTheOldestWaiter is the censoring guard AND the
// oldest-not-newest guard in one: three pending rows arrive newest-first, and the
// bound printed must be the OLDEST one's (3h), not row [0]'s (12m).
//
// MUTATION PROOF (criterion 4): delete the `if waited, _, ok := siteWaitingSince(
// …)` clause from siteTimeToWebLine and this test REDS ("must carry the censored
// waiting clause").
func TestSiteTimeToWebLineReportsTheOldestWaiter(t *testing.T) {
	ttwFreeze(t)
	dep := &cloudclient.SiteDeployment{
		ID: "dep-live", Status: "live",
		InsertedAt: "2026-08-07T10:00:00Z", BecameLiveAt: "2026-08-07T10:04:25Z",
	}
	ledger := []cloudclient.SiteDeployment{
		{ID: "dep-c", Status: "queued", InsertedAt: ttwStamp(12 * time.Minute)},
		{ID: "dep-b", Status: "building", InsertedAt: ttwStamp(47 * time.Minute)},
		{ID: "dep-a", Status: "queued", InsertedAt: ttwStamp(3 * time.Hour)},
		*dep,
	}
	line := siteTimeToWebLine(dep, ledger)
	if !strings.Contains(line, "is still waiting") {
		t.Fatalf("a pending revision must carry the censored waiting clause: %q", line)
	}
	if !strings.Contains(line, "at least 3h00m so far") {
		t.Fatalf("the bound must come from the OLDEST waiter (3h), got %q", line)
	}
	for _, shorter := range []string{"12m", "47m"} {
		if strings.Contains(line, "at least "+shorter) {
			t.Fatalf("the bound must not report a SHORTER wait (%s) while an older sibling is stranded: %q", shorter, line)
		}
	}
	// Rows OLDER than the live pointer are not "still waiting for the web" — they
	// are behind it — and settled rows (failed/cancelled/deferred) never are.
	settled := []cloudclient.SiteDeployment{
		{ID: "dep-f", Status: "failed", InsertedAt: ttwStamp(2 * time.Hour)},
		{ID: "dep-d", Status: "deferred", InsertedAt: ttwStamp(90 * time.Minute)},
		*dep,
		{ID: "dep-old", Status: "queued", InsertedAt: ttwStamp(30 * time.Hour)},
	}
	if line := siteTimeToWebLine(dep, settled); strings.Contains(line, "still waiting") {
		t.Fatalf("settled rows and rows behind the live pointer are not waiters: %q", line)
	}
}

// TestSiteWaitingSinceRefusesUnstampableRows: no inserted_at, no bound. A waiter
// we cannot time is not a waiter we may guess at.
func TestSiteWaitingSinceRefusesUnstampableRows(t *testing.T) {
	ttwFreeze(t)
	if _, _, ok := siteWaitingSince(nil, []cloudclient.SiteDeployment{
		{ID: "dep-x", Status: "queued", InsertedAt: ""},
		{ID: "dep-y", Status: "building", InsertedAt: "whenever"},
	}); ok {
		t.Fatal("an unstampable pending row must yield no censored bound")
	}
	// A future inserted_at (clock skew) is not a negative wait.
	if _, _, ok := siteWaitingSince(nil, []cloudclient.SiteDeployment{
		{ID: "dep-z", Status: "queued", InsertedAt: ttwClock.Add(5 * time.Minute).Format(time.RFC3339)},
	}); ok {
		t.Fatal("a future stamp must not produce a wait")
	}
}

// --- the slot -----------------------------------------------------------------

// TestStatusMapTimeToWebSurvivesBothRewriteArms is the dr-w7 precedence guard,
// structurally: BOTH existing arms that rewrite `status` fire here (the newest row
// FAILED while the live pointer is a deferred row), and the time-to-web line must
// still be present, in its OWN key, having changed nothing either arm wrote.
func TestStatusMapTimeToWebSurvivesBothRewriteArms(t *testing.T) {
	ttwFreeze(t)
	site := cloudclient.SpawnSite{ID: testSiteID, Name: "blog", Slug: "blog", Kind: "static", Framework: "astro"}
	dep := &cloudclient.SiteDeployment{
		ID: "dep-live", Status: "deferred",
		FailureReason: "the box is at its concurrent-build cap (refusal 3 of 12)",
		InsertedAt:    "2026-08-07T10:00:00Z", BecameLiveAt: "2026-08-07T10:04:25Z",
	}
	newest := &cloudclient.SiteDeployment{
		ID: "dep-new", Status: "failed", FailureClass: "BUILD_FAILED",
		FailureReason: "the build command exited non-zero", InsertedAt: ttwStamp(20 * time.Minute),
	}
	waiter := cloudclient.SiteDeployment{ID: "dep-wait", Status: "queued", InsertedAt: ttwStamp(2 * time.Hour)}
	ledger := []cloudclient.SiteDeployment{*newest, waiter, *dep}

	// Baseline: what the failed-stale arm writes with no clock in play at all.
	base := spawnSiteStatusMap(site, dep, newest, nil)
	m := spawnSiteStatusMap(site, dep, newest, ledger)
	if m["status"] != base["status"] {
		t.Fatalf("the time-to-web line must never touch status: %v vs %v", m["status"], base["status"])
	}
	if m["reason"] != base["reason"] {
		t.Fatalf("the time-to-web line must never touch reason: %v vs %v", m["reason"], base["reason"])
	}
	line, ok := m["time to web"].(string)
	if !ok || line == "" {
		t.Fatalf("the time-to-web line must be present alongside both rewrite arms, got %#v", m["time to web"])
	}
	if !strings.Contains(line, "the build you are being served went live 4m25s") {
		t.Fatalf("the clock is pointer-scoped and must describe the SERVED build: %q", line)
	}
	if !strings.Contains(line, "at least 2h00m so far") {
		t.Fatalf("the censored bound must ride the same line: %q", line)
	}
	// The louder truths are untouched.
	if s, _ := m["status"].(string); !strings.Contains(s, "NEWEST deploy FAILED") {
		t.Fatalf("the failed-stale arm must still own status, got %q", s)
	}
}

// TestStatusJSONCarriesTheCensoredPair proves the machine envelope end to end,
// through the real verb and the real fake control plane: the censored wait is a
// NUMBER paired with its censoring flag, never a bare duration, and the list is
// still ONE call.
func TestStatusJSONCarriesTheCensoredPair(t *testing.T) {
	ttwFreeze(t)
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-live","status":"live","stage":"RETIRE","inserted_at":"2026-08-07T10:00:00Z","became_live_at":"2026-08-07T10:04:25Z","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[` +
		`{"id":"dep-new","site_id":"` + testSiteID + `","status":"queued","inserted_at":"` + ttwStamp(12*time.Minute) + `"},` +
		`{"id":"dep-old","site_id":"` + testSiteID + `","status":"queued","inserted_at":"` + ttwStamp(3*time.Hour) + `"},` +
		`{"id":"dep-live","site_id":"` + testSiteID + `","status":"live","inserted_at":"2026-08-07T10:00:00Z","became_live_at":"2026-08-07T10:04:25Z"}` +
		`],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "json", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if cp.listHits != 1 {
		t.Fatalf("status must still make exactly ONE list call, got %d", cp.listHits)
	}
	var env struct {
		Deployment struct {
			InsertedAt      string `json:"inserted_at"`
			BecameLiveAt    string `json:"became_live_at"`
			TimeToWebSecond int64  `json:"time_to_web_seconds"`
		} `json:"deployment"`
		Staleness struct {
			WaitingAtLeast int64  `json:"latest_waiting_seconds_at_least"`
			Censored       bool   `json:"latest_waiting_censored"`
			WaitingID      string `json:"latest_waiting_deployment_id"`
		} `json:"staleness"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("status -o json must decode: %v\n%s", err, stdout)
	}
	if env.Deployment.TimeToWebSecond != 265 || env.Deployment.InsertedAt == "" || env.Deployment.BecameLiveAt == "" {
		t.Fatalf("the live deployment envelope must carry both clocks and the measured gap: %+v", env.Deployment)
	}
	if env.Staleness.WaitingAtLeast != int64(3*time.Hour/time.Second) {
		t.Fatalf("the censored bound must be the OLDEST waiter's 3h, got %ds", env.Staleness.WaitingAtLeast)
	}
	if !env.Staleness.Censored {
		t.Fatal("a waiting bound must never ship without latest_waiting_censored:true")
	}
	if env.Staleness.WaitingID != "dep-old" {
		t.Fatalf("the bound must name the row it came from, got %q", env.Staleness.WaitingID)
	}
	// And the sentence itself never reaches the JSON envelope's status keys.
	if strings.Contains(stdout, "after you made it") {
		t.Fatalf("no surface may claim the human's clock:\n%s", stdout)
	}
}
