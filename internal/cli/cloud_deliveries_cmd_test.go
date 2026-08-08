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
	PendingKeySet  []string `json:"pending_key_set_after_10942"`
	EnvelopeKeySet []string `json:"envelope_key_set"`
	NullClocks     struct {
		Keys    []string `json:"keys"`
		NotNull []string `json:"not_null"`
	} `json:"null_clocks"`
	Scenarios map[string]struct {
		Why    string          `json:"why"`
		Status int             `json:"status"`
		Body   json.RawMessage `json:"body"`
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
		t.Fatalf("fixture has no scenario %q — the five named scenarios are the contract", name)
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
	for _, label := range []string{"merged", "waited", "built", "serving"} {
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
	for _, name := range []string{"fully_clocked", "all_null_clocks", "carried", "unknown_sha_empty"} {
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

// ---------------------------------------------------------------------------
// the fixture's key sets
// ---------------------------------------------------------------------------

// TestPlatformDeliveriesFixtureRowsCarryExactlyTheLiveKeySet holds every
// scenario row to the fixture's declared live_key_set — EXACTLY, in both
// directions. A serializer that adds a key without moving this file reds here,
// and a row that drops one (a reader deciding for itself what a NULL means) reds
// here too.
func TestPlatformDeliveriesFixtureRowsCarryExactlyTheLiveKeySet(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	want := append([]string(nil), fx.LiveKeySet...)
	sort.Strings(want)
	if len(want) != 10 {
		t.Fatalf("live_key_set has %d keys, want the 10 PlatformDelivery.to_json/1 emits", len(want))
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

// TestPlatformDeliveriesPendingKeySetDeltaIsExactlyTheThreeQueuedColumns: the
// declared post-#10942 shape differs from today's live shape by EXACTLY the
// three nullable queue-split columns (charter D430), with nothing removed. The
// day that PR lands, the fixture and the decoder move together or this reds.
func TestPlatformDeliveriesPendingKeySetDeltaIsExactlyTheThreeQueuedColumns(t *testing.T) {
	fx := loadDeliveriesFixture(t)
	live := map[string]bool{}
	for _, k := range fx.LiveKeySet {
		live[k] = true
	}
	pending := map[string]bool{}
	for _, k := range fx.PendingKeySet {
		pending[k] = true
	}

	var added, removed []string
	for k := range pending {
		if !live[k] {
			added = append(added, k)
		}
	}
	for k := range live {
		if !pending[k] {
			removed = append(removed, k)
		}
	}
	sort.Strings(added)
	sort.Strings(removed)

	want := []string{"queued_pickup_seconds", "queued_self_seconds", "queued_stall_seconds"}
	if !reflect.DeepEqual(added, want) {
		t.Fatalf("pending_key_set_after_10942 adds %v, want exactly %v", added, want)
	}
	if len(removed) != 0 {
		t.Fatalf("pending_key_set_after_10942 REMOVES %v — the split sits BESIDE queued_seconds, it does not replace it", removed)
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
	if len(fx.NullClocks.Keys) != 4 {
		t.Fatalf("null_clocks.keys has %d entries, want the 4 nullable clocks", len(fx.NullClocks.Keys))
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
// all ten wire keys must be tags on PlatformDelivery, and the four nullable
// clocks must be POINTERS — an int/string there would decode NULL as 0 or "",
// which is the exact lie the record exists to prevent.
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
