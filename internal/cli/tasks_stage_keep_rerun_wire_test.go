package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// tasks_stage_keep_rerun_wire_test.go — does `--keep-rerun` REACH the server?
//
// tasks_stage_rerun_guard_test.go proves the CLIENT gate: --keep-rerun lets the
// stage through instead of refusing it locally. That test passes against a fake
// server that answers 200 to anything, so it says nothing about what the
// REQUEST carried — and until task-4d5a2dde8a02d057 the request carried nothing
// at all. The flag was stripped and never forwarded, so `--supersede
// --keep-rerun` sent a BARE supersede and PR #18817's server refused it 409
// rerun_would_orphan: the one flag an operator reaches for to get past the
// refusal was the one flag that could not reach the door that honours it.
//
// So the arms here never look for the flag NAME in the source. They stand up a
// fake instance that ENFORCES PR #18817's own rule and read what the client
// actually sent.

// keepRerunServerRule is the stage door's rule as api/lib/barkpark/tasks/stage.ex
// implements it (check_rerun_orphan): a note that DISPLACES a different non-blank
// disposition_reason over a row carrying a non-blank disposition_rerun is refused
// 409 rerun_would_orphan unless the same call also carries one of the three
// overrides — `rerun` (re-bind), `clear_rerun` (subtract), `keep_rerun` (it still
// binds).
func keepRerunServerRule(params url.Values) (refused bool) {
	note := params.Get("note")
	if strings.TrimSpace(note) == "" || strings.TrimSpace(note) == theBoundReason {
		return false
	}
	if params.Get("supersede") != "true" {
		return false
	}
	for _, override := range []string{"rerun", "clear_rerun", "clear-rerun", stageKeepRerunParam, "keep-rerun"} {
		if v := strings.TrimSpace(params.Get(override)); v != "" && v != "false" {
			return false
		}
	}
	return true
}

// keepRerunWireHarness is a fake instance that answers the row read with the
// bound (reason, rerun) pair and enforces keepRerunServerRule on the stage POST,
// recording the body it received.
type keepRerunWireHarness struct {
	t           *testing.T
	server      *httptest.Server
	m           *manifest.Manifest
	ctx         manifest.Context
	rerunOnRow  string
	stageBody   string
	stageSeen   bool
	stageCode   int
	stageParams url.Values
}

func newKeepRerunWireHarness(t *testing.T) *keepRerunWireHarness {
	t.Helper()
	h := &keepRerunWireHarness{t: t, rerunOnRow: theBoundRerun}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(taskRowBody(theBoundReason, h.rerunOnRow)))
			return
		}
		raw, _ := io.ReadAll(r.Body)
		h.stageSeen = true
		h.stageBody = string(raw)
		h.stageParams = r.URL.Query()
		if h.rerunOnRow != "" && keepRerunServerRule(h.stageParams) {
			h.stageCode = http.StatusConflict
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"error":{"code":"` + stageRerunOrphanCode +
				`","message":"refusing to supersede: the row carries a disposition_rerun this call says nothing about"}}`))
			return
		}
		h.stageCode = http.StatusOK
		// The door KEEPS the rerun byte-identical on a keep_rerun stage.
		_, _ = w.Write([]byte(taskRowBody(theRulingNote, h.rerunOnRow)))
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(stageRerunManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{Server: h.server.URL, Token: "tok", Workspace: "acme", Project: "site", Dataset: "production"}
	return h
}

func (h *keepRerunWireHarness) runStage(tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("task", "stage")
	if !ok {
		h.t.Fatal("fixture manifest has no task stage")
	}
	var so, se bytes.Buffer
	g := globals{yes: true}
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// ── THE ARM ──────────────────────────────────────────────────────────────────
//
// REVERT-RED: drop the `if stageKeepRerun { stampStageKeepRerun(req) }` block
// from run.go and the POST goes out BARE, keepRerunServerRule refuses it 409,
// and both the exit code and the body assertion below fail. It cannot pass on a
// client that merely names the flag in a comment, because what is measured is
// the bytes the fake instance received.
func TestStageKeepRerunSurvivesTheServersOwnRerunOrphanRefusal(t *testing.T) {
	h := newKeepRerunWireHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede", stageKeepRerunFlag)

	if !h.stageSeen {
		t.Fatalf("no stage was sent at all; stderr:\n%s", stderr)
	}
	if h.stageCode == http.StatusConflict {
		t.Errorf("the server refused %d %s — the request reached the door WITHOUT the override it opts into. body sent:\n%s",
			h.stageCode, stageRerunOrphanCode, h.stageBody)
	}
	if code != exitOK {
		t.Errorf("exit = %d — %s must land, not be refused end to end. stderr:\n%s", code, stageKeepRerunFlag, stderr)
	}

	if h.stageParams.Get(stageKeepRerunParam) != "true" {
		t.Errorf("the request carries no %s=true — %s never reached the wire. params sent: %v",
			stageKeepRerunParam, stageKeepRerunFlag, h.stageParams.Encode())
	}
	// The flags the caller actually typed must still ride the same request: the
	// stamp adds one key, it does not rebuild the payload.
	if h.stageParams.Get("note") != theRulingNote {
		t.Errorf("the stamp displaced the note the caller typed; params sent: %v", h.stageParams.Encode())
	}
	if h.stageParams.Get("supersede") != "true" {
		t.Errorf("the stamp displaced --supersede; params sent: %v", h.stageParams.Encode())
	}
	if !strings.Contains(h.stageBody, `"state":"open"`) {
		t.Errorf("the positional state left the body; body sent:\n%s", h.stageBody)
	}
}

// ── THE QUIET ARM ────────────────────────────────────────────────────────────
//
// The stamp must be exactly as narrow as the flag. A client that put keep_rerun
// on EVERY stage would pass the arm above and would also silently claim, on
// every future call, that a probe the caller never read still binds. So a stage
// with no --keep-rerun must send a body with no such key — measured on a row
// carrying NO rerun, which is a call the client guard lets straight through.
func TestStageWithoutKeepRerunSendsNoKeepRerunKey(t *testing.T) {
	h := newKeepRerunWireHarness(t)
	h.rerunOnRow = "" // nothing to orphan: the guard is silent and the stage goes out

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede")

	if code != exitOK {
		t.Fatalf("exit = %d — a row with no rerun has nothing to orphan. stderr:\n%s", code, stderr)
	}
	if !h.stageSeen {
		t.Fatalf("no stage was sent; stderr:\n%s", stderr)
	}
	if _, present := h.stageParams[stageKeepRerunParam]; present {
		t.Errorf("a stage that never said %s still sent %s — the client would be stating, on the caller's behalf, that a probe they never read still binds. params sent: %v",
			stageKeepRerunFlag, stageKeepRerunParam, h.stageParams.Encode())
	}
	if strings.Contains(h.stageBody, stageKeepRerunParam) {
		t.Errorf("a stage that never said %s carried it in the body:\n%s", stageKeepRerunFlag, h.stageBody)
	}
}

// The stamp is scoped to `task stage`. A different write verb must never gain a
// keep_rerun key, and --keep-rerun must stay an unknown flag there — the strip's
// own scope (stageKeepRerunFlagApplies), measured through the resolved request
// rather than by reading the scope function back to itself.
func TestKeepRerunIsNotStampedOnOtherCommands(t *testing.T) {
	h := newKeepRerunWireHarness(t)
	get, ok := h.m.Tree().Lookup("task", "get")
	if !ok {
		t.Fatal("fixture manifest has no task get")
	}
	if stageKeepRerunFlagApplies(*get) {
		t.Error("the strip claims task.get, which would swallow a real flag of that name")
	}
	req, derr := buildManifestRequest(globals{yes: true}, h.ctx, h.m, *get, []string{theAdjudicatedRow}, false)
	if derr != nil {
		t.Fatalf("build task get: %v", derr)
	}
	if strings.Contains(req.url, stageKeepRerunParam) || strings.Contains(string(req.body), stageKeepRerunParam) {
		t.Errorf("task get carries %s; url=%s body=%s", stageKeepRerunParam, req.url, req.body)
	}
}
