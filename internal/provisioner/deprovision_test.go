package provisioner

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
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
