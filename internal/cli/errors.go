package cli

import (
	"encoding/json"
	"fmt"
	"strings"
)

// apiError is the decoded outcome of a non-2xx (or error-shaped) API response.
// It carries the exit code already mapped per docs/cli/error-exit-table.md, plus
// a human message and the request id for support.
type apiError struct {
	exit       int
	code       string
	message    string
	requestID  string
	serverHint string // envelope `hint` field — the server's per-error fix suggestion
}

// codeExit is the SINGLE canonical error.code -> exit mapping (contract spine
// rule #3). The CLI keys on the envelope's `code` string and NEVER re-derives an
// exit code from the HTTP status. Source: docs/cli/error-exit-table.md.
var codeExit = map[string]int{
	"not_found":      exitNotFound,
	"schema_unknown": exitNotFound,
	"share_expired":  exitNotFound, // 410, bucketed as gone/not-found
	"unauthorized":   exitAuth,
	"forbidden":      exitAuth,
	// A filter/order over a field the caller may not read — semantically a
	// permission denial (use a token that can read the field), so the auth
	// bucket, even though the HTTP status is 422. Added when QueryController /
	// LegacyController moved forbidden_field to the canonical envelope (#571);
	// before that it was a bare-string `error` with no code and fell to exit 1.
	"forbidden_field": exitAuth,
	"cors_forbidden":  exitAuth,
	"csrf_required":   exitAuth,
	"malformed":       exitUsage,
	// An unknown filter operator (?filter[f][bogus]=x) — a malformed request,
	// same bucket as `malformed`. Added when the query API began rejecting
	// unknown ops instead of silently returning every row (#570).
	"invalid_filter":      exitUsage,
	"validation_failed":   exitValidation,
	"invalid_paper":       exitValidation,
	"malformed_op":        exitValidation,
	"invalid_op":          exitValidation,
	"block_not_found":     exitValidation,
	"type_mismatch":       exitValidation,
	"duplicate_id":        exitValidation,
	"rev_mismatch":        exitConflict,
	"precondition_failed": exitConflict,
	"conflict":            exitConflict,
	// A plugin lifecycle veto. The bare-string {"error":"halted"} shape is still
	// special-cased in classifyError (exit 6), but once the server moved halt to
	// the CANONICAL {"error":{"code":"halted"}} envelope (#559/#560) it arrives
	// via error.code and MUST be in this table too — otherwise it regressed from
	// exit 6 to the exit-1 unknown-code fallback.
	"halted": exitConflict,
	// Task claim/close contention — all 409 shapes from /v1/tasks/*. Absent
	// from this table they fell to the unknown-reason usage bucket (exit 2),
	// so `bp task close` with a stale epoch exited as if the COMMAND LINE were
	// wrong. The cheatsheet's contract is 6 = conflict.
	"fenced_off":                  exitConflict,
	"stale_claim":                 exitConflict,
	"not_ready":                   exitConflict,
	"blocked_by_unsatisfied_deps": exitConflict,
	"already_claimed":             exitConflict,
	"resource_conflict":           exitConflict,
	"rate_limited":                exitRateLimit,
	"internal_error":              exitServer,
}

// exitForCode maps an envelope error.code to a process exit code. An unknown or
// empty code falls back to exitGeneric (1), per the table's documented fallback.
func exitForCode(code string) int {
	if e, ok := codeExit[code]; ok {
		return e
	}
	return exitGeneric
}

// classifyError decodes an error response body into an apiError with the mapped
// exit code. It handles, in order:
//
//   - the canonical envelope {"error":{"code":…,"message":…,"request_id":…}}
//   - the bare-string lifecycle veto {"error":"halted",…}     -> exit 6
//   - the tasks add-edge shape {"ok":false,"reason":"invalid_edge"} -> exit 2
//   - the intents/plugin-settings string error {"error":"not_found"} / "invalid"
//   - the message-only no-code envelope {"error":{"message":…}}  -> 2 (or 4 if
//     the message reads like a not-found)
//
// (See docs/cli/error-exit-table.md "Codes that don't cleanly fit".) Anything it
// cannot recognise becomes exitGeneric with the raw body as the message.
func classifyError(status int, body []byte) apiError {
	// First: try the canonical {"error": <object>} envelope.
	var canon struct {
		Error struct {
			Code      string `json:"code"`
			Message   string `json:"message"`
			RequestID string `json:"request_id"`
			Hint      string `json:"hint"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &canon); err == nil && canon.Error.Code != "" {
		return apiError{
			exit:       exitForCode(canon.Error.Code),
			code:       canon.Error.Code,
			message:    canon.Error.Message,
			requestID:  canon.Error.RequestID,
			serverHint: canon.Error.Hint,
		}
	}

	// Bare string-valued `error` (lifecycle veto / intents / plugin-settings).
	var strErr struct {
		Error  string `json:"error"`
		Reason string `json:"reason"`
		OK     *bool  `json:"ok"`
	}
	if err := json.Unmarshal(body, &strErr); err == nil && strErr.Error != "" {
		switch strErr.Error {
		case "halted":
			return apiError{exit: exitConflict, code: "halted", message: vetoMessage(strErr.Reason)}
		case "not_found":
			return apiError{exit: exitNotFound, code: "not_found", message: "not found"}
		case "invalid", "settings_object_required":
			return apiError{exit: exitUsage, code: strErr.Error, message: strErr.Error}
		default:
			// Unknown string error: bucket conservatively as usage.
			return apiError{exit: exitUsage, code: strErr.Error, message: strErr.Error}
		}
	}

	// {"ok":false,"reason":…} (tasks claim/add-edge). Route the reason through the
	// canonical code->exit table so a not_found reason lands on exit 4 (not the
	// blanket exit 2 this branch used to apply, which mislabeled task 404s). A
	// reason absent from the table still falls back to exitGeneric via
	// exitForCode; we keep usage for the historical add-edge `invalid_edge` shape
	// by letting the table miss surface there.
	if strErr.OK != nil && !*strErr.OK && strErr.Reason != "" {
		exit := exitForCode(strErr.Reason)
		if _, known := codeExit[strErr.Reason]; !known {
			// Unknown reason (e.g. invalid_edge): bucket conservatively as usage,
			// preserving the prior behaviour for the add-edge validation shape.
			exit = exitUsage
		}
		msg := strErr.Reason
		if m := bodyMessage(body); m != "" {
			msg = m
		}
		return apiError{exit: exit, code: strErr.Reason, message: msg}
	}

	// Message-only no-code envelope: default usage, downgrade to not-found when
	// the message text reads like one.
	var msgOnly struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &msgOnly); err == nil && msgOnly.Error.Message != "" {
		exit := exitUsage
		if looksLikeNotFound(msgOnly.Error.Message) {
			exit = exitNotFound
		}
		return apiError{exit: exit, message: msgOnly.Error.Message}
	}

	// Truly unrecognised body: a non-JSON gateway/proxy page (nginx 502·503·504
	// HTML, a plain-text load-balancer banner) or JSON without any error field.
	// We could NOT read a `code`, so — unlike every envelope branch above — the
	// HTTP status is the ONLY signal. Key the exit bucket off it (statusExit) and
	// CAP the raw body (capBody) so a multi-KB HTML page never spews to stderr and
	// a 502 no longer misfiles as exit 1. Genuinely-JSON errors already returned
	// above, so the cap only ever trims opaque non-envelope bodies.
	return apiError{exit: statusExit(status), message: capBody(body)}
}

// statusExit maps a raw HTTP status to an exit bucket for a body we could NOT
// decode into a known error shape. It is the status-keyed fallback the canonical
// code->exit table (exitForCode) cannot cover because there is no `code`. A
// status of 0 or an unrecognised class falls to exitGeneric.
func statusExit(status int) int {
	switch {
	case status == 429:
		return exitRateLimit
	case status >= 500:
		return exitServer
	case status == 401, status == 403:
		return exitAuth
	case status == 404, status == 410:
		return exitNotFound
	case status >= 400:
		return exitUsage
	default:
		return exitGeneric
	}
}

// capBody trims an opaque (non-envelope) error body to a short, single-flavour
// message. A gateway 502/503/504 often returns a multi-KB HTML page or proxy
// banner; dumping it verbatim to stderr is noise. Keep the first ~200 runes
// (rune-safe, so a multibyte char is never split) and append an ellipsis. An
// empty body becomes "request failed".
func capBody(body []byte) string {
	msg := strings.TrimSpace(string(body))
	if msg == "" {
		return "request failed"
	}
	const maxRunes = 200
	if r := []rune(msg); len(r) > maxRunes {
		return strings.TrimSpace(string(r[:maxRunes])) + "…"
	}
	return msg
}

// renderErrorEnvelope emits the canonical {ok:false, error:{code, message,
// request_id, hint}} failure envelope on stdout when the resolved output is a
// machine shape (json/yaml), and reports whether it did (table/minimal return
// false so the caller prints its human stderr line instead). Empty request_id
// and hint keys are omitted, so a call passing only code+message reproduces
// useError's original two-field shape byte-for-byte. This is the ONE emitter the
// cloud/hetzner built-ins (via useError) and the manifest runner (via
// renderError) both route through, so a failing `bp <anything> -o json | jq`
// gets a parseable body on stdout rather than empty stdout.
func renderErrorEnvelope(out *writer, code, msg, requestID, hint string) bool {
	errObj := map[string]any{"code": code, "message": msg}
	if requestID != "" {
		errObj["request_id"] = requestID
	}
	if hint != "" {
		errObj["hint"] = hint
	}
	m := map[string]any{"ok": false, "error": errObj}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return true
	case "yaml":
		out.renderYAML(toGeneric(m))
		return true
	}
	return false
}

// usageErrf reports a usage-level (exit 2) failure from a BUILT-IN command's
// dispatch or flag validation. On a machine output (json/yaml) it emits the
// canonical {ok:false,error:{code:"usage",message}} envelope on stdout — so
// `bp <typo> -o json | jq` gets a parseable body instead of empty stdout —
// otherwise it prints the human "barkpark: <msg>" stderr line followed by the
// optional usageHelp (suppressed in machine mode). It is the built-in-dispatch
// counterpart to run.go's manifest-path usage guard, giving both paths the same
// machine-output parity. Always returns exitUsage.
func usageErrf(out *writer, usageHelp func(), format string, args ...any) int {
	msg := fmt.Sprintf(format, args...)
	if !renderErrorEnvelope(out, "usage", msg, "", "") {
		out.errf("barkpark: %s", msg)
		if usageHelp != nil {
			usageHelp()
		}
	}
	return exitUsage
}

// bodyMessage extracts a top-level "message" string from an error body, used to
// give the {"ok":false,"reason":…} shape a human one-liner (e.g. "task not
// found") instead of the bare reason token. Returns "" when absent.
func bodyMessage(body []byte) string {
	var m struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &m); err == nil {
		return strings.TrimSpace(m.Message)
	}
	return ""
}

func vetoMessage(reason string) string {
	if reason == "" {
		return "halted: write refused by a lifecycle veto"
	}
	return "halted: " + reason
}

func looksLikeNotFound(msg string) bool {
	m := strings.ToLower(msg)
	return strings.Contains(m, "not found") || strings.Contains(m, "no such") || strings.Contains(m, "does not exist")
}

// hint returns a code-keyed suggestion of the LIKELY FIX for an apiError, or ""
// when no useful hint applies. It is purely ADDITIVE UX — the runner prints it
// on a second stderr line below errorMessage(). It does NOT touch the 8-code
// exit ladder (codeExit / exitForCode / classifyError / errorMessage are the
// contract spine and stay byte-stable); a wrong or missing hint never changes
// an exit code.
func (e apiError) hint() string {
	// The server's per-error `hint` (envelope field) is the most specific, so
	// prefer it. The local code-keyed map below is the fallback — for codes the
	// server didn't send a hint for, and for older servers that send none. This
	// is what lets NEW error codes (mfa_required, share_expired, …) surface a
	// useful hint without adding a case here for each.
	if e.serverHint != "" {
		return e.serverHint
	}
	switch e.code {
	case "not_found", "schema_unknown":
		return "check the type/id and --dataset; run `bp schema ls` to list types"
	case "validation_failed", "invalid_op", "malformed_op", "type_mismatch", "duplicate_id", "block_not_found", "invalid_paper":
		return "re-run with -v for field errors; check required/pattern fields"
	case "rev_mismatch", "precondition_failed", "conflict":
		return "re-fetch the doc to get the current _rev, then retry"
	case "fenced_off", "stale_claim", "claimed_has_worker", "already_claimed", "not_ready":
		return "your claim epoch is stale — re-claim with `bp task next`"
	case "rate_limited":
		return "retry with backoff"
	case "unauthorized":
		return "set BARKPARK_API_TOKEN or run `bp setup --target connect`"
	case "forbidden", "cors_forbidden", "csrf_required":
		return "token needs write/admin — check `bp whoami`"
	default:
		return ""
	}
}

// errorMessage renders the user-facing one-liner for an apiError, following the
// "CLI message guidance" column of the table where a code is known.
func (e apiError) errorMessage() string {
	switch e.code {
	case "not_found", "schema_unknown":
		if e.message != "" {
			return "not found: " + e.message
		}
		return "not found"
	case "unauthorized":
		return "authentication required — set BARKPARK_API_TOKEN or run: bp setup --target connect --server <url> --token <token>"
	case "forbidden", "cors_forbidden", "csrf_required":
		if e.message != "" {
			return "forbidden: " + e.message
		}
		return "forbidden: token lacks permission for this command"
	case "rate_limited":
		return "rate limited; retry later"
	case "internal_error":
		if e.requestID != "" {
			return "server error (" + e.requestID + ")"
		}
		return "server error"
	default:
		if e.message != "" {
			return e.message
		}
		return "request failed"
	}
}
