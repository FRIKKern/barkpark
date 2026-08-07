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
		"degraded": "attention", "deploys_failing": "attention", "behind": "attention",
		"removing": "in-flight", "provisioning": "in-flight",
		// A box that HAS sites and cannot be scored is a silence, and a silence
		// belongs where a human looks — ranked last inside it, never healthy.
		"unmetered": "attention",
		"ok":        "healthy",
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
	// failed (2) < degraded (4) < ok (10).
	wantOrder := []string{"dead-box", "slow-box", "ok-box"}
	wantStatus := []string{"failed", "degraded", "ok"}
	wantRank := []int{2, 4, 10}
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

// ── The deploy rungs (dr-w10-s1) ─────────────────────────────────────────────

// deployBox builds a live, healthy fleet row carrying a deploy vital shaped like
// the control plane's: `sites` is the deploy SURFACE and `pct` nil is a refusing
// rate (never a zero).
func deployBox(name string, sites int, sample int, pct *float64) cloudclient.Barkpark {
	node := &cloudclient.BoxDeployRate{
		Sites:          sites,
		SitesDeploying: sites,
		Rate: cloudclient.DeployRate{
			Sample: sample, Pct: pct, MinSample: 200, Refused: pct == nil,
		},
	}
	if pct == nil && sample > 0 {
		node.Rate.Reason = "sample 55 below min_sample 200"
	}
	return cloudclient.Barkpark{
		ID: "id-" + name, Name: name, Host: "10.0.0.1",
		HealthStatus: "up", AgentStatus: "online", UpdateState: "current",
		DeployRate: node,
	}
}

func deployPct(v float64) *float64 { return &v }

// TestAttentionStatusDeploysFailing is MUTATION DIRECTION ONE: guerrilla's own
// recorded 24 h shape — 46.28% of 1,290 terminal deploys, 11 sites — must come
// out `deploys_failing`, and it is asserted as NOT `ok`, because `ok` is exactly
// what the shipped binary printed for this row. Deleting the rung from
// attentionStatus fails this test.
func TestAttentionStatusDeploysFailing(t *testing.T) {
	guerrilla := deployBox("guerrilla", 11, 1290, deployPct(46.28))
	got := attentionStatus(guerrilla)
	if got == "ok" {
		t.Fatalf("a box failing 46.28%% of 1290 terminal deploys must never read ok")
	}
	if got != "deploys_failing" {
		t.Fatalf("attentionStatus = %q, want deploys_failing", got)
	}
	if attentionBucket(got) != "attention" {
		t.Fatalf("deploys_failing must bucket into attention, got %q", attentionBucket(got))
	}
	// The fence is 20.0 and it is a FENCE, not a mood: just under it is calm,
	// exactly on it is not.
	if s := attentionStatus(deployBox("under", 11, 1290, deployPct(19.99))); s != "ok" {
		t.Fatalf("19.99%% is under the 20.0 fence: got %q, want ok", s)
	}
	if s := attentionStatus(deployBox("onfence", 11, 1290, deployPct(20.0))); s != "deploys_failing" {
		t.Fatalf("20.0%% is AT the fence: got %q, want deploys_failing", s)
	}
	// …and a degraded box is still degraded: the deploy rung ranks below it.
	deg := deployBox("deg", 11, 1290, deployPct(46.28))
	deg.HealthStatus = "down"
	if s := attentionStatus(deg); s != "degraded" {
		t.Fatalf("degraded outranks deploys_failing: got %q", s)
	}
}

// TestAttentionStatusDeployAbsence is MUTATION DIRECTION TWO — the tri-state.
// The SAME box, with the rate refused or absent, must come out `unmetered` and
// never `ok`; a box with ZERO sites keeps its verdict AND wears the marker.
func TestAttentionStatusDeployAbsence(t *testing.T) {
	// (a) has sites, sample below min_sample → a silence, said out loud.
	jarl := deployBox("jarl", 2, 55, nil)
	if got := attentionStatus(jarl); got != "unmetered" {
		t.Fatalf("a box with sites and a refused rate must be unmetered, got %q", got)
	}
	if attentionDetail(jarl, "unmetered") == "" {
		t.Fatalf("unmetered must carry the control plane's own refusal reason")
	}

	// (b) has sites, no terminal deploys at all in the window → still unmetered:
	// "nobody deployed" is not "deploys are fine".
	quiet := deployBox("quiet", 3, 0, nil)
	if got := attentionStatus(quiet); got != "unmetered" {
		t.Fatalf("sites but zero terminal rows must be unmetered, got %q", got)
	}

	// (c) ZERO sites → nothing to deploy, so the verdict is unchanged and the row
	// says why. Folding this into unmetered would alarm 6 of 8 boxes forever.
	empty := deployBox("empty", 0, 0, nil)
	if got := attentionStatus(empty); got != "ok" {
		t.Fatalf("a box with no sites has nothing to deploy: got %q, want ok", got)
	}
	marker := attentionDetail(empty, "ok")
	if !strings.Contains(marker, "no sites") {
		t.Fatalf("a zero-site ok row must wear the detail marker, got %q", marker)
	}

	// (d) an OLDER control plane sent no vital at all: verdict unchanged, and NO
	// marker — we could not ask, so we say nothing.
	older := cloudclient.Barkpark{ID: "o", Name: "older", Host: "h", HealthStatus: "up", AgentStatus: "online"}
	if got := attentionStatus(older); got != "ok" {
		t.Fatalf("an older CP row must be unchanged, got %q", got)
	}
	if d := attentionDetail(older, "ok"); d != "" {
		t.Fatalf("an older CP row must wear no marker, got %q", d)
	}

	// (e) a MEASURED, healthy rate is ok — and says so with its denominator, so a
	// calm row is readable as a measurement rather than as an absence of one.
	calm := deployBox("calm", 4, 900, deployPct(3.2))
	if got := attentionStatus(calm); got != "ok" {
		t.Fatalf("3.2%% is ok, got %q", got)
	}
	if d := attentionDetail(calm, "ok"); !strings.Contains(d, "900") {
		t.Fatalf("a measured ok marker must carry its denominator, got %q", d)
	}
}

// TestAttentionStatusOutputsSubsetOfLadder closes the enum hole this slice
// widens. TestAttentionVocabularyMatchesFixture pins attentionRankOrder against
// the fixture but NOT that attentionStatus's OUTPUTS live in the ladder — proved
// by mutation: a status returned by attentionStatus but absent from
// attentionRankOrder ranks past the end, buckets into "attention", and every
// other test stays green. Any status this function can produce must be in the
// ladder, or it silently sorts last.
func TestAttentionStatusOutputsSubsetOfLadder(t *testing.T) {
	known := map[string]bool{}
	for _, s := range attentionRankOrder {
		known[s] = true
	}

	shaped := []cloudclient.Barkpark{
		{DeprovisionStatus: "failed", Host: "h"},
		{Host: "", ProvisionStatus: "failed"},
		{Host: "h", Suspended: true},
		{Host: "h", HealthStatus: "down", AgentStatus: "online"},
		{Host: "h", HealthStatus: "up", AgentStatus: "offline"},
		{Host: "h", HealthStatus: "up", AgentStatus: "online", UpdateState: "behind"},
		{Host: "h", DeprovisionStatus: "pending"},
		{Host: "h", DeprovisionStatus: "claimed"},
		{Host: ""},
		{Host: "h", HealthStatus: "up", AgentStatus: "online"},
		{Host: "h", ProvisionStatus: "failed", HealthStatus: "up", AgentStatus: "online"},
		deployBox("df", 11, 1290, deployPct(46.28)),
		deployBox("unm", 2, 55, nil),
		deployBox("nosurface", 0, 0, nil),
		deployBox("calm", 4, 900, deployPct(1.0)),
	}
	seen := map[string]bool{}
	for _, b := range shaped {
		st := attentionStatus(b)
		seen[st] = true
		if !known[st] {
			t.Errorf("attentionStatus returned %q, which is NOT in attentionRankOrder %v", st, attentionRankOrder)
		}
	}
	// …and the table must actually exercise the two new rungs, or the subset
	// assertion above passes vacuously.
	for _, must := range []string{"deploys_failing", "unmetered"} {
		if !seen[must] {
			t.Errorf("the shaped table never produced %q — the subset assertion is vacuous", must)
		}
	}
}

// TestBoxDeployRateNullPctDecodes: the control plane sends `pct: null` for a
// refusing node. A float64 field would decode that as 0.0 — "0% of deploys
// failed", the most comforting lie available — so Pct is a pointer and this
// pins it.
func TestBoxDeployRateNullPctDecodes(t *testing.T) {
	const payload = `{"sites":2,"sites_deploying":1,
		"rate":{"sample":55,"pct":null,"numerator":3,"min_sample":200,"refused":true,"reason":"sample 55 below min_sample 200"},
		"absorption":{"sample":60,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"x"},
		"box_caused":{"sample":3,"pct":null,"numerator":1,"min_sample":200,"refused":true,"reason":"x"}}`
	var node cloudclient.BoxDeployRate
	if err := json.Unmarshal([]byte(payload), &node); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if node.Rate.Pct != nil {
		t.Fatalf("a null pct must decode to nil, got %v", *node.Rate.Pct)
	}
	if !node.Rate.Refused || node.Rate.Sample != 55 || node.Sites != 2 {
		t.Fatalf("the refusal must survive the wire: %+v", node)
	}
	// The whole row, through the real fleet decode path.
	var bp struct {
		Barkparks []cloudclient.Barkpark `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(`{"barkparks":[{"id":"a","name":"n","host":"h","deploy_rate":`+payload+`}]}`), &bp); err != nil {
		t.Fatalf("decode fleet: %v", err)
	}
	if bp.Barkparks[0].DeployRate == nil || bp.Barkparks[0].DeployRate.Rate.Pct != nil {
		t.Fatalf("fleet row lost the tri-state: %+v", bp.Barkparks[0].DeployRate)
	}
	// …and a row with NO deploy_rate key keeps a nil node — "we could not ask".
	// Decoded into a FRESH value: json.Unmarshal reuses an existing slice's
	// elements, so reusing `bp` here would silently carry the node above forward
	// and the assertion would be about the wrong bytes.
	var older struct {
		Barkparks []cloudclient.Barkpark `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(`{"barkparks":[{"id":"a","name":"n","host":"h"}]}`), &older); err != nil {
		t.Fatalf("decode older CP: %v", err)
	}
	if older.Barkparks[0].DeployRate != nil {
		t.Fatalf("an older CP must leave the node nil, got %+v", older.Barkparks[0].DeployRate)
	}
}

// TestRunCloudStatusDeployRungJSON drives the whole command against a control
// plane serving the day-one fleet reading: a box failing its deploys, a box that
// cannot be scored, and a box with nothing to deploy.
func TestRunCloudStatusDeployRungJSON(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"a","name":"guerrilla","host":"h","health_status":"up","agent_status":"online","update_state":"current",
			 "deploy_rate":{"sites":11,"sites_deploying":7,
			   "rate":{"sample":1290,"pct":46.28,"numerator":597,"min_sample":200,"refused":false,"reason":null},
			   "absorption":{"sample":3208,"pct":21.1,"numerator":677,"min_sample":200,"refused":false,"reason":null},
			   "box_caused":{"sample":597,"pct":61.2,"numerator":365,"min_sample":200,"refused":false,"reason":null}}},
			{"id":"b","name":"jarl","host":"h","health_status":"up","agent_status":"online","update_state":"current",
			 "deploy_rate":{"sites":2,"sites_deploying":1,
			   "rate":{"sample":55,"pct":null,"numerator":3,"min_sample":200,"refused":true,"reason":"sample 55 below min_sample 200"},
			   "absorption":{"sample":60,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"r"},
			   "box_caused":{"sample":3,"pct":null,"numerator":1,"min_sample":200,"refused":true,"reason":"r"}}},
			{"id":"c","name":"idle","host":"h","health_status":"up","agent_status":"online","update_state":"current",
			 "deploy_rate":{"sites":0,"sites_deploying":0,
			   "rate":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"sample 0 below min_sample 200"},
			   "absorption":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"r"},
			   "box_caused":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"r"}}}
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
	var resp struct {
		Buckets struct {
			Attention int `json:"attention"`
			Healthy   int `json:"healthy"`
		} `json:"buckets"`
		Barkparks []struct {
			Name     string   `json:"name"`
			Status   string   `json:"status"`
			Rank     int      `json:"rank"`
			Detail   string   `json:"detail"`
			Pct      *float64 `json:"deploy_failure_pct"`
			Sample   int      `json:"deploy_sample"`
			Sites    int      `json:"deploy_sites"`
			BoxCause *float64 `json:"deploy_box_caused_pct"`
		} `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(stdout), &resp); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	// guerrilla (5) before jarl (9) before idle (10) — the sick box is FIRST, which
	// is exactly what appending the rung instead of renumbering would have broken.
	want := []struct {
		name, status string
		rank         int
	}{
		{"guerrilla", "deploys_failing", 5},
		{"jarl", "unmetered", 9},
		{"idle", "ok", 10},
	}
	for i, w := range want {
		got := resp.Barkparks[i]
		if got.Name != w.name || got.Status != w.status || got.Rank != w.rank {
			t.Fatalf("row %d = %s/%s/%d, want %s/%s/%d", i, got.Name, got.Status, got.Rank, w.name, w.status, w.rank)
		}
	}
	if resp.Buckets.Attention != 2 || resp.Buckets.Healthy != 1 {
		t.Fatalf("buckets = %+v (deploys_failing and unmetered both need a human)", resp.Buckets)
	}
	if resp.Barkparks[0].Pct == nil || *resp.Barkparks[0].Pct != 46.28 || resp.Barkparks[0].Sample != 1290 {
		t.Fatalf("the rate must travel with its denominator: %+v", resp.Barkparks[0])
	}
	if resp.Barkparks[0].BoxCause == nil || *resp.Barkparks[0].BoxCause != 61.2 {
		t.Fatalf("box_caused must ride with the raw rate (charter D148): %+v", resp.Barkparks[0])
	}
	// A refused rate emits NO pct key at all — a script must not read a 0.0.
	if resp.Barkparks[1].Pct != nil {
		t.Fatalf("a refused rate must not emit a pct, got %v", *resp.Barkparks[1].Pct)
	}
	if resp.Barkparks[1].Sites != 2 || resp.Barkparks[2].Sites != 0 {
		t.Fatalf("the surface count must survive: %+v", resp.Barkparks)
	}
	if !strings.Contains(resp.Barkparks[0].Detail, "1290") ||
		!strings.Contains(resp.Barkparks[2].Detail, "no sites") {
		t.Fatalf("the deploy markers are missing: %+v", resp.Barkparks)
	}
}
