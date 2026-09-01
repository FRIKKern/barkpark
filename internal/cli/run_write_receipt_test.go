package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// writeReceiptCommand is a generic manifest WRITE verb — the shape 93 of them
// share: a POST through runCommand's generic path with the `minimal` write
// default. It is deliberately NOT paginated, because the write-receipt fence
// must not inherit the read fence's `cmd.Paginated` gate.
func writeReceiptCommand() manifest.Command {
	return manifest.Command{
		ID:            "doc.publish",
		Noun:          "doc",
		Verb:          "publish",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/docs"},
		Writes:        true,
		DefaultOutput: "minimal",
	}
}

// runWriteResponse drives the REAL runCommand against a fake API that answers
// one status + body, and returns (stdout, stderr, exit). It mirrors
// runPageResponse (run_test.go) but can set the status code, which the 204
// carve-out turns on.
func runWriteResponse(t *testing.T, shape string, status int, body string, cmd manifest.Command) (string, string, int) {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: shape, outputSet: true, yes: true}
	out.applyGlobals(g)

	code := runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{}, cmd, nil)
	return stdout.String(), stderr.String(), code
}

// unreadableWriteReceiptPoisons is the WRITE twin of
// unreadableDefaultPagePoisons (paginate_all_test.go). Every body arrives on a
// SUCCESS status — a 2xx has never been proof the payload came from Barkpark,
// and on a write it is not even proof the write landed.
//
// MEASURED ON origin/main BEFORE THIS FENCE, through this same harness (the
// capture is quoted in the slice's ledger): all eight bodies exited 0 in all
// four shapes. `-o minimal` printed the literal word "ok" over `null`, `{}`,
// `{"result":null}` and `[]`; `-o table` over `{}` printed ZERO BYTES on both
// channels; the HTML 502 and the plaintext page were echoed verbatim; and the
// ERROR envelope on a 200 was printed as the SUCCESS body under `-o json`.
var unreadableWriteReceiptPoisons = []struct{ name, body string }{
	{"proxy_502_html", `<html><head><title>502 Bad Gateway</title></head><body>502</body></html>`},
	{"plaintext", `service temporarily unavailable`},
	{"zero_bytes", ``},
	{"json_null", `null`},
	{"result_null", `{"result":null}`},
	{"empty_object", `{}`},
	{"empty_array", `[]`},
	{"ok_false_error_envelope", `{"ok":false,"error":{"code":"upstream_down","message":"nope"}}`},
}

// TestRunCommandRefusesUnreadableWriteReceipt is the wave-29 lock. Waves 27 and
// 28 both gate on `cmd.Paginated && !cmd.Writes` (run.go), so every write
// receipt was outside them BY CONSTRUCTION: a write verb could print `ok` at
// rc=0 over a proxy page. Each poison must now refuse at a NON-ZERO exit with
// the named code readable in ALL FOUR output shapes.
func TestRunCommandRefusesUnreadableWriteReceipt(t *testing.T) {
	for _, tc := range unreadableWriteReceiptPoisons {
		for _, shape := range []string{"minimal", "table", "json", "yaml"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				stdout, stderr, code := runWriteResponse(t, shape, http.StatusOK, tc.body, writeReceiptCommand())
				if code != exitGeneric {
					t.Fatalf("exit = %d, want %d — a write reported success on a body that said nothing; stdout=%q stderr=%q",
						code, exitGeneric, stdout, stderr)
				}
				if strings.Contains(stdout, `"ok":true`) || strings.TrimSpace(stdout) == "ok" {
					t.Fatalf("refusal still rendered a success receipt: stdout=%q", stdout)
				}
				switch shape {
				case "json":
					var envelope struct {
						OK    bool `json:"ok"`
						Error struct {
							Code    string `json:"code"`
							Message string `json:"message"`
							Hint    string `json:"hint"`
						} `json:"error"`
					}
					if err := json.Unmarshal([]byte(stdout), &envelope); err != nil {
						t.Fatalf("error output not JSON: %v\n%s", err, stdout)
					}
					if envelope.OK || envelope.Error.Code != "unreadable_write_receipt" {
						t.Fatalf("want named refusal unreadable_write_receipt, got: %s", stdout)
					}
					if !strings.Contains(envelope.Error.Message, "HTTP 200") {
						t.Fatalf("message must name the status that lied: %q", envelope.Error.Message)
					}
					// An unconfirmable write is NOT a failed write — the hint has to
					// say so, or an agent retries a mutation that already landed.
					if !strings.Contains(envelope.Error.Hint, "may still have landed") {
						t.Fatalf("refusal must warn the write may have landed: %q", envelope.Error.Hint)
					}
				case "yaml":
					if !strings.Contains(stdout, "code: unreadable_write_receipt") {
						t.Fatalf("yaml stdout carried no named refusal: %q", stdout)
					}
				default:
					if !strings.Contains(stderr, "unreadable write receipt") {
						t.Fatalf("%s shape said nothing readable on stderr: %q", shape, stderr)
					}
				}
			})
		}
	}
}

// honestWriteReceipts is the CONTROL list, RE-DERIVED from
// api/lib/barkpark_web/controllers/** rather than copied from a charter count:
//
//	{"ok":true}                          auth_controller.ex:466 (verify_email)
//	{key,raw,quickstart}                 ticket_keys_controller.ex:44 (201 mint)
//	{workspace,deleted:true}             workspace_controller.ex:112 (delete)
//	{"result":{transactionId,results}}   mutate_controller.ex:24
//	{"ok":false,"reason":"no_ready"}     the tasks queue on an empty queue (2xx)
//	{"ok":true,"doc":{doc_id,claim}}     the claim receipt
//	{"accepted":true}                    chat_controller.ex:261 (202)
//	{"request_id":…}                     chat_controller.ex:291 (202)
//	{rev,id}                             the publish receipt
//
// wantStdout is the byte-for-byte capture from the PRE-FENCE binary through the
// harness above. A fence that reds — or merely reformats — an honest receipt is
// a regression, not a fix.
var honestWriteReceipts = []struct {
	name, body, shape, wantStdout string
	status                        int
}{
	{"ok_true", `{"ok":true}`, "minimal", "ok\n", 200},
	{"ok_true", `{"ok":true}`, "table", "ok  true\n", 200},
	{"ok_true", `{"ok":true}`, "json", "{\"ok\":true}\n", 200},
	{"ok_true", `{"ok":true}`, "yaml", "ok: true\n", 200},

	{"quickstart_card", `{"key":{"id":"k1"},"raw":"bpk_x","quickstart":"1. export BARKPARK_TOKEN=bpk_x"}`, "minimal", "ok\n", 201},
	{"quickstart_card", `{"key":{"id":"k1"},"raw":"bpk_x","quickstart":"1. export BARKPARK_TOKEN=bpk_x"}`, "table", "1. export BARKPARK_TOKEN=bpk_x\n", 201},
	{"quickstart_card", `{"key":{"id":"k1"},"raw":"bpk_x","quickstart":"1. export BARKPARK_TOKEN=bpk_x"}`, "json", "{\"key\":{\"id\":\"k1\"},\"quickstart\":\"1. export BARKPARK_TOKEN=bpk_x\",\"raw\":\"bpk_x\"}\n", 201},

	{"workspace_deleted", `{"workspace":{"slug":"w1"},"deleted":true}`, "minimal", "workspace: w1\n", 200},
	{"workspace_deleted", `{"workspace":{"slug":"w1"},"deleted":true}`, "json", "{\"deleted\":true,\"workspace\":{\"slug\":\"w1\"}}\n", 200},

	{"mutate_transaction", `{"result":{"transactionId":"tx1","results":[{"id":"d1","operation":"update"}]}}`, "minimal", "rev: tx1\n", 200},
	{"mutate_transaction", `{"result":{"transactionId":"tx1","results":[{"id":"d1","operation":"update"}]}}`, "json", "{\"results\":[{\"id\":\"d1\",\"operation\":\"update\"}],\"transactionId\":\"tx1\"}\n", 200},

	{"no_ready", `{"ok":false,"reason":"no_ready"}`, "minimal", "no_ready\n", 200},
	{"no_ready", `{"ok":false,"reason":"no_ready"}`, "table", "ok      false\nreason  no_ready\n", 200},
	{"no_ready", `{"ok":false,"reason":"no_ready"}`, "json", "{\"ok\":false,\"reason\":\"no_ready\"}\n", 200},
	{"no_ready", `{"ok":false,"reason":"no_ready"}`, "yaml", "ok: false\nreason: no_ready\n", 200},

	{"claim_receipt", `{"ok":true,"doc":{"doc_id":"task-a","claim":{"epoch":7}}}`, "minimal", "task-a epoch=7\n", 200},
	{"claim_receipt", `{"ok":true,"doc":{"doc_id":"task-a","claim":{"epoch":7}}}`, "json", "{\"doc\":{\"claim\":{\"epoch\":7},\"doc_id\":\"task-a\"},\"ok\":true}\n", 200},

	{"chat_accepted_202", `{"accepted":true}`, "minimal", "ok\n", 202},
	{"chat_accepted_202", `{"accepted":true}`, "json", "{\"accepted\":true}\n", 202},

	{"chat_request_id_202", `{"request_id":"r1"}`, "minimal", "ok\n", 202},
	{"chat_request_id_202", `{"request_id":"r1"}`, "json", "{\"request_id\":\"r1\"}\n", 202},

	{"publish_rev_id", `{"rev":"r9","id":"d1"}`, "minimal", "rev: r9\nid: d1\n", 200},
	{"publish_rev_id", `{"rev":"r9","id":"d1"}`, "json", "{\"id\":\"d1\",\"rev\":\"r9\"}\n", 200},
}

func TestWriteReceiptControlsStayByteIdentical(t *testing.T) {
	for _, tc := range honestWriteReceipts {
		t.Run(tc.name+"/"+tc.shape, func(t *testing.T) {
			stdout, stderr, code := runWriteResponse(t, tc.shape, tc.status, tc.body, writeReceiptCommand())
			if code != exitOK {
				t.Fatalf("exit = %d, want 0 — the fence reddened an HONEST write receipt; stderr=%q", code, stderr)
			}
			if stdout != tc.wantStdout {
				t.Fatalf("stdout drifted from the pre-fence bytes:\n got %q\nwant %q", stdout, tc.wantStdout)
			}
		})
	}
}

// TestWriteReceiptPassesUnknownKeys pins the DECISION, not an accident: the
// discriminator is "did the server say anything at all", never "does the body
// carry a key we recognise". An allowlist would be PDS-D396's careless fence —
// it reds `{"ok":true}` and `{"deleted":true,…}` today, and would red every
// receipt any future endpoint invents. A later wave that tightens this to a
// known-key check reds THIS test on purpose.
func TestWriteReceiptPassesUnknownKeys(t *testing.T) {
	passes := []struct{ name, body string }{
		{"unknown_object_keys", `{"widgets":[{"a":1}]}`},
		{"unknown_scalar_key", `{"frobnicated":3}`},
		{"nonempty_bare_array", `[{"a":1}]`},
	}
	for _, tc := range passes {
		for _, shape := range []string{"minimal", "json"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				stdout, stderr, code := runWriteResponse(t, shape, http.StatusOK, tc.body, writeReceiptCommand())
				if code != exitOK {
					t.Fatalf("exit = %d, want 0 — an allowlist crept into the write fence; stdout=%q stderr=%q", code, stdout, stderr)
				}
			})
		}
	}
}

// TestWriteReceiptDeclaredNoContentExemption covers the carve-out this fence
// OWES an honest verb: `chat.approve` answers `send_resp(conn, :no_content,
// "")` (chat_controller.ex:334), so "empty body ⇒ refuse" would red a real
// write. 204/205 with an empty body is a DECLARED empty receipt at rc=0 — and
// it is not silence either: main printed a BARE EMPTY LINE there. An
// UNDECLARED empty 200 still refuses.
func TestWriteReceiptDeclaredNoContentExemption(t *testing.T) {
	for _, status := range []int{http.StatusNoContent, http.StatusResetContent} {
		for _, shape := range []string{"minimal", "table", "json", "yaml"} {
			t.Run("declared/"+http.StatusText(status)+"/"+shape, func(t *testing.T) {
				stdout, stderr, code := runWriteResponse(t, shape, status, ``, writeReceiptCommand())
				if code != exitOK {
					t.Fatalf("exit = %d, want 0 — a DECLARED no-content write was refused; stderr=%q", code, stderr)
				}
				if shape == "json" {
					var env struct {
						OK        bool   `json:"ok"`
						Confirmed bool   `json:"confirmed"`
						Reason    string `json:"reason"`
					}
					if err := json.Unmarshal([]byte(stdout), &env); err != nil {
						t.Fatalf("stdout not JSON: %v\n%s", err, stdout)
					}
					if !env.OK || env.Confirmed || !strings.Contains(env.Reason, "declared no receipt") {
						t.Fatalf("want {ok:true,confirmed:false,reason:…}, got: %s", stdout)
					}
					return
				}
				if shape == "yaml" {
					if !strings.Contains(stdout, "confirmed: false") || !strings.Contains(stdout, "declared no receipt for this write") {
						t.Fatalf("yaml shape printed no declared-empty receipt: stdout=%q", stdout)
					}
					return
				}
				if !strings.Contains(stdout, "not confirmed") || !strings.Contains(stdout, "declared no receipt for this write") {
					t.Fatalf("%s shape printed no declared-empty line: stdout=%q", shape, stdout)
				}
			})
		}
	}

	// A 204 that DOES carry bytes is not the carve-out: it falls through to the
	// ordinary screen, and a poison body there still refuses.
	if _, _, code := runWriteResponse(t, "json", http.StatusNoContent, `{}`, writeReceiptCommand()); code != exitOK {
		// net/http drops a body on a 204, so this arm documents the transport
		// rather than asserting a refusal it cannot produce.
		t.Logf("204-with-body arrived body-less (transport strips it); exit=%d", code)
	}

	for _, shape := range []string{"minimal", "json"} {
		t.Run("undeclared_empty_200/"+shape, func(t *testing.T) {
			stdout, stderr, code := runWriteResponse(t, shape, http.StatusOK, ``, writeReceiptCommand())
			if code != exitGeneric {
				t.Fatalf("exit = %d, want %d — an UNDECLARED empty 200 is not a receipt; stdout=%q stderr=%q",
					code, exitGeneric, stdout, stderr)
			}
		})
	}
}

// TestWriteReceiptFenceIsNotGatedOnPagination is the reachability proof the
// hole itself demands: waves 27 and 28 refused only `cmd.Paginated &&
// !cmd.Writes`, so a fence that inherited either half would miss most of the 93
// write verbs. A PAGINATED write (the shape that slips through BOTH read
// fences) and a plain write must refuse the same poison identically.
func TestWriteReceiptFenceIsNotGatedOnPagination(t *testing.T) {
	for _, cmd := range []manifest.Command{writeReceiptCommand(), paginatedWriteCommand(100)} {
		stdout, stderr, code := runWriteResponse(t, "minimal", http.StatusOK, `{}`, cmd)
		if code != exitGeneric {
			t.Fatalf("paginated=%v: exit = %d, want %d; stdout=%q stderr=%q", cmd.Paginated, code, exitGeneric, stdout, stderr)
		}
		if !strings.Contains(stderr, "unreadable write receipt") {
			t.Fatalf("paginated=%v: refusal not named on stderr: %q", cmd.Paginated, stderr)
		}
	}
}

// TestScreenWriteReceiptLeavesReadsAlone: the fence is keyed on cmd.Writes, so
// a READ carrying the very same poison must not be touched by it — the read
// fence (wave 28) owns that body, and its wording is what the user sees.
func TestScreenWriteReceiptLeavesReadsAlone(t *testing.T) {
	for _, cmd := range []manifest.Command{paginatedReadCommand(100), nonPaginatedReadCommand()} {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenWriteReceipt(out, cmd, http.StatusOK, []byte(`{}`)); handled {
			t.Fatalf("the write fence handled a READ command (paginated=%v)", cmd.Paginated)
		}
		if stdout.Len() != 0 || stderr.Len() != 0 {
			t.Fatalf("the write fence wrote on a READ command: stdout=%q stderr=%q", stdout.String(), stderr.String())
		}
	}
}
