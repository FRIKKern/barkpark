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

// scopedPrefixOf is a local *string helper — the package's scopedPrefixPtr
// (scope_honesty_test.go) hardcodes the same value, but this file states its own
// so a change there cannot silently retarget these assertions.
func scopedPrefixOf(s string) *string { return &s }

// tokenCreateManifestCmd mirrors the `token.create` command EXACTLY as the server
// declares it (api/lib/barkpark/plugins/capabilities.ex): a scoped_admin POST to
// /v1/tokens with a required `label` arg and a `permissions` flag documented as a
// comma list. Nothing here is invented — this is the shape a real `bp` reads out
// of GET /v1/capabilities.
func tokenCreateManifestCmd() manifest.Command {
	return manifest.Command{
		ID:       "token.create",
		Noun:     "token",
		Verb:     "create",
		AuthTier: "scoped_admin",
		HTTP:     manifest.HTTP{Method: "POST", PathTemplate: "/v1/tokens"},
		Args:     []manifest.Arg{{Name: "label", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "permissions", Type: "string", Default: "public-read",
				Summary: "Comma list — public-read|read ONLY (default public-read)."},
			{Name: "dataset", Type: "string", Default: "production"},
		},
		Writes:       true,
		ScopedPrefix: scopedPrefixOf("/w/:workspace_slug/p/:project_slug"),
	}
}

func tokenCtx(server string) manifest.Context {
	return manifest.Context{
		Server: server, Token: "admin-tok",
		Workspace: "gyldendal", Project: "default", Dataset: "production",
		WorkspaceExplicit: true, ProjectExplicit: true,
	}
}

// TestManifestTokenCreateCannotAskForTheReadTier is the REPRODUCTION of the filed
// gap, at the seam both the CLI dispatch and the headless MCP dispatch share.
//
// The manifest verb EXISTS and its --permissions flag is documented as a comma
// list, so a reader of `bp capabilities` concludes the read tier is mintable. It
// is not. commandFlagBelongsInBody admits a flag into the JSON body only for a
// BATCH write, and token.create is not one — so `--permissions read` leaves the
// body entirely and rides out as the query scalar `?permissions=read`. Phoenix
// merges that into params as a BINARY, and token_controller's fetch_permissions/1
// matches only `is_list(perms)`: the non-list clause 422s with
// `permissions [:invalid] not allowed`.
//
// This test pins the defect rather than the fix, on purpose. It is the evidence
// that the built-in below is not redundant, and it will red the day the manifest
// half is repaired in api/lib — which is exactly when this file should be revisited.
func TestManifestTokenCreateCannotAskForTheReadTier(t *testing.T) {
	req, derr := buildManifestRequest(globals{}, tokenCtx("https://s.example"),
		&manifest.Manifest{}, tokenCreateManifestCmd(),
		[]string{"desk-reader", "--permissions", "read"}, false)
	if derr != nil {
		t.Fatalf("buildManifestRequest: %v", derr)
	}

	var body map[string]any
	if err := json.Unmarshal(req.body, &body); err != nil {
		t.Fatalf("manifest body is not JSON: %v (%q)", err, string(req.body))
	}
	if _, present := body["permissions"]; present {
		t.Fatalf("permissions reached the BODY — the manifest path is fixed and this "+
			"reproduction is stale; re-read token_create_cmd.go's gate. body=%q", string(req.body))
	}
	if !strings.Contains(req.url, "permissions=read") {
		t.Errorf("permissions did not ride the query string either — the wire shape changed; url=%q", req.url)
	}
	// The scalar the server cannot accept. Named here so the reason this verb
	// 422s is visible without opening token_controller.ex.
	if got := body["label"]; got != "desk-reader" {
		t.Errorf("label = %v, want desk-reader (the arg half is fine; permissions is the hole)", got)
	}
}

// mintServer records the one POST it receives and answers with resp.
func mintServer(t *testing.T, status int, resp string, gotPath *string, gotBody *[]byte) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		*gotBody = b
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, resp)
	}))
}

// TestTokenCreateSendsPermissionsAsAJSONArrayOnTheScopedRoute is the GREEN half:
// the built-in puts `permissions` in the BODY, as an ARRAY, on the scoped mirror
// carrying the stated workspace. This is the shape token_controller accepts, and
// it is the only shape that can mint the read tier.
func TestTokenCreateSendsPermissionsAsAJSONArrayOnTheScopedRoute(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusCreated,
		`{"token":"raw-secret","id":"tok-1","label":"desk-reader","permissions":["read"],"dataset":"production","workspace":"gyldendal","inserted_at":"2026-09-05T00:00:00Z"}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code := runTokenCreate(w, globals{}, tokenCtx(srv.URL), []string{"desk-reader", "--permissions", "read"})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; stdout=%q stderr=%q", code, so.String(), se.String())
	}

	if path != "/w/gyldendal/p/default/v1/tokens" {
		t.Errorf("path = %q — the stated workspace did not reach the wire (a mint in Default is the silent failure this guards)", path)
	}
	var sent struct {
		Label       string   `json:"label"`
		Permissions []string `json:"permissions"`
		Dataset     string   `json:"dataset"`
	}
	if err := json.Unmarshal(body, &sent); err != nil {
		t.Fatalf("request body is not JSON: %v (%q)", err, string(body))
	}
	if len(sent.Permissions) != 1 || sent.Permissions[0] != "read" {
		t.Errorf("permissions = %v, want [read] as a JSON ARRAY — a scalar is the 422 the manifest path takes", sent.Permissions)
	}
	if sent.Label != "desk-reader" || sent.Dataset != "production" {
		t.Errorf("label/dataset = %q/%q, want desk-reader/production", sent.Label, sent.Dataset)
	}

	out := so.String()
	for _, want := range []string{"minted desk-reader", "read", "gyldendal", "raw-secret"} {
		if !strings.Contains(out, want) {
			t.Errorf("receipt does not name %q:\n%s", want, out)
		}
	}
}

// TestTokenCreateReceiptComesFromTheResponseNotTheRequest is the write-fence rule
// in its sharpest form: the caller asks for `read` in `gyldendal`, and the server
// answers `public-read` in `default`. A receipt echoed from the REQUEST would
// print the tier and workspace the operator wanted; the honest one prints what
// actually landed, which is the whole finding this verb closes.
func TestTokenCreateReceiptComesFromTheResponseNotTheRequest(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusCreated,
		`{"token":"raw-secret","id":"tok-9","label":"desk-reader","permissions":["public-read"],"dataset":"production","workspace":"default"}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if code := runTokenCreate(w, globals{}, tokenCtx(srv.URL), []string{"desk-reader", "--permissions", "read"}); code != exitOK {
		t.Fatalf("exit = %d, want exitOK; stderr=%q", code, se.String())
	}

	var got struct {
		OK          bool     `json:"ok"`
		Permissions []string `json:"permissions"`
		Workspace   string   `json:"workspace"`
	}
	if err := json.Unmarshal(so.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v (%q)", err, so.String())
	}
	if !got.OK {
		t.Errorf("ok = false, want true on a 201")
	}
	if len(got.Permissions) != 1 || got.Permissions[0] != "public-read" {
		t.Errorf("receipt permissions = %v, want [public-read] — the SERVER's answer, not the requested [read]", got.Permissions)
	}
	if got.Workspace != "default" {
		t.Errorf("receipt workspace = %q, want default — the SERVER's binding, not the requested gyldendal", got.Workspace)
	}
}

// TestTokenCreateRefusesAReceiptThatCannotCarryItsClaims — every poison body a 2xx
// can carry. None of them may produce a `minted` line, because each leaves at
// least one of the receipt's three claims (which secret, which tier, which
// workspace) unsupported by anything the server said.
func TestTokenCreateRefusesAReceiptThatCannotCarryItsClaims(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"empty 200", http.StatusOK, ``},
		{"null", http.StatusOK, `null`},
		{"empty object", http.StatusCreated, `{}`},
		{"result null", http.StatusCreated, `{"result":null}`},
		{"proxy page", http.StatusOK, `<html><body>502 upstream connect error</body></html>`},
		{"token but no tier", http.StatusCreated, `{"token":"raw","workspace":"gyldendal"}`},
		{"tier but no workspace", http.StatusCreated, `{"token":"raw","permissions":["read"]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var path string
			var body []byte
			srv := mintServer(t, tc.status, tc.body, &path, &body)
			defer srv.Close()

			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			code := runTokenCreate(w, globals{}, tokenCtx(srv.URL), []string{"desk-reader", "--permissions", "read"})
			if code == exitOK {
				t.Fatalf("exit = 0 on a body that proves nothing: stdout=%q", so.String())
			}
			if strings.Contains(so.String(), "minted") {
				t.Errorf("printed a mint receipt over %s: %q", tc.name, so.String())
			}
		})
	}
}

// TestTokenCreateSurfacesTheServersRefusal — a 422 from the read-only allowlist
// is rendered, not swallowed, and does not exit 0.
func TestTokenCreateSurfacesTheServersRefusal(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusUnprocessableEntity,
		`{"error":{"code":"unprocessable","message":"permissions [\"write\"] not allowed — this endpoint mints read-only tokens only (public-read, read)"}}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := runTokenCreate(w, globals{}, tokenCtx(srv.URL), []string{"desk-reader", "--permissions", "write"}); code == exitOK {
		t.Fatalf("exit = 0 on a 422")
	}
	if !strings.Contains(so.String()+se.String(), "read-only") {
		t.Errorf("the server's refusal never reached the operator: stdout=%q stderr=%q", so.String(), se.String())
	}
}

// TestTokenCreateGateShadowsOnlyAStatedPermissionSet — the blast radius. A bare
// `bp token create <label>` must NOT take the built-in: it keeps riding the
// untouched manifest path and mints public-read exactly as it did before.
func TestTokenCreateGateShadowsOnlyAStatedPermissionSet(t *testing.T) {
	for _, tc := range []struct {
		name string
		tail []string
		want bool
	}{
		{"bare create stays on the manifest path", []string{"desk-reader"}, false},
		{"dataset alone stays on the manifest path", []string{"site", "--dataset", "staging"}, false},
		{"--permissions value", []string{"desk-reader", "--permissions", "read"}, true},
		{"--permissions=value", []string{"desk-reader", "--permissions=read"}, true},
		{"single dash", []string{"desk-reader", "-permissions", "read"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, ok := lookupNounBuiltin("token", "create", globals{}, tc.tail)
			if ok != tc.want {
				t.Errorf("lookupNounBuiltin dispatched = %v, want %v for %v", ok, tc.want, tc.tail)
			}
		})
	}
}

// TestTokenCreateArgRefusals — the argument grammar, including the empty
// --permissions that would otherwise send an empty array for the server to 422.
func TestTokenCreateArgRefusals(t *testing.T) {
	for _, tc := range []struct {
		name string
		tail []string
	}{
		{"no label", []string{"--permissions", "read"}},
		{"blank label", []string{"   ", "--permissions", "read"}},
		{"two labels", []string{"a", "b", "--permissions", "read"}},
		{"empty permissions", []string{"a", "--permissions", " , "}},
		{"dangling value", []string{"a", "--permissions"}},
		{"unknown flag", []string{"a", "--permissions", "read", "--forever"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseTokenCreateArgs(tc.tail, "production"); err == nil {
				t.Errorf("parse accepted %v", tc.tail)
			}
		})
	}

	got, err := parseTokenCreateArgs([]string{"desk-reader", "--permissions", "read, public-read", "--dataset=staging"}, "production")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got.label != "desk-reader" || got.dataset != "staging" {
		t.Errorf("label/dataset = %q/%q", got.label, got.dataset)
	}
	if strings.Join(got.permissions, "|") != "read|public-read" {
		t.Errorf("permissions = %v, want [read public-read]", got.permissions)
	}
}

// TestTokenCreateHelpNamesTheReadTier — the help IS half of the deliverable: the
// finding is that nothing tells a customer the read tier exists.
func TestTokenCreateHelpNamesTheReadTier(t *testing.T) {
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := runTokenCreate(w, globals{help: true}, tokenCtx("https://s.example"), nil); code != exitOK {
		t.Fatalf("help exit = %d", code)
	}
	help := se.String()
	for _, want := range []string{"--permissions", "read", "public-read", "PRIVATE"} {
		if !strings.Contains(help, want) {
			t.Errorf("help does not name %q:\n%s", want, help)
		}
	}
	if so.Len() != 0 {
		t.Errorf("help wrote to stdout: %q", so.String())
	}
}

// TestTokenNounHelpAdvertisesTheReadTierVerb — the DISCOVERY surface. The finding
// is that nothing tells a customer the read tier is mintable, so the registry
// line `bp token --help` and `bp capabilities` both render from must name the
// gate flag. builtinVerbLines is the exact function both call.
func TestTokenNounHelpAdvertisesTheReadTierVerb(t *testing.T) {
	lines := strings.Join(builtinVerbLines("token"), "\n")
	for _, want := range []string{"create", "--permissions", "read"} {
		if !strings.Contains(lines, want) {
			t.Errorf("the token noun's built-in help block does not name %q:\n%s", want, lines)
		}
	}

	var found bool
	for _, b := range builtinVerbsFor("token") {
		if b.Verb == "create" && b.label() == "token create --permissions" {
			found = true
		}
	}
	if !found {
		t.Errorf("`bp capabilities` would name this verb without its gate flag, which reads as a "+
			"duplicate of the manifest verb; labels = %v", builtinVerbsFor("token"))
	}
}
