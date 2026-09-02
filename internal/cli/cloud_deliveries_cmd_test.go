package cli

// cloud_deliveries_cmd_test.go proves `bp cloud deliveries <sha>` ENTIRELY from
// the committed cross-language fixture cloud/priv/static/__fixtures__/
// platform_deliveries.json. No control-plane row, no recorder, no other slice:
// the reader is buildable and provable on its own, so a merge jam upstream
// cannot strand it.
//
// The load-bearing assertions are the ones about NOT LYING:
//
//   - every NULL clock renders as an UNMETERED sentence naming why, and NEVER as
//     0, an epoch, or a blank cell (the four nullable keys are the four ways this
//     record can silently flatter a deploy);
//   - a carried row says out loud that the delivering run is not the sha's own,
//     because its queue and build seconds belong to that other run;
//   - an unknown sha is an EMPTY read at exit 0, worded so it cannot be mistaken
//     for "the deploy failed" or for a 404;
//   - the typed 503 is its OWN message, decoding `reason` and printing the
//     route's own `detail` — never a zero page;
//   - no population percentage and no p95 appear anywhere (charter D429).
//
// And two SHAPE pins the file-global go-tag floor in the Elixir census cannot
// make: the fixture's live key set is held EXACTLY (mutation-proven able to red),
// and `count`/`scope` are pinned to DeliveriesPage ITSELF by reflection, because
// the floor unions tag NAMES across the whole package and both names are already
// declared by unrelated structs there.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// deliveriesFixturePath is the shared platform-delivery fixture, read relative
// to internal/cli/ exactly like usage_meters.json and verify_probes.json.
var deliveriesFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "platform_deliveries.json")

// deliveriesFixture is the whole fixture: the two declared key sets, the
// envelope key set, and the named scenarios with their status + body.
type deliveriesFixture struct {
	LiveKeySet     []string `json:"live_key_set"`
	EnvelopeKeySet []string `json:"envelope_key_set"`
	// PendingKeySetRaw exists ONLY so the retired prediction cannot creep back
	// in unnoticed. It must stay empty; see the test that asserts it.
	PendingKeySetRaw []string `json:"pending_key_set_after_10942"`
	NullClocks       struct {
		Keys            []string `json:"keys"`
		NullableBoolean []string `json:"nullable_boolean"`
		NotNull         []string `json:"not_null"`
	} `json:"null_clocks"`
	Scenarios map[string]struct {
		Why       string          `json:"why"`
		Synthetic string          `json:"synthetic"`
		Status    int             `json:"status"`
		Body      json.RawMessage `json:"body"`
	} `json:"scenarios"`
}

// loadDeliveriesFixture reads and decodes the committed fixture.
func loadDeliveriesFixture(t *testing.T) deliveriesFixture {
	t.Helper()
	raw, err := os.ReadFile(deliveriesFixturePath)
	if err != nil {
		t.Fatalf("read platform_deliveries.json fixture: %v", err)
	}
	var fx deliveriesFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode platform_deliveries.json: %v", err)
	}
	return fx
}

// deliveriesScenario returns one named scenario's status + body bytes, failing
// loudly when the scenario is missing — a renamed scenario must red here rather
// than silently skip the case it was covering.
func deliveriesScenario(t *testing.T, fx deliveriesFixture, name string) (int, string) {
	t.Helper()
	sc, okScenario := fx.Scenarios[name]
	if !okScenario {
		t.Fatalf("fixture has no scenario %q — the named scenarios ARE the contract", name)
	}
	return sc.Status, string(sc.Body)
}

// newDeliveriesServer stands up a fake control plane answering the deliveries
// route with the given status + body, seeds a cloud login pointed at it, and
// records the method, path, query and Authorization header it saw.
func newDeliveriesServer(t *testing.T, status int, body string) (method, path, query, auth *string) {
	t.Helper()
	var m, p, q, a string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, p, q, a = r.Method, r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &p, &q, &a
}

// runDeliveries drives runCloudDeliveries with an in-memory writer at the chosen
// output shape, returning stdout, stderr, exit.
func runDeliveries(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudDeliveries(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// ---------------------------------------------------------------------------
// registration
// ---------------------------------------------------------------------------

// TestCloudDeliveriesIsReachable: the verb dispatches through `bp cloud` and is
// listed in `bp cloud -h`. A reader nobody can find is the same as no reader.
func TestCloudDeliveriesIsReachable(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	if code := runCloud(w, globals{}, []string{"deliveries", "--help"}); code != exitOK {
		t.Fatalf("bp cloud deliveries --help exit = %d, want 0 (stderr: %s)", code, serr.String())
	}
	if !strings.Contains(sout.String(), "bp cloud deliveries") {
		t.Fatalf("help did not come from the deliveries verb:\n%s", sout.String())
	}

	var hout, herr bytes.Buffer
	hw := newWriter(&hout, &herr)
	printCloudHelp(hw)
	if !strings.Contains(hout.String(), "deliveries") {
		t.Fatalf("`bp cloud -h` does not list the deliveries verb:\n%s", hout.String())
	}
}

// ---------------------------------------------------------------------------
// the timeline
// ---------------------------------------------------------------------------

// TestCloudDeliveriesFullyClockedTimeline renders the real prod row: the run,
// the target, and merged / waited / built / serving in causal order, each
// carrying its own measured value.
func TestCloudDeliveriesFullyClockedTimeline(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "fully_clocked")
	method, path, query, auth := newDeliveriesServer(t, status, body)

	const sha = "2e38228b0048901b166d915d222cfc47f6f470d6"
	stdout, stderr, code := runDeliveries(t, "table", sha)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	// THE STRUCTURAL PIN: the platform record's own route, not the webhook
	// delivery proxy. An exact equality on purpose — a silent re-point at the
	// tenant route would otherwise render a tenant's webhook log under this
	// header, which is the confusion this whole verb is worded against.
	if *method != "GET" || *path != "/v1/deliveries" {
		t.Fatalf("hit %s %s, want GET /v1/deliveries", *method, *path)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	if !strings.Contains(*query, "sha="+sha) {
		t.Fatalf("query = %q, want the sha on the wire", *query)
	}

	for _, want := range []string{
		"run 31255918184",
		"target cp",
		"this sha's OWN run",
		"merged     2026-08-08T11:51:21Z",
		"waited     14s",
		"split      self 6s · stall 5s · pickup 3s",
		"pickup is the RESIDUAL",
		"built      216s",
		"serving    2026-08-08T11:55:11.517221Z",
		"recorded 2026-08-08T12:23:21.862544Z",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("render missing %q:\n%s", want, stdout)
		}
	}
	// A fully-clocked row says UNMETERED about nothing.
	if strings.Contains(stdout, "UNMETERED") {
		t.Fatalf("a fully clocked row must not print UNMETERED anywhere:\n%s", stdout)
	}
}

// TestCloudDeliveriesHeaderNamesItsPopulation: the header distinguishes this
// record from `bp cloud webhook deliveries`, which is a tenant's webhook send
// log. Nothing else on screen does.
func TestCloudDeliveriesHeaderNamesItsPopulation(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "fully_clocked")
	newDeliveriesServer(t, status, body)

	stdout, _, code := runDeliveries(t, "table", "2e38228b0048901b166d915d222cfc47f6f470d6")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	header := strings.SplitN(stdout, "\n", 2)[0]
	for _, want := range []string{"platform deliveries", "platform delivery record", "webhook"} {
		if !strings.Contains(header, want) {
			t.Fatalf("header %q must name the population it read and disown the webhook log", header)
		}
	}
	if !strings.Contains(stdout, "scope: platform") {
		t.Fatalf("render must print the control plane's declared scope:\n%s", stdout)
	}
}

// TestCloudDeliveriesNullClocksAreUnmetered: every NULL clock renders as an
// UNMETERED sentence naming WHY — never 0, never an epoch, never blank.
//
// This is the day-one case, not a hypothetical: the recorder writes NULL for
// every clock a failed query could not supply, and all four coalesce into
// flattery (0s of build, live at the epoch, merged at the epoch).
func TestCloudDeliveriesNullClocksAreUnmetered(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "all_null_clocks")
	newDeliveriesServer(t, status, body)

	stdout, stderr, code := runDeliveries(t, "table", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	// One UNMETERED sentence per nullable clock, each on its own labelled line,
	// and the VALUE — everything after the label — must OPEN with UNMETERED, so
	// a 0, an epoch or an empty cell cannot be the answer with an explanation
	// tacked on after it.
	for _, label := range []string{"merged", "waited", "split", "built", "serving"} {
		line := deliveriesLineWith(t, stdout, "  "+label+" ")
		value := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), label))
		if !strings.HasPrefix(value, "UNMETERED — ") {
			t.Fatalf("%s value = %q, want it to OPEN with an UNMETERED sentence", label, value)
		}
		// The sentence must name a REASON, not just refuse.
		if !strings.Contains(value, "unknown") {
			t.Fatalf("%s line = %q, want the reason it is unknown", label, line)
		}
	}
	// And no epoch leaked in anywhere — the shape a coalesced NULL datetime takes.
	for _, forbidden := range []string{"1970-01-01", "0001-01-01"} {
		if strings.Contains(stdout, forbidden) {
			t.Fatalf("a NULL clock rendered as %q — nil is UNMETERED, never zero:\n%s", forbidden, stdout)
		}
	}
}

// TestCloudDeliveriesCarriedSaysSoOutLoud: carried:true means the delivering run
// is NOT this sha's own, so the queue and build seconds on the row measure that
// other run. The render must say it in words, on the row.
func TestCloudDeliveriesCarriedSaysSoOutLoud(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "carried")
	newDeliveriesServer(t, status, body)

	stdout, stderr, code := runDeliveries(t, "table", "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{
		"CARRIED — not this sha's own run",
		"is NOT this sha's own run",
		"never this sha's own",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("carried render missing %q:\n%s", want, stdout)
		}
	}
	// The same fixture row with carried flipped false must NOT carry the warning
	// — otherwise the sentence is decoration rather than a signal.
	own := strings.Replace(body, `"carried": true`, `"carried": false`, 1)
	newDeliveriesServer(t, status, own)
	ownOut, _, _ := runDeliveries(t, "table", "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432")
	if strings.Contains(ownOut, "CARRIED") {
		t.Fatalf("carried:false rendered the carried warning:\n%s", ownOut)
	}
}

// TestCloudDeliveriesCarriedUnrecordedIsItsOwnState is THE mutation target of
// this slice, and it is deliberately the ONLY test that reds when `Carried` is
// narrowed from *bool back to bool.
//
// `carried` has three states and the third one is the dangerous one. true and
// false are both MEASUREMENTS; null is the absence of one, and the schema keeps
// no default (charter D422) precisely so that absence survives to the wire. A
// plain `bool` on this side undoes all of it in one hop — encoding/json decodes
// null to false — and the render then states, in plain confident English, that
// the run belongs to this sha. There is no missing number for a human to
// notice: the seconds are all present and correct, and only their OWNERSHIP is
// fiction.
//
// So the assertion is not "the word UNRECORDED appears" alone. It is that the
// row does NOT claim ownership, that it says ownership of the seconds is
// UNKNOWN, and that it is not the CARRIED sentence either — three states means
// the third is distinguishable from BOTH of the other two, not merely from one.
func TestCloudDeliveriesCarriedUnrecordedIsItsOwnState(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "carried_unrecorded")
	newDeliveriesServer(t, status, body)

	const sha = "7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d"
	stdout, stderr, code := runDeliveries(t, "table", sha)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	// THE LIE, ASSERTED ABSENT FIRST. This is the exact string the pre-fix
	// reader printed for this row, and its absence is the whole slice.
	if strings.Contains(stdout, "this sha's OWN run") {
		t.Fatalf("an UNRECORDED `carried` rendered as a confident ownership claim — "+
			"a *bool decoded as bool turns null into false and this is what a human then reads:\n%s", stdout)
	}
	// And it is not the CARRIED sentence either: "we know it was somebody
	// else's" is a different fact from "nobody checked".
	if strings.Contains(stdout, "CARRIED — not this sha's own run") {
		t.Fatalf("an UNRECORDED `carried` rendered as a measured CARRIED — three states, not two:\n%s", stdout)
	}

	for _, want := range []string{
		"carried UNRECORDED — whether this run is this sha's own was never measured",
		"was NEVER MEASURED",
		"OWNERSHIP of the waited/built seconds below is therefore UNKNOWN",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("unrecorded render missing %q:\n%s", want, stdout)
		}
	}
	// The clocks themselves ARE measured on this row and must still read as
	// measured — casting doubt on them would be a second, different lie.
	for _, want := range []string{"waited     14s", "built      216s"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("unrecorded render lost a MEASURED clock (%q) — only the attribution is unknown:\n%s", want, stdout)
		}
	}
}

// TestCloudDeliveriesSplitRendersTheThreeBucketsAndNamesTheResidual pins the
// wait decomposition (charter D430): three columns that have been on the wire
// since #10942 merged and that no code on any branch rendered until now.
//
// Two shapes, because they fail differently. FULLY METERED must print all three
// buckets and say that pickup is the RESIDUAL — a reader who takes "pickup" for
// "slow runner pickup" goes looking at GitHub's runner fleet for seconds spent
// in this repo's own queue. PARTIAL is the more dangerous one: three numbers
// look like arithmetic, so one missing bucket reads as "that one was about
// zero", which the residual definition makes actively wrong.
func TestCloudDeliveriesSplitRendersTheThreeBucketsAndNamesTheResidual(t *testing.T) {
	fx := loadDeliveriesFixture(t)

	status, body := deliveriesScenario(t, fx, "fully_clocked")
	newDeliveriesServer(t, status, body)
	metered, _, code := runDeliveries(t, "table", "2e38228b0048901b166d915d222cfc47f6f470d6")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, metered)
	}
	line := deliveriesLineWith(t, metered, "  split ")
	for _, want := range []string{"self 6s", "stall 5s", "pickup 3s", "RESIDUAL", "never a magnitude threshold"} {
		if !strings.Contains(line, want) {
			t.Fatalf("fully metered split line %q missing %q", line, want)
		}
	}
	// A complete split carries no PARTIAL warning — otherwise the warning is
	// decoration and a reader learns to skip it.
	if strings.Contains(line, "PARTIAL") {
		t.Fatalf("a fully metered split warned PARTIAL: %q", line)
	}

	// PARTIAL: the second row of two_rows_one_sha measures self and pickup and
	// leaves stall NULL.
	status, body = deliveriesScenario(t, fx, "two_rows_one_sha")
	newDeliveriesServer(t, status, body)
	multi, _, code := runDeliveries(t, "table", "4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, multi)
	}
	second := strings.Index(multi, "run 31260000777")
	if second < 0 {
		t.Fatalf("second row not rendered:\n%s", multi)
	}
	partial := deliveriesLineWith(t, multi[second:], "  split ")
	for _, want := range []string{"self 120s", "stall UNMETERED", "pickup 30s", "PARTIAL", "is not 0"} {
		if !strings.Contains(partial, want) {
			t.Fatalf("partial split line %q missing %q", partial, want)
		}
	}

	// And a row with NO bucket measured says so once, as one fact, rather than
	// three separate unknowns — one recorder went quiet, not three.
	status, body = deliveriesScenario(t, fx, "all_null_clocks")
	newDeliveriesServer(t, status, body)
	none, _, _ := runDeliveries(t, "table", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
	noneLine := deliveriesLineWith(t, none, "  split ")
	if !strings.Contains(noneLine, "no queue split at all") {
		t.Fatalf("an entirely unmetered split line %q must say the split is absent, not print three UNMETEREDs", noneLine)
	}
}

// TestCloudDeliveriesRendersEveryRowForOneSha (REVIEW ADDITION) pins the
// MULTI-ROW path, which no other case reaches: every other scenario carries 0 or
// 1 rows, so `if i > 0 { blank line }`, the per-row attribution, and the
// carried/not-carried mix never executed. One sha having several rows is not an
// edge case — the identity is (sha, delivering_run_id, first_seen_at) and the
// normal post-merge shape is a cp leg and an instance leg — so a render that
// silently dropped rows after the first, or ran two timelines together with no
// separator, would have shipped fully green.
func TestCloudDeliveriesRendersEveryRowForOneSha(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "two_rows_one_sha")
	newDeliveriesServer(t, status, body)

	stdout, stderr, code := runDeliveries(t, "table", "4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	// BOTH runs are rendered, each with its own target — a reader must be able to
	// see that the cp leg and the instance leg of one merge are two facts.
	for _, want := range []string{
		"run 31255918184", "target cp",
		"run 31260000777", "target instance",
		"2 deliveries recorded",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("multi-row render missing %q:\n%s", want, stdout)
		}
	}
	// The two blocks are SEPARATED. Without the blank line the second run line
	// abuts the first block's "first seen …" line and the two timelines read as
	// one, which is precisely how a reader mis-attributes one leg's clocks.
	first := strings.Index(stdout, "run 31255918184")
	second := strings.Index(stdout, "run 31260000777")
	if first < 0 || second < 0 || second < first {
		t.Fatalf("rows rendered out of wire order (first=%d second=%d):\n%s", first, second, stdout)
	}
	if !strings.Contains(stdout[first:second], "\n\n") {
		t.Fatalf("no blank line between the two delivery blocks:\n%s", stdout[first:second])
	}
	// Attribution is PER ROW, not per page: only the carried row warns, and only
	// the row whose clocks are NULL says UNMETERED.
	if strings.Count(stdout, "CARRIED — not this sha's own run") != 1 {
		t.Fatalf("carried warning must appear on exactly the carried row:\n%s", stdout)
	}
	if !strings.Contains(stdout[second:], "waited     UNMETERED") {
		t.Fatalf("the second row's NULL queue clock did not render UNMETERED:\n%s", stdout[second:])
	}
	if strings.Contains(stdout[first:second], "UNMETERED") {
		t.Fatalf("the fully-clocked first row must not print UNMETERED:\n%s", stdout[first:second])
	}
}

// TestCloudDeliveriesUnknownShaIsAnHonestEmptyRead: the route answers 200 with
// an empty list for an unknown sha (never a 404), so the READ succeeded and the
// verb exits 0 — while saying loudly that nothing was ever recorded, in words
// that cannot be read as "the deploy failed".
func TestCloudDeliveriesUnknownShaIsAnHonestEmptyRead(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "unknown_sha_empty")
	if status != 200 {
		t.Fatalf("unknown_sha_empty fixture status = %d, want 200 — an unknown sha is never a 404", status)
	}
	newDeliveriesServer(t, status, body)

	stdout, stderr, code := runDeliveries(t, "table", "0123456789abcdef0123456789abcdef01234567")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the read succeeded; it was empty)\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{
		"NO delivery was ever recorded",
		"NOT a 404",
		"NOT \"the deploy failed\"",
		"0 deliveries recorded",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("empty render missing %q:\n%s", want, stdout)
		}
	}
}

// TestCloudDeliveriesTyped503IsItsOwnMessage: the migration-missing refusal is a
// DIFFERENT sentence from every other failure, decodes `reason`, and prints the
// route's own `detail` verbatim — and it is never an empty page.
func TestCloudDeliveriesTyped503IsItsOwnMessage(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "unavailable_503")
	if status != 503 {
		t.Fatalf("unavailable_503 fixture status = %d, want 503", status)
	}
	newDeliveriesServer(t, status, body)

	stdout, stderr, code := runDeliveries(t, "table", "2e38228b0048901b166d915d222cfc47f6f470d6")
	if code != exitServer {
		t.Fatalf("exit = %d, want %d (exitServer)\nstdout:\n%s\nstderr:\n%s", code, exitServer, stdout, stderr)
	}
	// The route's own detail string, verbatim — never paraphrased into a second
	// drifting copy of the same explanation.
	var env struct {
		Detail string `json:"detail"`
	}
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("decode 503 fixture body: %v", err)
	}
	for _, want := range []string{
		"platform_deliveries_missing",
		env.Detail,
		"NOT 'no delivery was recorded",
	} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("503 refusal missing %q:\n%s", want, stderr)
		}
	}
	// A refusal renders NO timeline at all: an empty page here reads exactly
	// like a sha that delivered nothing.
	if strings.Contains(stdout, "NO delivery was ever recorded") {
		t.Fatalf("a 503 rendered the empty-read sentence — the two are different facts:\n%s", stdout)
	}
	// And it is a different sentence from a 401.
	newDeliveriesServer(t, 401, `{"error":"unauthorized"}`)
	_, unauth, ucode := runDeliveries(t, "table", "2e38228b0048901b166d915d222cfc47f6f470d6")
	if ucode != exitAuth {
		t.Fatalf("401 exit = %d, want %d (exitAuth)", ucode, exitAuth)
	}
	if strings.Contains(unauth, "platform_deliveries_missing") {
		t.Fatalf("401 borrowed the 503's sentence:\n%s", unauth)
	}
}

// TestCloudDeliveriesPrintsNoPopulationRateOrP95 (charter D429): this verb
// renders ONE sha and prints that sha's own seconds — never a population
// percentage, and never p95, which measured 12.8s vs 153.8s across two
// defensible definitions of the same window and is not a stable statistic.
func TestCloudDeliveriesPrintsNoPopulationRateOrP95(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	for _, name := range []string{"fully_clocked", "all_null_clocks", "carried", "carried_unrecorded", "unknown_sha_empty"} {
		status, body := deliveriesScenario(t, fx, name)
		newDeliveriesServer(t, status, body)
		stdout, stderr, _ := runDeliveries(t, "table", "2e38228b0048901b166d915d222cfc47f6f470d6")
		all := stdout + stderr
		if strings.Contains(all, "%") {
			t.Fatalf("%s render printed a %% — D429 forbids a population percentage on a single-sha render:\n%s", name, all)
		}
		for _, forbidden := range []string{"p95", "P95", "percentile"} {
			if strings.Contains(all, forbidden) {
				t.Fatalf("%s render printed %q:\n%s", name, forbidden, all)
			}
		}
	}
}

// TestCloudDeliveriesJSONIsTheEnvelopeVerbatim: `-o json` re-emits the control
// plane's bytes rather than a second, drifting definition of the contract.
func TestCloudDeliveriesJSONIsTheEnvelopeVerbatim(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "fully_clocked")
	newDeliveriesServer(t, status, body)

	stdout, _, code := runDeliveries(t, "json", "2e38228b0048901b166d915d222cfc47f6f470d6")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if strings.TrimSpace(stdout) != strings.TrimSpace(body) {
		t.Fatalf("-o json is not the envelope bytes:\ngot:  %s\nwant: %s", stdout, body)
	}
}

// TestCloudDeliveriesRefusesJunkShaBeforeAskingAnything: a typo must never come
// back as "nothing was recorded for this sha", which is a measurement.
func TestCloudDeliveriesRefusesJunkShaBeforeAskingAnything(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "unknown_sha_empty")
	method, _, _, _ := newDeliveriesServer(t, status, body)

	_, stderr, code := runDeliveries(t, "table", "not-a-sha")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (exitUsage)\n%s", code, exitUsage, stderr)
	}
	if *method != "" {
		t.Fatalf("a junk sha reached the control plane (method %q) — refuse it locally", *method)
	}
}

// TestCloudDeliveriesRollbackVerdictReachesTheHuman is THE mutation target for
// dr-w27-s2: delete the `moved` line from renderDelivery and this test, and only
// this test, reds.
//
// It asserts RENDERED BYTES, not a struct field, because the struct field was
// never the problem — the problem was that the field did not exist while both
// key-count pins stayed green, so `json.Unmarshal` dropped `transition` and a
// delivery that rolled the platform BACK printed byte-identically to one that
// moved forward. The proof that matters is therefore a comparison between the
// two renders, not the presence of a word.
//
// THREE STATES, AND THE THIRD IS THE ONE THAT NEEDED A DECISION. `rollback` and
// `unknown` are both RECORDED verdicts; a NULL is the absence of one. `unknown`
// means the writer tried and could not decide (a gc'd sha, an unreachable box, a
// shallow clone) — a NULL means it never attempted a verdict at all, which is
// what every row written before #11078 carries. Rendering them with one sentence
// would announce a failed grading on the entire history of the table.
func TestCloudDeliveriesRollbackVerdictReachesTheHuman(t *testing.T) {
	fx := loadDeliveriesFixture(t)

	status, body := deliveriesScenario(t, fx, "rollback_verdict")
	newDeliveriesServer(t, status, body)
	rolled, stderr, code := runDeliveries(t, "table", "c0e43440b1a2938475d6c7b8a9e0f1d2c3b4a596")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, rolled, stderr)
	}
	for _, want := range []string{
		"ROLLBACK — this delivery moved the platform BACK",
		"is an ANCESTOR of what was being served before",
		"from b976637",
	} {
		if !strings.Contains(rolled, want) {
			t.Fatalf("the rollback verdict never reached the render (%q missing):\n%s", want, rolled)
		}
	}

	// THE SILENCE, ASSERTED GONE. Same row, verdict flipped to `forward`: if the
	// two renders are equal, the verdict is being dropped exactly as it was
	// before this slice — and every assertion above would still pass on a
	// renderer that printed the word from somewhere else.
	forward := strings.Replace(body, `"transition": "rollback"`, `"transition": "forward"`, 1)
	if forward == body {
		t.Fatal("the rollback_verdict fixture no longer carries `\"transition\": \"rollback\"` — this test cannot compare the two renders")
	}
	newDeliveriesServer(t, status, forward)
	forwardOut, _, _ := runDeliveries(t, "table", "c0e43440b1a2938475d6c7b8a9e0f1d2c3b4a596")
	if forwardOut == rolled {
		t.Fatalf("a ROLLBACK renders byte-identically to a FORWARD delivery — the verdict is being dropped:\n%s", rolled)
	}
	if strings.Contains(forwardOut, "ROLLBACK") {
		t.Fatalf("a forward delivery rendered the ROLLBACK sentence — the line is decoration, not a signal:\n%s", forwardOut)
	}

	// NULL IS "NEVER ATTEMPTED", NOT "unknown". all_null_clocks carries a null
	// transition, which is the shape of every row older than #11078.
	nullStatus, nullBody := deliveriesScenario(t, fx, "all_null_clocks")
	newDeliveriesServer(t, nullStatus, nullBody)
	nullOut, _, nullCode := runDeliveries(t, "table", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
	if nullCode != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", nullCode, nullOut)
	}
	for _, want := range []string{
		"UNRECORDED — NO rollback verdict was ever attempted",
		"It is NOT the same as `unknown`",
		"previous sha NOT RECORDED",
	} {
		if !strings.Contains(nullOut, want) {
			t.Fatalf("a NULL transition did not render as UNRECORDED (%q missing):\n%s", want, nullOut)
		}
	}
	if strings.Contains(nullOut, "the writer TRIED to grade this move") {
		t.Fatalf("a NULL transition rendered as the wire's `unknown` — never attempted is not tried-and-failed:\n%s", nullOut)
	}

	// And a RECORDED `unknown` still says the writer tried: two_rows_one_sha's
	// instance leg carries it, so the distinction is exercised in both
	// directions rather than asserted in one.
	twoStatus, twoBody := deliveriesScenario(t, fx, "two_rows_one_sha")
	newDeliveriesServer(t, twoStatus, twoBody)
	twoOut, _, _ := runDeliveries(t, "table", "4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c")
	if !strings.Contains(twoOut, "the writer TRIED to grade this move and could NOT decide") {
		t.Fatalf("a recorded `unknown` transition did not say the writer tried:\n%s", twoOut)
	}
	if strings.Contains(twoOut, "NO rollback verdict was ever attempted") {
		t.Fatalf("a recorded `unknown` rendered as never-attempted — the two are different statements:\n%s", twoOut)
	}
}

// ---------------------------------------------------------------------------
// the fixture's key sets
// ---------------------------------------------------------------------------

// TestCloudDeliveriesRowShaIsTheRecordsOwn is THE mutation target for
// dr-w27-bl-decoded-but-never-rendered-sha: re-point deliveriesRowShaLine at the
// caller's positional (or delete the line) and this test reds.
//
// The fixture here is DELIBERATELY inline and DELIBERATELY inconsistent: the
// row's recorded sha differs from both the query and the envelope echo. Before
// the fix, this render was byte-identical to a correct answer — the header
// printed the operator's own input back at them and d.SHA was decoded and
// dropped, so a control plane answering with a DIFFERENT commit's delivery was
// structurally invisible.
func TestCloudDeliveriesRowShaIsTheRecordsOwn(t *testing.T) {
	const query = "2e38228b0048901b166d915d222cfc47f6f470d6"
	const rowSha = "beefbeefbeefbeefbeefbeefbeefbeefbeefbeef"
	body := `{"deliveries":[{"sha":"` + rowSha + `","delivering_run_id":"31255918184","first_seen_at":"2026-08-08T11:55:11.517221Z",` +
		`"merged_at":"2026-08-08T11:51:21Z","queued_seconds":14,"queued_self_seconds":6,"queued_pickup_seconds":3,` +
		`"queued_stall_seconds":5,"build_seconds":216,"serving_since":"2026-08-08T11:55:11.517221Z","target":"cp",` +
		`"carried":false,"previous_sha":null,"transition":"forward","recorded_at":"2026-08-08T12:23:21.862544Z"}],` +
		`"count":1,"sha":"` + query + `","limit":50,"scope":"platform"}`
	newDeliveriesServer(t, 200, body)

	stdout, stderr, code := runDeliveries(t, "table", query)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	// The row block opens with the RECORD'S OWN sha — the full recorded value,
	// which shares not even a prefix with the query here.
	if !strings.Contains(stdout, "sha "+rowSha) {
		t.Fatalf("render never prints the row's own recorded sha %s:\n%s", rowSha, stdout)
	}
	// And the disagreement is LOUD, on the row, naming the sha that was asked for.
	mismatch := deliveriesLineWith(t, stdout, "ROW MISMATCH")
	if !strings.Contains(mismatch, shortSha(query)) {
		t.Fatalf("the row mismatch does not name the requested sha %s: %q", shortSha(query), mismatch)
	}
}

// TestCloudDeliveriesRowShaMatchIsQuietAndStillTheRecordsOwn: on a CONSISTENT
// page the row sha line still reads d.SHA (the fixture's own value) and no
// mismatch of either kind is printed — the loud words are reserved for
// disagreement, so they cannot become wallpaper.
func TestCloudDeliveriesRowShaMatchIsQuietAndStillTheRecordsOwn(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "fully_clocked")
	newDeliveriesServer(t, status, body)

	const sha = "2e38228b0048901b166d915d222cfc47f6f470d6"
	stdout, _, code := runDeliveries(t, "table", sha)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "sha "+sha+" — the record's OWN sha for this row") {
		t.Fatalf("row block does not open with the record's own sha:\n%s", stdout)
	}
	if strings.Contains(stdout, "MISMATCH") {
		t.Fatalf("a consistent page must not print MISMATCH:\n%s", stdout)
	}
}

// TestCloudDeliveriesFilterEchoIsRendered: page.SHA (the echoed normalised
// filter) and page.Limit stop being decoded-and-dropped (dr-w27-bl). Three
// states, each its own sentence: the echo confirms the query, the echo is
// absent (null — an older control plane, or an unfiltered read), or the echo
// DISAGREES with the query, which means the page answers a different question
// and must say so loudly.
func TestCloudDeliveriesFilterEchoIsRendered(t *testing.T) {
	const query = "2e38228b0048901b166d915d222cfc47f6f470d6"
	empty := `"deliveries":[],"count":0`

	t.Run("echo confirms the query and the limit is named", func(t *testing.T) {
		newDeliveriesServer(t, 200, `{`+empty+`,"sha":"`+query+`","limit":50,"scope":"platform"}`)
		stdout, _, code := runDeliveries(t, "table", query)
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\n%s", code, stdout)
		}
		line := deliveriesLineWith(t, stdout, "filter echoed")
		if !strings.Contains(line, query) {
			t.Fatalf("the echo line does not carry the confirmed sha: %q", line)
		}
		if !strings.Contains(line, "page limit 50") {
			t.Fatalf("page.Limit is still decoded-and-dropped: %q", line)
		}
	})

	t.Run("a null echo renders as NOT ECHOED, never omitted", func(t *testing.T) {
		newDeliveriesServer(t, 200, `{`+empty+`,"sha":null,"limit":0,"scope":"platform"}`)
		stdout, _, code := runDeliveries(t, "table", query)
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\n%s", code, stdout)
		}
		if !strings.Contains(stdout, "filter NOT ECHOED") {
			t.Fatalf("a null echo must render as NOT ECHOED:\n%s", stdout)
		}
		if !strings.Contains(stdout, "page limit NOT NAMED") {
			t.Fatalf("a zero limit must render as NOT NAMED, never dropped:\n%s", stdout)
		}
	})

	t.Run("an echo that disagrees with the query is a loud mismatch", func(t *testing.T) {
		newDeliveriesServer(t, 200, `{`+empty+`,"sha":"beefbeefbeefbeefbeefbeefbeefbeefbeefbeef","limit":50,"scope":"platform"}`)
		stdout, _, code := runDeliveries(t, "table", query)
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\n%s", code, stdout)
		}
		line := deliveriesLineWith(t, stdout, "FILTER MISMATCH")
		if !strings.Contains(line, shortSha(query)) || !strings.Contains(stdout, "beefbeef") {
			t.Fatalf("the filter mismatch must name BOTH shas:\nline: %q\n%s", line, stdout)
		}
	})
}

// TestPlatformDeliveriesFixtureRowsCarryExactlyTheLiveKeySet holds every
// scenario row to the fixture's declared live_key_set — EXACTLY, in both
// directions. A serializer that adds a key without moving this file reds here,
// and a row that drops one (a reader deciding for itself what a NULL means) reds
// here too.
func TestPlatformDeliveriesFixtureRowsCarryExactlyTheLiveKeySet(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	want := append([]string(nil), fx.LiveKeySet...)
	sort.Strings(want)
	if len(want) != 15 {
		t.Fatalf("live_key_set has %d keys, want the 15 PlatformDelivery.to_json/1 emits "+
			"(10 until #10942 added queued_self/pickup/stall_seconds, 13 until #11078 added previous_sha "+
			"and transition — the rollback verdict; all are LIVE, none are pending)", len(want))
	}

	rows := 0
	for name, sc := range fx.Scenarios {
		if sc.Status != 200 {
			continue
		}
		var env struct {
			Deliveries []map[string]json.RawMessage `json:"deliveries"`
		}
		if err := json.Unmarshal(sc.Body, &env); err != nil {
			t.Fatalf("%s: decode body: %v", name, err)
		}
		for i, row := range env.Deliveries {
			rows++
			got := make([]string, 0, len(row))
			for k := range row {
				got = append(got, k)
			}
			sort.Strings(got)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("%s row %d key set:\n got: %v\nwant: %v", name, i, got, want)
			}
		}
	}
	if rows == 0 {
		t.Fatal("no scenario carried a delivery row — this test would pass vacuously")
	}
}

// TestPlatformDeliveriesTheQueueSplitIsLiveAndSitsBesideTheTotal replaces the
// old TestPlatformDeliveriesPendingKeySetDeltaIsExactlyTheThreeQueuedColumns,
// which asserted that a `pending_key_set_after_10942` block differed from the
// live set by exactly the three queue columns.
//
// THAT TEST IS DELETED BECAUSE ITS PREDICTION LANDED. #10942 merged on
// 2026-08-08 and to_json/1 emits all three columns today, so the pending block
// had become a second, permanently-satisfied copy of live_key_set: a test no
// future change could ever red, sitting in the file looking like coverage. A
// prediction that has come true is not evidence.
//
// What is worth asserting now is the SHAPE the split has to keep: three columns
// present, and `queued_seconds` still there BESIDE them. The split decomposes
// the total; it does not replace it, and a serializer that dropped the total
// while keeping the buckets would leave a reader with three numbers and no way
// to know whether they were all of the wait.
func TestPlatformDeliveriesTheQueueSplitIsLiveAndSitsBesideTheTotal(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	live := map[string]bool{}
	for _, k := range fx.LiveKeySet {
		live[k] = true
	}
	for _, k := range []string{
		"queued_seconds",
		"queued_self_seconds",
		"queued_pickup_seconds",
		"queued_stall_seconds",
	} {
		if !live[k] {
			t.Fatalf("`%s` is missing from live_key_set — the split is three columns BESIDE the total, never instead of it", k)
		}
	}
	if len(fx.PendingKeySetRaw) != 0 {
		t.Fatal("`pending_key_set_after_10942` is back in the fixture — #10942 MERGED, so that prediction is now a " +
			"permanently-green duplicate of live_key_set. Move the shape into live_key_set instead of predicting it again.")
	}
}

// TestPlatformDeliveriesFixtureNullClockKeysAreTheNullableOnes: the fixture's
// own statement of which keys may be NULL matches the ones the all_null_clocks
// scenario actually nulls, and the not-null keys are never null anywhere. A
// fixture that documents one law and demonstrates another is worse than none.
func TestPlatformDeliveriesFixtureNullClockKeysAreTheNullableOnes(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	_, body := deliveriesScenario(t, fx, "all_null_clocks")
	var env struct {
		Deliveries []map[string]json.RawMessage `json:"deliveries"`
	}
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("decode all_null_clocks: %v", err)
	}
	if len(env.Deliveries) != 1 {
		t.Fatalf("all_null_clocks carries %d rows, want 1", len(env.Deliveries))
	}
	row := env.Deliveries[0]
	for _, k := range fx.NullClocks.Keys {
		if string(row[k]) != "null" {
			t.Fatalf("all_null_clocks.%s = %s, want null", k, row[k])
		}
	}
	for _, k := range fx.NullClocks.NotNull {
		if string(row[k]) == "null" {
			t.Fatalf("%s is declared NOT NULL and is null in all_null_clocks", k)
		}
	}
	if len(fx.NullClocks.Keys) != 7 {
		t.Fatalf("null_clocks.keys has %d entries, want the 7 nullable clocks "+
			"(the original four plus the three queue-split columns #10942 added)", len(fx.NullClocks.Keys))
	}

	// `carried` IS NULLABLE AND MUST NOT BE FILED UNDER not_null. It is a
	// boolean, not a clock, so it lives in its own bucket — but a fixture that
	// swore it was never null could not carry the carried_unrecorded scenario at
	// all, and the reader's third state would have nothing to render from.
	if !reflect.DeepEqual(fx.NullClocks.NullableBoolean, []string{"carried"}) {
		t.Fatalf("null_clocks.nullable_boolean = %v, want exactly [carried] — the schema declares it with NO DEFAULT (D422) "+
			"so an unrecorded value stays null all the way to the wire", fx.NullClocks.NullableBoolean)
	}
	for _, k := range fx.NullClocks.NotNull {
		if k == "carried" {
			t.Fatal("`carried` is listed NOT NULL — it is the one field whose null the whole reader exists to render")
		}
	}
	_, unrecorded := deliveriesScenario(t, fx, "carried_unrecorded")
	var uenv struct {
		Deliveries []map[string]json.RawMessage `json:"deliveries"`
	}
	if err := json.Unmarshal([]byte(unrecorded), &uenv); err != nil {
		t.Fatalf("decode carried_unrecorded: %v", err)
	}
	if len(uenv.Deliveries) != 1 || string(uenv.Deliveries[0]["carried"]) != "null" {
		t.Fatalf("carried_unrecorded must carry exactly one row whose `carried` is null, got %v", uenv.Deliveries)
	}
}

// ---------------------------------------------------------------------------
// the per-struct pins the file-global go-tag floor cannot make
// ---------------------------------------------------------------------------

// TestDeliveriesPageDeclaresCountAndScopeOnItself is the D260-shaped pin, and it
// exists because the Elixir census's @go_tag_floor is provably blind here: it
// unions json tag NAMES across the whole of internal/cloudclient, and BOTH
// `count` and `scope` are already declared there by unrelated structs. Either
// field could vanish from DeliveriesPage and the floor would stay green while
// the CLI decoded nothing — "0 deliveries recorded" for a page that carried
// rows, and a population line claiming a scope nobody sent.
//
// Reflection, not a source scan: it asserts the tag on the struct that actually
// decodes the wire.
func TestDeliveriesPageDeclaresCountAndScopeOnItself(t *testing.T) {
	tags := structJSONTags(reflect.TypeOf(cloudclient.DeliveriesPage{}))
	for _, key := range []string{"count", "scope", "deliveries", "sha", "limit"} {
		if !tags[key] {
			t.Fatalf("`%s` is on the /v1/deliveries envelope but is NOT a json tag on DeliveriesPage itself — "+
				"the file-global @go_tag_floor cannot catch this: it unions tag names across the whole package, "+
				"so an unrelated struct declaring the same name greens it silently", key)
		}
	}
}

// TestPlatformDeliveryDeclaresEveryLiveKeyOnItself is the same pin for the ROW:
// all thirteen wire keys must be tags on PlatformDelivery, and the seven
// nullable clocks must be POINTERS — an int/string there would decode NULL as 0
// or "", which is the exact lie the record exists to prevent.
//
// IT DELIBERATELY DOES NOT ALSO PIN `carried`'s POINTER-NESS. That field's proof
// is a RENDERED-BYTES assertion (TestCloudDeliveriesCarriedUnrecordedIsItsOwnState),
// which is the stronger of the two: it holds what a human actually reads, not
// what the type happens to be. Asserting the type here as well would give the
// slice's mutation proof two reds instead of one and make the count stop meaning
// anything — the point of the count is that ONE named test carries the state.
func TestPlatformDeliveryDeclaresEveryLiveKeyOnItself(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	rt := reflect.TypeOf(cloudclient.PlatformDelivery{})
	tags := structJSONTags(rt)
	for _, key := range fx.LiveKeySet {
		if !tags[key] {
			t.Fatalf("`%s` is emitted by PlatformDelivery.to_json/1 and is NOT a json tag on PlatformDelivery itself", key)
		}
	}

	byTag := map[string]reflect.StructField{}
	for i := 0; i < rt.NumField(); i++ {
		f := rt.Field(i)
		if name := strings.Split(f.Tag.Get("json"), ",")[0]; name != "" && name != "-" {
			byTag[name] = f
		}
	}
	for _, key := range fx.NullClocks.Keys {
		f, has := byTag[key]
		if !has {
			t.Fatalf("nullable clock %q has no field on PlatformDelivery", key)
		}
		if f.Type.Kind() != reflect.Ptr {
			t.Fatalf("%s is %s, want a pointer — nil is UNMETERED and a zero value would render it as 0 or the epoch", key, f.Type)
		}
	}
}

// structJSONTags collects the json tag NAMES a struct declares on itself.
func structJSONTags(rt reflect.Type) map[string]bool {
	tags := map[string]bool{}
	for i := 0; i < rt.NumField(); i++ {
		name := strings.Split(rt.Field(i).Tag.Get("json"), ",")[0]
		if name != "" && name != "-" {
			tags[name] = true
		}
	}
	return tags
}

// deliveriesLineWith returns the single rendered line containing needle.
func deliveriesLineWith(t *testing.T, stdout, needle string) string {
	t.Helper()
	for _, line := range strings.Split(stdout, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	t.Fatalf("no rendered line contains %q:\n%s", needle, stdout)
	return ""
}

// ---------------------------------------------------------------------------
// the credential (task-e2acb66e9ed0da09)
// ---------------------------------------------------------------------------

// TestCloudDeliveriesSendsTheBearerItWasGiven: `bp cloud deliveries <sha>` works
// for the WORKER principal, and the reason it does is that the client is
// credential-AGNOSTIC — it sends `c.Token` verbatim and makes no judgement about
// which of the three kinds (session / PAT / worker) it holds.
//
// This is the CLI half of the row. The 401 that made the verb dark for every CI
// caller was decided in the control plane's router, not here: GET /v1/deliveries
// was gated `require_user_or_pat`, which resolves a session or a PAT and nothing
// else, so the faceless WORKER_TOKEN that deploy.yml's crown step carries — the
// only credential that WRITES these rows — landed on `unauthorized/1`. The route
// now takes `require_user_or_pat_or_worker` (cloud/lib/barkpark_cloud/web/
// auth.ex), and the whole CLI-side requirement is that nothing in this transport
// rewrites, filters or drops the bearer on the way out.
//
// So the assertion is the WIRE, not a stub's opinion: a worker-shaped token
// arrives at the route byte-for-byte, and a 200 renders the record. If anyone
// ever teaches this client to "validate" or reshape the credential — the obvious
// tempting shape being "reject anything that does not look like a session" — the
// verb goes dark again for the exact principal the row exists to serve, and this
// reds.
func TestCloudDeliveriesSendsTheBearerItWasGiven(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	status, body := deliveriesScenario(t, fx, "two_rows_one_sha")

	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)

	// A worker-shaped credential, deliberately unlike the `sess-` prefix every
	// other test in this file seeds: nothing here may key on its SHAPE.
	const workerToken = "wrk_9f3c2b7ae15d40c8b6a1e07d3c5f8e42"
	withTempConfigHome(t)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: workerToken}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	stdout, stderr, code := runDeliveries(t, "table", "4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c")
	if code != exitOK {
		t.Fatalf("`bp cloud deliveries` exit = %d, want 0 for the WORKER principal\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if gotAuth != "Bearer "+workerToken {
		t.Fatalf("the client did not send the bearer it was given.\n got: %q\nwant: %q\nA client that reshapes the credential re-darkens `bp cloud deliveries` for the WORKER principal — the one deploy.yml carries and the only one that WRITES these rows.", gotAuth, "Bearer "+workerToken)
	}
	// And the read actually rendered — an admitted credential that prints nothing
	// is not a working read path.
	if !strings.Contains(stdout, "2 deliveries recorded") {
		t.Fatalf("the worker-credentialed read rendered no record:\n%s", stdout)
	}
}

// TestCloudDeliveriesRouteAcceptsTheWorkerPrincipal pins the CONTROL-PLANE half
// from the Go side, read out of the router source, so the two languages cannot
// drift: if the guard on GET /v1/deliveries is ever narrowed back to
// `require_user_or_pat`, the verb above keeps passing against its own fake server
// while the real route 401s the worker again — the exact silent regression
// task-e2acb66e9ed0da09 closed.
func TestCloudDeliveriesRouteAcceptsTheWorkerPrincipal(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "cloud", "lib", "barkpark_cloud", "web", "router.ex"))
	if err != nil {
		t.Fatalf("read router.ex: %v", err)
	}
	i := strings.Index(string(src), `get "/v1/deliveries" do`)
	if i < 0 {
		t.Fatalf(`router.ex no longer declares get "/v1/deliveries" — this pin has gone vacuous`)
	}
	// The guard is the first line of the block; take a short, bounded window so a
	// later route's guard can never be borrowed.
	window := string(src)[i:min(i+300, len(string(src)))]
	if !strings.Contains(window, "Auth.require_user_or_pat_or_worker") {
		t.Fatalf("GET /v1/deliveries is not gated by Auth.require_user_or_pat_or_worker, so it answers HTTP 401 to the WORKER principal and `bp cloud deliveries <sha>` is dark for every CI caller. Guard window:\n%s", window)
	}
	// PAT reachability (D385/D412) must be PRESERVED, not replaced: the read
	// ability gate is what keeps a PAT in the door.
	if !strings.Contains(window, `Auth.require_ability("read")`) {
		t.Fatalf("GET /v1/deliveries lost its read-ability gate; D385/D412 PAT reachability is not preserved. Guard window:\n%s", window)
	}
}
