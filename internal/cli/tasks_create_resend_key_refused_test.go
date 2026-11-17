package cli

// A resend of the create leg that the server refuses over the leg's OWN
// Idempotency-Key is not a refusal of the task (task-f98d2eb6ff29781c). By the
// time a resend happens, an earlier attempt of this invocation went out and
// its answer was lost or was a 5xx, so that attempt may have committed. A
// "refused" render there sends the person to re-file, and the re-file is the
// duplicate.

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

// scriptedMutateDoor answers each mutate request with the next scripted
// (status, body); the last entry repeats.
func scriptedMutateDoor(t *testing.T, script ...[2]string) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var keys []string
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		mu.Lock()
		keys = append(keys, req.Header.Get(idempotencyHeader))
		step := script[min(len(keys), len(script))-1]
		mu.Unlock()
		status := map[string]int{"500": 500, "409": 409, "422": 422}[step[0]]
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(status)
		_, _ = rw.Write([]byte(step[1]))
	}))
	t.Cleanup(ts.Close)
	return ts, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), keys...)
	}
}

const (
	fault500     = `{"error":{"code":"internal_error","message":"boom"}}`
	keyReused422 = `{"error":{"code":"idempotency_key_reused","message":"this Idempotency-Key was already used with a different request"}}`
	keyInUse409  = `{"error":{"code":"idempotency_key_in_use","message":"a request with this key is in progress"}}`
)

func runScriptedCreate(t *testing.T, title string, script ...[2]string) (int, string, string, []string) {
	t.Helper()
	noResendSleep(t)
	ts, keys := scriptedMutateDoor(t, script...)
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs(title))
	return code, so.String(), se.String(), keys()
}

func assertAmbiguousResend(t *testing.T, code int, stdout, stderr string) {
	t.Helper()
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d)\nstdout=%s\nstderr=%s", code, exitAmbiguous, stdout, stderr)
	}
	if !strings.Contains(stderr, "may have landed") {
		t.Fatalf("stderr does not say the create may have landed:\n%s", stderr)
	}
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Details struct {
				Class string `json:"class"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not one envelope: %v\n%s", err, stdout)
	}
	if env.Error.Code != ambiguousWriteCode || env.Error.Details.Class != ambiguityCreateResendKeyRefused {
		t.Fatalf("envelope code/class = %q/%q, want %q/%q", env.Error.Code, env.Error.Details.Class,
			ambiguousWriteCode, ambiguityCreateResendKeyRefused)
	}
}

func TestTaskCreateResendRefusedAsKeyReusedMayHaveLanded(t *testing.T) {
	code, so, se, keys := runScriptedCreate(t, "A create whose resend met its own key",
		[2]string{"500", fault500}, [2]string{"422", keyReused422})
	if len(keys) != 2 || keys[0] == "" || keys[0] != keys[1] {
		t.Fatalf("keys = %v, want two sends under one key", keys)
	}
	assertAmbiguousResend(t, code, so, se)
}

func TestTaskCreateKeyStillInUseAfterEveryResendMayHaveLanded(t *testing.T) {
	code, so, se, keys := runScriptedCreate(t, "A create whose key stayed claimed",
		[2]string{"409", keyInUse409})
	if len(keys) != createResendAttempts {
		t.Fatalf("sent %d times, want %d", len(keys), createResendAttempts)
	}
	assertAmbiguousResend(t, code, so, se)
}

// The first send carries a key minted for this invocation, so the server has
// seen no earlier attempt of it: a key refusal there is a plain refusal.
func TestTaskCreateKeyReusedOnTheFirstSendIsARefusal(t *testing.T) {
	code, _, se, keys := runScriptedCreate(t, "A create refused on its first send",
		[2]string{"422", keyReused422})
	if len(keys) != 1 {
		t.Fatalf("sent %d times, want 1", len(keys))
	}
	if code == exitAmbiguous || strings.Contains(se, "may have landed") {
		t.Fatalf("a first-send refusal was rendered as ambiguous (exit %d):\n%s", code, se)
	}
}
