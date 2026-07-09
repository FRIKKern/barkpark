package cli

// cloud_instance_resurrect_cmd_test.go proves the provider-neutral portable
// resurrect against a fake control plane: the CLI POSTs /v1/resurrect on the
// USER-BEARER plane (the same plane as `bp launch` — the route is require_user +
// team-admin, S14c), threads bundle_ref (an explicit --bundle verbatim; else the
// newest bundle resolved from the store), rejects azure --fast honestly, and
// fails clean when not logged in or when no bundle exists. Zero live anything.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// resurrectFakeCP stands up a control plane that only answers POST /v1/resurrect
// with the S14c 202 receipt, recording the request body + auth so the test can
// assert what the CLI sent.
func resurrectFakeCP(t *testing.T, status int, resp string) (*map[string]any, *string) {
	t.Helper()
	var got map[string]any
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/resurrect" {
			t.Errorf("unexpected request %s %s (resurrect must POST /v1/resurrect only)", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		auth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, resp)
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &got, &auth
}

// seedResurrectBundle writes one complete bp-bundle-v1 for fqdn into the swapped
// fake store at the given instant and returns its prefix.
func seedResurrectBundle(t *testing.T, st *cloud.FakeBundleStore, fqdn string, at time.Time) string {
	t.Helper()
	man, err := cloud.WriteBundle(context.Background(), st, cloud.BundleWriteSpec{
		FQDN: fqdn, SourceProvider: cloud.ProviderHetzner, CreatedAt: at,
		DB: strings.NewReader("d"),
	})
	if err != nil {
		t.Fatalf("seed bundle: %v", err)
	}
	return man.Prefix()
}

// TestResurrectPortablePostsControlPlane proves the azure (portable-only) resurrect
// POSTs /v1/resurrect with {name, provider, bundle_ref} on the USER bearer, with
// the NEWEST bundle resolved from the store when no --bundle is passed.
func TestResurrectPortablePostsControlPlane(t *testing.T) {
	got, auth := resurrectFakeCP(t, http.StatusAccepted, `{"ok":true,"id":"bp-9","job_id":"job-42"}`)
	st := withFakeBundleStore(t)
	seedResurrectBundle(t, st, "okey.barkpark.cloud", time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	newest := seedResurrectBundle(t, st, "okey.barkpark.cloud", time.Date(2026, 7, 9, 8, 0, 0, 0, time.UTC))

	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud", "--provider", "azure")
	if code != 0 {
		t.Fatalf("resurrect exited %d, stderr: %s", code, stderr)
	}
	if *auth != "Bearer sess-abc" {
		t.Errorf("resurrect must ride the USER bearer (bp login session), got %q", *auth)
	}
	if (*got)["name"] != "okey.barkpark.cloud" || (*got)["provider"] != "azure" {
		t.Errorf("resurrect POST body wrong: %+v", *got)
	}
	if (*got)["bundle_ref"] != newest {
		t.Errorf("no --bundle passed → the NEWEST bundle prefix must be resolved and sent as bundle_ref:\n got:  %v\n want: %s", (*got)["bundle_ref"], newest)
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout not json: %v (%s)", err, stdout)
	}
	if out["job_id"] != "job-42" || out["provider"] != "azure" {
		t.Errorf("receipt wrong: %+v", out)
	}
}

// TestResurrectBundlePinnedThreads proves --bundle is threaded verbatim as
// bundle_ref (no store lookup needed).
func TestResurrectBundlePinnedThreads(t *testing.T) {
	got, _ := resurrectFakeCP(t, http.StatusAccepted, `{"ok":true,"id":"bp-1","job_id":"j1"}`)
	_, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "vega.barkpark.cloud",
		"--provider", "hetzner", "--bundle", "archives/t1/vega.barkpark.cloud/20260101T000000Z/")
	if code != 0 {
		t.Fatalf("resurrect exited %d, stderr: %s", code, stderr)
	}
	if (*got)["bundle_ref"] != "archives/t1/vega.barkpark.cloud/20260101T000000Z/" {
		t.Errorf("--bundle not threaded as bundle_ref: %+v", *got)
	}
	if (*got)["provider"] != "hetzner" {
		t.Errorf("provider wrong: %+v", *got)
	}
}

// TestResurrectNoBundleIsHonest proves a flag-less resurrect with NO archive in
// the store fails not-found with copy naming both fixes (archive it / --bundle),
// and never POSTs the control plane.
func TestResurrectNoBundleIsHonest(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "http://127.0.0.1:0") // any POST would fail loudly — none may happen
	withFakeBundleStore(t)

	stdout, stderr, code := runHzCLI(t, "table",
		"instance", "resurrect", "ghost.barkpark.cloud", "--provider", "azure")
	if code != exitNotFound {
		t.Fatalf("no bundle should exit %d (not found), got %d\n%s", exitNotFound, code, stderr)
	}
	for _, want := range []string{"no portable archive", "bp cloud instance archive", "--bundle"} {
		if !strings.Contains(stdout+stderr, want) {
			t.Errorf("no-bundle error missing %q:\n%s\n%s", want, stdout, stderr)
		}
	}
}

// TestResurrectAzureFastRejected proves azure has no --fast (no snapshot substrate):
// it is an honest usage error, not a silently-ignored flag.
func TestResurrectAzureFastRejected(t *testing.T) {
	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud",
		"--provider", "azure", "--fast")
	if code != exitUsage {
		t.Fatalf("azure --fast should be a usage error (exit %d), got %d; stderr: %s", exitUsage, code, stderr)
	}
	if !strings.Contains(stdout+stderr, "snapshot") {
		t.Errorf("azure --fast rejection should explain the missing snapshot substrate: %s / %s", stdout, stderr)
	}
}

// TestResurrectNeedsLogin proves the portable path fails with the standard
// not-logged-in auth error (the /v1/resurrect route is require_user — the same
// plane as `bp launch`), not a crash.
func TestResurrectNeedsLogin(t *testing.T) {
	withTempConfigHome(t) // no cloud token seeded
	stdout, stderr, code := runHzCLI(t, "json",
		"instance", "resurrect", "okey.barkpark.cloud", "--provider", "azure")
	if code != exitAuth {
		t.Fatalf("resurrect with no login should exit %d (auth), got %d; stderr: %s", exitAuth, code, stderr)
	}
	if !strings.Contains(stdout+stderr, "bp login") {
		t.Errorf("auth error should point at `bp login`: %s / %s", stdout, stderr)
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
