package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// appTokenCreateManifestCmd mirrors `app_token.create` as the server declares
// it (api/lib/barkpark/plugins/capabilities.ex): a flat admin POST to
// /v1/auth/app-tokens with a required `email` arg and string flags.
func appTokenCreateManifestCmd() manifest.Command {
	return manifest.Command{
		ID:       "app_token.create",
		Noun:     "app_token",
		Verb:     "create",
		AuthTier: "admin",
		HTTP:     manifest.HTTP{Method: "POST", PathTemplate: "/v1/auth/app-tokens"},
		Args:     []manifest.Arg{{Name: "email", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "workspace", Type: "string"},
			{Name: "permissions", Type: "string", Default: "read,write,chat"},
			{Name: "label", Type: "string"},
			{Name: "dataset", Type: "string", Default: "production"},
		},
		Writes: true,
	}
}

func appTokenCtx(server string) manifest.Context {
	return manifest.Context{
		Server: server, Token: "admin-tok",
		Workspace: "julegaveguide", Project: "default", Dataset: "development",
		WorkspaceExplicit: true,
	}
}

// The two workspaces the fake server knows.
const (
	appTokenDefaultID = "00000000-0000-0000-0000-00000000def0"
	appTokenJulID     = "11111111-1111-1111-1111-111111111111"
)

// appTokenServer fakes the instance. The mint resolves `workspace` from the
// JSON body the way app_token_controller.ex resolve_workspace/1 does: a slug
// or an id, and the Default workspace when the key is absent. honourBody=false
// fakes a server that ignores the body, so the receipt check can be tested.
func appTokenServer(t *testing.T, honourBody bool, gotBody *[]byte, gotQuery *string) *httptest.Server {
	t.Helper()
	workspaces := []map[string]string{
		{"id": appTokenDefaultID, "slug": "default"},
		{"id": appTokenJulID, "slug": "julegaveguide"},
	}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "GET" && r.URL.Path == "/api/workspaces":
			_ = json.NewEncoder(w).Encode(map[string]any{"workspaces": workspaces})
		case r.Method == "POST" && r.URL.Path == "/v1/auth/app-tokens":
			b, _ := io.ReadAll(r.Body)
			*gotBody = b
			*gotQuery = r.URL.RawQuery
			var req map[string]any
			_ = json.Unmarshal(b, &req)
			perms, ok := req["permissions"].([]any)
			if _, present := req["permissions"]; present && !ok {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = io.WriteString(w, `{"error":{"code":"unprocessable","message":"permissions must be a non-empty subset of [\"read\", \"write\", \"chat\"]"}}`)
				return
			}
			if !present(req, "permissions") {
				perms = []any{"read", "write", "chat"}
			}
			wsID := appTokenDefaultID
			if stated, _ := req["workspace"].(string); honourBody && stated != "" {
				wsID = ""
				for _, ws := range workspaces {
					if ws["slug"] == stated || ws["id"] == stated {
						wsID = ws["id"]
					}
				}
				if wsID == "" {
					w.WriteHeader(http.StatusUnprocessableEntity)
					_, _ = io.WriteString(w, `{"error":{"code":"unprocessable","message":"workspace could not be resolved"}}`)
					return
				}
			}
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"token": "bpapp_secret", "workspace_id": wsID, "permissions": perms, "expires_at": nil,
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func present(m map[string]any, k string) bool { _, ok := m[k]; return ok }

// TestManifestAppTokenCreateCannotSeatAWorkspaceOrStatePermissions is the
// reproduction of task-e044d53aceb0e5c8 at the manifest seam. The stated
// workspace never reaches the body (parseGlobals ate --workspace), and
// --permissions rides the query string as a scalar, which the server refuses.
// It pins the defect, so it reds the day the manifest path learns both, and
// this built-in can be revisited.
func TestManifestAppTokenCreateCannotSeatAWorkspaceOrStatePermissions(t *testing.T) {
	g := globals{workspace: "julegaveguide"}
	req, derr := buildManifestRequest(g, appTokenCtx("https://s.example"), &manifest.Manifest{},
		appTokenCreateManifestCmd(), []string{"ola@example.com", "--permissions", "read,write"}, false)
	if derr != nil {
		t.Fatalf("buildManifestRequest: %v", derr)
	}
	var body map[string]any
	if err := json.Unmarshal(req.body, &body); err != nil {
		t.Fatalf("manifest body is not JSON: %v (%q)", err, string(req.body))
	}
	if _, ok := body["workspace"]; ok {
		t.Fatalf("workspace reached the manifest body; the reproduction is stale: %s", req.body)
	}
	if _, ok := body["permissions"]; ok {
		t.Fatalf("permissions reached the manifest body; the reproduction is stale: %s", req.body)
	}
	if !strings.Contains(req.url, "permissions=read") {
		t.Errorf("permissions did not ride the query string either; the wire shape changed: %q", req.url)
	}
}

// TestAppTokenCreateSendsTheStatedFieldsInTheBody covers criteria 0 and 1:
// email, workspace, permissions (as an ARRAY), dataset and label all go in the
// JSON body, and the receipt reads the workspace back and confirms it.
func TestAppTokenCreateSendsTheStatedFieldsInTheBody(t *testing.T) {
	var body []byte
	var query string
	srv := appTokenServer(t, true, &body, &query)
	defer srv.Close()

	g := globals{workspace: "julegaveguide", dataset: "development", datasetSet: true}
	var so, se bytes.Buffer
	code := runAppTokenCreate(newWriter(&so, &se), g, appTokenCtx(srv.URL),
		[]string{"ola@example.com", "--permissions", "read,write", "--label", "jgg-editor"})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stdout=%q stderr=%q", code, so.String(), se.String())
	}

	var sent struct {
		Email       string   `json:"email"`
		Workspace   string   `json:"workspace"`
		Permissions []string `json:"permissions"`
		Dataset     string   `json:"dataset"`
		Label       string   `json:"label"`
	}
	if err := json.Unmarshal(body, &sent); err != nil {
		t.Fatalf("request body is not JSON: %v (%q)", err, body)
	}
	if sent.Email != "ola@example.com" || sent.Workspace != "julegaveguide" ||
		sent.Dataset != "development" || sent.Label != "jgg-editor" {
		t.Errorf("body = %s", body)
	}
	if strings.Join(sent.Permissions, ",") != "read,write" {
		t.Errorf("permissions = %v, want [read write] as a JSON array", sent.Permissions)
	}
	if query != "" {
		t.Errorf("the mint carried a query string %q; every field belongs in the body", query)
	}
	out := so.String()
	for _, want := range []string{"julegaveguide (" + appTokenJulID + ")", "matches the workspace you named", "read,write", "bpapp_secret"} {
		if !strings.Contains(out, want) {
			t.Errorf("receipt does not name %q:\n%s", want, out)
		}
	}
	if strings.Contains(se.String(), "WARNING") {
		t.Errorf("a confirmed workspace printed a warning: %q", se.String())
	}
}

// TestAppTokenCreateIsNotSeatedInDefaultWhenAWorkspaceIsNamed is criterion 2.
// Against a server that resolves `workspace` from the body (as
// app_token_controller.ex does), -w julegaveguide lands there and not in
// Default, by slug and by id.
func TestAppTokenCreateIsNotSeatedInDefaultWhenAWorkspaceIsNamed(t *testing.T) {
	for _, stated := range []string{"julegaveguide", appTokenJulID} {
		t.Run(stated, func(t *testing.T) {
			var body []byte
			var query string
			srv := appTokenServer(t, true, &body, &query)
			defer srv.Close()

			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = "json"
			if code := runAppTokenCreate(w, globals{workspace: stated}, appTokenCtx(srv.URL),
				[]string{"ola@example.com"}); code != exitOK {
				t.Fatalf("exit = %d; stderr=%q", code, se.String())
			}
			var got struct {
				OK             bool   `json:"ok"`
				WorkspaceID    string `json:"workspace_id"`
				WorkspaceCheck string `json:"workspace_check"`
			}
			if err := json.Unmarshal(so.Bytes(), &got); err != nil {
				t.Fatalf("stdout is not JSON: %v (%q)", err, so.String())
			}
			if got.WorkspaceID == appTokenDefaultID {
				t.Fatalf("the token was seated in Default although -w named %q", stated)
			}
			if got.WorkspaceID != appTokenJulID || got.WorkspaceCheck != appTokenWorkspaceConfirmed || !got.OK {
				t.Errorf("receipt = %+v, want ok, %s, confirmed", got, appTokenJulID)
			}
		})
	}
}

// TestAppTokenCreateSaysSoWhenTheWorkspaceDiffers: a server that ignores the
// body (the old behaviour) seats the token in Default. The receipt still
// prints the token, because it is live and must be revoked, then warns on
// stderr and exits 1, in both output shapes.
func TestAppTokenCreateSaysSoWhenTheWorkspaceDiffers(t *testing.T) {
	for _, output := range []string{"table", "json"} {
		t.Run(output, func(t *testing.T) {
			var body []byte
			var query string
			srv := appTokenServer(t, false, &body, &query)
			defer srv.Close()

			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = output
			code := runAppTokenCreate(w, globals{workspace: "julegaveguide"}, appTokenCtx(srv.URL),
				[]string{"ola@example.com"})
			if code != exitGeneric {
				t.Fatalf("exit = %d, want %d on a workspace mismatch", code, exitGeneric)
			}
			stderr := se.String()
			for _, want := range []string{"WARNING", "default (" + appTokenDefaultID + ")", `NOT in "julegaveguide"`, "revoke-by-id"} {
				if !strings.Contains(stderr, want) {
					t.Errorf("stderr does not say %q:\n%s", want, stderr)
				}
			}
			if !strings.Contains(so.String(), "bpapp_secret") {
				t.Errorf("the live token was not printed, so it cannot be found to revoke: %q", so.String())
			}
			if output == "json" {
				var got struct {
					OK             bool   `json:"ok"`
					WorkspaceCheck string `json:"workspace_check"`
				}
				if err := json.Unmarshal(so.Bytes(), &got); err != nil {
					t.Fatalf("stdout is not JSON: %v", err)
				}
				if got.OK || got.WorkspaceCheck != appTokenWorkspaceMismatch {
					t.Errorf("json = %+v, want ok=false, workspace_check=mismatch", got)
				}
			}
		})
	}
}

// With no -w the body names no workspace, the server picks Default, and the
// receipt says that is why.
func TestAppTokenCreateWithoutAWorkspaceSaysTheServerChoseDefault(t *testing.T) {
	var body []byte
	var query string
	srv := appTokenServer(t, true, &body, &query)
	defer srv.Close()

	var so, se bytes.Buffer
	if code := runAppTokenCreate(newWriter(&so, &se), globals{}, appTokenCtx(srv.URL), []string{"ola@example.com"}); code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, se.String())
	}
	var sent map[string]any
	_ = json.Unmarshal(body, &sent)
	for _, k := range []string{"workspace", "permissions", "dataset", "label"} {
		if _, ok := sent[k]; ok {
			t.Errorf("an unstated %q reached the body: %s", k, body)
		}
	}
	if !strings.Contains(so.String(), "Default workspace") {
		t.Errorf("the receipt does not say the server chose Default:\n%s", so.String())
	}
}

// TestAppTokenCreateRefusesAnUnknownPermission: refused before anything is
// sent, naming the allowed set; admin and public-read point at token create.
func TestAppTokenCreateRefusesAnUnknownPermission(t *testing.T) {
	for _, tc := range []struct {
		perms string
		want  []string
	}{
		{"read,delete", []string{`"delete"`, "read, write, chat"}},
		{"admin", []string{`"admin"`, "bp token create"}},
		{" , ", []string{"--permissions was empty"}},
	} {
		t.Run(tc.perms, func(t *testing.T) {
			var sent bool
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { sent = true }))
			defer srv.Close()

			var so, se bytes.Buffer
			code := runAppTokenCreate(newWriter(&so, &se), globals{workspace: "julegaveguide"}, appTokenCtx(srv.URL),
				[]string{"ola@example.com", "--permissions", tc.perms})
			if code != exitUsage {
				t.Errorf("exit = %d, want %d", code, exitUsage)
			}
			if sent {
				t.Error("a request was sent for a refused permission set")
			}
			for _, want := range tc.want {
				if !strings.Contains(se.String(), want) {
					t.Errorf("stderr does not name %q:\n%s", want, se.String())
				}
			}
		})
	}
}

func TestAppTokenCreateArgRefusals(t *testing.T) {
	for _, tc := range []struct {
		name string
		tail []string
	}{
		{"no email", []string{"--permissions", "read"}},
		{"two emails", []string{"a@x", "b@x"}},
		{"dangling value", []string{"a@x", "--label"}},
		{"unknown flag", []string{"a@x", "--forever", "1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseAppTokenCreateArgs(tc.tail, "", ""); err == nil {
				t.Errorf("parse accepted %v", tc.tail)
			}
		})
	}
}

// The receipt refuses a 2xx body that cannot carry its claims.
func TestAppTokenCreateRefusesAReceiptThatCannotCarryItsClaims(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"empty object", `{}`},
		{"no workspace_id", `{"token":"t","permissions":["read"]}`},
		{"no permissions", `{"token":"t","workspace_id":"w"}`},
		{"proxy page", `<html>502</html>`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var path string
			var body []byte
			srv := mintServer(t, http.StatusCreated, tc.body, &path, &body)
			defer srv.Close()
			var so, se bytes.Buffer
			if code := runAppTokenCreate(newWriter(&so, &se), globals{}, appTokenCtx(srv.URL), []string{"a@x"}); code == exitOK {
				t.Fatalf("exit 0 on %s: %q", tc.name, so.String())
			}
			if strings.Contains(so.String(), "minted") {
				t.Errorf("printed a receipt over %s", tc.name)
			}
		})
	}
}

// --dry-run prints the request and sends nothing.
func TestAppTokenCreateDryRunSendsNothing(t *testing.T) {
	var sent bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { sent = true }))
	defer srv.Close()
	var so, se bytes.Buffer
	if code := runAppTokenCreate(newWriter(&so, &se), globals{dryRun: true, workspace: "julegaveguide"}, appTokenCtx(srv.URL),
		[]string{"a@x", "--permissions", "read"}); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if sent {
		t.Fatal("--dry-run sent the mint")
	}
	if !strings.Contains(so.String()+se.String(), `"workspace":"julegaveguide"`) {
		t.Errorf("dry run does not show the workspace in the body: %q", so.String())
	}
}

// Every `app_token create` takes the built-in, so the manifest path can no
// longer mint into Default by dropping -w.
func TestAppTokenCreateAlwaysTakesTheBuiltin(t *testing.T) {
	for _, tail := range [][]string{{"a@x"}, {"a@x", "--permissions", "read"}} {
		if _, ok := lookupNounBuiltin("app_token", "create", globals{}, tail); !ok {
			t.Errorf("app_token create %v fell through to the manifest path", tail)
		}
	}
	if !strings.Contains(strings.Join(builtinVerbLines("app_token"), "\n"), "create") {
		t.Error("`bp app_token --help` does not list the built-in")
	}
}
