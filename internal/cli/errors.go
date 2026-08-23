package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
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
	// details is the envelope `details` object VERBATIM, kept as raw JSON. The
	// server sets it on 18 error paths and its shape is per-code — {field:[…]}
	// for validation_failed, {field,rule,fix,index} for label_spine,
	// {similar:[…]} for duplicate_task, {filter:"…"} for invalid_filter. It is
	// deliberately NOT decoded into a typed map: a typed decode fits exactly one
	// of those shapes and fails the whole unmarshal on the others (the
	// mutateErrorMessage bug), so the ONE payload that explains the refusal is
	// the first thing lost. Raw bytes survive every shape and re-serialize
	// byte-identically into the -o json / -o yaml envelope.
	details json.RawMessage
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
	// The cloud control plane's team gate: the caller's login has no ACTIVE TEAM.
	// Deliberately NOT the auth bucket even though it now arrives as a 403 — exit 3
	// means "your credential is bad", and here the credential is fine; the fix is
	// `bp team use <team>`, not a re-login. It kept exit 1 for the whole life of the
	// 422 shape and must keep it now that the gate answers 403 with
	// {"error":"forbidden","reason":"no_team"} (cch-w40-s4).
	"no_team":   exitGeneric,
	"malformed": exitUsage,
	// An unknown filter operator (?filter[f][bogus]=x) — a malformed request,
	// same bucket as `malformed`. Added when the query API began rejecting
	// unknown ops instead of silently returning every row (#570).
	"invalid_filter":    exitUsage,
	"validation_failed": exitValidation,
	"invalid_paper":     exitValidation,
	"malformed_op":      exitValidation,
	"invalid_op":        exitValidation,
	"block_not_found":   exitValidation,
	"type_mismatch":     exitValidation,
	"duplicate_id":      exitValidation,
	// Blob-push refusals from the media put_blob route (the sidecar channel
	// `bp cloud workspace import --with-blobs` writes to). Both are 422s emitted
	// BEFORE any byte touches disk — a traversal/malformed relative path, and an
	// empty body (usually a mislabeled content-type Plug.Parsers already ate).
	// Absent from this table they fell to the exit-1 unknown-code bucket, which
	// reads as "unexpected" for what is a plainly invalid payload (PDS-D52).
	"invalid_path":        exitValidation,
	"empty_body":          exitValidation,
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
	// The stamp/close refusal vocabulary (PDS-D371). Every one of these used to
	// land on exit 2 — the SAME code as a malformed `--met --miss` command line —
	// so a retry wrapper could not tell "the world moved, re-claim and retry"
	// apart from "your arguments are wrong, give up". They split by RETRYABILITY:
	//   6 (conflict): the lease/state moved under you — re-read, re-claim, retry.
	"not_holder":              exitConflict,
	"not_in_progress":         exitConflict,
	"doc_changed_since_claim": exitConflict,
	"claimed_has_worker":      exitConflict,
	//   5 (validation): the REQUEST is wrong — never retryable as sent.
	// illegal_transition is emitted with :unprocessable_entity (a 422) and is the
	// one member of this family that can never succeed on a retry, so it belongs
	// with the payload guards rather than the conflict bucket.
	"criteria_mismatch":           exitValidation,
	"criteria_index_out_of_range": exitValidation,
	"criterion_text_required":     exitValidation,
	"note_required":               exitValidation,
	"illegal_transition":          exitValidation,
	"rate_limited":                exitRateLimit,
	"internal_error":              exitServer,
}

// reasonKey reduces a COMPOUND server reason token to its table key. The tasks
// controller mints reasons that carry their detail inline — `not_holder:<worker>`,
// `not_in_progress:<status>`, `criteria_unmet:<indices>`, `invalid_lifecycle:<s>`,
// `sentinel_worker_id:<w>` (api/lib/barkpark_web/controllers/tasks_controller/
// params.ex, reason_to_string/1) — and a literal map key misses every one of
// them. Splitting at the FIRST ':' keeps the family name and drops the detail.
// It reads the reason STRING only; it never consults the HTTP status, so the
// contract-spine rule at the top of this file (code, never status) holds.
func reasonKey(code string) string {
	if i := strings.IndexByte(code, ':'); i >= 0 {
		return code[:i]
	}
	return code
}

// lookupExit is the ONE codeExit lookup — the literal code first, then its
// compound-token family name. It reports whether the code was KNOWN, because
// the two callers disagree about the fallback: exitForCode falls back to
// exitGeneric (the table's documented unknown-envelope-code rule) while the
// {"ok":false,"reason":…} branch falls back to exitUsage (preserving the
// historical add-edge `invalid_edge` behaviour). Both MUST consult the same
// table the same way: before this existed, classifyError did a second LITERAL
// codeExit lookup that overrode a compound-token match back to exit 2.
func lookupExit(code string) (int, bool) {
	if e, ok := codeExit[code]; ok {
		return e, true
	}
	if key := reasonKey(code); key != code {
		if e, ok := codeExit[key]; ok {
			return e, true
		}
	}
	return exitGeneric, false
}

// exitForCode maps an envelope error.code to a process exit code. An unknown or
// empty code falls back to exitGeneric (1), per the table's documented fallback.
func exitForCode(code string) int {
	e, _ := lookupExit(code)
	return e
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
			// Declared so encoding/json stops DISCARDING it: an unmapped key is
			// dropped silently, which is why every `details` the server has ever
			// sent died here and no printer could show it (PDS-D457).
			Details json.RawMessage `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &canon); err == nil && canon.Error.Code != "" {
		return apiError{
			exit:       exitForCode(canon.Error.Code),
			code:       canon.Error.Code,
			message:    canon.Error.Message,
			requestID:  canon.Error.RequestID,
			serverHint: canon.Error.Hint,
			details:    normalizeDetails(canon.Error.Details),
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
			// A refusal that names its CAUSE alongside a generic code — the shape
			// the cloud control plane's authority gates emit,
			// {"error":"forbidden","reason":"no_team","scope":"team"} — is classified
			// by the CAUSE. "forbidden" alone buckets as exit 3 ("your credential is
			// bad") and prints one word, which is a LIE for a login that merely has
			// no active team. Only a reason the canonical table KNOWS may re-key the
			// exit, so an unrecognised cause can never silently move an exit code;
			// the message keeps BOTH tokens so the machine code the server sent is
			// never hidden from the user.
			if strErr.Reason != "" {
				if e, known := lookupExit(strErr.Reason); known {
					return apiError{exit: e, code: strErr.Reason, message: strErr.Error + ": " + strErr.Reason}
				}
			}
			// A bare-string error the two branches above don't name (the cloud
			// router emits {"error":"illegal_transition"} this way). Route it
			// through the SAME table as the coded envelope so one token cannot
			// mean two exit codes depending on which shape carried it; an
			// unknown string still buckets conservatively as usage.
			if e, known := lookupExit(strErr.Error); known {
				return apiError{exit: e, code: strErr.Error, message: strErr.Error}
			}
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
		exit, known := lookupExit(strErr.Reason)
		if !known {
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
	return renderErrorEnvelopeDetailed(out, code, msg, requestID, hint, nil)
}

// renderErrorEnvelopeDetailed is renderErrorEnvelope plus the envelope `details`
// object — the per-code payload that names WHICH field/filter/rule the server
// refused. docs/cli/error-exit-table.md has declared details part of the v1
// envelope since :15 (and tells the CLI to print it at :97, to read
// details.retry_after at :117, and names error.details as wire contract at :153);
// the CLI never complied, because the canon struct in classifyError did not
// declare the key and encoding/json dropped it. This is that compliance, and it
// is purely ADDITIVE: no existing key moves or changes type, and an empty/absent
// details is omitted, so renderErrorEnvelope's ~60 detail-less call sites emit
// byte-identical bytes through this delegation.
func renderErrorEnvelopeDetailed(out *writer, code, msg, requestID, hint string, details json.RawMessage) bool {
	errObj := map[string]any{"code": code, "message": msg}
	if requestID != "" {
		errObj["request_id"] = requestID
	}
	if hint != "" {
		errObj["hint"] = hint
	}
	if d := normalizeDetails(details); d != nil {
		errObj["details"] = d
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

// useErrorDetailed is useError plus the envelope `details` payload — the same
// two-channel contract (machine envelope on stdout for -o json/yaml, human line
// on stderr otherwise) with a per-error `details` object routed through
// renderErrorEnvelopeDetailed. A nil/empty details reproduces useError's bytes
// exactly, so it is a safe superset. The human line NEVER carries the raw
// details — the caller folds whatever a human needs into `msg`; details is the
// machine-only channel a script parses.
func useErrorDetailed(out *writer, code, msg string, exit int, details json.RawMessage) int {
	if renderErrorEnvelopeDetailed(out, code, msg, "", "", details) {
		return exit
	}
	out.userErr("%s", msg)
	return exit
}

// normalizeDetails reduces a raw `details` value to either nil (nothing worth
// showing) or its COMPACT bytes. Nothing-worth-showing is: absent, JSON null,
// the empty object, the empty array, or bytes that are not valid JSON at all —
// the last so a malformed server payload can never make stdout unparseable under
// -o json. Compacting keeps key ORDER as the server sent it (raw bytes are never
// re-marshalled through a Go map, which would alphabetize them — the exact
// fingerprint that proved issue #4938 was observing bp and not the server).
func normalizeDetails(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return nil
	}
	switch buf.String() {
	case "", "null", "{}", "[]":
		return nil
	}
	return json.RawMessage(buf.Bytes())
}

// detailLines renders a `details` payload as the sorted `key: value` lines the
// human shapes (table/minimal) print above the hint. Scalars print VERBATIM (a
// string without its JSON quotes, so `filter: zzzgarbage` reads like a value and
// not like a fragment of a document); objects and arrays print as compact JSON,
// so a heterogeneous payload — {field,rule,fix,index}, {similar:[…]},
// {title:["can't be blank"]} — survives whole rather than being flattened to the
// one shape the CLI happened to expect. A details that is not an object at all
// (an array, or a bare scalar) prints as a single `details: …` line. Returns nil
// when there is nothing to print.
func detailLines(raw json.RawMessage) []string {
	d := normalizeDetails(raw)
	if d == nil {
		return nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(d, &obj); err != nil || len(obj) == 0 {
		return []string{"details: " + string(d)}
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	lines := make([]string, 0, len(keys))
	for _, k := range keys {
		lines = append(lines, k+": "+detailValue(obj[k]))
	}
	return lines
}

// detailLinesForCode renders the human (table/minimal) detail lines for ONE
// error code. The two publish-wall codes get an ACTIONABLE per-fact rendering —
// unknown_tag prints one line per unknown tag name with its trgm-nearest
// registered suggestions, and duplicate_of leads with the incumbent published
// id — because the generic compact-JSON lines bury exactly the token the author
// must copy into the retry (the per-name pairing, the one claimable id). Every
// other code, and a wall payload whose shape is not the contracted one, falls
// back to the generic sorted key:value lines (detailLines), so no payload is
// ever silently dropped. The machine channel (-o json/yaml) never routes
// through here — it carries `details` verbatim.
func detailLinesForCode(code string, raw json.RawMessage) []string {
	d := normalizeDetails(raw)
	if d == nil {
		return nil
	}
	switch code {
	case "unknown_tag":
		if lines := unknownTagLines(d); lines != nil {
			return lines
		}
	case "duplicate_of":
		if lines := duplicateOfLines(d); lines != nil {
			return lines
		}
	}
	return detailLines(raw)
}

// maxTagSuggestions bounds the per-name suggestion list unknown_tag prints —
// the server sends the trgm-nearest few, but a hostile/buggy payload must not
// flood stderr.
const maxTagSuggestions = 5

// unknownTagLines renders the unknown_tag wall payload {unknown:[name],
// suggestions:{name=>[nearest]}} (api tag_registry.ex, validate_publish) as one
// line per unknown name carrying ITS OWN suggestions — the pairing the generic
// sorted rendering destroys by printing the two maps as unrelated blobs. Names
// keep the server's `unknown` order (the document's tag order). Returns nil
// when the shape is not the contracted one, so the caller falls back to the
// generic lines.
func unknownTagLines(d json.RawMessage) []string {
	var p struct {
		Unknown     []string            `json:"unknown"`
		Suggestions map[string][]string `json:"suggestions"`
	}
	if err := json.Unmarshal(d, &p); err != nil || len(p.Unknown) == 0 {
		return nil
	}
	lines := make([]string, 0, len(p.Unknown))
	for _, name := range p.Unknown {
		sugg := p.Suggestions[name]
		if len(sugg) > maxTagSuggestions {
			sugg = sugg[:maxTagSuggestions]
		}
		if len(sugg) == 0 {
			lines = append(lines, "unknown tag "+strconv.Quote(name)+" — no similar registered tag; publish a type:tag doc with this _id, or drop it")
		} else {
			lines = append(lines, "unknown tag "+strconv.Quote(name)+" — did you mean: "+strings.Join(sugg, ", "))
		}
	}
	return lines
}

// duplicateOfLines renders the duplicate_of wall payload {duplicate_of:<id>,
// similar:[…], advise:…} (api content/errors.ex) with the incumbent published
// id FIRST and verbatim — the one token the author needs to claim or extend the
// incumbent instead of republishing. The remaining keys keep their generic
// sorted rendering below it, so similar/advise (or any future key) survive
// whole. Returns nil when the incumbent id is absent or not a string, so the
// caller falls back to the generic lines.
func duplicateOfLines(d json.RawMessage) []string {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(d, &obj); err != nil {
		return nil
	}
	var id string
	if err := json.Unmarshal(obj["duplicate_of"], &id); err != nil || id == "" {
		return nil
	}
	lines := []string{"duplicate of: " + id + " — claim or extend the incumbent instead of republishing"}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		if k != "duplicate_of" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		lines = append(lines, k+": "+detailValue(obj[k]))
	}
	return lines
}

// detailValue renders ONE details value for the human line: a JSON string loses
// its quotes, every other shape (number, bool, null, object, array) prints as
// compact JSON.
func detailValue(raw json.RawMessage) string {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return strings.TrimSpace(string(raw))
	}
	return buf.String()
}

// usageErrf reports a usage-level (exit 2) failure from a BUILT-IN command's
// dispatch or flag validation. On a machine output (json/yaml) it emits the
// canonical {ok:false,error:{code:"usage",message}} envelope on stdout — so
// `bp <typo> -o json | jq` gets a parseable body instead of empty stdout —
// otherwise it prints the human "bp: <msg>" stderr line followed by the
// optional usageHelp (suppressed in machine mode). It is the built-in-dispatch
// counterpart to run.go's manifest-path usage guard, giving both paths the same
// machine-output parity. Always returns exitUsage.
func usageErrf(out *writer, usageHelp func(), format string, args ...any) int {
	return usageErrHintf(out, usageHelp, "", format, args...)
}

// usageErrHintf is usageErrf with an explicit envelope `hint` — the machine-mode
// carrier for the did-you-mean suggestion. The dispatch sites that report an
// unknown noun/verb already compute the nearest known token for the HUMAN usage
// help block (usageSuggestNouns / usageSuggestVerb print it to stderr), but
// usageErrf hardcodes hint="" so that suggestion never reached the `-o json`
// error envelope — the exact surface agents (always piped) read. This threads
// the same suggestion into error.hint. usageErrf delegates here with hint="" so
// its ~60 no-op call sites stay byte-identical; only the four suggestion sites
// pass a real hint (via nounHint/verbHint). Table/minimal output is unaffected —
// renderErrorEnvelope emits nothing on stdout there, and the hint never appears
// on the human stderr line (the usageHelp block already shows it). Always
// returns exitUsage.
func usageErrHintf(out *writer, usageHelp func(), hint, format string, args ...any) int {
	msg := fmt.Sprintf(format, args...)
	if !renderErrorEnvelope(out, "usage", msg, "", hint) {
		out.userErr("%s", msg)
		if usageHelp != nil {
			usageHelp()
		}
	}
	return exitUsage
}

// fetchSnapshotErr reports a failed taskboard.FetchSnapshotFull as the shared
// board-fetch failure path for the client-side read verbs that intercept
// entirely before manifest dispatch (`bp task frontier`, `bp task lint`,
// `bp task next --frontier`, `bp cmux dispatch`). FetchSnapshotFull returns a
// plain wrapped Go error (a transport failure or a bare non-200 status,
// wrapped via fmt.Errorf in taskboard/fetch.go) rather than a decoded API
// envelope, so there is no server `code` for classifyError to key on; this
// mints the one fresh "fetch_failed" code for it instead of inventing a
// per-verb variant. On a machine output (json/yaml) it emits the canonical
// {ok:false,error:{code,message}} envelope on stdout via renderErrorEnvelope —
// closing exactly the gap renderErrorEnvelope's own doc comment describes:
// these four verbs used to `out.userErr(...)` unconditionally, leaving
// `bp task frontier -o json | jq` with empty stdout on a failed fetch even
// though the same verb emits proper json/yaml on success. Otherwise it prints
// the unchanged human "bp: <verb>: <err>" stderr line. Always returns
// exitGeneric — a board-fetch failure is operational, never a usage error.
func fetchSnapshotErr(out *writer, verb string, err error) int {
	msg := fmt.Sprintf("%s: %v", verb, err)
	if !renderErrorEnvelope(out, "fetch_failed", msg, "", "") {
		out.userErr("%s", msg)
	}
	return exitGeneric
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
	case "fenced_off", "stale_claim", "claimed_has_worker", "already_claimed":
		// fenced_off now covers more than a plain epoch bump: a blocker landing on
		// (or a move of) your claimed task, or a swept+reclaimed lease, all bump the
		// epoch. Name the wider cause, and point at the lease-RENEWAL recovery (a
		// re-claim under YOUR OWN worker id mints a fresh epoch) rather than a
		// generic `task next`.
		return "your claim epoch is stale (lease swept or a blocker/move fenced you) — re-claim under your worker id, then retry"
	case "not_ready":
		// not_ready is NOT a stale-epoch case: the targeted claim hit a task held by
		// ANOTHER worker, or one that is done/cancelled/blocked-by-deps. The fix is
		// not "re-claim to advance the epoch" — it is either wait for the holder, or
		// (if the holder is YOU) re-claim under your own id to renew the lease.
		return "the task isn't claimable — someone else holds it or it isn't ready; if YOU hold it, re-claim with your own worker id to renew the lease"
	case "doc_changed_since_claim":
		return "the task's brief changed since you claimed it — the 409 body names current_rev + changed_fields; re-read with `bp task get <id>`, reconcile, then close with `--set observed_rev=<current_rev>` (strict full-rev CAS, bypasses the digest fence). A plain re-read then close repeats the 409 — a same-worker re-read preserves the claim-time work digest"
	case "rate_limited":
		return "retry with backoff"
	case "unauthorized":
		return "set BARKPARK_API_TOKEN or run `bp setup --target connect`"
	case "forbidden", "cors_forbidden", "csrf_required":
		return "token needs write/admin — check `bp whoami`"
	case "no_team":
		return "your Cloud login has no active team — run `bp team use <team>`"
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
