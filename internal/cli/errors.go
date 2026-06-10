package cli

import (
	"encoding/json"
	"strings"
)

// apiError is the decoded outcome of a non-2xx (or error-shaped) API response.
// It carries the exit code already mapped per docs/cli/error-exit-table.md, plus
// a human message and the request id for support.
type apiError struct {
	exit      int
	code      string
	message   string
	requestID string
}

// codeExit is the SINGLE canonical error.code -> exit mapping (contract spine
// rule #3). The CLI keys on the envelope's `code` string and NEVER re-derives an
// exit code from the HTTP status. Source: docs/cli/error-exit-table.md.
var codeExit = map[string]int{
	"not_found":           exitNotFound,
	"schema_unknown":      exitNotFound,
	"share_expired":       exitNotFound, // 410, bucketed as gone/not-found
	"unauthorized":        exitAuth,
	"forbidden":           exitAuth,
	"cors_forbidden":      exitAuth,
	"csrf_required":       exitAuth,
	"malformed":           exitUsage,
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
	"rate_limited":        exitRateLimit,
	"internal_error":      exitServer,
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
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &canon); err == nil && canon.Error.Code != "" {
		return apiError{
			exit:      exitForCode(canon.Error.Code),
			code:      canon.Error.Code,
			message:   canon.Error.Message,
			requestID: canon.Error.RequestID,
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

	// Truly unrecognised: generic. Surface the body so the user can see it.
	msg := strings.TrimSpace(string(body))
	if msg == "" {
		msg = "request failed"
	}
	return apiError{exit: exitGeneric, message: msg}
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
