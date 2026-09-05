package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-f81c88e2c54f8e57 — THE REPRODUCTION, AND THEN THE FIX.
//
// SYMPTOM AS FILED: `bp task create … --publish --yes` prints no receipt and no
// error, exits non-zero, and the row IS on the ledger; the operator's natural
// retry is then refused as a duplicate of the row the first call silently
// created.
//
// The reproduction below drives BOTH ambiguous shapes against an httptest
// server that keeps its own ledger, so a read-back can prove the row landed:
//
//	(a) the CREATE lands and the answer is LOST (the connection is closed
//	    without a response) — the same error class the 30s client budget
//	    raises when it fires while the server is still working;
//	(b) the create is accepted and the PUBLISH answer is lost after the draft
//	    was written.
//
// The connection is dropped rather than slept past the real budget because the
// budget is a compile-time constant (dispatchClientTimeout = 30s,
// dispatch_retry.go:51) and a 30s test is not a test; the transport error the
// client observes is the same shape either way, and it is the RENDERING of that
// error — not its cause — that this row is about.
//
// WHAT THE REPRODUCTION FOUND (and it is not any of the three filed candidate
// causes verbatim): every failure arm of runTaskCreate speaks ONLY on stderr,
// through out.userErr / out.errf. Neither renderErrorEnvelope nor useError is
// reached from any of them. Under `-o json` — the shape every scripted and
// agent caller uses, and the shape `bp` resolves for a non-TTY caller —
// stdout is therefore EMPTY, the exit code is 1, and the row may be on the
// ledger. A caller that reads stdout (the documented machine channel: an
// `{"ok":false,"error":{…}}` envelope on every OTHER refusal path, e.g.
// usageErrHintf at errors.go:854) sees literally nothing at all.

// silentWriteLedger is a fake mutate endpoint that RECORDS every write it
// applies before deciding how (or whether) to answer. The recorded set is the
// read-back that proves "the row exists" independently of what bp printed.
type silentWriteLedger struct {
	mu sync.Mutex
	// landed holds every document id the server actually wrote, in order.
	landed []string
	// published holds every bare id the server actually published.
	published []string
	// dropCreate / dropPublish hijack the connection and close it WITHOUT a
	// response, after the write has been recorded.
	dropCreate  bool
	dropPublish bool
	// publishEmptyResult answers the publish 2xx with an EMPTY results array —
	// the server accepted it and echoed no record, so whether a published twin
	// exists is unknown.
	publishEmptyResult bool
	// duplicateOf, when set, makes a SECOND create refuse with the server's
	// real dedup-wall shape naming the incumbent id.
	duplicateOf string
	creates     int
	docID       string
}

func (l *silentWriteLedger) rows() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.landed...)
}

func (l *silentWriteLedger) serve(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		// The tag registry read, answered authoritatively — otherwise every
		// --publish case exercises the fail-closed registry refusal instead.
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"cli"},{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		if !strings.Contains(req.URL.Path, "/v1/data/mutate") {
			rw.WriteHeader(http.StatusNotFound)
			return
		}
		var body struct {
			Mutations []map[string]map[string]any `json:"mutations"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body.Mutations) == 0 {
			rw.WriteHeader(http.StatusBadRequest)
			return
		}
		op := body.Mutations[0]

		if _, ok := op["create"]; ok {
			l.mu.Lock()
			l.creates++
			nth := l.creates
			dup := l.duplicateOf
			l.mu.Unlock()

			// THE SECOND CREATE: the ledger already holds the row the first
			// (ambiguous) attempt wrote, so the dedup wall refuses with a 409
			// naming the incumbent — api/lib/barkpark/content/errors.ex:741
			// builds details as {duplicate_of, similar, advise}.
			if nth > 1 && dup != "" {
				rw.Header().Set("Content-Type", "application/json")
				rw.WriteHeader(http.StatusConflict)
				_, _ = rw.Write([]byte(`{"error":{"code":"duplicate_of","message":"This publish near-duplicates an already-published document",` +
					`"details":{"duplicate_of":"` + dup + `","similar":[{"id":"` + dup + `","similarity":0.98,"relation":"near_duplicate","lifecycle_status":"open"}]}}}`))
				return
			}

			// THE WRITE COMMITS FIRST — that is the whole shape of this defect.
			l.mu.Lock()
			l.landed = append(l.landed, l.docID)
			drop := l.dropCreate
			l.mu.Unlock()
			if drop {
				hijackAndClose(rw)
				return
			}
			doc := map[string]any{"_id": l.docID, "_draft": true}
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{map[string]any{"id": l.docID, "document": doc}}})
			return
		}

		if pub, ok := op["publish"]; ok {
			bare, _ := pub["id"].(string)
			l.mu.Lock()
			l.published = append(l.published, bare)
			l.landed = append(l.landed, bare)
			drop := l.dropPublish
			l.mu.Unlock()
			if drop {
				hijackAndClose(rw)
				return
			}
			l.mu.Lock()
			empty := l.publishEmptyResult
			l.mu.Unlock()
			if empty {
				_, _ = rw.Write([]byte(`{"results":[]}`))
				return
			}
			doc := map[string]any{"_id": bare, "_draft": false, "lifecycle_status": "open"}
			_ = json.NewEncoder(rw).Encode(map[string]any{"results": []any{map[string]any{"id": bare, "document": doc}}})
			return
		}
		rw.WriteHeader(http.StatusBadRequest)
	}))
}

// hijackAndClose kills the connection with no response written — the transport
// error the client sees ("EOF" / "connection reset") is the same one a client
// deadline firing mid-flight produces, and the same one the filed occurrences
// describe: the write is gone from the client's view, not from the server's.
func hijackAndClose(rw http.ResponseWriter) {
	hj, ok := rw.(http.Hijacker)
	if !ok {
		rw.WriteHeader(http.StatusInternalServerError)
		return
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		return
	}
	_ = conn.Close()
}

// TestReproCreateAnswerLostIsSilentOnStdout is the c0 reproduction for the
// CREATE leg: the row lands, the answer is lost, bp exits non-zero — and under
// -o json stdout carries not one byte.
func TestReproCreateAnswerLostIsSilentOnStdout(t *testing.T) {
	led := &silentWriteLedger{docID: "drafts.task-501", dropCreate: true}
	ts := led.serve(t)
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{"A row the operator will never hear about", "--description", "The create answer is lost after the write commits.", "--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"a create whose answer is lost is a tasks-plugin defect"}]`, "--publish"})

	t.Logf("REPRO create-answer-lost: exit=%d\nstdout=%q\nstderr=%s\nserver ledger read-back=%v",
		code, so.String(), se.String(), led.rows())

	if len(led.rows()) == 0 {
		t.Fatalf("the reproduction did not land a row — nothing ambiguous happened")
	}
	// THE FIX. Distinct exit code, a parseable envelope on stdout, and a stderr
	// block that names the ambiguity and the read to run.
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d) — a definite refusal and a maybe-landed write must not share a code", code, exitAmbiguous)
	}
	env := decodeAmbiguousEnvelope(t, so.Bytes())
	if env.Error.Code != ambiguousWriteCode {
		t.Errorf("envelope code = %q, want %q", env.Error.Code, ambiguousWriteCode)
	}
	if env.Error.Details.Class != ambiguityCreateAnswerLost {
		t.Errorf("details.class = %q, want %q", env.Error.Details.Class, ambiguityCreateAnswerLost)
	}
	if !env.Error.Details.Sent {
		t.Errorf("details.sent must be true — the request DID leave this process")
	}
	// No id ever came back on this leg, so the check command is the title search.
	if !strings.Contains(env.Error.Details.CheckCommand, "bp search query") {
		t.Errorf("check_command = %q, want a title search (no id came back)", env.Error.Details.CheckCommand)
	}
	assertAmbiguousStderr(t, se.String(), ambiguityCreateAnswerLost)
}

// TestReproPublishAnswerLostIsSilentOnStdout is the c0 reproduction for the
// PUBLISH leg: the create succeeds, the publish lands and its answer is lost.
func TestReproPublishAnswerLostIsSilentOnStdout(t *testing.T) {
	led := &silentWriteLedger{docID: "drafts.task-502", dropPublish: true}
	ts := led.serve(t)
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{"A row whose publish answer is lost", "--description", "The publish answer is lost after the draft is written.", "--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"a create whose answer is lost is a tasks-plugin defect"}]`, "--publish"})

	t.Logf("REPRO publish-answer-lost: exit=%d\nstdout=%q\nstderr=%s\nserver ledger read-back=%v",
		code, so.String(), se.String(), led.rows())

	if len(led.rows()) < 2 {
		t.Fatalf("the reproduction did not land create+publish: %v", led.rows())
	}
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d)", code, exitAmbiguous)
	}
	env := decodeAmbiguousEnvelope(t, so.Bytes())
	if env.Error.Details.Class != residuePublishAmbiguousTransport {
		t.Errorf("details.class = %q, want %q", env.Error.Details.Class, residuePublishAmbiguousTransport)
	}
	// THIS leg knows the id — the create response named it seconds ago — so the
	// caller gets a read on the row, not a search.
	if env.Error.Details.DocID != "task-502" {
		t.Errorf("details.doc_id = %q, want task-502", env.Error.Details.DocID)
	}
	if env.Error.Details.CheckCommand != "bp task get task-502" {
		t.Errorf("check_command = %q, want \"bp task get task-502\"", env.Error.Details.CheckCommand)
	}
	assertAmbiguousStderr(t, se.String(), residuePublishAmbiguousTransport)
	if !strings.Contains(se.String(), "bp task get task-502") {
		t.Errorf("stderr does not tell the operator which read to run:\n%s", se.String())
	}
	// The residue line still rides alongside — one event, one vocabulary.
	if !strings.Contains(se.String(), "residue["+residuePublishAmbiguousTransport+"]") {
		t.Errorf("the residue class line was lost:\n%s", se.String())
	}
}

// TestReproRetryIsRefusedAsAFreshDuplicate is the c2 reproduction: the row the
// first (ambiguous) attempt wrote is on the ledger, so the natural retry is
// refused — and the refusal must name the SURVIVING id with a resume command,
// not read as a fresh conflict.
func TestReproRetryIsRefusedAsAFreshDuplicate(t *testing.T) {
	led := &silentWriteLedger{docID: "drafts.task-503", dropCreate: true, duplicateOf: "task-503"}
	ts := led.serve(t)
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	title := "A row that lands twice if you let it"

	var so1, se1 bytes.Buffer
	w1 := &writer{stdout: &so1, stderr: &se1, output: "json"}
	code1 := runTaskCreate(w1, globals{yes: true}, ctx, []string{title, "--description", "A description long enough to clear the publish wall.", "--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"a create whose answer is lost is a tasks-plugin defect"}]`, "--publish"})

	var so2, se2 bytes.Buffer
	w2 := &writer{stdout: &so2, stderr: &se2, output: "json"}
	code2 := runTaskCreate(w2, globals{yes: true}, ctx, []string{title, "--description", "A description long enough to clear the publish wall.", "--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"a create whose answer is lost is a tasks-plugin defect"}]`, "--publish"})

	t.Logf("REPRO retry: first exit=%d stdout=%q\nfirst stderr=%s\nsecond exit=%d stdout=%q\nsecond stderr=%s\nledger=%v",
		code1, so1.String(), se1.String(), code2, so2.String(), se2.String(), led.rows())

	if code1 != exitAmbiguous {
		t.Fatalf("first attempt exit = %d, want exitAmbiguous (%d)", code1, exitAmbiguous)
	}
	// THE RETRY IS SURVIVABLE. The refusal names the surviving id, says it is
	// probably the caller's OWN row from the ambiguous first attempt, and hands
	// over the exact resume command — instead of reading as a fresh conflict.
	if code2 != exitConflict {
		t.Fatalf("retry exit = %d, want exitConflict (%d) — a duplicate of your own row is not a generic failure", code2, exitConflict)
	}
	got := se2.String()
	for _, want := range []string{
		"THE ROW ALREADY EXISTS: task-503",
		"resume it:            bp task get task-503",
		"publish it in place:  " + taskPublishCommand("task-503"),
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the retry refusal does not carry %q:\n%s", want, got)
		}
	}
	// And the machine channel is not empty either — that was the whole defect.
	if so2.Len() == 0 {
		t.Fatalf("the retry refusal printed NOTHING on stdout under -o json")
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Details struct {
				DuplicateOf   string `json:"duplicate_of"`
				ResumeCommand string `json:"resume_command"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so2.Bytes(), &env); err != nil {
		t.Fatalf("retry envelope did not parse: %v (%q)", err, so2.String())
	}
	if env.Error.Code != "duplicate_of" {
		t.Errorf("retry envelope code = %q, want duplicate_of", env.Error.Code)
	}
	if env.Error.Details.DuplicateOf != "task-503" || env.Error.Details.ResumeCommand != "bp task get task-503" {
		t.Errorf("retry envelope does not name the surviving row + resume command: %q", so2.String())
	}
}

// ambiguousEnvelope is the machine half every ambiguous arm must now emit.
type ambiguousEnvelope struct {
	OK    bool `json:"ok"`
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
		Hint    string `json:"hint"`
		Details struct {
			Class        string `json:"class"`
			Sent         bool   `json:"sent"`
			Landed       string `json:"landed"`
			DocID        string `json:"doc_id"`
			Title        string `json:"title"`
			CheckCommand string `json:"check_command"`
			Detail       string `json:"detail"`
		} `json:"details"`
	} `json:"error"`
}

func decodeAmbiguousEnvelope(t *testing.T, stdout []byte) ambiguousEnvelope {
	t.Helper()
	if len(stdout) == 0 {
		t.Fatalf("stdout was EMPTY under -o json — this is the defect: a write that may have landed said nothing on the machine channel")
	}
	var env ambiguousEnvelope
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("stdout was not a parseable error envelope: %v (%q)", err, stdout)
	}
	if env.OK {
		t.Fatalf("envelope reported ok:true for a failed write: %q", stdout)
	}
	if env.Error.Details.Landed != "unknown" {
		t.Errorf("details.landed = %q, want \"unknown\" — the whole point is that we do not know", env.Error.Details.Landed)
	}
	return env
}

// assertAmbiguousStderr pins the human half, which is printed in EVERY output
// shape (including json/yaml): a write that may have committed is not something
// to hide behind an output flag.
func assertAmbiguousStderr(t *testing.T, stderr, class string) {
	t.Helper()
	for _, want := range []string{
		"WAS SENT and may have landed",
		"ambiguous[" + class + "]",
		"do NOT blind-retry",
		"check with: ",
		"doc_id",
	} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr does not carry %q:\n%s", want, stderr)
		}
	}
}

// TestTaskCreateAmbiguityClassesAreEnumerated keeps the class set CLOSED: a new
// ambiguous arm added without a name and a why here reds this test, which is
// the only thing stopping the next silent branch.
func TestTaskCreateAmbiguityClassesAreEnumerated(t *testing.T) {
	for _, class := range []string{
		ambiguityCreateAnswerLost,
		ambiguityCreateServerFault,
		ambiguityCreateResultUnreadable,
		residuePublishAmbiguousTransport,
		residuePublishAmbiguousServerFault,
		residuePublishResultUnreadable,
	} {
		why, ok := taskCreateAmbiguityClasses[class]
		if !ok || strings.TrimSpace(why) == "" {
			t.Errorf("ambiguity class %q carries no explanation", class)
		}
	}
	if len(taskCreateAmbiguityClasses) != 6 {
		t.Errorf("taskCreateAmbiguityClasses has %d entries, want 6 — a new arm needs a name and a why", len(taskCreateAmbiguityClasses))
	}
}

// TestIncumbentTaskIDReadsBothDedupShapes: the surviving id arrives either as
// details.duplicate_of (a bare string) or as the first `similar` candidate.
// Reading only one shape is how the resume block goes silently missing.
func TestIncumbentTaskIDReadsBothDedupShapes(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"duplicate_of wins", `{"error":{"code":"duplicate_of","details":{"duplicate_of":"task-11","similar":[{"id":"task-99"}]}}}`, "task-11"},
		{"similar fallback", `{"error":{"code":"duplicate_of","details":{"similar":[{"id":"task-99","similarity":0.9}]}}}`, "task-99"},
		{"drafts prefix stripped", `{"error":{"code":"duplicate_of","details":{"duplicate_of":"drafts.task-12"}}}`, "task-12"},
		{"names nothing", `{"error":{"code":"validation_failed","details":{"title":["is required"]}}}`, ""},
		{"not an envelope", `not json`, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := incumbentTaskID([]byte(c.body)); got != c.want {
				t.Errorf("incumbentTaskID = %q, want %q", got, c.want)
			}
		})
	}
}

// TestPublishResultUnreadableIsNotAPlainFailure: a 2xx that echoes no record is
// the subtlest ambiguous arm — the publish very likely landed. It used to exit
// 1, the same code as an outright refusal, with nothing on stdout.
func TestPublishResultUnreadableIsNotAPlainFailure(t *testing.T) {
	led := &silentWriteLedger{docID: "drafts.task-504", publishEmptyResult: true}
	ts := led.serve(t)
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"A publish that echoes no record",
		"--description", "The publish answers 2xx and echoes nothing back.",
		"--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"a create whose answer is lost is a tasks-plugin defect"}]`,
		"--publish",
	})

	t.Logf("exit=%d\nstdout=%s\nstderr=%s\nledger=%v", code, so.String(), se.String(), led.rows())

	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d)", code, exitAmbiguous)
	}
	env := decodeAmbiguousEnvelope(t, so.Bytes())
	if env.Error.Details.Class != residuePublishResultUnreadable {
		t.Errorf("details.class = %q, want %q", env.Error.Details.Class, residuePublishResultUnreadable)
	}
	if env.Error.Details.CheckCommand != "bp task get task-504" {
		t.Errorf("check_command = %q, want \"bp task get task-504\"", env.Error.Details.CheckCommand)
	}
	assertAmbiguousStderr(t, se.String(), residuePublishResultUnreadable)
}

// TestCreateServerFaultIsAmbiguousWithATitleHandle: the create 5xx arm, under
// -o json, where the whole event used to vanish. No id ever came back, so the
// only handle is the title the caller supplied — and it must be IN the envelope,
// not only in a stderr sentence.
func TestCreateServerFaultIsAmbiguousWithATitleHandle(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		rw.WriteHeader(http.StatusInternalServerError)
		_, _ = rw.Write([]byte(`{"error":{"code":"internal_error","message":"the database connection pool is exhausted","request_id":"req-abc123"}}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	title := "A create the server faults on"
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{title})

	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d), stderr: %s", code, exitAmbiguous, se.String())
	}
	env := decodeAmbiguousEnvelope(t, so.Bytes())
	if env.Error.Details.Class != ambiguityCreateServerFault {
		t.Errorf("details.class = %q, want %q", env.Error.Details.Class, ambiguityCreateServerFault)
	}
	if env.Error.Details.Title != title {
		t.Errorf("details.title = %q, want %q — the title is the ONLY handle when no id came back", env.Error.Details.Title, title)
	}
	if env.Error.Details.DocID != "" {
		t.Errorf("details.doc_id = %q, want empty — no id ever came back and one must never be guessed", env.Error.Details.DocID)
	}
	// The server's request_id must survive into the human channel: it is the one
	// thing the API operator can act on.
	if !strings.Contains(se.String(), "req-abc123") {
		t.Errorf("the server's request_id was dropped:\n%s", se.String())
	}
}
