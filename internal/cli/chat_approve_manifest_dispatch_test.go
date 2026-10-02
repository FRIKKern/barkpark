package cli

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// THE 204 ARM OF screenWriteReceipt HAD NO CLI CALLER.
//
// `chat.approve` is the only manifest verb in the whole API whose controller
// answers `send_resp(conn, :no_content, "")` — the other empty-2xx emitters
// (SCIM users, SCIM groups, the pulse OPTIONS preflight) are not manifest
// nouns. So writeReceiptDeclaredEmpty, the arm run.go's screenWriteReceipt
// documents with the words "`chat.approve` really does answer
// send_resp(conn, :no_content, \"\")", was reachable by NO bp invocation:
// Execute routed the entire `chat` noun into the runChat TUI built-in, which
// rejects every argument but `ls` and `unarchive` before the manifest tree is
// ever consulted.
//
// MEASURED on origin/main (651f7cc27), a real binary against the real server:
//
//	$ bp chat approve <session-id> req-probe deny --yes
//	{"error":{"code":"usage","message":"bp chat takes no arguments besides `ls` and `unarchive` (got \"approve\")"},"ok":false}
//	rc=2
//
// MEASURED with the peel (same binary shape, same live session):
//
//	$ bp chat approve a5462ec1-… req-w36-probe deny --yes -o json
//	{"confirmed":false,"ok":true,"reason":"HTTP 204, no content returned — the server declared no receipt for this write"}
//	rc=0
//
// and the transport underneath, by curl, is exactly the declared-empty shape
// the arm exists for — HTTP/2 204, zero bytes, no content-type:
//
//	HTTP/2 204
//	via: 1.1 Caddy
//	x-request-id: GNXXkS-r1EeTEKwAAGAR
//
// These tests are the standing arm for that, at ARGV level: they drive
// Execute, not runCommand, because the defect was never in runCommand — it was
// that argv could not REACH it.

// writeChatApproveManifest drops a minimal manifest carrying chat.approve (the
// real route and the real arg triple, copied from `bp capabilities --full`) and
// one non-approve chat write, and returns its path.
func writeChatApproveManifest(t *testing.T, baseURL string) string {
	t.Helper()
	body := fmt.Sprintf(`{
  "manifest_version": "1",
  "server": {"name":"test","version":"0","base_url":%q,"api_version":"1","min_cli":"0.0.1"},
  "auth_tier": "admin",
  "generated_at": "2026-09-16T00:00:00Z",
  "etag": "W/\"caps-test\"",
  "nouns": [{"name":"chat","summary":"Chat sessions.","plugin":null}],
  "commands": [
    {
      "id": "chat.approve", "noun": "chat", "verb": "approve",
      "summary": "Answer a pending tool-permission ask on a chat session (allow | deny).",
      "http": {"method":"POST","path_template":"/v1/chat/sessions/:id/approval"},
      "auth_tier": "admin",
      "args": [
        {"name":"id","required":true,"type":"string","summary":"Chat session id."},
        {"name":"request_id","required":true,"type":"string","summary":"The ask's request id."},
        {"name":"decision","required":true,"type":"string","summary":"allow | deny."}
      ],
      "flags": [], "writes": true, "batch": false, "paginated": false,
      "dry_run": false, "default_output": "minimal", "source": "core"
    },
    {
      "id": "chat.interrupt", "noun": "chat", "verb": "interrupt",
      "summary": "Interrupt a chat session's in-flight turn.",
      "http": {"method":"POST","path_template":"/v1/chat/sessions/:id/interrupt"},
      "auth_tier": "admin",
      "args": [{"name":"id","required":true,"type":"string","summary":"Chat session id."}],
      "flags": [], "writes": true, "batch": false, "paginated": false,
      "dry_run": false, "default_output": "minimal", "source": "core"
    }
  ]
}`, baseURL)
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return path
}

// TestChatApproveReachesManifestDispatchAnd204Arm is THE DETECTOR. Revert the
// `if verb != "approve"` peel in cli.go's `case "chat"` and this test fails
// twice over: the server is never called at all (hits = 0) and the output is
// the runChat usage refusal at exit 2 instead of the declared-empty envelope at
// exit 0. It is the test that FAILS if that line is wrong.
func TestChatApproveReachesManifestDispatchAnd204Arm(t *testing.T) {
	var hits int32
	var gotPath, gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		gotPath, gotMethod = r.URL.Path, r.Method
		// EXACTLY what api/lib/barkpark_web/controllers/chat_controller.ex
		// answers for an approval: 204, zero bytes, no content-type. curl
		// against the live server confirmed the same shape (see the file
		// header) — this is not an invented fixture.
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	manifestPath := writeChatApproveManifest(t, srv.URL)
	var code int
	outStr := captureExecuteOutput(t, func() {
		code = Execute([]string{
			"--server", srv.URL, "--manifest", manifestPath, "--yes",
			"-o", "json", "chat", "approve", "sess-1", "req-1", "deny",
		})
	})

	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("chat approve must REACH the manifest POST: server saw %d requests, want 1.\n"+
			"This is the unreachability itself: runChat rejected the argv before dispatch.\noutput:\n%s", n, outStr)
	}
	if gotMethod != http.MethodPost || gotPath != "/v1/chat/sessions/sess-1/approval" {
		t.Fatalf("wrong route: %s %s, want POST /v1/chat/sessions/sess-1/approval", gotMethod, gotPath)
	}
	if code != exitOK {
		t.Fatalf("a DECLARED empty 204 receipt is an honest success: exit %d, want %d.\noutput:\n%s",
			code, exitOK, outStr)
	}
	// The 204 arm's own words, from writeReceiptVerdict. If dispatch ever
	// stopped landing on writeReceiptDeclaredEmpty (a refusal, or a bare
	// blank line), this is what changes.
	if !strings.Contains(outStr, `"confirmed":false`) {
		t.Fatalf("the 204 arm must name itself with confirmed:false; output:\n%s", outStr)
	}
	if !strings.Contains(outStr, "no content returned") {
		t.Fatalf("the 204 arm's reason must reach the caller; output:\n%s", outStr)
	}
	// THE RE-EXAMINED RECEIPT SHAPE (row criterion 3), pinned rather than
	// assumed: the envelope says ok:true on a write that produced no evidence
	// at all, so `jq -e .ok` reads SUCCESS and only `confirmed` discriminates.
	// Documented in docs/cli/error-exit-table.md. Pinned here so the hazard
	// cannot drift silently in either direction.
	if !strings.Contains(outStr, `"ok":true`) {
		t.Fatalf("the declared-empty envelope's shape is ok:true + confirmed:false "+
			"(see docs/cli/error-exit-table.md); output:\n%s", outStr)
	}
	if strings.Contains(outStr, "takes no arguments") {
		t.Fatalf("runChat must not intercept `chat approve` any more; output:\n%s", outStr)
	}
}

// TestChatNonApproveVerbsStayInterceptedByTheTUI is THE QUIET ARM: the peel is
// exactly ONE verb wide. `chat interrupt` is declared in the same manifest,
// with the same auth tier and the same writes:true — the only thing keeping it
// out of manifest dispatch is the deliberate `verb != "approve"` guard. If the
// peel were widened to the whole noun (or to a prefix match), this test reds:
// the server would be called and the usage refusal would disappear.
func TestChatNonApproveVerbsStayInterceptedByTheTUI(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	manifestPath := writeChatApproveManifest(t, srv.URL)
	var code int
	outStr := captureExecuteOutput(t, func() {
		code = Execute([]string{
			"--server", srv.URL, "--manifest", manifestPath, "--yes",
			"-o", "json", "chat", "interrupt", "sess-1",
		})
	})

	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("only `approve` is peeled: `chat interrupt` must NOT reach the API "+
			"(server saw %d requests).\noutput:\n%s", n, outStr)
	}
	if code != exitUsage {
		t.Fatalf("`chat interrupt` must still hit runChat's refusal: exit %d, want %d.\noutput:\n%s",
			code, exitUsage, outStr)
	}
	if !strings.Contains(outStr, "takes no arguments") {
		t.Fatalf("the refusal must still name the built-in's contract; output:\n%s", outStr)
	}
}

// TestChatApproveHonoursThePoisonedArmToo is the other direction of the SAME
// newly-reachable fence: now that argv can get there, a stated success whose
// body says nothing must REFUSE. Without this arm the detector above would
// still pass if the fence were reduced to "204 ⇒ ok", which is the exact
// half-fix the write-receipt law exists to prevent.
func TestChatApproveHonoursThePoisonedArmToo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// An UNDECLARED empty 200: a stated success with no receipt at all.
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	manifestPath := writeChatApproveManifest(t, srv.URL)
	var code int
	outStr := captureExecuteOutput(t, func() {
		code = Execute([]string{
			"--server", srv.URL, "--manifest", manifestPath, "--yes",
			"-o", "json", "chat", "approve", "sess-1", "req-1", "allow",
		})
	})

	if code != exitGeneric {
		t.Fatalf("an UNDECLARED empty 200 on chat approve must refuse: exit %d, want %d.\noutput:\n%s",
			code, exitGeneric, outStr)
	}
	if !strings.Contains(outStr, "unreadable_write_receipt") {
		t.Fatalf("the refusal must carry the shared code; output:\n%s", outStr)
	}
}
