package cli

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// fakeFleetClient is an in-memory cloudFleetClient for the cloud-target tests: it
// returns a canned fleet and canned credentials (or errors) per Barkpark id.
type fakeFleetClient struct {
	list     []cloudclient.Barkpark
	listErr  error
	creds    map[string]cloudclient.Credentials
	credErrs map[string]error
	credTeam string
}

func (f *fakeFleetClient) ListAllBarkparks(context.Context) ([]cloudclient.Barkpark, error) {
	return f.list, f.listErr
}

func (f *fakeFleetClient) GetCredentials(_ context.Context, id string) (cloudclient.Credentials, error) {
	return f.GetCredentialsForTeam(context.Background(), id, "")
}

func (f *fakeFleetClient) GetCredentialsForTeam(_ context.Context, id, teamID string) (cloudclient.Credentials, error) {
	f.credTeam = teamID
	if err, ok := f.credErrs[id]; ok {
		return cloudclient.Credentials{}, err
	}
	return f.creds[id], nil
}

// newTestWriter is the shared buffer-backed writer helper (defined in
// upgrade_test.go): (*writer, *stdout, *stderr).

// TestCloudFleetPickEmptyFleetFinishesLoggedIn: with no Barkparks, the pick
// finishes LOGGED IN (not a dead end) and prints launch guidance.
func TestCloudFleetPickEmptyFleetFinishesLoggedIn(t *testing.T) {
	w, out, _ := newTestWriter()
	client := &fakeFleetClient{list: nil}

	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil {
		t.Fatalf("empty fleet should be a clean success, got: %v", err)
	}
	if !res.LoggedInOnly {
		t.Fatalf("empty fleet must return LoggedInOnly, got %+v", res)
	}
	if res.Server != "" || res.Token != "" {
		t.Fatalf("empty fleet must not resolve a server/token, got %+v", res)
	}
	if !strings.Contains(out.String(), "bp launch hetzner") || !strings.Contains(out.String(), "bp go-live") {
		t.Fatalf("empty-fleet output should carry launch/deploy guidance:\n%s", out.String())
	}
}

// TestCloudFleetPickNumberedPickResolvesCredentials: a valid numbered pick
// fetches that Barkpark's credentials and returns them as the connect target —
// and the admin token never appears in the printed output.
func TestCloudFleetPickNumberedPickResolvesCredentials(t *testing.T) {
	w, out, errb := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: &cloudclient.Team{Name: "Primary"}},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com", Team: &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "admin"}},
		},
		creds: map[string]cloudclient.Credentials{
			"bp-2": {AdminToken: "super-secret-token", URL: "https://bravo.example.com"},
		},
	}

	// Pick #2 (bravo).
	res, err := cloudFleetPick(w, client, strings.NewReader("2\n"))
	if err != nil {
		t.Fatalf("valid pick should succeed, got: %v", err)
	}
	if res.Server != "https://bravo.example.com" {
		t.Fatalf("resolved server = %q, want bravo's URL", res.Server)
	}
	if res.Token != "super-secret-token" {
		t.Fatalf("resolved token = %q, want bravo's admin token", res.Token)
	}
	if res.Name != "bravo" {
		t.Fatalf("resolved name = %q, want bravo", res.Name)
	}
	if res.LoggedInOnly {
		t.Fatal("a resolved pick must not be LoggedInOnly")
	}
	if client.credTeam != "team-docs" {
		t.Fatalf("credential team = %q, want selected secondary team", client.credTeam)
	}
	// The admin token must never be printed on either stream.
	if strings.Contains(out.String()+errb.String(), "super-secret-token") {
		t.Fatalf("admin token leaked into output:\nstdout:%s\nstderr:%s", out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "bravo · Docs") {
		t.Fatalf("numbered fleet should disambiguate teams:\n%s", out.String())
	}
}

// TestCloudFleetPickBlankSelectionStaysLoggedIn: a blank / EOF selection is not a
// dead end — it finishes logged-in. (Two Barkparks so the numbered pick — not the
// single-Barkpark fast path — is exercised.)
func TestCloudFleetPickBlankSelectionStaysLoggedIn(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com"},
		},
		creds: map[string]cloudclient.Credentials{"bp-1": {AdminToken: "t", URL: "https://alpha.example.com"}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader("\n"))
	if err != nil {
		t.Fatalf("blank selection should be a clean success, got: %v", err)
	}
	if !res.LoggedInOnly {
		t.Fatalf("blank selection must stay logged-in, got %+v", res)
	}
}

// TestCloudFleetPickOutOfRangeStaysLoggedIn: an out-of-range number is treated
// like no selection (logged-in), never an index panic.
func TestCloudFleetPickOutOfRangeStaysLoggedIn(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com"},
		},
		creds: map[string]cloudclient.Credentials{"bp-1": {AdminToken: "t", URL: "https://alpha.example.com"}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader("9\n"))
	if err != nil {
		t.Fatalf("out-of-range selection should be a clean success, got: %v", err)
	}
	if !res.LoggedInOnly {
		t.Fatalf("out-of-range selection must stay logged-in, got %+v", res)
	}
}

// TestCloudFleetPickNoAdminTokenOffersManualPaste: a no_admin_token 404 on the
// picked Barkpark offers a manual token paste, which feeds the same connect. (Two
// Barkparks so the pick — not the fast path — runs; #1 is the one that 404s.)
func TestCloudFleetPickNoAdminTokenManualPaste(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com"},
		},
		credErrs: map[string]error{"bp-1": errors.New("no_admin_token")},
	}
	// Pick #1, then paste a token when prompted.
	res, err := cloudFleetPick(w, client, strings.NewReader("1\npasted-token\n"))
	if err != nil {
		t.Fatalf("manual-paste path should succeed, got: %v", err)
	}
	if res.Server != "https://alpha.example.com" {
		t.Fatalf("server = %q, want alpha's URL", res.Server)
	}
	if res.Token != "pasted-token" {
		t.Fatalf("token = %q, want the pasted token", res.Token)
	}
	if res.LoggedInOnly {
		t.Fatal("a pasted token must resolve a connect, not LoggedInOnly")
	}
}

// TestCloudFleetPickNoAdminTokenBlankStaysLoggedIn: a no_admin_token 404 with no
// pasted token finishes logged-in rather than dead-ending.
func TestCloudFleetPickNoAdminTokenBlankStaysLoggedIn(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com"},
		},
		credErrs: map[string]error{"bp-1": errors.New("no_admin_token")},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader("1\n\n"))
	if err != nil {
		t.Fatalf("no-token no-paste path should be a clean success, got: %v", err)
	}
	if !res.LoggedInOnly {
		t.Fatalf("declining the paste must stay logged-in, got %+v", res)
	}
}

// TestCloudFleetPickSingleBarkparkAutoConnects: the overwhelmingly common case —
// exactly one Barkpark — skips the numbered pick, resolves its credentials, and
// returns the connect target with NO input read. The auto-selection is announced
// on stderr and the admin token never leaks.
func TestCloudFleetPickSingleBarkparkAutoConnects(t *testing.T) {
	w, out, errb := newTestWriter()
	client := &fakeFleetClient{
		list:  []cloudclient.Barkpark{{ID: "bp-1", Name: "solo", URL: "https://solo.example.com"}},
		creds: map[string]cloudclient.Credentials{"bp-1": {AdminToken: "solo-secret", URL: "https://solo.example.com"}},
	}
	// Empty reader: a fast path must never block on a pick prompt.
	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil {
		t.Fatalf("single-Barkpark auto-connect should succeed, got: %v", err)
	}
	if res.LoggedInOnly {
		t.Fatalf("a single Barkpark must auto-connect, not stay logged-in: %+v", res)
	}
	if res.Server != "https://solo.example.com" || res.Token != "solo-secret" || res.Name != "solo" {
		t.Fatalf("resolved target wrong: %+v", res)
	}
	// The choice is announced on stderr; the numbered pick prompt never appears.
	if !strings.Contains(errb.String(), "solo") {
		t.Fatalf("single-Barkpark choice should be announced on stderr:\n%s", errb.String())
	}
	if strings.Contains(errb.String(), "Pick a Barkpark") || strings.Contains(out.String(), "Your Barkparks:") {
		t.Fatalf("single Barkpark must skip the numbered pick; stdout=%q stderr=%q", out.String(), errb.String())
	}
	if strings.Contains(out.String()+errb.String(), "solo-secret") {
		t.Fatalf("admin token leaked into output:\nstdout:%s\nstderr:%s", out.String(), errb.String())
	}
}

func TestCloudFleetPickSingleSecondaryTeamUsesTeamContext(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list:  []cloudclient.Barkpark{{ID: "bp-2", Name: "docs", URL: "https://docs.example.com", Team: &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "owner"}}},
		creds: map[string]cloudclient.Credentials{"bp-2": {AdminToken: "secret", URL: "https://docs.example.com"}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil || res.Server != "https://docs.example.com" {
		t.Fatalf("secondary-team single pick = %+v, %v", res, err)
	}
	if client.credTeam != "team-docs" {
		t.Fatalf("credential team = %q, want team-docs", client.credTeam)
	}
}

func TestCloudFleetPickMemberStaysLoggedInWithoutCredentials(t *testing.T) {
	w, out, _ := newTestWriter()
	client := &fakeFleetClient{
		list: []cloudclient.Barkpark{{ID: "bp-2", Name: "docs", Team: &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "member"}}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil || !res.LoggedInOnly {
		t.Fatalf("member pick = %+v, %v; want clean logged-in-only", res, err)
	}
	if client.credTeam != "" {
		t.Fatalf("member selection attempted credential retrieval for %q", client.credTeam)
	}
	if !strings.Contains(out.String(), "member role") || !strings.Contains(out.String(), "owner or admin") {
		t.Fatalf("member guidance not actionable:\n%s", out.String())
	}
}

// TestCloudFleetPickSingleBarkparkNoAdminTokenPaste: the single-Barkpark fast path
// still honors the no_admin_token fallback — it prompts for a manual token paste,
// reading the FIRST line as the token (no pick line to consume first).
func TestCloudFleetPickSingleBarkparkNoAdminTokenPaste(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list:     []cloudclient.Barkpark{{ID: "bp-1", Name: "solo", URL: "https://solo.example.com"}},
		credErrs: map[string]error{"bp-1": errors.New("no_admin_token")},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader("pasted-token\n"))
	if err != nil {
		t.Fatalf("single-Barkpark no-admin-token paste should succeed, got: %v", err)
	}
	if res.Server != "https://solo.example.com" || res.Token != "pasted-token" {
		t.Fatalf("resolved target wrong: %+v", res)
	}
	if res.LoggedInOnly {
		t.Fatal("a pasted token must resolve a connect, not LoggedInOnly")
	}
}

// TestCloudFleetPickStillProvisioningStaysLoggedIn: when the picked Barkpark's
// credentials carry no URL or host yet (still provisioning), the flow finishes
// LOGGED IN rather than erroring — a complete outcome, never a dead end.
func TestCloudFleetPickStillProvisioningStaysLoggedIn(t *testing.T) {
	w, out, _ := newTestWriter()
	client := &fakeFleetClient{
		// Single Barkpark whose creds have neither url nor host (still coming up).
		list:  []cloudclient.Barkpark{{ID: "bp-1", Name: "warming", URL: "https://warming.example.com"}},
		creds: map[string]cloudclient.Credentials{"bp-1": {AdminToken: "tok"}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil {
		t.Fatalf("still-provisioning must be a clean success, got: %v", err)
	}
	if !res.LoggedInOnly {
		t.Fatalf("still-provisioning must stay logged-in, got %+v", res)
	}
	if res.Server != "" || res.Token != "" {
		t.Fatalf("still-provisioning must not resolve a server/token, got %+v", res)
	}
	if !strings.Contains(out.String(), "still provisioning") {
		t.Fatalf("still-provisioning output should explain the wait:\n%s", out.String())
	}
}

// TestCloudFleetPickHostOnlyCanonicalizesToHTTPS: a Barkpark reachable only by a
// scheme-less host resolves to a canonical https://<host> connect target, so the
// W2 steal-guard's normalizeServerURL comparison sees a real URL.
func TestCloudFleetPickHostOnlyCanonicalizesToHTTPS(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list:  []cloudclient.Barkpark{{ID: "bp-1", Name: "iponly", Host: "203.0.113.7"}},
		creds: map[string]cloudclient.Credentials{"bp-1": {AdminToken: "tok", Host: "203.0.113.7"}},
	}
	res, err := cloudFleetPick(w, client, strings.NewReader(""))
	if err != nil {
		t.Fatalf("host-only auto-connect should succeed, got: %v", err)
	}
	if res.Server != "https://203.0.113.7" {
		t.Fatalf("host-only server = %q, want https://203.0.113.7", res.Server)
	}
}

// TestFleetTargetCanonicalizesScheme: fleetTarget always returns a scheme+host
// URL — full URLs pass through, scheme-less hosts gain https://, and an all-blank
// input yields "".
func TestFleetTargetCanonicalizesScheme(t *testing.T) {
	cases := []struct{ url, host, want string }{
		{"https://a.example.com", "a.example.com", "https://a.example.com"}, // URL wins
		{"http://a.example.com", "", "http://a.example.com"},                // scheme preserved
		{"", "b.example.com", "https://b.example.com"},                      // host promoted
		{"", "203.0.113.7", "https://203.0.113.7"},                          // ip host promoted
		{"  ", "  ", ""}, // all blank
	}
	for _, c := range cases {
		if got := fleetTarget(c.url, c.host); got != c.want {
			t.Errorf("fleetTarget(%q,%q) = %q, want %q", c.url, c.host, got, c.want)
		}
	}
}

// TestCloudFleetPickListErrorSurfaces: a transport error listing the fleet is
// returned (not swallowed as an empty fleet).
func TestCloudFleetPickListErrorSurfaces(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{listErr: errors.New("boom")}
	if _, err := cloudFleetPick(w, client, strings.NewReader("")); err == nil {
		t.Fatal("a list error must surface, got nil")
	}
}

// TestCloudSetupLoginUsesDeviceFlowOnTTY: the wizard's Barkpark Cloud target
// logs in through the SAME device-link routine as bare `bp login` (charter
// decision 13 — no duplicated login): with no BARKPARK_PASSWORD and both
// streams a TTY, cloudSetupDeviceLogin drives /v1/auth/device/start → poll and
// stores the minted token, never touching /v1/auth/login.
func TestCloudSetupLoginUsesDeviceFlowOnTTY(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)
	forceDeviceTTY(t, true)
	stubBrowserOpener(t)
	t.Setenv("BARKPARK_PASSWORD", "")

	var ds deviceServer
	srv := newDeviceServer(t, &ds, 1, "sess-wizard", "team-wiz")

	// Point the saved config's CloudURL at the fake control plane (no token yet).
	if err := SaveConfig(&Config{CloudURL: srv.URL}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	w, _, _ := newTestWriter()
	w.output = "table"
	cfg, err := cloudSetupDeviceLogin(w)
	if err != nil {
		t.Fatalf("cloudSetupDeviceLogin: %v", err)
	}
	if ds.startHits.Load() != 1 {
		t.Fatalf("device/start hits = %d, want 1 (the device flow must run)", ds.startHits.Load())
	}
	if ds.loginHits.Load() != 0 {
		t.Fatalf("password /v1/auth/login must not be hit; got %d", ds.loginHits.Load())
	}
	if cfg.CloudToken != "sess-wizard" {
		t.Fatalf("CloudToken = %q, want the device-minted session", cfg.CloudToken)
	}
}
