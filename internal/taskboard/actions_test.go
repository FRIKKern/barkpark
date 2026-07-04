package taskboard

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func testClient(baseURL string) *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: baseURL, Token: "t"})
}

// capture records what the httptest server saw so the test can assert the exact
// request the action layer sent (path + decoded JSON body).
type capture struct {
	path string
	body map[string]interface{}
}

func serve(t *testing.T, status int, respBody string, cap *capture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cap.path = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &cap.body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, respBody)
	}))
}

func TestDoClaim_Success(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusOK, `{"ok":true,"doc":{"claim":{"epoch":4}}}`, &cap)
	defer srv.Close()

	got := DoClaim(testClient(srv.URL), "t1", "tui-mbp")

	if !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if got.Message != "claimed as tui-mbp · epoch 4" {
		t.Errorf("message = %q", got.Message)
	}
	// Exact request assertions: targeted claim path + worker_id body.
	if cap.path != "/v1/tasks/t1/claim" {
		t.Errorf("path = %q", cap.path)
	}
	if cap.body["worker_id"] != "tui-mbp" {
		t.Errorf("worker_id = %v", cap.body["worker_id"])
	}
}

func TestDoClaim_Failures(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		resp    string
		wantMsg string
	}{
		{"resource_conflict", http.StatusConflict, `{"ok":false,"reason":"resource_conflict"}`,
			"claim failed: resource conflict — files held by another task"},
		{"already_claimed", http.StatusConflict, `{"ok":false,"reason":"already_claimed"}`,
			"claim failed: already claimed by another worker"},
		{"stale_claim", http.StatusConflict, `{"ok":false,"reason":"stale_claim"}`,
			"claim failed: claim moved under us (stale)"},
		{"not_ready", http.StatusConflict, `{"ok":false,"reason":"not_ready"}`,
			"claim failed: task is not ready"},
		{"not_found", http.StatusNotFound, `{"ok":false,"reason":"not_found"}`,
			"claim failed: task not found"},
		// ok:true but no fencing epoch → apiclient synthesises an error we pass through verbatim-ish.
		{"no_epoch", http.StatusOK, `{"ok":true,"doc":{"claim":{"epoch":0}}}`,
			"claim failed: claim t1: server returned no fencing epoch"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, tc.status, tc.resp, &cap)
			defer srv.Close()

			got := DoClaim(testClient(srv.URL), "t1", "tui-mbp")
			if got.OK {
				t.Fatalf("expected failure, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
		})
	}
}

func TestDoClaim_NetworkFailure(t *testing.T) {
	srv := serve(t, http.StatusOK, ``, &capture{})
	url := srv.URL
	srv.Close() // now nothing listens — the POST fails at the transport.

	got := DoClaim(testClient(url), "t1", "tui-mbp")
	if got.OK {
		t.Fatalf("expected failure, got %+v", got)
	}
	// Transport errors must arrive SHORT — "server unreachable (connection
	// refused)" — never the raw Go url.Error that spells the whole request.
	if !strings.HasPrefix(got.Message, "claim failed: server unreachable (") {
		t.Errorf("message = %q, want a short server-unreachable message", got.Message)
	}
	if strings.Contains(got.Message, "http://") {
		t.Errorf("message = %q leaks the raw request URL", got.Message)
	}
}

func TestDoClose_Success(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusOK, `{"ok":true,"doc":{}}`, &cap)
	defer srv.Close()

	got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)

	if !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if got.Message != "closed · epoch 4" {
		t.Errorf("message = %q", got.Message)
	}
	if cap.path != "/v1/tasks/t1/close" {
		t.Errorf("path = %q", cap.path)
	}
	// Epoch CAS: the observed epoch the caller held must ride the close body.
	if cap.body["worker_id"] != "tui-mbp" {
		t.Errorf("worker_id = %v", cap.body["worker_id"])
	}
	if cap.body["observed_epoch"] != float64(4) {
		t.Errorf("observed_epoch = %v (want 4)", cap.body["observed_epoch"])
	}
	if cap.body["lifecycle_status"] != "done" {
		t.Errorf("lifecycle_status = %v (want done)", cap.body["lifecycle_status"])
	}
}

func TestDoClose_Failures(t *testing.T) {
	cases := []struct {
		name    string
		resp    string
		wantMsg string
	}{
		{"fenced_off", `{"ok":false,"reason":"fenced_off"}`,
			"close rejected: stale epoch (task moved)"},
		{"stale_claim", `{"ok":false,"reason":"stale_claim"}`,
			"close rejected: claim moved under us (stale)"},
		{"invalid_lifecycle", `{"ok":false,"reason":"invalid_lifecycle:frobnicate"}`,
			"close rejected: invalid_lifecycle:frobnicate"}, // unknown reason → verbatim
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, http.StatusConflict, tc.resp, &cap)
			defer srv.Close()

			got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)
			if got.OK {
				t.Fatalf("expected failure, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
		})
	}
}

func TestDoClose_NetworkFailure(t *testing.T) {
	srv := serve(t, http.StatusOK, ``, &capture{})
	url := srv.URL
	srv.Close()

	got := DoClose(testClient(url), "t1", "tui-mbp", 4)
	if got.OK {
		t.Fatalf("expected failure, got %+v", got)
	}
	if !strings.HasPrefix(got.Message, "close rejected: server unreachable (") {
		t.Errorf("message = %q, want a short server-unreachable message", got.Message)
	}
	if strings.Contains(got.Message, "http://") {
		t.Errorf("message = %q leaks the raw request URL", got.Message)
	}
}

func TestResolveWorker(t *testing.T) {
	t.Run("env override wins", func(t *testing.T) {
		t.Setenv("BARKPARK_WORKER_ID", "opus-3")
		if got := ResolveWorker(); got != "opus-3" {
			t.Errorf("ResolveWorker() = %q, want opus-3", got)
		}
	})
	t.Run("falls back to tui-<hostname>", func(t *testing.T) {
		t.Setenv("BARKPARK_WORKER_ID", "")
		got := ResolveWorker()
		if !strings.HasPrefix(got, "tui-") {
			t.Errorf("ResolveWorker() = %q, want a tui- prefix", got)
		}
		if got == "tui-" {
			t.Errorf("ResolveWorker() = %q, hostname suffix missing", got)
		}
	})
}

func TestStudioTaskURL(t *testing.T) {
	cases := []struct {
		name    string
		baseURL string
		docID   string
		want    string
	}{
		{"http host", "http://localhost:4000", "t1", "http://localhost:4000/studio/production/task/t1"},
		{"https preserved", "https://guerrilla.barkpark.cloud", "abc", "https://guerrilla.barkpark.cloud/studio/production/task/abc"},
		{"trailing slash trimmed", "https://acme.test/", "t1", "https://acme.test/studio/production/task/t1"},
		{"multiple trailing slashes trimmed", "https://acme.test///", "t1", "https://acme.test/studio/production/task/t1"},
		{"draft doc id escaped", "https://acme.test", "drafts.a b", "https://acme.test/studio/production/task/drafts.a%20b"},
		{"slash in doc id escaped", "https://acme.test", "a/b", "https://acme.test/studio/production/task/a%2Fb"},
		{"empty base yields empty", "", "t1", ""},
		{"empty doc id yields empty", "https://acme.test", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := StudioTaskURL(tc.baseURL, tc.docID); got != tc.want {
				t.Errorf("StudioTaskURL(%q, %q) = %q, want %q", tc.baseURL, tc.docID, got, tc.want)
			}
		})
	}
}
