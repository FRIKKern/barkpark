package cli

import (
	"bytes"
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestUnreadableReadBodyDiscriminator pins the READ discriminator and, just as
// importantly, everything it must NOT touch.
//
// The write-side sibling (unreadableWriteReceipt) refuses `{}` and `[]` because
// a write has no honest empty receipt. A read does — data.counts on a fresh
// dataset really answers `{}`, media.collections on an empty library really
// answers `[]` — so those stay green here BY DECISION, and the "honest" rows
// below are what make that decision testable rather than assumed.
//
// MUTATION PROOF: widen the JSON arm from isHTMLDocument to "does not parse as
// JSON" and the ONIX row fails, which is the whole reason the HTML check is
// shaped the way it is.
func TestUnreadableReadBodyDiscriminator(t *testing.T) {
	tests := []struct {
		name              string
		body              string
		wantReason        string // substring; "" means the body must PASS
		wantContradiction bool
	}{
		{"empty body", "", "empty body without declaring one", false},
		{"whitespace only", "   \n\t ", "empty body without declaring one", false},
		{"html doctype page", `<!DOCTYPE html><html><body>502 Bad Gateway</body></html>`, "HTML document", false},
		{"html no doctype", `<html><head><title>502</title></head></html>`, "HTML document", false},
		{"xhtml behind an xml declaration", `<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body/></html>`, "HTML document", false},
		{"error envelope bare", `{"ok":false,"error":{"code":"internal","message":"boom"}}`, "ERROR envelope (internal)", true},
		{"error envelope nested under result", `{"result":{"ok":false,"error":{"code":"forbidden"}}}`, "ERROR envelope (forbidden)", true},
		{"error envelope, error is a string", `{"ok":false,"error":"boom"}`, "ERROR envelope (boom)", true},

		// PASSES — an honest read, or a body this screen deliberately declines
		// to judge.
		{"honest document", `{"_id":"p1","_type":"post"}`, "", false},
		{"honest empty object", `{}`, "", false},
		{"honest empty array", `[]`, "", false},
		{"honest null", `null`, "", false},
		{"honest result:null", `{"result":null}`, "", false},
		{"honest ok:false with a reason, not an error", `{"ok":false,"reason":"no_ready"}`, "", false},
		{"honest ok:true", `{"ok":true,"count":0}`, "", false},
		{"ONIX 3.0 XML — onixedit.export", `<?xml version="1.0"?><ONIXMessage release="3.0"><Product/></ONIXMessage>`, "", false},
		{"plaintext — needs Content-Type to judge, filed not guessed", `upstream connect error`, "", false},
		{"scalar", `42`, "", false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			reason, contradiction := unreadableReadBody([]byte(tc.body))
			if tc.wantReason == "" {
				if reason != "" {
					t.Fatalf("body must PASS, got refusal %q", reason)
				}
				return
			}
			if !strings.Contains(reason, tc.wantReason) {
				t.Fatalf("reason = %q, want it to contain %q", reason, tc.wantReason)
			}
			if contradiction != tc.wantContradiction {
				t.Errorf("contradiction = %v, want %v — the two classes carry DIFFERENT remedies", contradiction, tc.wantContradiction)
			}
		})
	}
}

// TestScreenUnpaginatedReadRefusesAndCarriesTheRemedy is the end-to-end half:
// the refusal must red the exit code AND say something actionable. The two
// classes get DIFFERENT hints on purpose — advising "retry" on a server that
// contradicted itself would be true and useless.
func TestScreenUnpaginatedReadRefusesAndCarriesTheRemedy(t *testing.T) {
	cmd := nonPaginatedReadCommand()

	t.Run("transport class names the transport", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		code, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, []byte(`<html><body>502</body></html>`))
		if !handled || code != exitGeneric {
			t.Fatalf("handled=%v code=%d, want true/%d", handled, code, exitGeneric)
		}
		if !strings.Contains(stderr.String(), "unreadable read") {
			t.Errorf("refusal not named: %q", stderr.String())
		}
		if !strings.Contains(stderr.String(), "the transport, not the query") {
			t.Errorf("transport remedy missing: %q", stderr.String())
		}
	})

	t.Run("contradiction class does NOT advise a retry", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		code, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, []byte(`{"ok":false,"error":{"code":"internal"}}`))
		if !handled || code != exitGeneric {
			t.Fatalf("handled=%v code=%d, want true/%d", handled, code, exitGeneric)
		}
		got := stderr.String()
		if !strings.Contains(got, "contradicted itself") {
			t.Errorf("contradiction remedy missing: %q", got)
		}
		if strings.Contains(got, "Retry") {
			t.Errorf("a server that contradicted itself must not be told to retry: %q", got)
		}
	})

	t.Run("204 with an empty body is an honest no-content read", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusNoContent, nil); handled {
			t.Fatalf("204 + empty body was refused; the server DECLARED no content")
		}
		if stdout.Len() != 0 || stderr.Len() != 0 {
			t.Fatalf("wrote on an honest 204: stdout=%q stderr=%q", stdout.String(), stderr.String())
		}
	})
}

// TestScreenUnpaginatedReadLeavesItsSiblingsAlone keeps the three screens
// disjoint. Each poison body belongs to exactly ONE fence, and the wording the
// user sees depends on which — so an overlap is not harmless duplication, it is
// two different explanations of the same bytes.
//
// It also pins the gap this screen closes. run_write_receipt_test.go says of a
// non-paginated read carrying `{}` that "the read fence (wave 28) owns that
// body" — wave 28's fence is refuseUnreadableDefaultPage, which returns early
// unless cmd.Paginated. Nothing owned it. That sentence is why the hole survived
// three waves of exactly this work.
func TestScreenUnpaginatedReadLeavesItsSiblingsAlone(t *testing.T) {
	poison := []byte(`<html><body>502</body></html>`)

	t.Run("a paginated read belongs to refuseUnreadableDefaultPage", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		if _, handled := screenUnpaginatedRead(out, paginatedReadCommand(50), http.StatusOK, poison); handled {
			t.Fatalf("handled a PAGINATED read — refuseUnreadableDefaultPage owns it")
		}
		if stdout.Len() != 0 || stderr.Len() != 0 {
			t.Fatalf("wrote on a paginated read: stdout=%q stderr=%q", stdout.String(), stderr.String())
		}
	})

	t.Run("a write belongs to screenWriteReceipt", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		cmd := nonPaginatedReadCommand()
		cmd.Writes = true
		if _, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, poison); handled {
			t.Fatalf("handled a WRITE — screenWriteReceipt owns it")
		}
		if stdout.Len() != 0 || stderr.Len() != 0 {
			t.Fatalf("wrote on a write command: stdout=%q stderr=%q", stdout.String(), stderr.String())
		}
	})
}

// TestIsHTMLDocumentNeverEatsONIX is the narrow guard behind the narrow check.
// onixedit.export (api/lib/barkpark/plugins/onixedit/cli.ex:34) is a REAL
// non-paginated read that streams ONIX 3.0 XML through this dispatch, so "the
// body is not JSON" could never be the discriminator — the fence had to be an
// HTML ROOT, and this test is what stops a later widening from silently
// breaking the exporter.
func TestIsHTMLDocumentNeverEatsONIX(t *testing.T) {
	html := []string{
		`<!DOCTYPE html><html></html>`,
		`<!doctype HTML>`,
		"\n\n  <html lang=\"en\">",
		`<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"></html>`,
	}
	notHTML := []string{
		`<?xml version="1.0"?><ONIXMessage release="3.0"><Product/></ONIXMessage>`,
		`<ONIXMessage release="3.0"/>`,
		`{"_id":"p1"}`,
		`upstream connect error`,
		`<htmlish>not a document root</htmlish>`,
		``,
	}
	for _, s := range html {
		if !isHTMLDocument([]byte(s)) {
			t.Errorf("isHTMLDocument(%q) = false, want true", s)
		}
	}
	for _, s := range notHTML {
		if isHTMLDocument([]byte(s)) {
			t.Errorf("isHTMLDocument(%q) = true — this body is NOT a proxy page", s)
		}
	}
}

// TestScreenUnpaginatedReadKeysOnlyOnWritesAndPaginated pins the gate itself:
// the screen reaches EVERY command that is neither a write nor paginated, with
// no allowlist and no per-verb carve-out. That is what makes the population
// (52 commands on the live manifest, from doc.get to task.events to auth.me)
// covered by construction rather than by enumeration — a lane adding the 53rd
// inherits the screen without touching this file.
func TestScreenUnpaginatedReadKeysOnlyOnWritesAndPaginated(t *testing.T) {
	for _, cmd := range []manifest.Command{
		nonPaginatedReadCommand(),
		{ID: "doc.get", Noun: "doc", Verb: "get"},
		{ID: "auth.me", Noun: "auth", Verb: "me", DefaultOutput: "json"},
		{ID: "onixedit.export", Noun: "onixedit", Verb: "export", DefaultOutput: "minimal"},
	} {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		code, handled := screenUnpaginatedRead(out, cmd, http.StatusOK, []byte(`<html><body>502 Bad Gateway</body></html>`))
		if !handled || code != exitGeneric {
			t.Fatalf("%s: handled=%v code=%d, want true/%d", cmd.ID, handled, code, exitGeneric)
		}
	}
}
