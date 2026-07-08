package cli

// cloud_members_test.go proves `bp cloud members` against a fake control plane
// answering BOTH team routes (/members + /invitations): the full roster + the
// pending invitations render, the admin-gated 403 on invitations degrades to an
// honest note (never a failure of the whole view), `-o json` emits the two
// arrays verbatim under {members, invitations} (invitations:null when forbidden),
// and the team-scoped 404 on members maps to the no-existence-leak sentence.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const membersBody = `{"members":[` +
	`{"user_id":"u-1","email":"owner@team.io","role":"owner","joined_at":"2026-06-01T09:00:00Z"},` +
	`{"user_id":"u-2","email":"dev@team.io","role":"member","joined_at":"2026-06-15T12:00:00Z"}]}`

const invitationsBody = `{"invitations":[` +
	`{"id":"i-1","email":"newhire@team.io","role":"member","expires_at":"2026-07-15T00:00:00Z","inserted_at":"2026-07-08T00:00:00Z"}]}`

// membersRoute is one route the fake control plane serves: a status + body for a
// given path suffix.
type membersRoute struct {
	status int
	body   string
}

// newMembersServer stands up a fake control plane routing /members and
// /invitations independently, seeds a cloud login (team "team-1") pointed at it,
// and records each path it saw.
func newMembersServer(t *testing.T, members, invitations membersRoute) *[]string {
	t.Helper()
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/members"):
			w.WriteHeader(members.status)
			_, _ = w.Write([]byte(members.body))
		case strings.HasSuffix(r.URL.Path, "/invitations"):
			w.WriteHeader(invitations.status)
			_, _ = w.Write([]byte(invitations.body))
		default:
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
		}
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &seen
}

// runMembers drives runCloudMembers with an in-memory writer.
func runMembers(t *testing.T, output string, color bool, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = color
	code := runCloudMembers(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudMembersFull: both routes answer 200 — the roster + the pending
// invitation render, the requests hit the session team, and exit is 0.
func TestRunCloudMembersFull(t *testing.T) {
	seen := newMembersServer(t, membersRoute{200, membersBody}, membersRoute{200, invitationsBody})

	stdout, stderr, code := runMembers(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{"owner@team.io", "dev@team.io", "owner", "member", "newhire@team.io", "Pending invitations"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("render missing %q:\n%s", want, stdout)
		}
	}
	// The session team ("team-1", from seedCloudLogin) drove both paths.
	if len(*seen) != 2 || (*seen)[0] != "/v1/teams/team-1/members" {
		t.Fatalf("paths hit = %v, want the two team-1 routes", *seen)
	}
}

// TestRunCloudMembersInvitationsForbidden: a plain member's 403 on invitations
// degrades to an honest note — the roster still renders and exit stays 0.
func TestRunCloudMembersInvitationsForbidden(t *testing.T) {
	newMembersServer(t, membersRoute{200, membersBody}, membersRoute{403, `{"error":"forbidden"}`})

	stdout, _, code := runMembers(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (a forbidden invitations list is not a failure)", code)
	}
	if !strings.Contains(stdout, "owner@team.io") {
		t.Fatalf("the roster must still render:\n%s", stdout)
	}
	if !strings.Contains(stdout, "admins only") {
		t.Fatalf("want the honest admin-gated note:\n%s", stdout)
	}
}

// TestRunCloudMembersEmptyInvitations: a 200 with no pending invitations shows
// the calm empty state, not a blank table.
func TestRunCloudMembersEmptyInvitations(t *testing.T) {
	newMembersServer(t, membersRoute{200, membersBody}, membersRoute{200, `{"invitations":[]}`})
	stdout, _, code := runMembers(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "No pending invitations.") {
		t.Fatalf("want the empty-invitations state:\n%s", stdout)
	}
}

// TestRunCloudMembersJSON: `-o json` emits the two arrays verbatim under
// {members, invitations}.
func TestRunCloudMembersJSON(t *testing.T) {
	newMembersServer(t, membersRoute{200, membersBody}, membersRoute{200, invitationsBody})
	stdout, _, code := runMembers(t, "json", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env struct {
		Members     []map[string]any `json:"members"`
		Invitations []map[string]any `json:"invitations"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("decode combined json: %v\n%s", err, stdout)
	}
	if len(env.Members) != 2 || len(env.Invitations) != 1 {
		t.Fatalf("combined json = %d members, %d invitations; want 2, 1", len(env.Members), len(env.Invitations))
	}
	if env.Members[0]["email"] != "owner@team.io" {
		t.Fatalf("members array not verbatim:\n%s", stdout)
	}
}

// TestRunCloudMembersJSONForbidden: when invitations are forbidden, the json
// carries invitations:null (honest absence) — never an empty list posing as
// "no invitations".
func TestRunCloudMembersJSONForbidden(t *testing.T) {
	newMembersServer(t, membersRoute{200, membersBody}, membersRoute{403, `{"error":"forbidden"}`})
	stdout, _, code := runMembers(t, "json", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal([]byte(stdout), &probe); err != nil {
		t.Fatalf("decode combined json: %v\n%s", err, stdout)
	}
	if strings.TrimSpace(string(probe["invitations"])) != "null" {
		t.Fatalf("forbidden invitations must be json null, got %q\n%s", probe["invitations"], stdout)
	}
}

// TestRunCloudMembersNotFound: a 404 on members (a non-member, or no such team)
// maps to the no-existence-leak sentence, exit not_found.
func TestRunCloudMembersNotFound(t *testing.T) {
	newMembersServer(t, membersRoute{404, `{"error":"not_found"}`}, membersRoute{200, invitationsBody})
	_, stderr, code := runMembers(t, "table", false)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "not a member") {
		t.Fatalf("want the no-existence-leak sentence:\n%s", stderr)
	}
}

// TestRunCloudMembersExplicitTeam: a positional team id overrides the session
// team, and both routes are scoped to it.
func TestRunCloudMembersExplicitTeam(t *testing.T) {
	seen := newMembersServer(t, membersRoute{200, membersBody}, membersRoute{200, invitationsBody})
	_, _, code := runMembers(t, "table", false, "team-other")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if len(*seen) == 0 || (*seen)[0] != "/v1/teams/team-other/members" {
		t.Fatalf("paths hit = %v, want the team-other route", *seen)
	}
}

// TestRunCloudMembersNoTeam: a session carrying a token but no team (and no
// positional) is a clear, actionable error before any network call.
func TestRunCloudMembersNoTeam(t *testing.T) {
	withTempConfigHome(t)
	if err := SaveConfig(&Config{CloudURL: "http://127.0.0.1:0", CloudToken: "sess-abc"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	_, stderr, code := runMembers(t, "table", false)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (generic)", code, exitGeneric)
	}
	if !strings.Contains(stderr, "no team") {
		t.Fatalf("want the no-team sentence:\n%s", stderr)
	}
}

// TestRunCloudMembersNoToken: without a Cloud session the command is an auth
// error with a `bp login` hint and makes no network call.
func TestRunCloudMembersNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runMembers(t, "table", false)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudMembersHelp: -h prints usage and exits 0 without a network call.
func TestRunCloudMembersHelp(t *testing.T) {
	withTempConfigHome(t)
	stdout, _, code := runMembers(t, "table", false, "-h")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "bp cloud members") {
		t.Fatalf("help must name the command:\n%s", stdout)
	}
}
