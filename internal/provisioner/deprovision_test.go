package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// fakeDeprovisionControlPlane is an httptest-backed stand-in for the Elixir
// control plane's internal DEPROVISION-jobs endpoints. It serves one queued spec
// on claim (then 204 once drained) and records the succeed/fail report — the
// deprovision-queue twin of fakeControlPlane, so the worker test double-checks the
// Remove wire shape the Elixir side must match.
type fakeDeprovisionControlPlane struct {
	mu sync.Mutex

	spec *DeprovisionSpec // served on the next claim; nil → 204

	claimCount   int
	claimAuth    string
	succeededID  string
	succeedAuth  string
	succeedCalls int
	failedID     string
	failedError  string
	failAuth     string
	failCalls    int
	// claim-fence (bp-c55): the claim_token echoed on each transition + the raw
	// bodies, so a test can assert both presence (right token) and absence.
	succeededClaimToken string
	succeededRawBody    []byte
	failedClaimToken    string
	failedRawBody       []byte
}

func (f *fakeDeprovisionControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/internal/deprovision-jobs/claim", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.claimCount++
		f.claimAuth = r.Header.Get("Authorization")
		if f.spec == nil {
			w.WriteHeader(http.StatusNoContent) // 204 — nothing pending
			return
		}
		// 200 {job_id, ip, dns_label, dns_zone}
		_ = json.NewEncoder(w).Encode(f.spec)
		f.spec = nil // serve it once; subsequent claims are 204
	})

	// /v1/internal/deprovision-jobs/:id/succeed and /fail — route on the trailing verb.
	mux.HandleFunc("/v1/internal/deprovision-jobs/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		id, verb := parseDeprovisionJobPath(r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)

		switch verb {
		case "succeed":
			f.succeedCalls++
			f.succeededID = id
			f.succeededClaimToken = payload["claim_token"]
			f.succeededRawBody = body
			f.succeedAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case "fail":
			f.failCalls++
			f.failedID = id
			f.failedError = payload["error"]
			f.failedClaimToken = payload["claim_token"]
			f.failedRawBody = body
			f.failAuth = r.Header.Get("Authorization")
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})

	return mux
}

// parseDeprovisionJobPath splits /v1/internal/deprovision-jobs/<id>/<verb>.
func parseDeprovisionJobPath(p string) (id, verb string) {
	const prefix = "/v1/internal/deprovision-jobs/"
	rest := p[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i], rest[i+1:]
		}
	}
	return rest, ""
}

// TestRunOnceDeprovisionClaimsRunsAndSucceeds is the happy Remove path: the
// control plane hands back a deprovision spec → the worker runs the injected
// Deprovision with EXACTLY that spec → POSTs succeed with the Bearer WORKER_TOKEN.
// Asserts the spec reached Deprovision intact and that succeed (not fail) was sent.
func TestRunOnceDeprovisionClaimsRunsAndSucceeds(t *testing.T) {
	cp := &fakeDeprovisionControlPlane{
		spec: &DeprovisionSpec{JobID: "dejob-1", IP: "203.0.113.7", DNSLabel: "acme-abc", DNSZone: "barkpark.cloud"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	var got DeprovisionSpec
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Deprovision: func(_ context.Context, spec DeprovisionSpec) error {
			got = spec
			return nil
		},
	}

	claimed, err := w.RunOnceDeprovision(context.Background())
	if err != nil {
		t.Fatalf("RunOnceDeprovision: %v", err)
	}
	if !claimed {
		t.Fatal("RunOnceDeprovision claimed=false, want true (a deprovision job was queued)")
	}

	// ── the spec reached Deprovision intact ──
	if got.JobID != "dejob-1" || got.IP != "203.0.113.7" || got.DNSLabel != "acme-abc" || got.DNSZone != "barkpark.cloud" {
		t.Errorf("Deprovision got %+v, want the queued spec", got)
	}
	// ── claim carried the Bearer WORKER_TOKEN ──
	if cp.claimAuth != "Bearer "+testToken {
		t.Errorf("claim Authorization = %q, want Bearer %s", cp.claimAuth, testToken)
	}
	// ── succeed was POSTed with the right id + auth; fail was NOT called ──
	if cp.succeededID != "dejob-1" {
		t.Errorf("succeed job id = %q, want dejob-1", cp.succeededID)
	}
	if cp.succeedAuth != "Bearer "+testToken {
		t.Errorf("succeed Authorization = %q, want Bearer %s", cp.succeedAuth, testToken)
	}
	if cp.failedID != "" {
		t.Errorf("fail was called (id=%q) on the happy path, want none", cp.failedID)
	}
}

// TestRunOnceDeprovisionEmptyQueueNoCall proves a 204 claim is a clean no-op: the
// injected Deprovision never runs, no report is posted, claimed=false, no error.
func TestRunOnceDeprovisionEmptyQueueNoCall(t *testing.T) {
	cp := &fakeDeprovisionControlPlane{spec: nil} // 204 on claim
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	calls := 0
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Deprovision: func(context.Context, DeprovisionSpec) error {
			calls++
			return nil
		},
	}

	claimed, err := w.RunOnceDeprovision(context.Background())
	if err != nil {
		t.Fatalf("RunOnceDeprovision: %v", err)
	}
	if claimed {
		t.Error("RunOnceDeprovision claimed=true on a 204, want false")
	}
	if calls != 0 {
		t.Errorf("Deprovision ran %d times on an empty queue, want 0", calls)
	}
	if cp.succeededID != "" || cp.failedID != "" {
		t.Errorf("a report was posted on an empty queue: succeed=%q fail=%q", cp.succeededID, cp.failedID)
	}
}

// TestRunOnceDeprovisionErrorReportsFail proves a deletion FAILURE is reported to
// /fail with the error message (not /succeed), the cycle still counts as a handled
// claim, and RunOnceDeprovision does NOT propagate that as an error (the box stays
// for a retry, the dashboard shows a failed removal).
func TestRunOnceDeprovisionErrorReportsFail(t *testing.T) {
	cp := &fakeDeprovisionControlPlane{
		spec: &DeprovisionSpec{JobID: "dejob-2", IP: "203.0.113.8", DNSLabel: "boom-abc", DNSZone: "barkpark.cloud"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Deprovision: func(context.Context, DeprovisionSpec) error {
			return errBoom
		},
	}

	claimed, err := w.RunOnceDeprovision(context.Background())
	if err != nil {
		t.Fatalf("RunOnceDeprovision returned an error for a delete failure, want nil (reported to /fail): %v", err)
	}
	if !claimed {
		t.Error("RunOnceDeprovision claimed=false, want true (the job was drained even though it failed)")
	}

	if cp.failedID != "dejob-2" {
		t.Errorf("fail job id = %q, want dejob-2", cp.failedID)
	}
	if cp.failedError != errBoom.Error() {
		t.Errorf("fail error = %q, want %q", cp.failedError, errBoom.Error())
	}
	if cp.failAuth != "Bearer "+testToken {
		t.Errorf("fail Authorization = %q, want Bearer %s", cp.failAuth, testToken)
	}
	if cp.succeededID != "" {
		t.Errorf("succeed was called (id=%q) on a delete failure, want none", cp.succeededID)
	}
}

// TestRunOnceDeprovisionEchoesClaimToken (claim-fence bp-c55) proves the
// deprovision succeed/fail transitions echo the claim_token from the deprovision
// claim, and that a token-less claim (pre-Stage-1 CP) produces no claim_token key.
func TestRunOnceDeprovisionEchoesClaimToken(t *testing.T) {
	const deClaimToken = "ct-deprov-xyz"
	for _, tc := range []struct {
		name   string
		token  string
		failIt bool
	}{
		{"succeed with token", deClaimToken, false},
		{"succeed without token", "", false},
		{"fail with token", deClaimToken, true},
		{"fail without token", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cp := &fakeDeprovisionControlPlane{
				spec: &DeprovisionSpec{JobID: "dejob-1", ClaimToken: tc.token, IP: "203.0.113.7", DNSLabel: "acme-abc", DNSZone: "barkpark.cloud"},
			}
			srv := httptest.NewServer(cp.handler())
			defer srv.Close()

			w := &Worker{
				ControlURL: srv.URL,
				Token:      testToken,
				HTTPClient: srv.Client(),
				Deprovision: func(context.Context, DeprovisionSpec) error {
					if tc.failIt {
						return errBoom
					}
					return nil
				},
			}

			if _, err := w.RunOnceDeprovision(context.Background()); err != nil {
				t.Fatalf("RunOnceDeprovision: %v", err)
			}

			gotToken := cp.succeededClaimToken
			rawBody := cp.succeededRawBody
			if tc.failIt {
				gotToken = cp.failedClaimToken
				rawBody = cp.failedRawBody
			}
			if gotToken != tc.token {
				t.Errorf("echoed claim_token = %q, want %q", gotToken, tc.token)
			}
			if tc.token == "" && strings.Contains(string(rawBody), "claim_token") {
				t.Errorf("body carried a claim_token key with no claim token: %s", rawBody)
			}
		})
	}
}

// attachThenDeprovisionFixture wires the REAL attach → deprovision chain against
// one shared fake zone: a managed box carrying its barkpark-fqdn identity label,
// its platform A record as the go-live chain wrote it, and the seams both
// AttachDomainWith and DeprovisionWith run through. Nothing is stubbed between
// the two — the custom-domain record under test is written by the production
// attach path, not seeded by the test.
func attachThenDeprovisionFixture(t *testing.T) (Seams, *cloud.FakeProvider, *cloud.FakeDNS, cloud.Server) {
	t.Helper()
	ctx := context.Background()

	prov := cloud.NewFakeProvider()
	box, err := prov.Create(ctx, cloud.ServerSpec{Name: "bp-acme-t1-abc123"})
	if err != nil {
		t.Fatalf("create box: %v", err)
	}
	if err := prov.LabelServer(ctx, box.Name, cloud.FQDNLabelKey, "acme-t1."+Zone); err != nil {
		t.Fatalf("label box: %v", err)
	}

	dns := cloud.NewFakeDNS()
	if err := dns.UpsertRecord(ctx, cloud.Record{Zone: Zone, Name: "acme-t1", Type: "A", Value: box.IP}); err != nil {
		t.Fatalf("seed platform record: %v", err)
	}

	seams := Seams{
		Provider:  prov,
		DNS:       dns,
		RunnerFor: func(string) cloud.StepRunner { return &recordingAttachRunner{} },
	}
	return seams, prov, dns, box
}

// zoneNames returns the fake zone's records as sorted "name=value" lines — the
// BEFORE/AFTER census the orphan assertions read.
func zoneNames(t *testing.T, dns *cloud.FakeDNS, zone string) []string {
	t.Helper()
	recs, err := dns.ListRecords(context.Background(), zone)
	if err != nil {
		t.Fatalf("list zone %s: %v", zone, err)
	}
	names := []string{}
	for _, r := range recs {
		names = append(names, r.Name+"="+r.Value)
	}
	sort.Strings(names)
	return names
}

// TestDeprovisionSweepsAttachedCustomDomainRecord is the orphan guard, driven
// end to end through the REAL chain: AttachDomainWith upserts a SECOND A record
// (the customer's custom host) into the platform zone at the box's IP, then
// DeprovisionWith runs with the EXACT claim payload the control plane emits —
// which carries the PLATFORM dns_label only, never the custom host.
//
// The by-name delete this replaced released the box and left
// gyldendal.barkpark.cloud pointing at an address about to be recycled, with the
// registry row (the only place custom_host lived) deleted right after, so the
// leftover record was attributable to nothing. The sweep goes by VALUE, so BOTH
// names die with the box and the zone is left empty.
func TestDeprovisionSweepsAttachedCustomDomainRecord(t *testing.T) {
	ctx := context.Background()
	seams, prov, dns, box := attachThenDeprovisionFixture(t)

	if err := AttachDomainWith(ctx, seams, AttachDomainSpec{
		JobID:      "adjob-1",
		IP:         box.IP,
		CustomHost: "gyldendal." + Zone,
		DNSLabel:   "gyldendal",
		DNSZone:    Zone,
		AppPort:    4000,
	}); err != nil {
		t.Fatalf("AttachDomainWith: %v", err)
	}

	before := zoneNames(t, dns, Zone)
	if len(before) != 2 {
		t.Fatalf("BEFORE deprovision the zone holds %v, want both the platform and the custom-host record", before)
	}
	t.Logf("BEFORE deprovision: %v", before)

	if err := DeprovisionWith(ctx, seams, DeprovisionSpec{
		JobID:    "dejob-1",
		IP:       box.IP,
		DNSLabel: "acme-t1", // the platform label — the ONLY DNS the claim carries
		DNSZone:  Zone,
	}); err != nil {
		t.Fatalf("DeprovisionWith: %v", err)
	}

	after := zoneNames(t, dns, Zone)
	t.Logf("AFTER deprovision: %v", after)
	if len(after) != 0 {
		t.Errorf("records survived the deprovision pointing at the released IP %s: %v — a custom-domain orphan", box.IP, after)
	}
	if vals, _ := dns.Resolve(ctx, "gyldendal."+Zone); len(vals) != 0 {
		t.Errorf("the ATTACHED custom-domain record outlived the box: gyldendal.%s → %v", Zone, vals)
	}
	if vals, _ := dns.Resolve(ctx, "acme-t1."+Zone); len(vals) != 0 {
		t.Errorf("the platform record outlived the box: acme-t1.%s → %v", Zone, vals)
	}

	remaining, _ := prov.List(ctx)
	if len(remaining) != 0 {
		t.Errorf("managed servers remaining = %d, want 0", len(remaining))
	}
}

// TestDeprovisionSweepsRecordAtIPTheClaimNeverNamed asserts the tradeoff rather
// than assuming it: the sweep removes EVERY A record in the zone that points at
// the released IP — including one no claim payload ever mentioned (a re-attach
// that overwrote custom_host on a live box strands exactly this shape). It is a
// WIDER delete than a by-name delete, and that is the decision. It stays SCOPED
// to the released address: a record at another IP is untouched.
func TestDeprovisionSweepsRecordAtIPTheClaimNeverNamed(t *testing.T) {
	ctx := context.Background()
	seams, _, dns, box := attachThenDeprovisionFixture(t)

	if err := dns.UpsertRecord(ctx, cloud.Record{Zone: Zone, Name: "forgotten", Type: "A", Value: box.IP}); err != nil {
		t.Fatalf("seed forgotten record: %v", err)
	}
	if err := dns.UpsertRecord(ctx, cloud.Record{Zone: Zone, Name: "neighbour", Type: "A", Value: "203.0.113.77"}); err != nil {
		t.Fatalf("seed neighbour record: %v", err)
	}

	if err := DeprovisionWith(ctx, seams, DeprovisionSpec{
		JobID: "dejob-2", IP: box.IP, DNSLabel: "acme-t1", DNSZone: Zone,
	}); err != nil {
		t.Fatalf("DeprovisionWith: %v", err)
	}

	if vals, _ := dns.Resolve(ctx, "forgotten."+Zone); len(vals) != 0 {
		t.Errorf("an unclaimed record at the released IP survived: forgotten.%s → %v", Zone, vals)
	}
	if vals, _ := dns.Resolve(ctx, "neighbour."+Zone); len(vals) != 1 {
		t.Errorf("the sweep took a record at ANOTHER address: neighbour.%s → %v, want it untouched", Zone, vals)
	}
}

// TestDeprovisionDeletesDriftedPlatformRecordByName covers the sweep's blind
// spot honestly: a platform record whose value has drifted off the box IP is
// invisible to a by-value sweep, so the by-name delete still runs behind it —
// the label must never outlive the box it names.
func TestDeprovisionDeletesDriftedPlatformRecordByName(t *testing.T) {
	ctx := context.Background()
	seams, _, dns, box := attachThenDeprovisionFixture(t)

	if err := dns.UpsertRecord(ctx, cloud.Record{Zone: Zone, Name: "acme-t1", Type: "A", Value: "203.0.113.55"}); err != nil {
		t.Fatalf("drift platform record: %v", err)
	}

	if err := DeprovisionWith(ctx, seams, DeprovisionSpec{
		JobID: "dejob-3", IP: box.IP, DNSLabel: "acme-t1", DNSZone: Zone,
	}); err != nil {
		t.Fatalf("DeprovisionWith: %v", err)
	}
	if vals, _ := dns.Resolve(ctx, "acme-t1."+Zone); len(vals) != 0 {
		t.Errorf("a drifted platform record outlived the box: acme-t1.%s → %v", Zone, vals)
	}
}

// TestAttachExternalHostWritesNothingIntoPlatformZone is the scope probe for the
// V2 EXTERNAL arm: an arbitrary customer-owned FQDN is attached by RESOLUTION
// (the customer owns that zone), so the attach writes ZERO records into the
// platform zone. Whatever dangles after a decommission lives in the CUSTOMER's
// zone, is not ours to delete, and is a COPY problem — out of this sweep's scope
// by construction rather than by assumption.
func TestAttachExternalHostWritesNothingIntoPlatformZone(t *testing.T) {
	ctx := context.Background()
	seams, _, dns, box := attachThenDeprovisionFixture(t)
	seams.LookupHost = func(context.Context, string) ([]string, error) { return []string{box.IP}, nil }

	before := zoneNames(t, dns, Zone)
	if err := AttachDomainWith(ctx, seams, AttachDomainSpec{
		JobID:      "adjob-ext",
		IP:         box.IP,
		CustomHost: "barkpark.jarl.no",
		AppPort:    4000, // an external host carries EMPTY platform DNS halves
	}); err != nil {
		t.Fatalf("AttachDomainWith (external): %v", err)
	}
	after := zoneNames(t, dns, Zone)
	t.Logf("platform zone before external attach: %v; after: %v", before, after)
	if len(after) != len(before) {
		t.Errorf("an EXTERNAL attach wrote into the platform zone: before=%v after=%v", before, after)
	}
	if vals, _ := dns.Resolve(ctx, "barkpark.jarl.no"); len(vals) != 0 {
		t.Errorf("an EXTERNAL attach created a platform record for barkpark.jarl.no → %v", vals)
	}
}
