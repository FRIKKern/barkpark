package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func studioCtx(server string) manifest.Context {
	return manifest.Context{Server: server, Token: "session-tok", Dataset: "production"}
}

func TestStudioTokenPrintsTheEnvLineOnce(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusCreated,
		`{"token":"raw-secret","id":"tok-1","label":"studio (pensum)","permissions":["read"],"dataset":"production","workspace":"pensum","expires_at":null}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	code := studioTokenMint(newWriter(&so, &se), studioCtx(srv.URL), []string{"--workspace", "pensum"})
	if code != exitOK {
		t.Fatalf("exit = %d; stdout=%q stderr=%q", code, so.String(), se.String())
	}
	if path != "/v1/auth/studio-tokens" {
		t.Errorf("path = %q", path)
	}
	var sent map[string]string
	if err := json.Unmarshal(body, &sent); err != nil || sent["workspace"] != "pensum" {
		t.Errorf("body = %q, want workspace pensum", string(body))
	}
	if _, ok := sent["dataset"]; ok {
		t.Errorf("an unstated dataset reached the body: %q", string(body))
	}
	if got := so.String(); got != "BARKPARK_TOKEN=raw-secret\n" {
		t.Errorf("stdout = %q, want only the BARKPARK_TOKEN line", got)
	}
	if strings.Contains(se.String(), "raw-secret") {
		t.Errorf("the token was printed twice: stderr=%q", se.String())
	}
	if !strings.Contains(se.String(), "member seat in workspace pensum") {
		t.Errorf("stderr does not name the seat: %q", se.String())
	}
}

func TestStudioTokenSurfacesTheRefusal(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusForbidden,
		`{"error":{"code":"studio_token_forbidden","message":"only an owner or admin of workspace \"pensum\", or the instance admin token, may mint its Studio token. Nothing was minted"}}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	code := studioTokenMint(newWriter(&so, &se), studioCtx(srv.URL), []string{"--workspace=pensum"})
	if code == exitOK {
		t.Fatalf("exit = 0 on a 403")
	}
	if !strings.Contains(so.String()+se.String(), "owner or admin") {
		t.Errorf("the reason never reached the operator: stdout=%q stderr=%q", so.String(), se.String())
	}
	if strings.Contains(so.String(), "BARKPARK_TOKEN=") {
		t.Errorf("printed a token line on a refusal")
	}
}

func TestStudioTokenRefusesAReceiptWithoutAToken(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusCreated, `{"permissions":["read"],"workspace":"pensum"}`, &path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	if code := studioTokenMint(newWriter(&so, &se), studioCtx(srv.URL), []string{"--workspace", "pensum"}); code == exitOK {
		t.Fatalf("exit = 0 on a body with no token")
	}
	if strings.Contains(so.String(), "BARKPARK_TOKEN=") {
		t.Errorf("printed a token line: %q", so.String())
	}
}

func TestStudioTokenArgs(t *testing.T) {
	if _, err := parseInstanceStudioTokenArgs(nil, ""); err == nil || !strings.Contains(err.Error(), "--workspace") {
		t.Errorf("no workspace: err = %v", err)
	}
	a, err := parseInstanceStudioTokenArgs(nil, "pensum")
	if err != nil || a.workspace != "pensum" {
		t.Errorf("-w fallback: %+v %v", a, err)
	}
	if _, err := parseInstanceStudioTokenArgs([]string{"--bogus", "x"}, "pensum"); err == nil {
		t.Errorf("unknown flag accepted")
	}
	var so, se bytes.Buffer
	ctx := studioCtx("https://s.example")
	ctx.Token = ""
	if code := studioTokenMint(newWriter(&so, &se), ctx, []string{"--workspace", "pensum"}); code != exitAuth {
		t.Errorf("no credential: exit = %d, want exitAuth", code)
	}
}
