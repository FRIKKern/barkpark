package setup

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// connect_stranger_test.go pins what a first-time user reads after
// `bp setup --target connect` (the stranger walk, 2026-09-30):
//
//   - the first suggested step must RUN — `bp doc ls` alone is a usage error
//     (it needs a <type>) and exited 2 as the very first thing a stranger typed;
//   - a tokenless connect must say it is read-only and how to add a token,
//     because every write verb is hidden at tier none and nothing else says so.

func capsServer(t *testing.T, tier string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth_tier":"` + tier + `","manifest_version":"1","server":{"name":"barkpark","version":"0.1.0"},"commands":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestConnectNextStepsNeverSuggestABareDocLs(t *testing.T) {
	srv := capsServer(t, "admin")
	var out bytes.Buffer
	if err := executeConnect(SetupPlan{Server: srv.URL, Token: "tok"}, Options{Store: &memConfigStore{}, Out: &out}); err != nil {
		t.Fatalf("connect: %v", err)
	}
	for _, ln := range strings.Split(out.String(), "\n") {
		if f := strings.Fields(ln); len(f) == 3 && f[0] == "bp" && f[1] == "doc" && f[2] == "ls" {
			t.Fatalf("next steps suggest a bare `bp doc ls`, which exits 2 (missing <type>):\n%s", out.String())
		}
	}
	for _, want := range []string{"bp schema ls", "bp doc ls <type>"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("next steps lack %q:\n%s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "no credential") {
		t.Errorf("an admin connect must not carry the anonymous warning:\n%s", out.String())
	}
	for _, s := range nextSteps("", "admin") {
		if s == "bp doc ls" {
			t.Errorf("JSON next steps still carry the bare `bp doc ls`: %v", nextSteps("", "admin"))
		}
	}
}

func TestAnonymousConnectSaysItIsReadOnlyAndHowToWrite(t *testing.T) {
	srv := capsServer(t, "none")
	var out bytes.Buffer
	if err := executeConnect(SetupPlan{Server: srv.URL}, Options{Store: &memConfigStore{}, Out: &out}); err != nil {
		t.Fatalf("tokenless connect must still succeed: %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "no credential") || !strings.Contains(got, "--token <token>") {
		t.Fatalf("a tokenless connect must say it is anonymous and name the --token remedy:\n%s", got)
	}
	if next := nextSteps("", "none"); len(next) == 0 || !strings.Contains(next[0], "--token") {
		t.Fatalf("JSON next steps for an anonymous connect must lead with the token step, got %v", next)
	}
}
