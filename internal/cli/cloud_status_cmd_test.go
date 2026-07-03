package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// TestAttentionStatusClassification pins the decision-15 label for each rank,
// including the precedence edges (removing beats suspended; degraded beats
// behind; a host-set failed provision is not "live").
func TestAttentionStatusClassification(t *testing.T) {
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"removal_failed", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "failed"}, "removal_failed"},
		{"removal_failed beats everything", cloudclient.Barkpark{Host: "h", Suspended: true, DeprovisionStatus: "failed"}, "removal_failed"},
		{"failed needs no host", cloudclient.Barkpark{Host: "", ProvisionStatus: "failed"}, "failed"},
		{"suspended", cloudclient.Barkpark{Host: "h", Suspended: true}, "suspended"},
		{"suspended+removing is removing", cloudclient.Barkpark{Host: "h", Suspended: true, DeprovisionStatus: "pending"}, "removing"},
		{"degraded via health", cloudclient.Barkpark{Host: "h", HealthStatus: "unknown", AgentStatus: "online"}, "degraded"},
		{"degraded via agent", cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "offline"}, "degraded"},
		{"degraded beats behind", cloudclient.Barkpark{Host: "h", HealthStatus: "down", AgentStatus: "online", UpdateState: "behind"}, "degraded"},
		{"behind", cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online", UpdateState: "behind"}, "behind"},
		{"removing pending", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "pending"}, "removing"},
		{"removing claimed", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "claimed"}, "removing"},
		{"provisioning no host", cloudclient.Barkpark{Host: ""}, "provisioning"},
		{"provisioning with in-flight provision", cloudclient.Barkpark{Host: "", ProvisionStatus: "claimed"}, "provisioning"},
		{"ok", cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online", UpdateState: "current"}, "ok"},
		{"ok with empty update_state", cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online"}, "ok"},
	}
	for _, c := range cases {
		if got := attentionStatus(c.bp); got != c.want {
			t.Errorf("%s: attentionStatus = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestAttentionBucket(t *testing.T) {
	cases := map[string]string{
		"removal_failed": "attention", "failed": "attention", "suspended": "attention",
		"degraded": "attention", "behind": "attention",
		"removing": "in_flight", "provisioning": "in_flight",
		"ok": "healthy",
	}
	for status, want := range cases {
		if got := attentionBucket(status); got != want {
			t.Errorf("attentionBucket(%q) = %q, want %q", status, got, want)
		}
	}
}

// attentionFixture is the shape of testdata/attention_order.json — the
// cross-surface D15 contract.
type attentionFixture struct {
	Barkparks     []cloudclient.Barkpark `json:"barkparks"`
	ExpectedOrder []string               `json:"expected_order"`
}

func loadAttentionFixture(t *testing.T) attentionFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "attention_order.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f attentionFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(f.Barkparks) != len(f.ExpectedOrder) {
		t.Fatalf("fixture has %d barkparks but %d expected names", len(f.Barkparks), len(f.ExpectedOrder))
	}
	return f
}

// TestRankBarkparksFixture is the contract assertion: rankBarkparks reproduces
// the committed fixture's expected order EXACTLY — every rank + the
// case-insensitive name tiebreak (alpha < ok-1 < Zeta within the ok bucket).
func TestRankBarkparksFixture(t *testing.T) {
	f := loadAttentionFixture(t)
	ranked := rankBarkparks(f.Barkparks)
	got := make([]string, len(ranked))
	for i, r := range ranked {
		got[i] = r.BP.Name
	}
	if len(got) != len(f.ExpectedOrder) {
		t.Fatalf("ranked %d rows, expected %d", len(got), len(f.ExpectedOrder))
	}
	for i := range got {
		if got[i] != f.ExpectedOrder[i] {
			t.Fatalf("rank order mismatch at %d:\n got: %v\nwant: %v", i, got, f.ExpectedOrder)
		}
	}
}

// TestRankBarkparksTiebreakCaseInsensitive isolates the tiebreak: two same-rank
// boxes whose only difference is case sort case-insensitively (ASCII-sensitive
// order would put "Zebra" before "apple").
func TestRankBarkparksTiebreakCaseInsensitive(t *testing.T) {
	ok := func(id, name string) cloudclient.Barkpark {
		return cloudclient.Barkpark{ID: id, Name: name, Host: "h", HealthStatus: "up", AgentStatus: "online"}
	}
	ranked := rankBarkparks([]cloudclient.Barkpark{ok("2", "Zebra"), ok("1", "apple")})
	if ranked[0].BP.Name != "apple" || ranked[1].BP.Name != "Zebra" {
		t.Fatalf("case-insensitive tiebreak failed: %s then %s", ranked[0].BP.Name, ranked[1].BP.Name)
	}
}

// TestRunCloudStatusJSON drives the whole command against a fake control plane
// and asserts the ranked, bucketed -o json structure.
func TestRunCloudStatusJSON(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"a","name":"ok-box","host":"h","health_status":"up","agent_status":"online","update_state":"current"},
			{"id":"b","name":"dead-box","host":"","provision_status":"failed"},
			{"id":"c","name":"slow-box","host":"h","health_status":"unknown","agent_status":"online"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/barkparks" {
		t.Fatalf("hit %q, want /v1/barkparks", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}

	var resp struct {
		OK      bool `json:"ok"`
		Count   int  `json:"count"`
		Buckets struct {
			Attention int `json:"attention"`
			InFlight  int `json:"in_flight"`
			Healthy   int `json:"healthy"`
		} `json:"buckets"`
		Barkparks []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Bucket string `json:"bucket"`
			Rank   int    `json:"rank"`
		} `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(stdout), &resp); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	if !resp.OK || resp.Count != 3 {
		t.Fatalf("ok/count = %v/%d", resp.OK, resp.Count)
	}
	if resp.Buckets.Attention != 2 || resp.Buckets.Healthy != 1 || resp.Buckets.InFlight != 0 {
		t.Fatalf("buckets = %+v", resp.Buckets)
	}
	// Ranked most-urgent-first: failed (dead-box) < degraded (slow-box) < ok.
	wantOrder := []string{"dead-box", "slow-box", "ok-box"}
	wantStatus := []string{"failed", "degraded", "ok"}
	for i := range wantOrder {
		if resp.Barkparks[i].Name != wantOrder[i] || resp.Barkparks[i].Status != wantStatus[i] {
			t.Fatalf("row %d = %s/%s, want %s/%s", i, resp.Barkparks[i].Name, resp.Barkparks[i].Status, wantOrder[i], wantStatus[i])
		}
	}
}

// TestRunCloudStatusNoToken: without a Cloud token the command is an auth error
// with a `bp login` hint, and makes no network call.
func TestRunCloudStatusNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // human path: the hint lands on stderr
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !bytes.Contains([]byte(stderr), []byte("bp login")) {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudStatusEmptyFleet: a logged-in user with no Barkparks gets a clean
// guiding line, not an empty table.
func TestRunCloudStatusEmptyFleet(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !bytes.Contains([]byte(stdout), []byte("no Barkparks yet")) {
		t.Fatalf("expected empty-fleet guidance:\n%s", stdout)
	}
}
