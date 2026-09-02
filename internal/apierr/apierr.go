// Package apierr is the ONE reader of Barkpark's error envelope.
//
// WHY THIS PACKAGE EXISTS. Every surface that talks to the API has to turn
//
//	{"error":{"code":…,"message":…,"hint":…,"request_id":…,"details":…}}
//
// into something a human reads. Before this package there were EIGHT private
// decoders doing it — a census of internal/ and cmd/ found ten envelope-decode
// sites in nine files, two of them the canonical pair in internal/cli/errors.go
// and eight re-implementations. They had drifted exactly as forks do:
//
//   - five of the eight never declared `hint` at all, so every refusal they
//     printed arrived with its remedy stripped — the server said what to do
//     and the CLI dropped that sentence on the floor;
//   - six never declared `details`, silently discarding the payload that names
//     WHICH row, WHICH field, WHICH id the refusal is about;
//   - one (tasks_create_cmd.go's mutateErrorMessage) typed `details` as
//     map[string][]string, a guess at ONE shape. encoding/json rejects the
//     WHOLE document on a single field mismatch, so a duplicate_task 409 —
//     whose details is {"similar":[{…}],"advise":[]} — failed to unmarshal and
//     took code, message AND hint down with it, leaving a raw body clamped
//     mid-sentence. The refusal told the caller to pass distinct_from:["<id>"]
//     while withholding the id.
//
// The fix is one decoder, not eight. This package holds it.
//
// WHY IT IS A LEAF. internal/apiclient and internal/cloudclient sit BELOW
// internal/cli and must not depend upward (ConfigFromEnv's axi-b4 note, stated
// on three separate declarations and enforced by the compiler — cli imports
// apiclient, so the reverse edge is an import cycle). That constraint is what
// produced the forks in the first place: humanAPIError's own comment records
// the previous author hitting this wall and choosing to DUPLICATE
// internal/cli's rendering "rather than imported — apiclient sits BELOW cli".
// A shared decoder therefore cannot live in cli. It lives here, below
// everything, importing nothing of ours, so all three layers reach DOWN to it.
//
// WHAT IS SHARED AND WHAT IS NOT. This package PARSES; it does not RENDER and
// it does not decide exit codes. classifyError still owns the CLI's
// code→exit-code table, its four alternative body shapes and its multi-line
// refusal block; the TUI still owns its one-line status bar; humanAPIError
// still owns its display budget. That split is deliberate: one behaviour
// (reading the envelope) with several presentations is not a fork, whereas one
// presentation forced onto several surfaces would be a regression.
package apierr

import (
	"bytes"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
)

// Envelope is the canonical error object, decoded permissively.
//
// EVERY field that the server may shape differently is json.RawMessage or a
// plain string — never a typed map. That is the whole lesson of the fork this
// package replaces: a concrete type is a GUESS about one payload, and
// encoding/json punishes a wrong guess by discarding the entire document,
// including the fields it could have read perfectly well.
type Envelope struct {
	Code      string          `json:"code"`
	Message   string          `json:"message"`
	Hint      string          `json:"hint"`
	RequestID string          `json:"request_id"`
	Details   json.RawMessage `json:"details"`
}

// Parse reads the canonical {"error":{…}} envelope out of a response body.
//
// ok is true when the body carried an error object with at least a code or a
// message — the same admission test classifyError has always applied. It is
// false for a body that is not JSON, that carries no "error" key, or whose
// "error" is a bare string (the lifecycle-veto and plugin-settings shapes,
// which classifyError handles separately and which are NOT this package's
// business).
//
// Parse never fails on an unexpected `details`: the field is RawMessage, so any
// shape the server invents next rides through untouched and every sibling field
// still arrives.
func Parse(body []byte) (Envelope, bool) {
	var wrapper struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &wrapper) != nil {
		return Envelope{}, false
	}
	trimmed := bytes.TrimSpace(wrapper.Error)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		// Absent, null, or a bare string — not the canonical object shape.
		return Envelope{}, false
	}
	var env Envelope
	if json.Unmarshal(trimmed, &env) != nil {
		return Envelope{}, false
	}
	if env.Code == "" && env.Message == "" {
		return Envelope{}, false
	}
	return env, true
}

// Summary is the envelope as one line: the message (falling back to the code),
// with the details appended as sorted "field: reason" parts when they carry
// that shape. It is what a caller wants when it has exactly one line to spend —
// a TUI status bar, a wrapped error value.
//
// It deliberately does NOT append the hint: a hint is a second sentence, and a
// caller with one line has already spent it. HintLine exists for callers with
// room. This keeps the one-line surfaces byte-compatible with what they printed
// before, which is why adopting this package is not a display change for them.
func (e Envelope) Summary() string {
	msg := e.Message
	if msg == "" {
		msg = e.Code
	}
	if parts := e.DetailParts(); len(parts) > 0 {
		msg += " — " + strings.Join(parts, " · ")
	}
	return msg
}

// HintLine returns the server's hint, trimmed, or "" when it sent none. The
// hint is the sentence that says what to DO about the refusal; five of the
// eight decoders this package replaces never read it, so five surfaces could
// print a refusal whose remedy the server had supplied and they discarded.
func (e Envelope) HintLine() string { return strings.TrimSpace(e.Hint) }

// DetailParts renders a `details` payload as sorted "field: value" parts.
//
// This is apiclient.humanDetailParts's algorithm, adopted VERBATIM as the
// canonical one because it is the most capable of the eight: it renders EVERY
// key generically rather than only validation_failed's {field:[reasons]}, so
// duplicate_of's bare incumbent id, resource_conflict's conflicts list and
// label_spine's {rule,fix,index} all print instead of vanishing. Migrating the
// weaker decoders onto a weaker shared version would have been a regression
// dressed as consolidation — the point of one reader is that every surface gets
// the BEST behaviour, not the average one.
//
// Sorting by KEY is byte-identical to sorting the joined parts for this shape:
// every part shares the "<field>: " prefix, so key order and part order agree
// as long as field names use ordinary identifier characters (true of every
// field name this server emits). A details payload that is absent, empty, or
// not a JSON object (a bare scalar or array) renders nothing.
func (e Envelope) DetailParts() []string {
	d := bytes.TrimSpace(e.Details)
	if len(d) == 0 {
		return nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(d, &obj); err != nil || len(obj) == 0 {
		return nil
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+": "+detailValue(obj[k]))
	}
	return parts
}

// detailValue renders ONE details value. A []string (validation_failed's
// {field:[reasons]}) joins with "; ", a JSON string loses its quotes
// (duplicate_of's bare incumbent id), and every other shape (number, bool,
// null, object, array) prints as compact JSON — so nothing is ever silently
// dropped. Ported unchanged from apiclient.humanDetailValue.
func detailValue(raw json.RawMessage) string {
	var reasons []string
	if err := json.Unmarshal(raw, &reasons); err == nil {
		return strings.Join(reasons, "; ")
	}
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

// Candidate is one near-match row from a dedup refusal's details — the shape
// api/lib/barkpark/tasks/dedup.ex present/1 builds: {id, similarity, relation,
// lifecycle_status}.
type Candidate struct {
	ID         string  `json:"id"`
	Similarity float64 `json:"similarity"`
	Relation   string  `json:"relation"`
	Lifecycle  string  `json:"lifecycle_status"`
}

// Line renders one candidate, ID FIRST, because the id is the input the
// refusal's own remedy demands. kind labels the list it came from. A row with
// no id renders "" — a candidate we cannot name is not worth a line, since
// naming it is the entire point.
func (c Candidate) Line(kind string) string {
	if strings.TrimSpace(c.ID) == "" {
		return ""
	}
	s := kind + " " + c.ID
	var extras []string
	if c.Similarity > 0 {
		extras = append(extras, "similarity "+strconv.FormatFloat(c.Similarity, 'f', 2, 64))
	}
	if c.Relation != "" {
		extras = append(extras, c.Relation)
	}
	if c.Lifecycle != "" {
		extras = append(extras, c.Lifecycle)
	}
	if len(extras) > 0 {
		s += " (" + strings.Join(extras, ", ") + ")"
	}
	return s
}

// Candidates pulls the near-match lists a dedup refusal carries — details.similar
// (the rows that CAUSED the refusal) and details.advise (rows worth a look that
// did not). Returns nil for any other details shape.
func (e Envelope) Candidates() (similar, advise []Candidate) {
	if len(e.Details) == 0 {
		return nil, nil
	}
	var d struct {
		Similar []Candidate `json:"similar"`
		Advise  []Candidate `json:"advise"`
	}
	if json.Unmarshal(e.Details, &d) != nil {
		return nil, nil
	}
	return d.Similar, d.Advise
}

// RetryAfterSeconds pulls details.retry_after — the wait, in seconds, that a
// rate_limited (429) refusal names for the caller. The measured envelope is
//
//	{"error":{"code":"rate_limited","message":"too many requests",
//	          "details":{"retry_after":1}}}
//
// ok is false whenever the field is absent, the details are not an object, or
// the value is not a JSON number. Decoding into a *float64 (not an int) accepts
// both the integer form the server sends today and a fractional one it may send
// later; a non-number for that key makes the whole decode fail, which is
// exactly the ok=false answer the caller wants.
//
// It reports the server's number verbatim and applies NO policy: whether a
// value is worth waiting on, and what upper bound is sane, belongs to the
// caller that will do the sleeping (see manifest.retryAfterDelay).
func (e Envelope) RetryAfterSeconds() (float64, bool) {
	if len(e.Details) == 0 {
		return 0, false
	}
	var d struct {
		RetryAfter *float64 `json:"retry_after"`
	}
	if json.Unmarshal(e.Details, &d) != nil {
		return 0, false
	}
	if d.RetryAfter == nil {
		return 0, false
	}
	return *d.RetryAfter, true
}
