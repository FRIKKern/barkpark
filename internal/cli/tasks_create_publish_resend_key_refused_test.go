package cli

// A resend of the PUBLISH leg that the server refuses over the leg's own
// Idempotency-Key is not a refusal of the publish (task-babfa19b991a8d8a). An
// earlier publish attempt went out first and may have committed, so the draft
// must stay and the outcome is ambiguous. Treated as a refusal, bp discarded
// the draft and said nothing was kept, about a row that may be on the board.

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

// publishScriptDoor accepts the create, answers each publish with the next
// scripted (status, body) (the last repeats), and records every mutation kind.
func publishScriptDoor(t *testing.T, script ...[2]string) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var kinds []string
	publishes := 0
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/query/") {
			_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"tasks"}],"hasMore":false}}`))
			return
		}
		var body struct {
			Mutations []map[string]json.RawMessage `json:"mutations"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		kind := "other"
		if len(body.Mutations) > 0 {
			for k := range body.Mutations[0] {
				kind = k
			}
		}
		mu.Lock()
		kinds = append(kinds, kind)
		n := 0
		if kind == "publish" {
			publishes++
			n = publishes
		}
		mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		switch kind {
		case "create":
			_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-950","document":{"_id":"drafts.task-950","_draft":true}}]}`))
		case "publish":
			step := script[min(n, len(script))-1]
			status := map[string]int{"500": 500, "401": 401, "403": 403, "404": 404, "409": 409, "422": 422, "429": 429}[step[0]]
			rw.WriteHeader(status)
			_, _ = rw.Write([]byte(step[1]))
		default:
			_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-950","operation":"discardDraft"}]}`))
		}
	}))
	t.Cleanup(ts.Close)
	return ts, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), kinds...)
	}
}

func runScriptedPublish(t *testing.T, script ...[2]string) (int, string, string, []string) {
	t.Helper()
	noResendSleep(t)
	ts, kinds := publishScriptDoor(t, script...)
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A publish whose resend met its own key", "--publish"))
	return code, so.String(), se.String(), kinds()
}

func assertPublishKeptAndAmbiguous(t *testing.T, code int, stdout, stderr string, kinds []string) {
	t.Helper()
	for _, k := range kinds {
		if k != "create" && k != "publish" {
			t.Fatalf("bp sent a %q mutation after an ambiguous publish — the draft must be kept: %v", k, kinds)
		}
	}
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d)\nstdout=%s\nstderr=%s", code, exitAmbiguous, stdout, stderr)
	}
	if !strings.Contains(stderr, "may have landed") {
		t.Fatalf("stderr does not say the publish may have landed:\n%s", stderr)
	}
	var env struct {
		Error struct {
			Details struct {
				Class string `json:"class"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not one envelope: %v\n%s", err, stdout)
	}
	if env.Error.Details.Class != residuePublishResendKeyRefused {
		t.Fatalf("class = %q, want %q", env.Error.Details.Class, residuePublishResendKeyRefused)
	}
}

func TestTaskCreatePublishResendRefusedAsKeyReusedKeepsTheDraft(t *testing.T) {
	code, so, se, kinds := runScriptedPublish(t, [2]string{"500", fault500}, [2]string{"422", keyReused422})
	assertPublishKeptAndAmbiguous(t, code, so, se, kinds)
}

func TestTaskCreatePublishKeyStillInUseAfterEveryResendKeepsTheDraft(t *testing.T) {
	code, so, se, kinds := runScriptedPublish(t, [2]string{"409", keyInUse409})
	assertPublishKeptAndAmbiguous(t, code, so, se, kinds)
}

// A publish refused on its FIRST send is a definite refusal: the draft is still
// discarded, as before.
func TestTaskCreatePublishKeyReusedOnTheFirstSendStillDiscards(t *testing.T) {
	code, _, se, kinds := runScriptedPublish(t, [2]string{"422", keyReused422})
	if code == exitAmbiguous || strings.Contains(se, "may have landed") {
		t.Fatalf("a first-send refusal was rendered as ambiguous (exit %d):\n%s", code, se)
	}
	if kinds[len(kinds)-1] == "publish" {
		t.Fatalf("the refused first-send publish did not discard the draft: %v", kinds)
	}
}
