package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// chatHostServer answers the workspace chat-host routes. owner decides
// whether a mint is allowed (403 otherwise, as the server does for a
// non-owner token).
func chatHostServer(t *testing.T, owner bool, seen *[]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		*seen = append(*seen, r.Method+" "+r.URL.Path+" "+string(body))
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "GET" && r.URL.Path == "/w/acme/v1/chat-hosts":
			_, _ = w.Write([]byte(`{"hosts":[{"id":"h1","name":"vm","enrolled":false,"online":false,"approved_roots":["/srv/bot"],"enrollment_expires_at":"` +
				time.Now().Add(5*time.Minute).UTC().Format(time.RFC3339) + `"},{"id":"h2","name":"mac","enrolled":true,"online":true,"approved_roots":["/Users/me/bot"],"capabilities":{"providers":{"claude":{"installed":true,"auth_ready":true,"version":"2.1.328"},"codex":{"installed":false,"auth_ready":false}}}}]}`))
		case !owner && r.Method == "POST":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"workspace owner required"}}`))
		case r.Method == "POST" && r.URL.Path == "/w/acme/v1/chat-hosts/enrollments":
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"host":{"id":"h9","name":"vm2","enrolled":false,"approved_roots":["/srv/bot"],"enrollment_expires_at":"2099-01-01T00:00:00Z"},"enrollment_token":"SECRET-CODE"}`))
		case r.Method == "POST" && r.URL.Path == "/w/acme/v1/chat-hosts/h1/enrollment":
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"host":{"id":"h10","name":"vm","enrolled":false,"approved_roots":["/srv/bot"],"enrollment_expires_at":"2099-01-01T00:00:00Z"},"enrollment_token":"NEW-CODE"}`))
		case r.Method == "DELETE" && r.URL.Path == "/w/acme/v1/chat-hosts/h2":
			_, _ = w.Write([]byte(`{"host":{"id":"h2","name":"mac","revoked":true}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"host not found"}}`))
		}
	}))
}

func chatHostCtx(url string) manifest.Context {
	return manifest.Context{Server: url, Token: "tok", Workspace: "acme"}
}

// TestChatHostEnrollNonOwnerHint: a token that is not the workspace owner's
// is refused by the server; bp says whose token it needs, exits 3, and prints
// no code.
func TestChatHostEnrollNonOwnerHint(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, false, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"enroll", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitAuth {
		t.Fatalf("rc = %d, want %d (auth)", rc, exitAuth)
	}
	if !strings.Contains(stderr.String(), "this needs the workspace owner's token") {
		t.Fatalf("stderr does not say whose token it needs:\n%s", stderr.String())
	}
	if strings.Contains(stdout.String()+stderr.String(), "printf") {
		t.Fatal("a refused mint must print no command")
	}
}

func TestChatHostEnrollPrintsTheCommandWithTheCodeOnStdin(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"enroll", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitOK {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
	want := "printf '%s\\n' SECRET-CODE | barkpark-chat-host enroll --url " + srv.URL + " --root /srv/bot"
	if !strings.Contains(stdout.String(), want) {
		t.Fatalf("stdout lacks the command %q:\n%s", want, stdout.String())
	}
	if len(seen) != 1 || !strings.Contains(seen[0], `"approved_roots":["/srv/bot"]`) || !strings.Contains(seen[0], `"name":"vm2"`) {
		t.Fatalf("requests = %q", seen)
	}
}

func TestChatHostEnrollJSONCarriesTheCommand(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if rc := runChatHost(w, globals{}, chatHostCtx(srv.URL), []string{"enroll", "--name=vm2", "--root=/srv/bot"}); rc != exitOK {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, stdout.String())
	}
	if got["enrollment_token"] != "SECRET-CODE" || !strings.Contains(got["command"].(string), "barkpark-chat-host enroll") {
		t.Fatalf("json = %v", got)
	}
}

func TestChatHostListReadsStates(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	if rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"list"}); rc != exitOK {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
	text := stdout.String()
	for _, want := range []string{"waiting, code expires in", "online", "Claude: signed in · 2.1.328", "Codex: not installed"} {
		if !strings.Contains(text, want) {
			t.Errorf("list output lacks %q:\n%s", want, text)
		}
	}
}

func TestChatHostNewCodeResolvesTheName(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	if rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"new-code", "vm"}); rc != exitOK {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
	if !strings.Contains(stdout.String(), "NEW-CODE") || seen[len(seen)-1] != "POST /w/acme/v1/chat-hosts/h1/enrollment {}" {
		t.Fatalf("stdout %s\nrequests %q", stdout.String(), seen)
	}
}

func TestChatHostRevokeByName(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	if rc := runChatHost(newWriter(&stdout, &stderr), globals{yes: true}, chatHostCtx(srv.URL), []string{"revoke", "mac"}); rc != exitOK {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
	if !strings.Contains(stdout.String(), "Revoked mac") {
		t.Fatalf("stdout = %s", stdout.String())
	}
}

// sentDelete reports whether the fake server saw a DELETE.
func sentDelete(seen []string) bool {
	for _, s := range seen {
		if strings.HasPrefix(s, "DELETE ") {
			return true
		}
	}
	return false
}

// TestChatHostRevokeSendsNoDeleteWithoutYes: revoke is destructive. In a
// script (stdin not a terminal) with no --yes it refuses before the DELETE;
// on a terminal it asks, and only "y" sends it.
func TestChatHostRevokeSendsNoDeleteWithoutYes(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	prevIn, prevTTY := destroyStdin, destroyStdinIsTTY
	t.Cleanup(func() { destroyStdin, destroyStdinIsTTY = prevIn, prevTTY })

	destroyStdinIsTTY = func(io.Reader) bool { return false }
	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"revoke", "mac"})
	if rc != exitUsage || sentDelete(seen) {
		t.Fatalf("rc = %d, DELETE sent = %v; want exit %d and no DELETE", rc, sentDelete(seen), exitUsage)
	}
	if !strings.Contains(stderr.String(), "--yes") || !strings.Contains(stderr.String(), "Revoke mac") {
		t.Fatalf("stderr does not name the host and --yes:\n%s", stderr.String())
	}

	destroyStdinIsTTY = func(io.Reader) bool { return true }
	destroyStdin = strings.NewReader("n\n")
	stderr.Reset()
	if rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"revoke", "mac"}); rc != exitUsage || sentDelete(seen) {
		t.Fatalf("answering n: rc = %d, DELETE sent = %v", rc, sentDelete(seen))
	}

	destroyStdin = strings.NewReader("y\n")
	if rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"revoke", "mac"}); rc != exitOK || !sentDelete(seen) {
		t.Fatalf("answering y: rc = %d, DELETE sent = %v, stderr %s", rc, sentDelete(seen), stderr.String())
	}
}

// TestChatHostRevokeYesFromExecute: --yes after the verb reaches revoke
// through the global flags, with no usage error.
func TestChatHostRevokeYesFromExecute(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()

	g, rest, err := parseGlobals([]string{"chat-host", "revoke", "mac", "--yes"})
	if err != nil || !g.yes {
		t.Fatalf("parseGlobals: g.yes = %v, err = %v", g.yes, err)
	}
	var stdout, stderr bytes.Buffer
	if rc := runChatHost(newWriter(&stdout, &stderr), g, chatHostCtx(srv.URL), rest[1:]); rc != exitOK || !sentDelete(seen) {
		t.Fatalf("rc = %d, DELETE sent = %v, stderr %s", rc, sentDelete(seen), stderr.String())
	}
}

// TestChatHostNewCodeOnAnOldServer: a server without the new-code route
// answers 404 "document not found"; bp says the server is too old and what
// to do instead.
func TestChatHostNewCodeOnAnOldServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "GET" {
			_, _ = w.Write([]byte(`{"hosts":[{"id":"h1","name":"vm","enrolled":false,"approved_roots":["/srv/bot"]}]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"document not found"}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL), []string{"new-code", "vm"})
	if rc == exitOK || !strings.Contains(stderr.String(), "too old for new-code") {
		t.Fatalf("rc = %d, stderr:\n%s", rc, stderr.String())
	}
	if strings.Contains(stderr.String(), "document not found") {
		t.Fatalf("stderr passes the server's raw 404 through:\n%s", stderr.String())
	}
}

// TestChatHostListSurvivesAnEmptyProviderName: a host may report a provider
// with an empty name; list reads it instead of panicking.
func TestChatHostListSurvivesAnEmptyProviderName(t *testing.T) {
	lines := chatHostCapabilityLines(map[string]any{"providers": map[string]any{
		"": map[string]any{"installed": true}, "claude": map[string]any{"installed": false},
	}})
	if len(lines) != 2 || lines[0] != "(unnamed provider): installed, not signed in" || lines[1] != "Claude: not installed" {
		t.Fatalf("lines = %q", lines)
	}
}

func TestChatHostEnrollRefusesARelativeRoot(t *testing.T) {
	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx("http://unused"),
		[]string{"enroll", "--name", "vm", "--root", "bot"})
	if rc != exitUsage || !strings.Contains(stderr.String(), "absolute") {
		t.Fatalf("rc = %d, stderr %s", rc, stderr.String())
	}
}
