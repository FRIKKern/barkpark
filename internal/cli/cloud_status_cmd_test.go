package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
		"removing": "in-flight", "provisioning": "in-flight",
		"ok": "healthy",
	}
	for status, want := range cases {
		if got := attentionBucket(status); got != want {
			t.Errorf("attentionBucket(%q) = %q, want %q", status, got, want)
		}
	}
}

// attentionVocabularyFixturePath is the decision-32 cross-surface status
// vocabulary — the SAME file the node harness asserts statusOf/statusMeta
// against (from wave 3), read here relative to internal/cli/ exactly like the
// hetzner_overview.json golden.
var attentionVocabularyFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "attention_order.json")

// TestAttentionVocabularyMatchesFixture holds the Go implementation to the
// committed decision-32 fixture: every state, in fixture order, must carry the
// pinned rank (attentionRank), bucket (attentionBucket) and tone (statusRole),
// and the state set must be exactly attentionRankOrder. A drift on either side
// — code or fixture — fails here, not in production.
func TestAttentionVocabularyMatchesFixture(t *testing.T) {
	raw, err := os.ReadFile(attentionVocabularyFixturePath)
	if err != nil {
		t.Fatalf("read decision-32 fixture: %v", err)
	}
	var f struct {
		States []struct {
			State  string `json:"state"`
			Rank   int    `json:"rank"`
			Bucket string `json:"bucket"`
			Tone   string `json:"tone"`
			Glyph  string `json:"glyph"`
			Label  string `json:"label"`
		} `json:"states"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode decision-32 fixture: %v", err)
	}
	if len(f.States) != len(attentionRankOrder) {
		t.Fatalf("fixture has %d states, code has %d", len(f.States), len(attentionRankOrder))
	}
	for i, s := range f.States {
		if s.State != attentionRankOrder[i] {
			t.Errorf("state %d: fixture %q, code %q", i, s.State, attentionRankOrder[i])
		}
		if got := attentionRank(s.State); got != s.Rank {
			t.Errorf("%s: attentionRank = %d, fixture rank %d", s.State, got, s.Rank)
		}
		if got := attentionBucket(s.State); got != s.Bucket {
			t.Errorf("%s: attentionBucket = %q, fixture bucket %q", s.State, got, s.Bucket)
		}
		if got := statusRole(s.State); got != s.Tone {
			t.Errorf("%s: statusRole = %q, fixture tone %q", s.State, got, s.Tone)
		}
		if s.Glyph == "" || s.Label == "" {
			t.Errorf("%s: fixture glyph/label must be non-empty (%q/%q)", s.State, s.Glyph, s.Label)
		}
	}
}

// attentionFixture is the shape of testdata/attention_order_cases.json — the
// concrete input→order test companion of the decision-32 vocabulary fixture.
type attentionFixture struct {
	Barkparks     []cloudclient.Barkpark `json:"barkparks"`
	ExpectedOrder []string               `json:"expected_order"`
}

func loadAttentionFixture(t *testing.T) attentionFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "attention_order_cases.json"))
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
			{"id":"b","name":"dead-box","host":"","provision_status":"failed","provision_error":"cloud-init timed out"},
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
			InFlight  int `json:"in-flight"` // decision-32 bucket spelling
			Healthy   int `json:"healthy"`
		} `json:"buckets"`
		Barkparks []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Bucket string `json:"bucket"`
			Rank   int    `json:"rank"`
			Detail string `json:"detail"`
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
	// Ranked most-urgent-first, ranks 1-based per the decision-32 fixture:
	// failed (2) < degraded (4) < ok (8).
	wantOrder := []string{"dead-box", "slow-box", "ok-box"}
	wantStatus := []string{"failed", "degraded", "ok"}
	wantRank := []int{2, 4, 8}
	for i := range wantOrder {
		if resp.Barkparks[i].Name != wantOrder[i] || resp.Barkparks[i].Status != wantStatus[i] || resp.Barkparks[i].Rank != wantRank[i] {
			t.Fatalf("row %d = %s/%s/rank %d, want %s/%s/rank %d", i,
				resp.Barkparks[i].Name, resp.Barkparks[i].Status, resp.Barkparks[i].Rank,
				wantOrder[i], wantStatus[i], wantRank[i])
		}
	}
	// The failure reason the control plane sent rides along as detail.
	if resp.Barkparks[0].Detail != "cloud-init timed out" {
		t.Fatalf("dead-box detail = %q, want the provision error", resp.Barkparks[0].Detail)
	}
	if resp.Barkparks[2].Detail != "" {
		t.Fatalf("ok-box detail = %q, want empty", resp.Barkparks[2].Detail)
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

// TestRunCloudStatusTableDetailColumn: the human table carries the control
// plane's own failure reason as a DETAIL column — but only in buckets where at
// least one row has one (the healthy bucket never grows the column).
func TestRunCloudStatusTableDetailColumn(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"a","name":"ok-box","host":"h","url":"https://ok.example","health_status":"up","agent_status":"online"},
			{"id":"b","name":"dead-box","host":"","provision_status":"failed","provision_error":"cloud-init timed out"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	lines := strings.Split(stdout, "\n")
	attentionHeader, healthyHeader := "", ""
	for i, l := range lines {
		if strings.HasPrefix(l, "ATTENTION") && i+1 < len(lines) {
			attentionHeader = lines[i+1]
		}
		if strings.HasPrefix(l, "HEALTHY") && i+1 < len(lines) {
			healthyHeader = lines[i+1]
		}
	}
	if !strings.Contains(attentionHeader, "DETAIL") {
		t.Fatalf("attention bucket should carry a DETAIL column:\n%s", stdout)
	}
	if !strings.Contains(stdout, "cloud-init timed out") {
		t.Fatalf("the provision error should be visible:\n%s", stdout)
	}
	if strings.Contains(healthyHeader, "DETAIL") {
		t.Fatalf("healthy bucket must not grow a DETAIL column:\n%s", stdout)
	}
}
