package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Scope-selector create pins (TUI long-tail, 2026-06-11): `n` on the
// workspace/project list opens a name prompt; the server derives the slug and
// seeds child defaults, so a created workspace flows into its project list
// and a created project flows straight to the dataset step. Failures stay on
// the prompt with the server's reason inline.

func tenancyServer(t *testing.T, failCreate bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "POST" && r.URL.Path == "/api/workspaces":
			if failCreate {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"errors":{"slug":["has already been taken"]}}`))
				return
			}
			var in struct {
				Name string `json:"name"`
			}
			_ = json.NewDecoder(r.Body).Decode(&in)
			if in.Name != "Probe WS" {
				t.Errorf("create workspace name = %q", in.Name)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"workspace":{"id":"w1","slug":"probe-ws","name":"Probe WS"}}`))
		case r.Method == "POST" && r.URL.Path == "/api/workspaces/probe-ws/projects":
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"project":{"id":"p1","slug":"probe-proj","name":"Probe Proj"}}`))
		case r.Method == "GET" && r.URL.Path == "/api/workspaces/probe-ws/projects":
			_, _ = w.Write([]byte(`{"workspace":{"slug":"probe-ws"},"projects":[{"id":"d1","slug":"default","name":"Default"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func typeName(m model, s string) model {
	for _, r := range s {
		next, _ := m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(model)
	}
	return m
}

func TestSelectorCreateWorkspaceFlowsToProjectList(t *testing.T) {
	srv := tenancyServer(t, false)
	defer srv.Close()

	m := model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})}
	m.selector = selectorState{active: true, stage: stageWorkspace,
		workspaces: []WorkspaceInfo{{Slug: "default", Name: "Default"}}}

	// `n` opens the name prompt.
	next, _ := m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	m = next.(model)
	if m.selector.stage != stageNewWorkspace {
		t.Fatalf("stage = %v, want stageNewWorkspace", m.selector.stage)
	}

	// Type the name, enter creates and lands on the seeded project list.
	m = typeName(m, "Probe WS")
	next, _ = m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.selector.stage != stageProject {
		t.Fatalf("stage = %v (err %q), want stageProject", m.selector.stage, m.selector.err)
	}
	if m.selector.chosenWorkspace != "probe-ws" {
		t.Errorf("chosenWorkspace = %q", m.selector.chosenWorkspace)
	}
	if len(m.selector.projects) != 1 || m.selector.projects[0].Slug != "default" {
		t.Errorf("projects = %+v, want the seeded Default", m.selector.projects)
	}
}

func TestSelectorCreateProjectFlowsToDataset(t *testing.T) {
	srv := tenancyServer(t, false)
	defer srv.Close()

	m := model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})}
	m.selector = selectorState{active: true, stage: stageProject, chosenWorkspace: "probe-ws",
		projects: []ProjectInfo{{Slug: "default", Name: "Default"}}}

	next, _ := m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	m = next.(model)
	if m.selector.stage != stageNewProject {
		t.Fatalf("stage = %v, want stageNewProject", m.selector.stage)
	}

	m = typeName(m, "Probe Proj")
	next, _ = m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.selector.stage != stageDataset {
		t.Fatalf("stage = %v (err %q), want stageDataset", m.selector.stage, m.selector.err)
	}
	if m.selector.chosenProject != "probe-proj" {
		t.Errorf("chosenProject = %q", m.selector.chosenProject)
	}
}

func TestSelectorCreateFailureStaysOnPrompt(t *testing.T) {
	srv := tenancyServer(t, true)
	defer srv.Close()

	m := model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})}
	m.selector = selectorState{active: true, stage: stageWorkspace,
		workspaces: []WorkspaceInfo{{Slug: "default", Name: "Default"}}}

	next, _ := m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	m = next.(model)
	m = typeName(m, "Probe WS")
	next, _ = m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)

	if m.selector.stage != stageNewWorkspace {
		t.Errorf("a failed create must stay on the prompt, stage = %v", m.selector.stage)
	}
	if !strings.Contains(m.selector.err, "create failed") || !strings.Contains(m.selector.err, "taken") {
		t.Errorf("err should carry the server reason, got %q", m.selector.err)
	}

	// Empty name never hits the wire.
	m.selector.nameInput.SetValue("   ")
	next, _ = m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.selector.err != "name is required" {
		t.Errorf("blank-name err = %q", m.selector.err)
	}

	// esc steps back to the workspace list.
	next, _ = m.handleSelectorKey(tea.KeyMsg{Type: tea.KeyEsc})
	m = next.(model)
	if m.selector.stage != stageWorkspace {
		t.Errorf("esc should return to the list, stage = %v", m.selector.stage)
	}
}

func TestSelectorRenderCreateStage(t *testing.T) {
	m := model{}
	m.selector = selectorState{active: true}
	m.seedNameInput(stageNewWorkspace)

	out := m.renderSelector(100, 30)
	for _, want := range []string{"New workspace", "slug derives from the name", "enter create"} {
		if !strings.Contains(out, want) {
			t.Errorf("create stage missing %q:\n%s", want, out)
		}
	}

	// Both list stages advertise `n new`.
	m.selector = selectorState{active: true, stage: stageWorkspace,
		workspaces: []WorkspaceInfo{{Slug: "default", Name: "Default"}}}
	if out := m.renderSelector(100, 30); !strings.Contains(out, "n new") {
		t.Error("workspace list should advertise n new")
	}
	m.selector = selectorState{active: true, stage: stageProject, chosenWorkspace: "default",
		projects: []ProjectInfo{{Slug: "default", Name: "Default"}}}
	if out := m.renderSelector(100, 30); !strings.Contains(out, "n new") {
		t.Error("project list should advertise n new")
	}
}
