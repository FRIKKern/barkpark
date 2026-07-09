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
}

func (f *fakeFleetClient) ListBarkparks(context.Context) ([]cloudclient.Barkpark, error) {
	return f.list, f.listErr
}

func (f *fakeFleetClient) GetCredentials(_ context.Context, id string) (cloudclient.Credentials, error) {
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
			{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"},
			{ID: "bp-2", Name: "bravo", URL: "https://bravo.example.com"},
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
	// The admin token must never be printed on either stream.
	if strings.Contains(out.String()+errb.String(), "super-secret-token") {
		t.Fatalf("admin token leaked into output:\nstdout:%s\nstderr:%s", out.String(), errb.String())
	}
}

// TestCloudFleetPickBlankSelectionStaysLoggedIn: a blank / EOF selection is not a
// dead end — it finishes logged-in.
func TestCloudFleetPickBlankSelectionStaysLoggedIn(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list:  []cloudclient.Barkpark{{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"}},
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
		list:  []cloudclient.Barkpark{{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"}},
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
// picked Barkpark offers a manual token paste, which feeds the same connect.
func TestCloudFleetPickNoAdminTokenManualPaste(t *testing.T) {
	w, _, _ := newTestWriter()
	client := &fakeFleetClient{
		list:     []cloudclient.Barkpark{{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"}},
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
		list:     []cloudclient.Barkpark{{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com"}},
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
