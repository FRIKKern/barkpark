package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

const loginTeamUUID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

// teamLoginServer is a fake control plane for `bp login --team`: it records the
// team_id device/start received, answers 422 invalid_team when refuse is set,
// approves the first poll with the requested team, and serves /v1/me with one
// membership (slug "acme") for slug resolution.
type teamLoginServer struct {
	refuse    bool
	startHits atomic.Int64
	meHits    atomic.Int64
	gotTeam   atomic.Value // string; "<absent>" when the body carried no team_id
}

func newTeamLoginServer(t *testing.T, s *teamLoginServer) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/device/start":
			s.startHits.Add(1)
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			if v, ok := body["team_id"].(string); ok {
				s.gotTeam.Store(v)
			} else {
				s.gotTeam.Store("<absent>")
			}
			if s.refuse {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = io.WriteString(w, `{"error":"invalid_team"}`)
				return
			}
			_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"http://x/device","interval":1,"expires_in":900}`)
		case "/v1/auth/device/poll":
			_, _ = io.WriteString(w, `{"token":"sess-team","team_id":"`+loginTeamUUID+`"}`)
		case "/v1/me":
			s.meHits.Add(1)
			_, _ = io.WriteString(w, `{"user":{"id":"u1","email":"a@b.com"},"teams":[{"id":"`+loginTeamUUID+`","name":"Acme","slug":"acme","role":"owner"}]}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func (s *teamLoginServer) team() string {
	v, _ := s.gotTeam.Load().(string)
	return v
}

// TestLoginTeamSendsTeamID: `bp login --team <uuid>` takes the browser flow and
// sends team_id on device/start; the session lands in that team.
func TestLoginTeamSendsTeamID(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 5)
	stubBrowserOpener(t)
	t.Setenv("BARKPARK_PASSWORD", "")

	var s teamLoginServer
	srv := newTeamLoginServer(t, &s)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runLoginCloud(out, []string{"--url", srv.URL, "--team", loginTeamUUID})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if got := s.team(); got != loginTeamUUID {
		t.Fatalf("device/start team_id = %q, want %s", got, loginTeamUUID)
	}
	if loaded, _ := LoadConfig(); loaded.CloudTeam != loginTeamUUID || loaded.CloudToken != "sess-team" {
		t.Fatalf("stored team/token = %q/%q", loaded.CloudTeam, loaded.CloudToken)
	}
}

// TestLoginWithoutTeamSendsNoTeamID: the unbound login is unchanged on the wire.
func TestLoginWithoutTeamSendsNoTeamID(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 5)
	stubBrowserOpener(t)
	t.Setenv("BARKPARK_PASSWORD", "")

	var s teamLoginServer
	srv := newTeamLoginServer(t, &s)
	_, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runLoginCloud(out, []string{"--url", srv.URL, "--device"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if got := s.team(); got != "<absent>" {
		t.Fatalf("unbound login sent team_id %q; want none", got)
	}
}

// TestLoginTeamInvalidTeamRefusal: a 422 invalid_team is a clear usage refusal
// naming the --team value — not "could not start browser login", not exitAuth.
func TestLoginTeamInvalidTeamRefusal(t *testing.T) {
	for _, extra := range [][]string{nil, {"--device-start"}} {
		name := "interactive"
		if extra != nil {
			name = "device-start"
		}
		t.Run(name, func(t *testing.T) {
			withTempConfigHome(t)
			withInstantDevicePolls(t, 5)
			stubBrowserOpener(t)
			t.Setenv("BARKPARK_PASSWORD", "")

			s := teamLoginServer{refuse: true}
			srv := newTeamLoginServer(t, &s)
			args := append([]string{"--url", srv.URL, "--team", loginTeamUUID}, extra...)
			stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
				return runLoginCloud(out, args)
			})
			if code != exitUsage {
				t.Fatalf("exit = %d, want exitUsage (%d)\n%s", code, exitUsage, stdout)
			}
			if !strings.Contains(stdout, `"invalid_team"`) || !strings.Contains(stdout, "no team "+loginTeamUUID+" exists") {
				t.Fatalf("envelope should carry code invalid_team and name the team:\n%s", stdout)
			}
			if loaded, _ := LoadConfig(); loaded.CloudToken != "" {
				t.Fatalf("a refused start must store nothing; token %q", loaded.CloudToken)
			}
		})
	}
}

// TestLoginTeamDeviceStartSendsTeamID: the non-interactive first leg binds too.
func TestLoginTeamDeviceStartSendsTeamID(t *testing.T) {
	withTempConfigHome(t)
	var s teamLoginServer
	srv := newTeamLoginServer(t, &s)
	_, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runLoginCloud(out, []string{"--url", srv.URL, "--device-start", "--team=" + loginTeamUUID})
	})
	if code != exitOK || s.team() != loginTeamUUID {
		t.Fatalf("exit=%d team_id=%q, want 0 and %s", code, s.team(), loginTeamUUID)
	}
}

// TestLoginTeamSlugResolution: a slug resolves through /v1/me from a signed-in
// session on the same control plane; with no session it is refused up front
// (the control plane's device/start takes a UUID only).
func TestLoginTeamSlugResolution(t *testing.T) {
	t.Run("signed in → slug resolves to UUID", func(t *testing.T) {
		withTempConfigHome(t)
		withInstantDevicePolls(t, 5)
		stubBrowserOpener(t)
		t.Setenv("BARKPARK_PASSWORD", "")
		var s teamLoginServer
		srv := newTeamLoginServer(t, &s)
		if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "old-sess"}); err != nil {
			t.Fatal(err)
		}
		_, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--team", "ACME"})
		})
		if code != exitOK || s.team() != loginTeamUUID || s.meHits.Load() < 1 { // +1 for the receipt's account lookup
			t.Fatalf("exit=%d team_id=%q meHits=%d", code, s.team(), s.meHits.Load())
		}
	})
	t.Run("signed in, not a member → invalid_team, no start", func(t *testing.T) {
		withTempConfigHome(t)
		var s teamLoginServer
		srv := newTeamLoginServer(t, &s)
		if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "old-sess"}); err != nil {
			t.Fatal(err)
		}
		stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--team", "other"})
		})
		if code != exitUsage || s.startHits.Load() != 0 || !strings.Contains(stdout, "acme") {
			t.Fatalf("exit=%d startHits=%d\n%s", code, s.startHits.Load(), stdout)
		}
	})
	t.Run("no session → refused, no network", func(t *testing.T) {
		withTempConfigHome(t)
		var s teamLoginServer
		srv := newTeamLoginServer(t, &s)
		stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
			return runLoginCloud(out, []string{"--url", srv.URL, "--team", "acme"})
		})
		if code != exitUsage || s.startHits.Load() != 0 || s.meHits.Load() != 0 {
			t.Fatalf("exit=%d startHits=%d meHits=%d", code, s.startHits.Load(), s.meHits.Load())
		}
		if !strings.Contains(stdout, "UUID") {
			t.Fatalf("refusal should ask for the UUID:\n%s", stdout)
		}
	})
}

// TestLoginTeamFlagConflicts: --team rides only the browser start; beside a
// password credential or a --device-poll code it is a usage error, never dropped.
func TestLoginTeamFlagConflicts(t *testing.T) {
	for _, args := range [][]string{
		{"--team", loginTeamUUID, "--email", "a@b.com"},
		{"--team", loginTeamUUID, "--password", "pw"},
		{"--team", loginTeamUUID, "--device-poll", "d"},
	} {
		t.Run(strings.Join(args[2:], " "), func(t *testing.T) {
			withTempConfigHome(t)
			var s teamLoginServer
			srv := newTeamLoginServer(t, &s)
			_, _, code := runCloudCapture(t, true, func(out *writer) int {
				return runLoginCloud(out, append([]string{"--url", srv.URL}, args...))
			})
			if code != exitUsage || s.startHits.Load() != 0 {
				t.Fatalf("exit=%d startHits=%d, want exitUsage and no start", code, s.startHits.Load())
			}
		})
	}
}

// TestClassifyDevicePollTeamMismatch: a team_mismatch reaching the poll names the
// cause instead of "denied or expired", and is an auth refusal (exitAuth).
func TestClassifyDevicePollTeamMismatch(t *testing.T) {
	err := classifyDevicePollError(&testErr{"team_mismatch"})
	if !asDeviceAuthError(err) || !strings.Contains(err.Error(), "not a member of the team") {
		t.Fatalf("got %v", err)
	}
}

type testErr struct{ s string }

func (e *testErr) Error() string { return e.s }
