package setup

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// task-43b7ec75e293c155: a .barkpark.json pinning another server OUTRANKS the
// default a connect just saved, for every command run under it. Found
// dogfooding: `bp setup --target connect` inside the barkpark checkout (which
// pins guerrilla) answered "bp now defaults here", and the very next command
// went to guerrilla.

func adminCapsServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth_tier":"admin","manifest_version":"1","server":{"name":"barkpark","version":"0.1.0"},"commands":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func connectReceipt(t *testing.T, plan SetupPlan, pin *RepoPin) (string, Result) {
	t.Helper()
	var out bytes.Buffer
	var res Result
	opts := Options{Out: &out, Store: &memConfigStore{}, RepoPin: pin, Result: &res}
	if err := executeConnect(plan, opts); err != nil {
		t.Fatalf("connect failed: %v", err)
	}
	return out.String(), res
}

func TestConnectUnderARepoFilePinningElsewhereDoesNotClaimTheDefault(t *testing.T) {
	srv := adminCapsServer(t)
	pin := &RepoPin{Path: "/work/barkpark/.barkpark.json", Server: "https://guerrilla.barkpark.cloud"}

	human, res := connectReceipt(t, SetupPlan{Server: srv.URL, Token: "tok"}, pin)

	if strings.Contains(human, "bp now defaults here") {
		t.Fatalf("the receipt claims the default while %s pins another server:\n%s", pin.Path, human)
	}
	for _, want := range []string{"saved as your default server", "/work/barkpark/.barkpark.json", "https://guerrilla.barkpark.cloud", "-s <name>"} {
		if !strings.Contains(human, want) {
			t.Fatalf("receipt missing %q:\n%s", want, human)
		}
	}
	if strings.Contains(res.Message, "bp now defaults here") || len(res.Warnings) != 1 ||
		!strings.Contains(res.Warnings[0], ".barkpark.json") {
		t.Fatalf("-o json must carry the shadowing warning, got message=%q warnings=%v", res.Message, res.Warnings)
	}
}

func TestConnectReceiptIsUnchangedWithoutAShadowingRepoFile(t *testing.T) {
	srv := adminCapsServer(t)
	for name, pin := range map[string]*RepoPin{
		"no repo file":           nil,
		"file pins only scope":   {Path: "/w/.barkpark.json", Server: ""},
		"file pins this URL":     {Path: "/w/.barkpark.json", Server: srv.URL + "/"},
		"file pins saved handle": {Path: "/w/.barkpark.json", Server: "local"},
	} {
		human, res := connectReceipt(t, SetupPlan{Server: srv.URL, Token: "tok", Name: "local"}, pin)
		if !strings.Contains(human, "; bp now defaults here\n") || strings.Contains(human, "! BUT") {
			t.Fatalf("%s: receipt changed:\n%s", name, human)
		}
		if len(res.Warnings) != 0 || !strings.HasSuffix(res.Message, "bp now defaults here") {
			t.Fatalf("%s: json result changed: %+v", name, res)
		}
	}
}
