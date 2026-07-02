package apiclient

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestCreateWorkspace covers the POST /api/workspaces write: body {name},
// 201-gated, decoding {workspace:{...}}.
func TestCreateWorkspace(t *testing.T) {
	var gotPath, gotMethod string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotMethod = r.URL.Path, r.Method
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"workspace":{"id":"ws_1","slug":"acme","name":"Acme"}}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t"})

	ws, err := c.CreateWorkspace("Acme")
	if err != nil {
		t.Fatalf("CreateWorkspace: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/api/workspaces" {
		t.Errorf("request = %s %s, want POST /api/workspaces", gotMethod, gotPath)
	}
	var body map[string]string
	_ = json.Unmarshal(gotBody, &body)
	if body["name"] != "Acme" {
		t.Errorf("body name = %q, want Acme (body=%s)", body["name"], gotBody)
	}
	if ws.ID != "ws_1" || ws.Slug != "acme" || ws.Name != "Acme" {
		t.Errorf("decoded workspace = %+v, want {ws_1 acme Acme}", ws)
	}
}

// A non-201 response must surface as an error, not a zero-value success.
func TestCreateWorkspaceNon201Errors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":"slug taken"}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t"})

	if _, err := c.CreateWorkspace("Acme"); err == nil {
		t.Error("CreateWorkspace on 409 returned nil error")
	}
}

// TestCreateProject covers POST /api/workspaces/:slug/projects, including that
// the workspace slug is PathEscaped into the URL.
func TestCreateProject(t *testing.T) {
	var gotPath string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"project":{"id":"pr_1","slug":"web","name":"Web"}}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t"})

	// A slug with a space must be encoded, not spliced raw.
	pr, err := c.CreateProject("my ws", "Web")
	if err != nil {
		t.Fatalf("CreateProject: %v", err)
	}
	if gotPath != "/api/workspaces/my%20ws/projects" {
		t.Errorf("path = %q, want /api/workspaces/my%%20ws/projects", gotPath)
	}
	var body map[string]string
	_ = json.Unmarshal(gotBody, &body)
	if body["name"] != "Web" {
		t.Errorf("body name = %q, want Web", body["name"])
	}
	if pr.ID != "pr_1" || pr.Slug != "web" {
		t.Errorf("decoded project = %+v, want id pr_1 slug web", pr)
	}
}

// TestListWorkspaces covers GET /api/workspaces → {workspaces:[...]}.
func TestListWorkspaces(t *testing.T) {
	var gotPath, gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotMethod = r.URL.Path, r.Method
		_, _ = w.Write([]byte(`{"workspaces":[{"id":"ws_1","slug":"acme","name":"Acme"},{"id":"ws_2","slug":"beta","name":"Beta"}]}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t"})

	list, err := c.ListWorkspaces()
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/api/workspaces" {
		t.Errorf("request = %s %s, want GET /api/workspaces", gotMethod, gotPath)
	}
	if len(list) != 2 || list[0].Slug != "acme" || list[1].Slug != "beta" {
		t.Errorf("decoded list = %+v, want [acme beta]", list)
	}
}

// TestListProjects covers GET /api/workspaces/:slug/projects → {projects:[...]},
// with the slug PathEscaped.
func TestListProjects(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		_, _ = w.Write([]byte(`{"workspace":{"id":"ws_1","slug":"acme","name":"Acme"},"projects":[{"id":"pr_1","slug":"web","name":"Web"}]}`))
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "t"})

	projs, err := c.ListProjects("acme/x")
	if err != nil {
		t.Fatalf("ListProjects: %v", err)
	}
	if gotPath != "/api/workspaces/acme%2Fx/projects" {
		t.Errorf("path = %q, want the slug PathEscaped", gotPath)
	}
	if len(projs) != 1 || projs[0].Slug != "web" {
		t.Errorf("decoded projects = %+v, want [web]", projs)
	}
}
