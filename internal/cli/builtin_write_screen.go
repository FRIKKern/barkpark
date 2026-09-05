package cli

import "fmt"

// THE BUILT-IN HALF OF THE WRITE FENCE.
//
// screenWriteReceipt (run.go) is bound to runCommand: it takes a
// manifest.Command and fires only when cmd.Writes. The built-ins in
// builtinWriteCensus have no manifest.Command — they compose their own request
// — so they could never reach it. These two functions are the seam that lets
// them reach the SAME verdict.
//
// THERE IS STILL EXACTLY ONE VERDICT. Both call writeReceiptVerdict and neither
// re-derives a discriminator; the copy #15900 removed does not come back here.
// What differs is only how a built-in REPORTS: some render through a *writer
// and return an exit code, others hand an error up a call chain. Two shapes,
// one judgment — the same split #15917 made between the CLI render path and the
// MCP tool result.
//
// The refusal CODE is the shared `unreadable_write_receipt`, not a built-in
// specific one. A caller scripting against bp should not have to learn a second
// code for the same class of lie depending on which verb it invoked.

// screenBuiltinWriteReceipt is the render-path form: it returns (exit code,
// handled). `what` names the write for the message ("seed mutate", "workspace
// import") — the built-ins have no verb name in a manifest to borrow.
//
// The three outcomes mirror screenWriteReceipt exactly:
//
//   - a DECLARED empty receipt (204/205, empty body) → named, exitOK. Not
//     silence: the alternative was a bare blank line.
//   - a poisoned receipt → refuseWithRemedy at exitGeneric.
//   - anything else → (0,false): the caller renders its own receipt.
func screenBuiltinWriteReceipt(out *writer, what string, status int, respBody []byte) (int, bool) {
	switch kind, reason, hint := writeReceiptVerdict(status, respBody); kind {
	case writeReceiptDeclaredEmpty:
		if !out.emitStructured(map[string]any{"ok": true, "confirmed": false, "reason": reason}) {
			out.outf("%s: not confirmed: %s", what, reason)
		}
		return exitOK, true
	case writeReceiptPoisoned:
		refuseWithRemedy(out, "unreadable_write_receipt",
			builtinUnreadableMessage(what, status, reason, respBody), hint)
		return exitGeneric, true
	}
	return 0, false
}

// builtinWriteReceiptErr is the same verdict for a built-in that reports
// through an error rather than a *writer — migrateSchemas collects errs, the
// vercel deploy steps return error up to their driver. A DECLARED empty receipt
// is nil here: the caller's own success line is the honest outcome, and there is
// no structured envelope on this path to hang a "confirmed:false" on.
func builtinWriteReceiptErr(what string, status int, respBody []byte) error {
	kind, reason, hint := writeReceiptVerdict(status, respBody)
	if kind != writeReceiptPoisoned {
		return nil
	}
	return fmt.Errorf("%s\n  hint: %s", builtinUnreadableMessage(what, status, reason, respBody), hint)
}

// builtinUnreadableMessage is the ONE refusal sentence both forms print, for the
// same reason #15917 extracted mcpUnreadableResult: two surfaces screening the
// same bodies must not drift in WORDING either. It is screenWriteReceipt's
// sentence with the write's name in front, because a built-in has no verb name
// the caller can otherwise attach the refusal to.
func builtinUnreadableMessage(what string, status int, reason string, respBody []byte) string {
	return fmt.Sprintf("%s: unreadable write receipt: HTTP %d %s (%d bytes): %s",
		what, status, reason, len(respBody), bodyPreview(respBody))
}
