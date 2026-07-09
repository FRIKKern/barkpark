package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// resurrectFakeCP stands up a control plane that only answers POST /v1/resurrect,
// recording the request body so the test can assert what the CLI sent.
func resurrectFakeCP(t *testing.T, status int, resp string) (*httptest.Server, *map[string]any) {
	t.Helper()
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/resurrect" {
			t.Errorf("unexpected request %s %s (resurrect must POST /v1/resurrect only)", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if auth := r.Header.Get("Authorization"); auth != "Bearer wtok" {
			t.Errorf("missing/wrong worker bearer: %q", auth)
		}
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, resp)
	}))
	t.Cleanup(srv.Close)
	return srv, &got
}

// TestResurrectPortablePostsControlPlane proves the azure (portable-only) resurrect
// POSTs /v1/resurrect with {name, provider} and reports the enqueued job.
func TestResurrectPortablePostsControlPlane(t *testing.T) {
	srv, got := resurrectFakeCP(t, http.StatusAccepted,
		`{"job_id":"job-42","status":"queued","bundle":"bundles/newest.tar.zst","follow_url":"https://barkpark.cloud/new/job-42"}`)

	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud",
		"--provider", "azure",
		"--control-url", srv.URL, "--worker-token", "wtok")
	if code != 0 {
		t.Fatalf("resurrect exited %d, stderr: %s", code, stderr)
	}
	if (*got)["name"] != "okey.barkpark.cloud" || (*got)["provider"] != "azure" {
		t.Errorf("resurrect POST body wrong: %+v", *got)
	}
	if _, pinned := (*got)["bundle"]; pinned {
		t.Errorf("no --bundle was passed, so the body must omit it (newest-default): %+v", *got)
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout not json: %v (%s)", err, stdout)
	}
	if out["job_id"] != "job-42" || out["provider"] != "azure" {
		t.Errorf("receipt wrong: %+v", out)
	}
}

// TestResurrectBundlePinnedThreads proves --bundle is threaded to the control plane.
func TestResurrectBundlePinnedThreads(t *testing.T) {
	srv, got := resurrectFakeCP(t, http.StatusAccepted, `{"job_id":"j1","status":"queued"}`)
	_, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "vega.barkpark.cloud",
		"--provider", "hetzner", "--bundle", "bundles/pinned.tar.zst",
		"--control-url", srv.URL, "--worker-token", "wtok")
	if code != 0 {
		t.Fatalf("resurrect exited %d, stderr: %s", code, stderr)
	}
	if (*got)["bundle"] != "bundles/pinned.tar.zst" {
		t.Errorf("--bundle not threaded to the control plane: %+v", *got)
	}
	if (*got)["provider"] != "hetzner" {
		t.Errorf("provider wrong: %+v", *got)
	}
}

// TestResurrectAzureFastRejected proves azure has no --fast (no snapshot substrate):
// it is an honest usage error, not a silently-ignored flag.
func TestResurrectAzureFastRejected(t *testing.T) {
	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud",
		"--provider", "azure", "--fast",
		"--control-url", "http://127.0.0.1:0", "--worker-token", "wtok")
	if code != exitUsage {
		t.Fatalf("azure --fast should be a usage error (exit %d), got %d; stderr: %s", exitUsage, code, stderr)
	}
	if !strings.Contains(stdout+stderr, "snapshot") {
		t.Errorf("azure --fast rejection should explain the missing snapshot substrate: %s / %s", stdout, stderr)
	}
}

// TestResurrectNeedsControlPlane proves the portable path fails with an auth error
// (not a crash) when no worker token is available — the bundle store lives there.
func TestResurrectNeedsControlPlane(t *testing.T) {
	t.Setenv("WORKER_TOKEN", "")
	t.Setenv("BARKPARK_CONTROL_URL", "")
	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud", "--provider", "azure")
	if code != exitAuth {
		t.Fatalf("resurrect with no control plane should exit %d (auth), got %d; stderr: %s", exitAuth, code, stderr)
	}
	if !strings.Contains(stdout+stderr, "WORKER_TOKEN") {
		t.Errorf("auth error should name WORKER_TOKEN: %s / %s", stdout, stderr)
	}
}

// TestSplitFastFlag pins the pure --fast extraction: the flag is pulled and the rest
// of the tail is returned verbatim (so the legacy snapshot free function stays
// byte-identical).
func TestSplitFastFlag(t *testing.T) {
	fast, rest := splitFastFlag([]string{"okey.barkpark.cloud", "--fast", "--zone", "barkpark.cloud"})
	if !fast {
		t.Error("--fast not detected")
	}
	if strings.Join(rest, " ") != "okey.barkpark.cloud --zone barkpark.cloud" {
		t.Errorf("rest not preserved verbatim: %v", rest)
	}
	fast2, rest2 := splitFastFlag([]string{"okey.barkpark.cloud"})
	if fast2 || strings.Join(rest2, " ") != "okey.barkpark.cloud" {
		t.Errorf("no --fast case wrong: fast=%v rest=%v", fast2, rest2)
	}
}
