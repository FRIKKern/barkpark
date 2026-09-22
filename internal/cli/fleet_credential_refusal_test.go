package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// fleet_credential_refusal_test.go pins task-3f8604ba07cfac82: bp must not decide
// a role-based affordance locally, and the fail-open shapes the deleted check
// missed must land on the SAME outcome as the shape it caught.
//
// THE REFUSALS HERE ARE REAL. Every refused arm drives a genuine
// *cloudclient.Client against an httptest control plane, so the *CloudRefusal the
// code reads is produced by cloudError's own decode (#10086) — not a struct this
// file filled in. A test that hand-builds the typed value proves the renderer and
// nothing about the decode it depends on.

// fleetCredServer is a control plane that answers the credentials route with one
// canned status+body and COUNTS the calls, so a test can prove the request was
// actually made (the old code's whole defect was answering without asking).
type fleetCredServer struct {
	*httptest.Server
	calls atomic.Int64
}

func newFleetCredServer(t *testing.T, status int, body string) *fleetCredServer {
	t.Helper()
	s := &fleetCredServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/credentials") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		s.calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *fleetCredServer) fleetClient(list []cloudclient.Barkpark) *liveFleetClient {
	return &liveFleetClient{
		list:   list,
		client: &cloudclient.Client{BaseURL: s.URL, Token: "sess-abc"},
	}
}

// liveFleetClient is a cloudFleetClient whose LIST is canned but whose
// CREDENTIALS call goes over the wire to the httptest control plane above.
type liveFleetClient struct {
	list   []cloudclient.Barkpark
	client *cloudclient.Client
}

func (f *liveFleetClient) ListAllBarkparks(context.Context) ([]cloudclient.Barkpark, error) {
	return f.list, nil
}

func (f *liveFleetClient) GetCredentialsForTeam(ctx context.Context, id, teamID string) (cloudclient.Credentials, error) {
	return f.client.GetCredentialsForTeam(ctx, id, teamID)
}

// forbiddenBody is the shape the control plane sends when a gate refuses: the
// machine code in `error`, the human sentence in `detail`, and the cause +
// requirement as their own keys.
const fleetForbiddenBody = `{"error":"forbidden","detail":"your role on Docs cannot mint this Barkpark's admin token","reason":"role","required":"admin","scope":"team"}`

// fleetRoleShapes are the three Team shapes the row named. The first is the ONLY
// one the deleted local check could see; the other two are the wire shapes it
// failed open on — a nil Team (the default shape of the fleet list) and a Team
// whose Role key never arrived.
func fleetRoleShapes() []struct {
	name string
	team *cloudclient.Team
} {
	return []struct {
		name string
		team *cloudclient.Team
	}{
		{"explicit member", &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "member"}},
		{"empty role", &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: ""}},
		{"nil team", nil},
	}
}

// TestFleetCredentialAuthorityComesFromTheServerNotTheRoleString is the fail-open
// pin. All three Team shapes are run against ONE refusing control plane; all
// three must converge on the refusal, and — the half that could not be true
// before — all three must have actually ASKED. A spelling-keyed check cannot pass
// this: it answers "member" locally (never asking) and walks the other two
// straight past the refusal into a saved token.
func TestFleetCredentialAuthorityComesFromTheServerNotTheRoleString(t *testing.T) {
	for _, shape := range fleetRoleShapes() {
		t.Run(shape.name, func(t *testing.T) {
			withTempConfigHome(t)
			srv := newFleetCredServer(t, http.StatusForbidden, fleetForbiddenBody)
			picked := cloudclient.Barkpark{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: shape.team}
			client := srv.fleetClient([]cloudclient.Barkpark{picked})
			w, out, _ := newTestWriter()

			res, err := cloudResolveTarget(w, bufio.NewReader(strings.NewReader("")), client, picked)
			if err != nil {
				t.Fatalf("a refusal is a complete outcome, not a wizard error: %v", err)
			}
			if !res.LoggedInOnly {
				t.Fatalf("refused caller must stay LoggedInOnly, got %+v", res)
			}
			if res.Token != "" || res.Server != "" {
				t.Fatalf("refused caller resolved a credential: %+v", res)
			}
			if got := srv.calls.Load(); got != 1 {
				t.Fatalf("credentials route called %d times, want 1 — bp must ASK, never answer authority locally", got)
			}
			if !strings.Contains(out.String(), "cannot mint this Barkpark's admin token") {
				t.Fatalf("the server's own sentence is missing from the refusal:\n%s", out.String())
			}
			if strings.Contains(out.String(), "your member role") {
				t.Fatalf("bp restated the role itself instead of the server's reason:\n%s", out.String())
			}
		})
	}
}

// TestFleetCredentialPermittedRoleStillConnects is the QUIET arm: the same three
// shapes against a control plane that GRANTS must all resolve the target. Without
// it the fix above could be satisfied by refusing everyone.
func TestFleetCredentialPermittedRoleStillConnects(t *testing.T) {
	granted, err := json.Marshal(cloudclient.Credentials{AdminToken: "super-secret-token", URL: "https://alpha.example.com"})
	if err != nil {
		t.Fatalf("marshal credentials: %v", err)
	}
	for _, shape := range fleetRoleShapes() {
		t.Run(shape.name, func(t *testing.T) {
			withTempConfigHome(t)
			srv := newFleetCredServer(t, http.StatusOK, string(granted))
			picked := cloudclient.Barkpark{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: shape.team}
			client := srv.fleetClient([]cloudclient.Barkpark{picked})
			w, out, _ := newTestWriter()

			res, resErr := cloudResolveTarget(w, bufio.NewReader(strings.NewReader("")), client, picked)
			if resErr != nil {
				t.Fatalf("a granted fetch should succeed: %v", resErr)
			}
			if res.Token != "super-secret-token" {
				t.Fatalf("granted caller did not get the admin token, got %+v", res)
			}
			if res.LoggedInOnly {
				t.Fatalf("granted caller must not finish LoggedInOnly: %+v", res)
			}
			if strings.Contains(out.String(), "refused") {
				t.Fatalf("a granted fetch printed a refusal:\n%s", out.String())
			}
		})
	}
}

// TestFleetCredentialTransportBlipIsNotARefusal: a 500 decided NOTHING about
// authority and must not be rendered as one. This is the third defect the row
// named — the bare %v fall-through made a 403 and a hiccup identical.
func TestFleetCredentialTransportBlipIsNotARefusal(t *testing.T) {
	withTempConfigHome(t)
	srv := newFleetCredServer(t, http.StatusBadGateway, `{"error":"upstream_unavailable"}`)
	picked := cloudclient.Barkpark{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "member"}}
	client := srv.fleetClient([]cloudclient.Barkpark{picked})
	w, out, _ := newTestWriter()

	_, err := cloudResolveTarget(w, bufio.NewReader(strings.NewReader("")), client, picked)
	if err == nil {
		t.Fatal("a 502 must surface as an error on the setup path, not a silent logged-in-only")
	}
	if strings.Contains(out.String(), "refused your access") {
		t.Fatalf("a transport failure was rendered as an authority refusal:\n%s", out.String())
	}
}

// TestFinishSingleBarkparkRefusalIsServerStated runs the SECOND site — the
// auto-connect path in cloud12_cmd.go — through the same refusing control plane.
// Both sites carried the same local check, so both need the arm.
func TestFinishSingleBarkparkRefusalIsServerStated(t *testing.T) {
	for _, shape := range fleetRoleShapes() {
		t.Run(shape.name, func(t *testing.T) {
			withTempConfigHome(t)
			srv := newFleetCredServer(t, http.StatusForbidden, fleetForbiddenBody)
			only := cloudclient.Barkpark{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: shape.team}
			client := srv.fleetClient([]cloudclient.Barkpark{only})
			w, out, _ := newTestWriter()

			if code := finishSingleBarkpark(w, client, only); code != exitOK {
				t.Fatalf("a refusal is exit %d, want exitOK (%d)", code, exitOK)
			}
			if got := srv.calls.Load(); got != 1 {
				t.Fatalf("credentials route called %d times, want 1", got)
			}
			if !strings.Contains(out.String(), "cannot mint this Barkpark's admin token") {
				t.Fatalf("server sentence missing:\n%s", out.String())
			}
			if !strings.Contains(out.String(), "The server requires admin on the team.") {
				t.Fatalf("the server-named requirement is missing:\n%s", out.String())
			}
			if strings.Contains(out.String(), "your member role") {
				t.Fatalf("bp restated the role itself:\n%s", out.String())
			}
		})
	}
}

// TestFinishSingleBarkparkNoAdminTokenStillDivertsToManualPaste is the QUIET arm
// for the classifier's other branch: a 404/no_admin_token is a property of the
// BOX, not a refusal of the caller, and it must keep its manual-paste divert.
// Without this arm the widened refusal branch could swallow it.
func TestFinishSingleBarkparkNoAdminTokenStillDivertsToManualPaste(t *testing.T) {
	withTempConfigHome(t)
	srv := newFleetCredServer(t, http.StatusNotFound, `{"error":"no_admin_token"}`)
	only := cloudclient.Barkpark{ID: "bp-1", Name: "alpha", URL: "https://alpha.example.com", Team: &cloudclient.Team{ID: "team-docs", Name: "Docs", Role: "owner"}}
	client := srv.fleetClient([]cloudclient.Barkpark{only})
	w, out, _ := newTestWriter()

	if code := finishSingleBarkpark(w, client, only); code != exitOK {
		t.Fatalf("no_admin_token is exit %d, want exitOK", code)
	}
	if !strings.Contains(out.String(), "has no stored admin token") {
		t.Fatalf("manual-paste divert lost:\n%s", out.String())
	}
	if strings.Contains(out.String(), "refused your access") {
		t.Fatalf("no_admin_token was rendered as an authority refusal:\n%s", out.String())
	}
}

// TestNoLocalRoleStringDecidesAFleetAffordance is the STANDING guard, and it is
// the one that cannot be satisfied by deleting today's two lines and writing them
// again tomorrow: it scans the package source for a role-vocabulary string being
// compared in the fleet-credential files. It carries a reachability control so a
// zero can never mean "the scan found no files".
func TestNoLocalRoleStringDecidesAFleetAffordance(t *testing.T) {
	files := []string{"cloud12_cmd.go", "setup_cloud_login.go"}
	roleTokens := []string{`"member"`, `"owner"`, `"admin"`}

	scanned := 0
	for _, name := range files {
		src := readPackageSource(t, name)
		scanned++
		for _, tok := range roleTokens {
			for _, line := range strings.Split(src, "\n") {
				trimmed := strings.TrimSpace(line)
				if strings.HasPrefix(trimmed, "//") {
					continue // a comment may NAME the vocabulary; only code decides.
				}
				if strings.Contains(line, tok) {
					t.Errorf("%s decides on a role literal locally: %s\n"+
						"authority for a fleet affordance is the server's — see fleet_credential_refusal.go", name, trimmed)
				}
			}
		}
	}
	if scanned != len(files) {
		t.Fatalf("scanned %d files, want %d — the guard read nothing and would pass vacuously", scanned, len(files))
	}
	// REACHABILITY CONTROL: the scan must be able to see code in these files at
	// all. If this token vanishes the guard is measuring an empty string.
	for _, name := range files {
		if !strings.Contains(readPackageSource(t, name), "GetCredentialsForTeam") {
			t.Fatalf("%s does not contain the control token — the source scan is not reading the file it names", name)
		}
	}
}

// TestClassifyFleetCredentialErrorKeysOnTheTypedStatus pins the classifier on the
// facts rather than the sentence: the SAME prose with different statuses must
// classify differently, and a nil error must never read as a refusal.
func TestClassifyFleetCredentialErrorKeysOnTheTypedStatus(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want fleetCredentialOutcome
	}{
		{"nil", nil, fleetCredTransport},
		{"403 refusal", &cloudclient.CloudRefusal{HTTPStatus: http.StatusForbidden, Code: "forbidden"}, fleetCredForbidden},
		{"401 refusal", &cloudclient.CloudRefusal{HTTPStatus: http.StatusUnauthorized, Code: "unauthorized"}, fleetCredForbidden},
		{"502 blip", &cloudclient.CloudRefusal{HTTPStatus: http.StatusBadGateway, Code: "forbidden"}, fleetCredTransport},
		{"no_admin_token beats the 404", &cloudclient.CloudRefusal{HTTPStatus: http.StatusNotFound, Code: "no_admin_token"}, fleetCredNoAdminToken},
		{"untyped no_admin_token", errors.New("get credentials: no_admin_token"), fleetCredNoAdminToken},
		{"untyped transport", errors.New("dial tcp: i/o timeout"), fleetCredTransport},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got, _ := classifyFleetCredentialError(tc.err); got != tc.want {
				t.Fatalf("classify(%v) = %d, want %d", tc.err, got, tc.want)
			}
		})
	}
}

// readPackageSource reads one .go file of THIS package off disk. The guard above
// is a source scan, so it must read the real file rather than a copy.
func readPackageSource(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(raw)
}
