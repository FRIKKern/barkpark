package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// token_create_dry_run_test.go — `bp token create --permissions … --dry-run`
// (task-7dc7985e5b44b9a6). The built-in used to send the mint request even with
// --dry-run, so a dry run minted a real token and printed its secret. Both mint
// routes must now stop before the wire and print the request instead.

func TestTokenCreateDryRunSendsNothing(t *testing.T) {
	for _, perms := range []string{"read", "read,write"} {
		t.Run(perms, func(t *testing.T) {
			hits := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits++
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(`{"token":"raw-secret","id":"tok-1","label":"x","permissions":["read"],"dataset":"development","workspace":"gyldendal"}`))
			}))
			defer srv.Close()

			ctx := tokenCtx(srv.URL)
			ctx.Dataset = "development"
			var so, se bytes.Buffer
			code := runTokenCreate(newWriter(&so, &se), globals{dryRun: true, datasetSet: true}, ctx,
				[]string{"x", "--permissions", perms, "--expires-in", "180d"})
			if code != exitOK {
				t.Fatalf("exit = %d; stdout=%q stderr=%q", code, so.String(), se.String())
			}
			if hits != 0 {
				t.Fatalf("--dry-run sent %d request(s) to the server; it must send none", hits)
			}
			out := so.String() + se.String()
			if strings.Contains(out, "raw-secret") {
				t.Errorf("--dry-run printed a minted token:\n%s", out)
			}
			if strings.Contains(out, "admin-tok") {
				t.Errorf("--dry-run printed the caller's token instead of redacting it:\n%s", out)
			}
			if !strings.Contains(out, "/v1/tokens") || !strings.Contains(out, `"development"`) {
				t.Errorf("--dry-run did not print the mint route and body:\n%s", out)
			}
		})
	}
}

func TestTokenCreateDryRunJSONIsParseable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("--dry-run reached the server: %s %s", r.Method, r.URL.Path)
	}))
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if code := runTokenCreate(w, globals{dryRun: true}, tokenCtx(srv.URL), []string{"x", "--permissions", "read"}); code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, se.String())
	}
	var preview map[string]any
	if err := json.Unmarshal(so.Bytes(), &preview); err != nil {
		t.Fatalf("dry-run JSON is not parseable: %v\n%s", err, so.String())
	}
	if preview["method"] != "POST" {
		t.Errorf("method = %v, want POST", preview["method"])
	}
}
