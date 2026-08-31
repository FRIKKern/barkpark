package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// webhookTestSendCommand is the real manifest shape for `bp webhook
// test-send` (api/lib/barkpark/plugins/capabilities.ex "webhook.test-send"):
// POST /v1/webhooks/:dataset/:id/test-send, a write, minimal default output,
// one required path arg (id). --fail-on-failed-delivery is NOT declared here
// — it must never reach splitArgs as a manifest-local flag.
func webhookTestSendCommand() manifest.Command {
	return manifest.Command{
		ID:            "webhook.test-send",
		Noun:          "webhook",
		Verb:          "test-send",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/v1/webhooks/:dataset/:id/test-send"},
		Args:          []manifest.Arg{{Name: "id", Required: true, Type: "string", In: "path"}},
		Writes:        true,
		DefaultOutput: "minimal",
	}
}

// runWebhookTestSend drives the REAL runCommand against a fake API answering
// a fixed 200 body, exactly like run_write_receipt_test.go's runWriteResponse,
// but carrying the :dataset/:id path placeholders webhook.test-send actually
// has and letting the caller supply extra tail tokens (the flag under test).
func runWebhookTestSend(t *testing.T, body string, tail []string) (string, string, int) {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "minimal", outputSet: true, yes: true}
	out.applyGlobals(g)

	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}
	code := runCommand(out, g, ctx, &manifest.Manifest{}, webhookTestSendCommand(), tail)
	return stdout.String(), stderr.String(), code
}

const failedDeliveryBody = `{"delivery":{"id":7,"endpoint_id":null,"event_id":null,"status":"failed_giveup","attempts":1,"last_status_code":null,"last_error_text":"connection refused","last_latency_ms":12}}`

const deliveredBody = `{"delivery":{"id":7,"endpoint_id":null,"event_id":null,"status":"ok","attempts":1,"last_status_code":200,"last_error_text":null,"last_latency_ms":34}}`

// TestWebhookTestSendDefaultExitsZeroOnFailedDelivery pins the BYTE-STABLE
// default (task-60887badc1d2900f decision (a)): webhook_controller.test_send/2
// reports the delivery verdict in a 2xx body by design, and without the flag
// the CLI must still exit 0 with unchanged stdout — this is not a silent
// success, it is the documented contract (docs/cli/error-exit-table.md).
func TestWebhookTestSendDefaultExitsZeroOnFailedDelivery(t *testing.T) {
	stdoutFlagged, _, codeFlagged := runWebhookTestSend(t, failedDeliveryBody, []string{"wh1", "--fail-on-failed-delivery"})
	stdoutDefault, _, codeDefault := runWebhookTestSend(t, failedDeliveryBody, []string{"wh1"})

	if codeDefault != exitOK {
		t.Fatalf("default (no flag) exit = %d, want %d (byte-stable: a 2xx failed-delivery verdict stays exit 0 unless the flag is passed)", codeDefault, exitOK)
	}
	if codeFlagged != exitGeneric {
		t.Fatalf("--fail-on-failed-delivery against a failed verdict: exit = %d, want exitGeneric (%d)", codeFlagged, exitGeneric)
	}
	// The flag must change ONLY the exit code, never the rendered receipt.
	if stdoutFlagged != stdoutDefault {
		t.Fatalf("stdout diverged between flagged and default runs:\nflagged: %q\ndefault: %q", stdoutFlagged, stdoutDefault)
	}
}

// TestWebhookTestSendFailOnFailedDeliveryFlag is the MUTATION-PROOF test: the
// opt-in flag against a stub returning a FAILED delivery verdict must exit
// non-zero using an EXISTING exit ladder code, and the identical stub with the
// verdict flipped to "ok" must exit 0 — with the flag present either way, so
// the branch under test is genuinely the verdict, not the flag's absence.
func TestWebhookTestSendFailOnFailedDeliveryFlag(t *testing.T) {
	stdout, _, code := runWebhookTestSend(t, failedDeliveryBody, []string{"wh1", "--fail-on-failed-delivery"})
	if code != exitGeneric {
		t.Fatalf("failed delivery + --fail-on-failed-delivery: exit = %d, want exitGeneric (%d); stdout=%q", code, exitGeneric, stdout)
	}

	okStdout, _, okCode := runWebhookTestSend(t, deliveredBody, []string{"wh1", "--fail-on-failed-delivery"})
	if okCode != exitOK {
		t.Fatalf("delivered + --fail-on-failed-delivery: exit = %d, want %d; stdout=%q", okCode, exitOK, okStdout)
	}
}

// TestWebhookTestSendFailOnFailedDeliveryFlagIsScopedToTestSend proves the
// flag is keyed on cmd.ID, not parsed generically: any OTHER command still
// refuses it as the unknown flag it is (splitArgs' ordinary usage error),
// exactly as before this change landed.
func TestWebhookTestSendFailOnFailedDeliveryFlagIsScopedToTestSend(t *testing.T) {
	other := manifest.Command{
		ID:            "webhook.create",
		Noun:          "webhook",
		Verb:          "create",
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/v1/webhooks/:dataset"},
		Writes:        true,
		DefaultOutput: "minimal",
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"webhook":{"id":"wh1"}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "minimal", outputSet: true, yes: true}
	out.applyGlobals(g)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	code := runCommand(out, g, ctx, &manifest.Manifest{}, other, []string{"--fail-on-failed-delivery"})
	if code != exitUsage {
		t.Fatalf("webhook.create --fail-on-failed-delivery: exit = %d, want exitUsage (%d) — the flag must stay scoped to webhook.test-send; stdout=%q stderr=%q",
			code, exitUsage, stdout.String(), stderr.String())
	}
}
