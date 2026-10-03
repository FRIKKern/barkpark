package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// whoami_memberships_test.go — `bp whoami` shows the token's workspace seats
// (task-7d4d405e0ee4bcbf, criterion 3). An admin token with no seat answers 403
// not_a_member everywhere; whoami is where an operator sees that state.

// identityServer serves the scope-fate manifest plus GET /v1/tokens/current with
// the given body (or a 404 when body is empty, like a server predating the route).
func identityServer(t *testing.T, identityBody string, sawBearer *string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/capabilities":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(scopeFateManifestJSON))
		case "/v1/tokens/current":
			if sawBearer != nil {
				*sawBearer = r.Header.Get("Authorization")
			}
			if identityBody == "" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(identityBody))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func whoamiSeatsJSON(t *testing.T, ctx manifest.Context) map[string]any {
	t.Helper()
	var out, errb bytes.Buffer
	w := newWriter(&out, &errb)
	w.output = "json"
	if code := runWhoami(w, globals{server: ctx.Server}, ctx, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, errb.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(out.Bytes(), &payload); err != nil {
		t.Fatalf("parse json: %v\n%s", err, out.String())
	}
	return payload
}

const identityTwoSeats = `{"token":{"id":"tok-1","label":"laptop","permissions":["read","write","admin"],"expires_at":null,"workspace_id":"ws-a","workspace":"acme"},
 "memberships":[{"workspace_id":"ws-a","workspace_slug":"acme","role":"admin"},{"workspace_id":"ws-b","workspace_slug":"beta","role":"member"}]}`

func TestWhoamiJSONShowsTheTokensMemberships(t *testing.T) {
	withTempConfigHome(t)
	var bearer string
	srv := identityServer(t, identityTwoSeats, &bearer)

	payload := whoamiSeatsJSON(t, manifest.Context{Server: srv.URL, Token: "sekret", Workspace: "default", Project: "default", Dataset: "production"})

	if bearer != "Bearer sekret" {
		t.Errorf("identity probe bearer = %q, want the resolved token", bearer)
	}
	got, ok := payload["memberships"].([]any)
	if !ok || len(got) != 2 {
		t.Fatalf("memberships = %v, want two seats", payload["memberships"])
	}
	first := got[0].(map[string]any)
	if first["id"] != "ws-a" || first["workspace"] != "acme" || first["role"] != "admin" {
		t.Errorf("first seat = %v, want {id ws-a, workspace acme, role admin}", first)
	}
	if strings.Contains(mustJSON(t, payload), "sekret") {
		t.Errorf("whoami JSON leaked the token value")
	}
}

func TestWhoamiJSONNoSeatsIsAnEmptyList(t *testing.T) {
	withTempConfigHome(t)
	srv := identityServer(t, `{"token":{"id":"tok-2","permissions":["read","write","admin"]},"memberships":[]}`, nil)

	payload := whoamiSeatsJSON(t, manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})

	got, ok := payload["memberships"].([]any)
	if !ok || len(got) != 0 {
		t.Fatalf("memberships = %#v, want an empty list (measured: no seats)", payload["memberships"])
	}
}

func TestWhoamiJSONMembershipsNullWhenNotMeasured(t *testing.T) {
	withTempConfigHome(t)

	// An older server without the route: null, never a fabricated empty list.
	old := identityServer(t, "", nil)
	if v, ok := whoamiSeatsJSON(t, manifest.Context{Server: old.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"})["memberships"]; !ok || v != nil {
		t.Errorf("memberships = %#v on a server without the route, want null", v)
	}

	// No token: nothing to ask about, and no probe.
	var bearer string
	srv := identityServer(t, identityTwoSeats, &bearer)
	if v := whoamiSeatsJSON(t, manifest.Context{Server: srv.URL, Workspace: "default", Project: "default", Dataset: "production"})["memberships"]; v != nil {
		t.Errorf("memberships = %#v with no token, want null", v)
	}
	if bearer != "" {
		t.Errorf("whoami probed /v1/tokens/current without a token")
	}
}

func TestWhoamiHumanPrintsTheSeats(t *testing.T) {
	withTempConfigHome(t)
	srv := identityServer(t, identityTwoSeats, nil)

	var out, errb bytes.Buffer
	w := newWriter(&out, &errb)
	w.output = "table"
	ctx := manifest.Context{Server: srv.URL, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
	if code := runWhoami(w, globals{server: srv.URL}, ctx, tokenProvenance{}); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(out.String(), "seats:     acme (admin), beta (member)") {
		t.Errorf("human whoami does not list the seats:\n%s", out.String())
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}
