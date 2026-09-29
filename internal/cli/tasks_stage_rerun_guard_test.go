package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// stageRerunManifestJSON is the two-verb slice of the LIVE manifest this guard
// needs, copied field-for-field from what the api declares (task.get /
// task.stage as they appear in /v1/capabilities on guerrilla). Neither carries a
// scoped_prefix, which is how the task doors really ship, so the URLs the fake
// server sees are the URLs the CLI sends.
const stageRerunManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "task", "summary": "Tasks."}],
  "commands": [
    {"id":"task.get","noun":"task","verb":"get","summary":"Fetch one task.",
     "http":{"method":"GET","path_template":"/v1/tasks/:doc_id"},
     "auth_tier":"read",
     "args":[{"name":"doc_id","required":true,"type":"string","summary":"Task id."}],
     "flags":[{"name":"dataset","type":"string","summary":"Dataset."}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":null},
    {"id":"task.stage","noun":"task","verb":"stage","summary":"Stage a task.",
     "http":{"method":"POST","path_template":"/v1/tasks/:doc_id/stage"},
     "auth_tier":"write",
     "args":[{"name":"doc_id","required":true,"type":"string","summary":"Task id."},
             {"name":"state","required":true,"type":"string","summary":"Target state."}],
     "flags":[{"name":"note","type":"string","summary":"Adjudication reason."},
              {"name":"supersede","type":"bool","summary":"Replace a different reason."},
              {"name":"rerun","type":"string","summary":"Falsifying command."},
              {"name":"clear-rerun","type":"bool","summary":"Remove the falsifying command."},
              {"name":"dataset","type":"string","summary":"Dataset."}],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":null}
  ]
}`

// theAdjudicatedRow, theBoundReason and theBoundRerun are the scratch row
// measured on guerrilla 2026-09-17 (task-a5b928e4d5dfba60): a reason that turns
// on one file, and a rerun that probes exactly that file.
const (
	theAdjudicatedRow = "task-a5b928e4d5dfba60"
	theBoundReason    = "REASON A: tasks_adjudication.go exists on origin/main, so the vocabulary screen ships."
	theBoundRerun     = "git cat-file -e origin/main:internal/cli/tasks_adjudication.go"
	// theRulingNote is the replacement measured in the reproduction: a pure
	// ruling that names no file and no symbol, so nothing the rerun runs binds
	// to it.
	theRulingNote = "REASON C: THE RULING — pick it up. Nothing here turns on any file or symbol."
)

// stageRerunHarness stands up a fake instance and the parsed manifest pointed at
// it, and records every request path+method the CLI actually sends — the only
// way to prove the stage was WITHHELD rather than merely unrendered.
type stageRerunHarness struct {
	t          *testing.T
	server     *httptest.Server
	m          *manifest.Manifest
	ctx        manifest.Context
	seen       []string
	getStatus  int    // status the row read answers (0 -> 200)
	getBody    string // body the row read answers with (empty -> bound reason + rerun)
	recordBody func(string)
}

// taskRowBody renders a task row the way GET /v1/tasks/:doc_id really does:
// {"doc":{"content":{…}}}, with the adjudication keys inside content. A field
// left empty is OMITTED, which is the shape a row without it really has (the
// key is absent, not null).
func taskRowBody(reason, rerun string) string {
	var fields []string
	fields = append(fields, `"kind":"task"`, `"lifecycle_status":"open"`)
	if reason != "" {
		fields = append(fields, `"disposition_reason":`+quoteJSON(reason))
	}
	if rerun != "" {
		fields = append(fields, `"disposition_rerun":`+quoteJSON(rerun))
	}
	return `{"ok":true,"doc":{"doc_id":"` + theAdjudicatedRow + `","type":"task","content":{` +
		strings.Join(fields, ",") + `}}}`
}

// quoteJSON is a minimal JSON string escaper for the fixture bodies — enough for
// the measured text, which carries quotes-free prose and an em dash.
func quoteJSON(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func newStageRerunHarness(t *testing.T) *stageRerunHarness {
	t.Helper()
	h := &stageRerunHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			status := h.getStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			body := h.getBody
			if body == "" {
				body = taskRowBody(theBoundReason, theBoundRerun)
			}
			if status != http.StatusOK {
				body = `{"error":{"code":"not_found","message":"no such task"}}`
			}
			_, _ = w.Write([]byte(body))
		default:
			if h.recordBody != nil {
				raw, _ := io.ReadAll(r.Body)
				h.recordBody(string(raw))
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"` + theAdjudicatedRow + `"}}`))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(stageRerunManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server:    h.server.URL,
		Token:     "tok",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
		// NOT explicit: the task ledger routes carry no scoped_prefix, so a
		// stated -w/-p is refused by refuseUnrepresentableScope before any guard
		// runs. That refusal is a different gate's subject; this fixture must
		// reach THIS one.
	}
	return h
}

func (h *stageRerunHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

const (
	stageRerunGetPath   = "/v1/tasks/" + theAdjudicatedRow
	stageRerunStagePath = "/v1/tasks/" + theAdjudicatedRow + "/stage"
)

// runStage drives the real runCommand — the whole guarded path, not the guard in
// isolation — so a future edit that moves or drops the gate call site reds these
// tests instead of passing on a bypassed helper.
func (h *stageRerunHarness) runStage(tail ...string) (code int, stdout, stderr string) {
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

// ── THE RED ARM ──────────────────────────────────────────────────────────────
//
// THE DEFECT (task-5509618e1868d9f2), reproduced on guerrilla 2026-09-17:
// `bp task stage <row> open --note <different> --supersede` on a row carrying a
// disposition_rerun replaces the reason, exits 0, and leaves the rerun
// byte-identical — a green, symbol-specific probe now attached to a claim the
// row no longer makes. The stage must not be sent, and the refusal must quote
// the rerun and name the ways out.
//
// REVERT-RED: drop the guardStageRerunOrphan call from run.go and the stage is
// sent, so `h.sent(POST …)` fires and the exit code is exitOK.
func TestStageSupersedingAReasonOverARerunSendsNoStage(t *testing.T) {
	h := newStageRerunHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede")

	if code == exitOK {
		t.Errorf("exit = %d (ok) — a write that strands the row's falsifier must not report success", code)
	}
	if h.sent("POST " + stageRerunStagePath) {
		t.Error("the stage was sent over a row carrying a disposition_rerun — the guard did not hold")
	}
	if !h.sent("GET " + stageRerunGetPath) {
		t.Errorf("the guard never read the row; requests seen: %v", h.seen)
	}
	// The refusal must carry: the rerun IN FULL (a truncated command cannot be
	// judged), both ways past the gate, and the guarantee that nothing landed.
	for _, want := range []string{
		theBoundRerun,
		"--rerun",
		stageKeepRerunFlag,
		"nothing was written",
		stageRerunOrphanCode,
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("refusal omits %q — it must quote the probe and name the way out:\n%s", want, stderr)
		}
	}
}

// The override is ITS OWN FLAG and never --supersede: a caller who stated they
// read the REASON has not stated they read the rerun. --supersede alone is the
// refused call above; only --keep-rerun lets it through, and when it does the
// guard PREVIEWS what is being kept rather than going silent.
func TestStageKeepRerunFlagIsTheOnlyOverride(t *testing.T) {
	h := newStageRerunHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede", stageKeepRerunFlag)

	if code != exitOK {
		t.Errorf("exit = %d — %s is the stated opt-in and must let the write through, stderr:\n%s", code, stageKeepRerunFlag, stderr)
	}
	if !h.sent("POST " + stageRerunStagePath) {
		t.Errorf("the stage was withheld despite %s; requests seen: %v", stageKeepRerunFlag, h.seen)
	}
	if !strings.Contains(stderr, theBoundRerun) {
		t.Errorf("the deliberate keep printed no preview of what is being kept:\n%s", stderr)
	}
}

// ── THE QUIET ARMS ───────────────────────────────────────────────────────────
//
// Every shape that cannot orphan a rerun must be invisible to this guard: the
// stage goes out, the exit is 0, and it says nothing about reruns. The first
// four do no network work at all, which is asserted directly — a guard that
// probed on every stage would be a per-call round trip on the fleet's busiest
// adjudication verb.
func TestStageShapesThatCannotOrphanAreUntouched(t *testing.T) {
	cases := []struct {
		name      string
		tail      []string
		rowReason string
		rowRerun  string
		wantProbe bool
	}{
		{
			name: "no --note at all — nothing is displaced",
			tail: []string{theAdjudicatedRow, "open"},
		},
		{
			name: "a blank --note overwrites nothing",
			tail: []string{theAdjudicatedRow, "open", "--note", "   "},
		},
		{
			name: "no --supersede — the SERVER's own 409 owns this call, so the gate has no subject",
			tail: []string{theAdjudicatedRow, "open", "--note", theRulingNote},
		},
		{
			name: "--rerun on the same call re-binds the probe: that is the fix, not the defect",
			tail: []string{theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede", "--rerun", "git cat-file -e origin/main:README.md"},
		},
		{
			name:      "the row carries NO rerun — there is nothing to orphan",
			tail:      []string{theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede"},
			rowReason: theBoundReason,
			wantProbe: true,
		},
		{
			name:      "the row's reason is ABSENT — the reason is being set, not displaced",
			tail:      []string{theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede"},
			rowRerun:  theBoundRerun,
			wantProbe: true,
		},
		{
			name:      "a re-stage with the SAME note text replaces nothing",
			tail:      []string{theAdjudicatedRow, "open", "--note", theBoundReason, "--supersede"},
			rowReason: theBoundReason,
			rowRerun:  theBoundRerun,
			wantProbe: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newStageRerunHarness(t)
			h.getBody = taskRowBody(tc.rowReason, tc.rowRerun)

			code, _, stderr := h.runStage(tc.tail...)

			if code != exitOK {
				t.Errorf("exit = %d — this shape cannot orphan a rerun and must stage exactly as before, stderr:\n%s", code, stderr)
			}
			if !h.sent("POST " + stageRerunStagePath) {
				t.Errorf("the stage was withheld; requests seen: %v", h.seen)
			}
			for _, unwanted := range []string{"refusing to supersede", stageRerunOrphanCode, stageKeepRerunFlag} {
				if strings.Contains(stderr, unwanted) {
					t.Errorf("the guard spoke about reruns on a harmless shape (%q):\n%s", unwanted, stderr)
				}
			}
			if got := h.sent("GET " + stageRerunGetPath); got != tc.wantProbe {
				t.Errorf("probed = %v, want %v — a guard that reads the row on every stage is a round trip per call; requests seen: %v",
					got, tc.wantProbe, h.seen)
			}
		})
	}
}

// A DISTINCTNESS refusal is explicitly NOT this guard's business (PDS-D391b(b),
// PDS-D336(a)): a SHARED rerun over distinct rows is the honest shape, and the
// filing measured that refusing it would have refused 191 correct writes. So a
// call that re-binds the rerun to a command some other row already carries goes
// straight through — this is the arm that stays quiet when a plausible-sounding
// extra rule would have fired.
func TestStageDoesNotRefuseASharedRerun(t *testing.T) {
	h := newStageRerunHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open",
		"--note", theRulingNote, "--supersede", "--rerun", theBoundRerun)

	if code != exitOK {
		t.Errorf("exit = %d — a shared rerun is the honest shape and must never be refused here, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + stageRerunStagePath) {
		t.Errorf("the stage was withheld over a SHARED rerun; requests seen: %v", h.seen)
	}
}

// UNKNOWN FAILS OPEN, AND SAYS SO. A row the check could not read must not be
// reported as carrying no rerun — the guard proceeds, and prints one line naming
// why it could not measure. The inverse (refusing) would stall the fleet's
// adjudication verb on a read hiccup.
func TestStageProceedsWithANoticeWhenTheRowCannotBeRead(t *testing.T) {
	h := newStageRerunHarness(t)
	h.getStatus = http.StatusInternalServerError

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede")

	if code != exitOK {
		t.Errorf("exit = %d — a blind check must not block the write, stderr:\n%s", code, stderr)
	}
	if !h.sent("POST " + stageRerunStagePath) {
		t.Errorf("the stage was withheld on a BLIND check; requests seen: %v", h.seen)
	}
	for _, want := range []string{"could not check", "HTTP 500", stageKeepRerunFlag} {
		if !strings.Contains(stderr, want) {
			t.Errorf("the blind branch omits %q — it must never assert an absence it did not measure:\n%s", want, stderr)
		}
	}
}

// `--keep-rerun` is ADDITIVE and scoped: it is stripped only for `task stage`,
// so it stays an ordinary unknown-flag refusal everywhere else, and the inline
// `--keep-rerun=x` form is refused rather than silently succeeding on a typo.
func TestStageKeepRerunFlagIsScopedAndRefusesAnInlineValue(t *testing.T) {
	h := newStageRerunHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede", stageKeepRerunFlag+"=yes")

	if code == exitOK {
		t.Errorf("exit = %d — an inline value on the bool opt-in must be a usage error, not a silent keep", code)
	}
	if h.sent("POST " + stageRerunStagePath) {
		t.Error("a typo'd opt-in let the write through")
	}
	if !strings.Contains(stderr, "keep-rerun") {
		t.Errorf("the refusal does not name the flag it rejected:\n%s", stderr)
	}

	get, ok := h.m.Tree().Lookup("task", "get")
	if !ok {
		t.Fatal("fixture manifest has no task get")
	}
	if found, kept := extractStageKeepRerunFlag([]string{stageKeepRerunFlag}); !found || len(kept) != 0 {
		t.Errorf("extractStageKeepRerunFlag did not strip its own flag: found=%v kept=%v", found, kept)
	}
	if stageKeepRerunFlagApplies(*get) {
		t.Error("the additive flag is being stripped from a command that is not `task stage`")
	}
}

// ── THE SUBTRACTION DOOR (task-5509618e1868d9f2 c3, cli half) ────────────────
//
// THE DEFECT, measured on guerrilla 2026-09-17 with a bp built from origin/main
// 4f6b7f5e4: `--supersede --clear-rerun` — the operator taking exactly the door
// PDS-D750's REMOVE arm is built on — exited 5 rerun_would_orphan HERE, nothing
// was sent, and the row read back with its rerun still present. The server
// implements the removal (PR #18817) and its own refusal names --clear-rerun;
// this guard was the only thing withholding it, while printing a refusal that
// said the removal did not exist.
//
// REVERT-RED: drop the stageClearRerunFlagName stand-down from stageRerunArgs
// and this test fails — the stage is withheld and the exit is non-zero.
func TestStageClearRerunIsNotRefusedForStrandingTheRerunItRemoves(t *testing.T) {
	h := newStageRerunHarness(t)

	code, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede", "--clear-rerun")

	if code != exitOK {
		t.Errorf("exit = %d — %s REMOVES the rerun, so there is nothing left to strand and the guard must stand down; stderr:\n%s",
			code, stageClearRerunFlag, stderr)
	}
	if !h.sent("POST " + stageRerunStagePath) {
		t.Errorf("the stage was withheld despite %s; requests seen: %v", stageClearRerunFlag, h.seen)
	}
	// Costs no round trip either: the flag is read off the call, so the guard
	// never needs to know what the row carries.
	if h.sent("GET " + stageRerunGetPath) {
		t.Errorf("the guard probed the row on a call that removes the rerun; requests seen: %v", h.seen)
	}
	if strings.Contains(stderr, stageRerunOrphanCode) {
		t.Errorf("a removal was described as an orphaning:\n%s", stderr)
	}
}

// The refusal must name the subtraction door as a way out — and must NOT assert
// the removal is impossible, which is what it said for as long as the server
// half was unlanded. A refusal that hides the door built to answer it sends the
// operator to --keep-rerun, i.e. to keeping a probe that does not bind the
// reason they are writing: the exact orphan this guard exists to prevent.
//
// REVERT-RED: restore the old third line of stageRerunOrphanRefusal and this
// test fails on both halves — no --clear-rerun, and "not possible at any door".
func TestStageRerunRefusalNamesAllThreeDoors(t *testing.T) {
	h := newStageRerunHarness(t)

	_, _, stderr := h.runStage(theAdjudicatedRow, "open", "--note", theRulingNote, "--supersede")

	for _, want := range []string{"--rerun", stageKeepRerunFlag, stageClearRerunFlag} {
		if !strings.Contains(stderr, want) {
			t.Errorf("refusal omits the %s door — every way out must be on the page:\n%s", want, stderr)
		}
	}
	// The stale claim, in the spellings it shipped in. Probing for the NEW text
	// alone would pass on a refusal that named --clear-rerun in one breath and
	// called it unimplemented in the next.
	for _, gone := range []string{
		"not possible at any door",
		"until it lands",
		"server half of task-5509618e1868d9f2",
	} {
		if strings.Contains(stderr, gone) {
			t.Errorf("refusal still asserts the removal is unlanded (%q) — it shipped in PR #18817 and is live:\n%s", gone, stderr)
		}
	}
}
