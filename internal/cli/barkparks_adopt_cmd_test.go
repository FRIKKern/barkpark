package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const adoptBoxToken = "box-admin-token-from-file"

const adoptOKBody = `{"ok":true,"barkpark":{"id":"bp-new","name":"standby","slug":"standby","url":"https://standby.example.org","host":"203.0.113.20","mode":"managed"},
"adopted":{"workspace":"default","credential_id":"tok-cloud-1","credential_label":"barkpark cloud admin",
"armed":{"credential":{"status":"stored","detail":"Cloud's own admin token"},"self_update":{"status":"arming","detail":"enable_apply job queued"},
"autoupdate":{"status":"on"},"monitoring_agent":{"status":"not_installed","detail":"no Cloud job installs barkpark-agent"}}}}`

type adoptPlane struct {
	hits int
	body map[string]any
}

func newAdoptPlane(t *testing.T, status int, resp string) (*httptest.Server, *adoptPlane) {
	t.Helper()
	p := &adoptPlane{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits++
		if r.Method != http.MethodPost || r.URL.Path != "/v1/barkparks/adopt" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &p.body)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, resp)
	}))
	t.Cleanup(srv.Close)
	return srv, p
}

func writeTokenFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "box.token")
	if err := os.WriteFile(path, []byte(adoptBoxToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func adoptArgs(extra ...string) []string {
	return append([]string{"adopt", "--url", "https://standby.example.org", "--host", "203.0.113.20", "--name", "Standby Box"}, extra...)
}

func TestBarkparksAdoptSendsFileTokenAndPrintsWhatWasArmed(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newAdoptPlane(t, http.StatusCreated, adoptOKBody)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, adoptArgs("--token-file", writeTokenFile(t)))
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s\n%s", code, stdout, stderr)
	}
	if plane.body["admin_token"] != adoptBoxToken {
		t.Fatalf("the file's token must reach the plane trimmed; got %v", plane.body["admin_token"])
	}
	if plane.body["slug"] != "standby-box" || plane.body["host"] != "203.0.113.20" {
		t.Fatalf("body = %v", plane.body)
	}
	if strings.Contains(stdout+stderr, adoptBoxToken) {
		t.Fatal("the box token must never be printed")
	}
	for _, want := range []string{"Attached standby (bp-new)", "self_update", "arming", "monitoring_agent", "not_installed", `"barkpark cloud admin"`, "was not stored"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
}

func TestBarkparksAdoptJSONReemitsTheEnvelope(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newAdoptPlane(t, http.StatusCreated, adoptOKBody)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runBarkparks(out, adoptArgs("--token-file", writeTokenFile(t)))
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stdout)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("stdout is not one JSON object: %v\n%s", err, stdout)
	}
	adopted, _ := got["adopted"].(map[string]any)
	if adopted["credential_label"] != "barkpark cloud admin" {
		t.Fatalf("envelope = %v", got)
	}
}

func TestBarkparksAdoptTokenFromConfig(t *testing.T) {
	withTempConfigHome(t)
	srv, plane := newAdoptPlane(t, http.StatusCreated, adoptOKBody)
	if err := SaveConfig(&Config{
		CloudURL: srv.URL, CloudToken: "sess-abc", CloudTeam: "team-1",
		Server: "https://standby.example.org", AdminToken: "saved-admin-token",
	}); err != nil {
		t.Fatal(err)
	}

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, adoptArgs("--token-from-config"))
	})
	if code != exitOK {
		t.Fatalf("exit = %d\n%s", code, stderr)
	}
	if plane.body["admin_token"] != "saved-admin-token" {
		t.Fatalf("admin_token = %v", plane.body["admin_token"])
	}
}

func TestBarkparksAdoptRefusesBeforeAnyRequest(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"token on argv", adoptArgs("--admin-token", "leaky")},
		{"no token source", adoptArgs()},
		{"both token sources", adoptArgs("--token-file", "x", "--token-from-config")},
		{"plain http url", []string{"adopt", "--url", "http://203.0.113.20", "--host", "203.0.113.20", "--name", "x", "--token-from-config"}},
		{"missing host", []string{"adopt", "--url", "https://x.example.org", "--name", "x", "--token-from-config"}},
		{"nothing saved for the url", adoptArgs("--token-from-config")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			srv, plane := newAdoptPlane(t, http.StatusCreated, adoptOKBody)
			seedCloudLogin(t, srv.URL)

			stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
				out.output = "table"
				return runBarkparks(out, tc.args)
			})
			if code != exitUsage {
				t.Fatalf("exit = %d, want %d\n%s%s", code, exitUsage, stdout, stderr)
			}
			if plane.hits != 0 {
				t.Fatalf("a refused adopt must not reach the plane; %d request(s)", plane.hits)
			}
			if strings.Contains(stdout+stderr, "leaky") {
				t.Fatal("the argv token must not be echoed")
			}
		})
	}
}

func TestBarkparksAdoptSurfacesTheBoxTooOldRefusal(t *testing.T) {
	withTempConfigHome(t)
	srv, _ := newAdoptPlane(t, http.StatusConflict,
		`{"error":"box_too_old","missing":"POST /v1/tokens/elevated","detail":"The box has no POST /v1/tokens/elevated. Update the box to current main first, then adopt it."}`)
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, adoptArgs("--token-file", writeTokenFile(t)))
	})
	if code == exitOK {
		t.Fatalf("a refusal must not exit 0\n%s", stdout)
	}
	if !strings.Contains(stdout+stderr, "Update the box") {
		t.Fatalf("the plane's sentence must reach the user:\n%s%s", stdout, stderr)
	}
}

func TestAdoptSlug(t *testing.T) {
	for in, want := range map[string]string{
		"Standby Box":     "standby-box",
		"barkpark-cms":    "barkpark-cms",
		"  Prod (old) #2": "prod-old-2",
	} {
		if got := adoptSlug(in); got != want {
			t.Errorf("adoptSlug(%q) = %q, want %q", in, got, want)
		}
	}
}
