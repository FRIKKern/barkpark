package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TUI parity pins for gaps 3+4:
//   - D delete (two-press confirm): first D arms a status-bar prompt, second D
//     sends {"delete":{"id":<as listed>,"type":…}}; esc disarms (swallowed),
//     any other key disarms and handles normally. Deleting the open editor doc
//     pops out of the editor.
//   - task quick actions: `c` claims via the FLAT POST /v1/tasks/:doc_id/claim
//     ({"worker_id":…}), `x` closes via POST /v1/tasks/:doc_id/close
//     ({"worker_id":…,"observed_epoch":<claim-time epoch>,"lifecycle_status":
//     "done"}). Close without a claim object errors LOCALLY; ok:false reasons
//     surface verbatim. Both keys are inert outside task contexts.
//   - pure-render: task doc-lists advertise "c claim  x close  D delete".

const (
	postDocJSON = `{"_id":"drafts.post-1","_type":"post","_draft":true,
		"title":"Hello","_updatedAt":"2026-06-09T10:00:00Z"}`
	taskDocJSON = `{"_id":"task-1","_type":"task","_draft":false,
		"title":"Fix the bug","lifecycle_status":"open",
		"_updatedAt":"2026-06-09T10:00:00Z"}`
	claimedTaskDocJSON = `{"_id":"task-1","_type":"task","_draft":false,
		"title":"Fix the bug","lifecycle_status":"in_progress",
		"claim":{"worker":"w-test","epoch":7},
		"_updatedAt":"2026-06-09T10:00:00Z"}`
)

// listModel builds a model focused on a doc-list pane of typeName (pane 1,
// mirroring TestCreateSendsCreateMutationAndDrillsIn's setup), with the worker
// identity pinned so claim/close bodies are assertable.
func listModel(t *testing.T, srvURL, typeName string) model {
	t.Helper()
	prevSchemas, prevRoot := schemas, rootStructure
	t.Cleanup(func() { schemas, rootStructure = prevSchemas, prevRoot })
	schemas = []Schema{{Name: typeName, Title: typeName + "s", Icon: "📄"}}
	initRootStructure()

	m := model{
		ds:       apiclient.New(apiclient.Config{BaseURL: srvURL, Token: "t"}),
		width:    120,
		height:   40,
		path:     []string{typeName},
		workerID: "w-test",
	}
	m.rebuildPanes()
	if len(m.panes) != 2 || !m.panes[1].IsDocList {
		t.Fatalf("setup: want a doc-list pane at index 1, got %d panes", len(m.panes))
	}
	m.focus = focusState{Target: FocusPane, PaneIndex: 1}
	return m
}

// press drives one key through handleKey and returns the updated model.
func press(t *testing.T, m model, key string) model {
	t.Helper()
	var msg tea.KeyMsg
	switch key {
	case "esc":
		msg = tea.KeyMsg{Type: tea.KeyEsc}
	case "enter":
		msg = tea.KeyMsg{Type: tea.KeyEnter}
	default:
		msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
	}
	mm, _ := m.handleKey(msg)
	return mm.(model)
}

// docServer serves one doc on the query endpoint and captures mutate bodies.
func docServer(docJSON string, mutates *[][]byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/v1/data/mutate/"):
			b, _ := io.ReadAll(r.Body)
			*mutates = append(*mutates, b)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"transactionId":"t1","results":[]}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[` + docJSON + `]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

func parseDeleteBody(t *testing.T, captured []byte) (id, typeName string) {
	t.Helper()
	var body struct {
		Mutations []struct {
			Delete struct {
				ID   string `json:"id"`
				Type string `json:"type"`
			} `json:"delete"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(captured, &body); err != nil {
		t.Fatalf("parse captured mutate body: %v", err)
	}
	if len(body.Mutations) != 1 {
		t.Fatalf("want 1 mutation, got %d", len(body.Mutations))
	}
	return body.Mutations[0].Delete.ID, body.Mutations[0].Delete.Type
}

// ─── D delete ────────────────────────────────────────────────────────────────

func TestDeleteTwoPressSendsDeleteMutation(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")

	// First D arms — prompt in the status bar, NO request.
	m = press(t, m, "D")
	if !m.deleteArmed {
		t.Fatal("first D must arm the delete confirm")
	}
	if !strings.Contains(m.status, `delete "Hello"?`) || !strings.Contains(m.status, "press D again") {
		t.Errorf("armed status = %q, want the confirm prompt", m.status)
	}
	if len(mutates) != 0 {
		t.Fatalf("arming must not hit the API, got %d mutate(s)", len(mutates))
	}

	// Second D deletes — the id goes over the wire EXACTLY as listed
	// (drafts. prefix included, per the drafts-vs-published API contract).
	m = press(t, m, "D")
	if len(mutates) != 1 {
		t.Fatalf("confirm must send exactly one mutate, got %d", len(mutates))
	}
	id, typeName := parseDeleteBody(t, mutates[0])
	if id != "drafts.post-1" || typeName != "post" {
		t.Errorf("delete body = {id:%q type:%q}, want the listed drafts.post-1/post", id, typeName)
	}
	if m.deleteArmed {
		t.Error("confirm must disarm")
	}
	if m.statusErr || m.status != "deleted" {
		t.Errorf("status = (%q, err=%v), want the deleted confirmation", m.status, m.statusErr)
	}
}

func TestDeleteEscDisarmsAndIsSwallowed(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m = press(t, m, "D")
	m = press(t, m, "esc")

	if m.deleteArmed {
		t.Error("esc must disarm")
	}
	if len(mutates) != 0 {
		t.Errorf("esc must send nothing, got %d mutate(s)", len(mutates))
	}
	// Swallowed: esc must ONLY disarm — not also pop the navigation path.
	if len(m.path) != 1 {
		t.Errorf("esc while armed must not navigate back, path = %v", m.path)
	}
}

func TestDeleteOtherKeyDisarmsAndHandlesNormally(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m = press(t, m, "D")
	m = press(t, m, "j") // disarms AND falls through to its normal handler

	if m.deleteArmed {
		t.Error("any other key must disarm")
	}
	if len(mutates) != 0 {
		t.Errorf("disarm must send nothing, got %d mutate(s)", len(mutates))
	}
	// A fresh D after a disarm ARMS again — it never inherits the old state.
	m = press(t, m, "D")
	if !m.deleteArmed || len(mutates) != 0 {
		t.Errorf("re-press must re-arm, not delete: armed=%v mutates=%d", m.deleteArmed, len(mutates))
	}
}

func TestDeleteFromEditorPopsOut(t *testing.T) {
	var mutates [][]byte
	srv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m = press(t, m, "enter") // drill into the doc's editor
	if !m.showEditor || m.focus.Target != FocusEditor {
		t.Fatalf("setup: want editor focus, got showEditor=%v focus=%v", m.showEditor, m.focus.Target)
	}

	m = press(t, m, "D")
	m = press(t, m, "D")

	if len(mutates) != 1 {
		t.Fatalf("want 1 delete mutate, got %d", len(mutates))
	}
	id, _ := parseDeleteBody(t, mutates[0])
	if id != "drafts.post-1" {
		t.Errorf("delete id = %q, want drafts.post-1", id)
	}
	if m.showEditor || m.focus.Target != FocusPane {
		t.Errorf("delete must pop out of the editor: showEditor=%v focus=%v", m.showEditor, m.focus.Target)
	}
	if m.statusErr || m.status != "deleted" {
		t.Errorf("status = (%q, err=%v), want deleted", m.status, m.statusErr)
	}
}

// ─── Task quick actions ──────────────────────────────────────────────────────

func TestClaimHitsFlatPathWithWorkerID(t *testing.T) {
	var taskPaths []string
	var taskBodies [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			taskPaths = append(taskPaths, r.URL.Path)
			b, _ := io.ReadAll(r.Body)
			taskBodies = append(taskBodies, b)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"task-1","claim":{"worker":"w-test","epoch":3}}}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[` + taskDocJSON + `]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "task")
	m = press(t, m, "c")

	if len(taskPaths) != 1 {
		t.Fatalf("want 1 task request, got %d", len(taskPaths))
	}
	// FLAT path — top-level /v1/tasks (auth: :token_root), NOT the
	// /w/:ws/p/:proj prefix scopedURL builds for /v1/data.
	if taskPaths[0] != "/v1/tasks/task-1/claim" {
		t.Errorf("claim path = %q, want the flat /v1/tasks/task-1/claim", taskPaths[0])
	}
	var body map[string]any
	if err := json.Unmarshal(taskBodies[0], &body); err != nil {
		t.Fatalf("parse claim body: %v", err)
	}
	if body["worker_id"] != "w-test" || len(body) != 1 {
		t.Errorf("claim body = %v, want exactly {worker_id: w-test}", body)
	}
	if m.statusErr || m.status != "claimed (epoch 3)" {
		t.Errorf("status = (%q, err=%v), want the epoch confirmation", m.status, m.statusErr)
	}
}

func TestClaimSurfacesReasonVerbatim(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			// ok:false rides a 4xx with the reason string as the contract.
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"already_claimed"}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[` + taskDocJSON + `]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "task")
	m = press(t, m, "c")

	if !m.statusErr || m.status != "already_claimed" {
		t.Errorf("status = (%q, err=%v), want the server reason VERBATIM", m.status, m.statusErr)
	}
}

func TestCloseSendsWorkerEpochLifecycle(t *testing.T) {
	var taskPaths []string
	var taskBodies [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			taskPaths = append(taskPaths, r.URL.Path)
			b, _ := io.ReadAll(r.Body)
			taskBodies = append(taskBodies, b)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"task-1","lifecycle_status":"done"}}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"result":{"documents":[` + claimedTaskDocJSON + `]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "task")
	m = press(t, m, "x")

	if len(taskPaths) != 1 {
		t.Fatalf("want 1 task request, got %d", len(taskPaths))
	}
	if taskPaths[0] != "/v1/tasks/task-1/close" {
		t.Errorf("close path = %q, want the flat /v1/tasks/task-1/close", taskPaths[0])
	}
	var body map[string]any
	if err := json.Unmarshal(taskBodies[0], &body); err != nil {
		t.Fatalf("parse close body: %v", err)
	}
	// observed_epoch comes from the doc's claim object (Extra["claim"].epoch).
	if body["worker_id"] != "w-test" || body["observed_epoch"] != float64(7) ||
		body["lifecycle_status"] != "done" {
		t.Errorf("close body = %v, want {worker_id:w-test observed_epoch:7 lifecycle_status:done}", body)
	}
	if m.statusErr || m.status != "closed" {
		t.Errorf("status = (%q, err=%v), want closed", m.status, m.statusErr)
	}
}

func TestCloseWithoutClaimErrorsLocally(t *testing.T) {
	taskRequests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			taskRequests++
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true}`))
		case strings.Contains(r.URL.Path, "/v1/data/query/"):
			w.WriteHeader(http.StatusOK)
			// Unclaimed task — no claim object, so no epoch to echo.
			_, _ = w.Write([]byte(`{"result":{"documents":[` + taskDocJSON + `]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "task")
	m = press(t, m, "x")

	if taskRequests != 0 {
		t.Errorf("close without an epoch must error LOCALLY, got %d request(s)", taskRequests)
	}
	if !m.statusErr || m.status != "not claimed — claim first (c)" {
		t.Errorf("status = (%q, err=%v), want the claim-first error", m.status, m.statusErr)
	}
}

func TestTaskKeysInertOnNonTaskList(t *testing.T) {
	taskRequests := 0
	var mutates [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			taskRequests++
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true}`))
		default:
			docServer(postDocJSON, &mutates)(w, r)
		}
	}))
	defer srv.Close()

	m := listModel(t, srv.URL, "post")
	m = press(t, m, "c")
	m = press(t, m, "x")

	if taskRequests != 0 {
		t.Errorf("c/x on a non-task list must be inert, got %d task request(s)", taskRequests)
	}
	if m.status != "" {
		t.Errorf("inert keys must set no status, got %q", m.status)
	}
}

// ─── Help-bar hints ──────────────────────────────────────────────────────────

func TestHelpBarTaskQuickActionHints(t *testing.T) {
	var mutates [][]byte
	taskSrv := httptest.NewServer(docServer(taskDocJSON, &mutates))
	defer taskSrv.Close()

	m := listModel(t, taskSrv.URL, "task")
	bar := m.renderHelpBar()
	for _, hint := range []string{"c claim", "x close", "D delete"} {
		if !strings.Contains(bar, hint) {
			t.Errorf("task-list help bar must hint %q:\n%s", hint, bar)
		}
	}

	postSrv := httptest.NewServer(docServer(postDocJSON, &mutates))
	defer postSrv.Close()

	m = listModel(t, postSrv.URL, "post")
	bar = m.renderHelpBar()
	if !strings.Contains(bar, "D delete") {
		t.Errorf("doc-list help bar must hint the delete key:\n%s", bar)
	}
	if strings.Contains(bar, "c claim") || strings.Contains(bar, "x close") {
		t.Errorf("non-task list must not hint the task quick actions:\n%s", bar)
	}
}
