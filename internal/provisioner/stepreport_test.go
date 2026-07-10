package provisioner

// stepreport_test.go — component tests for the production HTTP step reporter
// (dwb-14). The scenario tests (provision_test.go / verify_test.go) exercise a
// FAKE recorder wired onto Seams.StepReporter, so the real HTTPStepReporter — the
// thing that actually marshals the body, sets the auth header and reads the
// status — had no direct coverage. These tests drive it against an httptest
// control plane so every branch (2xx, detail on/off, no-token, non-2xx, transport
// error, default vs injected client) is proven.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// stepSink is a minimal control plane that records the one step-report POST it
// receives and replies with a configurable status.
type stepSink struct {
	path   string
	auth   string
	ctype  string
	body   map[string]any
	status int // response status to send (0 → 202 Accepted)
	hits   int
}

func (s *stepSink) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.hits++
		s.path = r.URL.Path
		s.auth = r.Header.Get("Authorization")
		s.ctype = r.Header.Get("Content-Type")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &s.body)
		code := s.status
		if code == 0 {
			code = http.StatusAccepted
		}
		w.WriteHeader(code)
		if code >= 400 {
			_, _ = io.WriteString(w, "control plane says no")
		}
	}
}

// TestHTTPStepReporterReport drives Report against a recording control plane: the
// URL carries the job id, the body carries step/status (detail only when set), the
// bearer header rides only a non-empty token, and a non-2xx reply is an error.
func TestHTTPStepReporterReport(t *testing.T) {
	tests := []struct {
		name       string
		token      string
		detail     string
		respStatus int
		wantErr    bool
		wantAuth   string
		wantDetail bool
	}{
		{name: "2xx with detail and token", token: "worker-tok", detail: "phase 3", respStatus: http.StatusAccepted, wantAuth: "Bearer worker-tok", wantDetail: true},
		{name: "2xx no detail omits the detail key", token: "worker-tok", detail: "", respStatus: http.StatusOK, wantAuth: "Bearer worker-tok", wantDetail: false},
		{name: "empty token sends no auth header", token: "", detail: "d", respStatus: http.StatusNoContent, wantAuth: "", wantDetail: true},
		{name: "non-2xx is an error", token: "t", detail: "d", respStatus: http.StatusInternalServerError, wantErr: true, wantAuth: "Bearer t", wantDetail: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			sink := &stepSink{status: tc.respStatus}
			srv := httptest.NewServer(sink.handler())
			defer srv.Close()

			// A trailing slash on ControlURL exercises the TrimRight join.
			r := &HTTPStepReporter{ControlURL: srv.URL + "/", Token: tc.token, HTTPClient: srv.Client()}
			err := r.Report(context.Background(), "job-9", "create", "started", tc.detail)
			if (err != nil) != tc.wantErr {
				t.Fatalf("Report err = %v, wantErr = %v", err, tc.wantErr)
			}
			if sink.hits != 1 {
				t.Fatalf("control plane hits = %d, want 1", sink.hits)
			}
			if want := "/v1/internal/provision-jobs/job-9/step"; sink.path != want {
				t.Fatalf("POST path = %q, want %q", sink.path, want)
			}
			if sink.ctype != "application/json" {
				t.Fatalf("Content-Type = %q, want application/json", sink.ctype)
			}
			if sink.auth != tc.wantAuth {
				t.Fatalf("Authorization = %q, want %q", sink.auth, tc.wantAuth)
			}
			if sink.body["step"] != "create" || sink.body["status"] != "started" {
				t.Fatalf("body step/status mismapped: %+v", sink.body)
			}
			if _, ok := sink.body["detail"]; ok != tc.wantDetail {
				t.Fatalf("detail present = %v, want %v (body=%+v)", ok, tc.wantDetail, sink.body)
			}
		})
	}
}

// TestHTTPStepReporterReportTransportErrorSurfaces: a dead control plane makes
// Do() fail; that transport error is returned raw (never swallowed here — the
// caller decides to log-and-continue).
func TestHTTPStepReporterReportTransportErrorSurfaces(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // now nothing is listening

	r := &HTTPStepReporter{ControlURL: url, Token: "t", HTTPClient: &http.Client{Timeout: 200 * time.Millisecond}}
	if err := r.Report(context.Background(), "j", "s", "st", ""); err == nil {
		t.Fatal("a transport failure must be returned to the caller")
	}
}

// TestHTTPStepReporterHTTPClient: a nil HTTPClient yields a client carrying the
// tight default timeout (never nil); an injected client is returned unchanged.
func TestHTTPStepReporterHTTPClient(t *testing.T) {
	c := (&HTTPStepReporter{}).httpClient()
	if c == nil {
		t.Fatal("httpClient() must never return nil")
	}
	if c.Timeout != defaultStepReportTimeout {
		t.Fatalf("default timeout = %s, want %s", c.Timeout, defaultStepReportTimeout)
	}

	inj := &http.Client{Timeout: time.Hour}
	if got := (&HTTPStepReporter{HTTPClient: inj}).httpClient(); got != inj {
		t.Fatal("an injected HTTPClient must be returned unchanged")
	}
}
