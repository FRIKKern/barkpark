package cli

// tasks_create_idempotency_test.go — task-a520c703e4e9b931.
//
// THE DOOR IN THESE TESTS EMULATES THE PLUG, not just a header sink. An earlier
// draft of this file recorded the Idempotency-Key and nothing else, and that is
// precisely why it could not see the defect the criterion was re-cut for: the
// server hashes (raw_key, token_id, method, request_path) and NOTHING FROM THE
// BODY (api/lib/barkpark_web/plugs/idempotency.ex:6 and :47), and both legs of
// `bp task create --publish` POST the same path. A door that only records
// headers is green whether the two legs share a key or not — while a real
// server, handed a shared key, would REPLAY the create response for the publish
// request and the publish would silently never run.
//
// So idemPlugDoor caches the first response per (key, method, path) and replays
// it with `Idempotency-Replay: true`, exactly as the plug does, and the c0
// detector asserts the PUBLISH ACTUALLY EXECUTED — the row ends published, not
// merely created. That assertion is what goes red under a shared key.
//
// THE CLAIMS:
//
//	c0  every mutate request carries an Idempotency-Key; the create leg and the
//	    publish leg of one invocation carry DIFFERENT keys; two invocations never
//	    share one; and the publish leg runs.
//	c1  a resend of ONE leg carries that leg's SAME key, and exactly one row
//	    results.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// idemSeen is one request as the door saw it.
type idemSeen struct {
	leg      string
	key      string
	replayed bool
}

// idemCached is one recorded response, keyed like the plug's row.
type idemCached struct {
	status int
	body   []byte
}

// idemPlugDoor is a fake POST /v1/data/mutate/<dataset> that behaves like the
// :idempotent plug in the ways that matter to a client.
type idemPlugDoor struct {
	mu    sync.Mutex
	seen  []idemSeen
	cache map[string]idemCached
	// created holds every draft id written; published holds every bare id the
	// publish handler actually ran for. The second list is the one that proves
	// the publish leg was not silently replayed away.
	created   []string
	published []string
	// failCreates fails the first N create attempts that actually REACH the
	// handler. A 5xx or a crash releases the plug's claim, so a failed attempt is
	// deliberately NOT cached — the resend re-runs the handler.
	failCreates int
	// dropInsteadOf500 fails by hijacking the connection rather than answering.
	dropInsteadOf500 bool
	// answerLostAfterCommit models the nastiest real shape: the handler runs, the
	// row lands, the response is RECORDED by the plug, and then the connection
	// dies before the client reads it. The resend under the same key then meets a
	// genuine REPLAY.
	answerLostAfterCommit bool
	createHandlerRuns     int
	docID                 string
}

func (d *idemPlugDoor) snapshot() ([]idemSeen, []string, []string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]idemSeen(nil), d.seen...), append([]string(nil), d.created...), append([]string(nil), d.published...)
}

func (d *idemPlugDoor) serve(t *testing.T) *httptest.Server {
	t.Helper()
	d.cache = map[string]idemCached{}
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		// The tag registry read, answered authoritatively, so a --publish run
		// exercises the write path and not the fail-closed registry refusal.
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
		leg := "other"
		if _, ok := op["create"]; ok {
			leg = "create"
		} else if _, ok := op["publish"]; ok {
			leg = "publish"
		}

		key := req.Header.Get(idempotencyHeader)
		// THE PLUG'S SCOPE, VERBATIM: key + method + path. NOT the body. This one
		// line is the whole reason the two legs need different keys.
		scope := key + "|" + req.Method + "|" + req.URL.Path

		d.mu.Lock()
		cached, replay := idemCached{}, false
		if key != "" {
			cached, replay = d.cache[scope]
		}
		d.seen = append(d.seen, idemSeen{leg: leg, key: key, replayed: replay})
		d.mu.Unlock()

		if replay {
			// The handler NEVER runs. Whatever the first request under this scope
			// answered is what this one gets, byte for byte.
			rw.Header().Set("Idempotency-Replay", "true")
			rw.Header().Set("Content-Type", "application/json")
			rw.WriteHeader(cached.status)
			_, _ = rw.Write(cached.body)
			return
		}

		record := func(status int, payload []byte) {
			if key == "" {
				return
			}
			d.mu.Lock()
			d.cache[scope] = idemCached{status: status, body: payload}
			d.mu.Unlock()
		}

		switch leg {
		case "create":
			d.mu.Lock()
			d.createHandlerRuns++
			nth := d.createHandlerRuns
			fail := nth <= d.failCreates
			drop := d.dropInsteadOf500
			d.mu.Unlock()
			if fail {
				// Fails BEFORE writing, and is NOT cached — a 5xx or a crash
				// releases the plug's claim so the resend re-runs the handler.
				if drop {
					hijackAndClose(rw)
					return
				}
				rw.WriteHeader(http.StatusInternalServerError)
				_, _ = rw.Write([]byte(`{"error":{"code":"internal_error","message":"boom"}}`))
				return
			}
			d.mu.Lock()
			d.created = append(d.created, d.docID)
			id := d.docID
			lost := d.answerLostAfterCommit
			d.mu.Unlock()
			payload, _ := json.Marshal(map[string]any{"results": []any{map[string]any{
				"id": id, "document": map[string]any{"_id": id, "_draft": true}}}})
			record(http.StatusOK, payload)
			if lost {
				// The write landed and the response was recorded; the client never
				// sees it. The resend under the same key gets the replay.
				hijackAndClose(rw)
				return
			}
			rw.Header().Set("Content-Type", "application/json")
			_, _ = rw.Write(payload)
		case "publish":
			bare, _ := op["publish"]["id"].(string)
			d.mu.Lock()
			d.published = append(d.published, bare)
			d.mu.Unlock()
			payload, _ := json.Marshal(map[string]any{"results": []any{map[string]any{
				"id": bare, "document": map[string]any{"_id": bare, "_draft": false, "lifecycle_status": "open"}}}})
			record(http.StatusOK, payload)
			rw.Header().Set("Content-Type", "application/json")
			_, _ = rw.Write(payload)
		default:
			rw.WriteHeader(http.StatusBadRequest)
		}
	}))
}

// noResendSleep replaces the resend clock for one test, so the SCHEDULE is
// exercised without paying for it.
func noResendSleep(t *testing.T) {
	t.Helper()
	orig := createResendSleep
	createResendSleep = func(time.Duration) {}
	t.Cleanup(func() { createResendSleep = orig })
}

func createArgs(title string, extra ...string) []string {
	args := []string{title,
		"--description", "A description long enough to clear the publish wall and say what this row is for.",
		"--set", `tags:=[{"tag":"tasks","strength":80,"rationale":"an idempotency key on the create door is a tasks-plugin concern"}]`,
	}
	return append(args, extra...)
}

// TestTaskCreatePublishLegRunsUnderItsOwnKey is the c0 DETECTOR — the one the
// corrected criterion names, and the one a header-only door could not have
// written. It is RED three ways:
//
//	no header at all        every recorded key is "" (main today)
//	one key for both legs   the publish request is REPLAYED, published is EMPTY
//	one key across runs     the second invocation replays the first's answer
func TestTaskCreatePublishLegRunsUnderItsOwnKey(t *testing.T) {
	door := &idemPlugDoor{docID: "drafts.task-901"}
	ts := door.serve(t)
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A row whose publish leg must actually run", "--publish"))
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout=%s\nstderr=%s", code, so.String(), se.String())
	}

	seen, created, published := door.snapshot()
	t.Logf("requests=%+v created=%v published=%v", seen, created, published)

	if len(seen) != 2 || seen[0].leg != "create" || seen[1].leg != "publish" {
		t.Fatalf("recorded %+v, want exactly create then publish", seen)
	}
	for _, s := range seen {
		if s.key == "" {
			t.Fatalf("the %s leg carried NO %s header: %+v", s.leg, idempotencyHeader, seen)
		}
	}
	// THE CORRECTED REQUIREMENT. Same path, key not hashed over the body — so a
	// shared key is a silently skipped publish.
	if seen[0].key == seen[1].key {
		t.Fatalf("both legs carried the SAME key %q — the plug hashes (key, token, method, path) and NOT the body, so the publish replays the create's response", seen[0].key)
	}
	if seen[1].replayed {
		t.Fatalf("the publish request was answered from the idempotency cache — the publish handler never ran")
	}
	// The proof that the publish EXECUTED, independent of anything bp printed.
	if len(published) != 1 {
		t.Fatalf("the publish handler ran %d times, want exactly 1 (created=%v)", len(published), created)
	}
	if len(created) != 1 {
		t.Fatalf("created %d rows, want 1: %v", len(created), created)
	}

	// A SECOND INVOCATION IS A SECOND KEY BASE — against the SAME door, so a
	// shared base is caught by the door's own cache rather than assumed.
	var so2, se2 bytes.Buffer
	w2 := &writer{stdout: &so2, stderr: &se2, output: "json"}
	door.mu.Lock()
	door.docID = "drafts.task-902"
	door.mu.Unlock()
	if code := runTaskCreate(w2, globals{yes: true}, ctx, createArgs("A second row, a second key base", "--publish")); code != exitOK {
		t.Fatalf("second invocation exit = %d, want 0\nstderr=%s", code, se2.String())
	}
	seen2, created2, published2 := door.snapshot()
	for _, s := range seen2 {
		if s.replayed {
			t.Fatalf("a second invocation replayed a first-invocation key — keys are per-invocation: %+v", seen2)
		}
	}
	if len(created2) != 2 || len(published2) != 2 {
		t.Fatalf("after two invocations created=%v published=%v, want two of each", created2, published2)
	}
}

// TestTaskCreateResendReusesThatLegsKeyAndLandsOneRow is the c1 DETECTOR: one
// leg's attempt fails with an unknown outcome, the resend carries THAT LEG's
// same key, and exactly one row results.
func TestTaskCreateResendReusesThatLegsKeyAndLandsOneRow(t *testing.T) {
	noResendSleep(t)
	for _, tc := range []struct {
		name string
		drop bool
	}{
		{name: "5xx", drop: false},
		{name: "dropped connection", drop: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			door := &idemPlugDoor{docID: "drafts.task-903", failCreates: 1, dropInsteadOf500: tc.drop}
			ts := door.serve(t)
			defer ts.Close()
			ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

			var so, se bytes.Buffer
			w := &writer{stdout: &so, stderr: &se, output: "json"}
			code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A row that survives one bad attempt", "--publish"))

			seen, created, published := door.snapshot()
			t.Logf("exit=%d requests=%+v created=%v published=%v\nstderr=%s", code, seen, created, published, se.String())

			if code != exitOK {
				t.Fatalf("exit = %d, want 0 — the resend must turn a single unknown outcome into an answer\nstdout=%s\nstderr=%s", code, so.String(), se.String())
			}
			var creates []idemSeen
			for _, s := range seen {
				if s.leg == "create" {
					creates = append(creates, s)
				}
			}
			if len(creates) != 2 {
				t.Fatalf("recorded %d create attempts, want exactly 2 (one failure + one resend): %+v", len(creates), seen)
			}
			if creates[0].key == "" || creates[0].key != creates[1].key {
				t.Fatalf("the resend did not reuse the create leg's key: %q then %q", creates[0].key, creates[1].key)
			}
			if len(created) != 1 {
				t.Fatalf("landed %d rows, want exactly 1: %v", len(created), created)
			}
			// The publish leg still runs, under its own key, after the resend.
			if len(published) != 1 {
				t.Fatalf("the publish handler ran %d times, want 1", len(published))
			}
		})
	}
}

// TestTaskCreateReplayedResendIsASuccessNotAnAmbiguity is the honest half of the
// replay story: the create COMMITS, the plug records the answer, the connection
// then dies before the client reads it. Before this change that was the
// ambiguous-write render — exit 9, "WAS SENT and may have landed", a human left
// to search by title. The resend under the same key now meets a genuine REPLAY
// (Idempotency-Replay: true carrying the recorded 200), the strongest outcome
// available: it proves the first attempt landed AND that the second wrote
// nothing. So the invocation renders a receipt.
func TestTaskCreateReplayedResendIsASuccessNotAnAmbiguity(t *testing.T) {
	noResendSleep(t)
	door := &idemPlugDoor{docID: "drafts.task-904", answerLostAfterCommit: true}
	ts := door.serve(t)
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A row whose answer was lost after it committed"))

	seen, created, _ := door.snapshot()
	t.Logf("exit=%d requests=%+v created=%v\nstdout=%s\nstderr=%s", code, seen, created, so.String(), se.String())

	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — a replayed 2xx is a definite answer, not an ambiguity", code)
	}
	if len(seen) != 2 || !seen[1].replayed {
		t.Fatalf("the resend was not answered from the idempotency cache: %+v", seen)
	}
	if len(created) != 1 {
		t.Fatalf("the replay wrote a SECOND row: %v", created)
	}
	if strings.Contains(se.String(), "may have landed") {
		t.Fatalf("the ambiguous caveat survived a definite replayed answer:\n%s", se.String())
	}
}

// TestTaskCreateResendsA409KeyInUse pins the one 4xx worth re-asking: the plug
// says a request already holds the claim on this key, which on this path is our
// OWN earlier attempt. Waiting and asking again is the header's whole purpose;
// reporting it as a refusal would announce "the server said no" about a write
// that is at that moment committing.
func TestTaskCreateResendsA409KeyInUse(t *testing.T) {
	noResendSleep(t)
	var mu sync.Mutex
	attempts := 0
	var keys []string
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		mu.Lock()
		attempts++
		nth := attempts
		keys = append(keys, req.Header.Get(idempotencyHeader))
		mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		if nth == 1 {
			rw.WriteHeader(http.StatusConflict)
			_, _ = rw.Write([]byte(`{"error":{"code":"` + idempotencyInUseCode + `","message":"a request with this key is in progress"}}`))
			return
		}
		_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-905","document":{"_id":"drafts.task-905","_draft":true}}]}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A row whose key was still claimed"))
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 — a 409 idempotency_key_in_use is a WAIT, not a refusal\nstderr=%s", code, se.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if attempts != 2 || keys[0] == "" || keys[0] != keys[1] {
		t.Fatalf("attempts=%d keys=%v, want 2 attempts under one key", attempts, keys)
	}
}

// TestTaskCreateDoesNotResendAnOrdinaryRefusal pins the narrowness: a 422 is an
// ANSWER, sent once.
func TestTaskCreateDoesNotResendAnOrdinaryRefusal(t *testing.T) {
	noResendSleep(t)
	var mu sync.Mutex
	attempts := 0
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		mu.Lock()
		attempts++
		mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = rw.Write([]byte(`{"error":{"code":"validation_failed","message":"nope"}}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A row the server refuses outright")); code == exitOK {
		t.Fatalf("a 422 must not be reported as success")
	}
	mu.Lock()
	defer mu.Unlock()
	if attempts != 1 {
		t.Fatalf("the 422 was sent %d times, want 1 — an ordinary 4xx is an ANSWER", attempts)
	}
}

// TestIdempotencyKeysAreFreshWideAndPerLeg pins the key shape and the split.
func TestIdempotencyKeysAreFreshWideAndPerLeg(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		base := newIdempotencyKey()
		if len(base) != 32 {
			t.Fatalf("base %q has length %d, want 32 hex chars (128 bits)", base, len(base))
		}
		if seen[base] {
			t.Fatalf("base %q was minted twice", base)
		}
		seen[base] = true
		c, p := legKey(base, "create"), legKey(base, "publish")
		if c == p {
			t.Fatalf("legKey collapsed both legs onto %q", c)
		}
		if !strings.HasPrefix(c, base) || !strings.HasPrefix(p, base) {
			t.Fatalf("leg keys %q/%q do not carry the invocation base %q", c, p, base)
		}
	}
	if legKey("", "create") != "" {
		t.Fatalf("an empty base must stay empty — an empty key means NO header at all")
	}
}
