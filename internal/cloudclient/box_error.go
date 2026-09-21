package cloudclient

// box_error.go — THE FIELD THAT CARRIES TWO SHAPES.
//
// THE DEFECT THIS EXISTS FOR (task-3468f99ad5a4e9b8). `box_error` is written by
// ONE function, duplicated byte-for-byte in the control plane's two build-log
// modules:
//
//	defp box_error(body) when is_map(body), do: Map.get(body, "error") || Map.get(body, "code")
//
// It was written for a box body whose "error" is a SLUG STRING
// (build_log_unscrubbed, build_log_evicted). But the box's GENERIC 500 handler
// answers with the standard error ENVELOPE, where "error" is a MAP of
// code/hint/message/request_id — so box_error/1 passes a map straight out
// through a field every consumer typed as a string. Measured live 2026-09-18:
//
//	$ bp sites logs app 91fe0b3f-0371-431d-8248-d437059dda84
//	json: cannot unmarshal object into Go struct field SiteBuildLogRecord.box_error of type string
//
// encoding/json hard-FAILS the WHOLE record on that one field, so the entire
// designed 502 branch — the one that names box_unreachable and the box's own
// log_state — became dead code for the shape production actually sends. An
// operator running the supported verb saw a Go struct-field message, which
// reads as a CLIENT bug, so nobody chased the box. The two facts that route the
// incident (request_id, message) never left the wire.
//
// THE RULE THIS ENCODES: a shape surprise must degrade ONE FIELD, never the
// whole record. A decoder for a field the producer does not type cannot be a
// scalar. But tolerating is not enough — a decode that merely SUCCEEDS while
// printing nothing leaves the operator exactly as stranded as the crash did, so
// this type also carries the render (Line) that puts request_id in front of the
// human.
//
// NOT A SWALLOW. Nothing here discards bytes: an unrecognised shape (a number,
// an array, a nested object we do not model) is kept VERBATIM in Raw and
// rendered as itself. There is no arm that turns a loud failure into a silent
// empty record.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// BoxError is the box's own refusal as relayed under `box_error`. It decodes
// BOTH shapes the producer can emit and neither is a fallback for the other:
//
//	"build_log_unscrubbed"                        the HISTORICAL slug string
//	{"code":…,"hint":…,"message":…,"request_id":…} the standard error ENVELOPE
//
// Raw always holds the exact bytes that arrived, so a third shape nobody has
// seen yet still reaches the operator instead of vanishing.
type BoxError struct {
	// Slug is set only for the string shape — the vocabulary the field was
	// originally typed for. It is relayed verbatim, never mapped.
	Slug string

	// Code/Message/Hint/RequestID are the envelope shape. RequestID is the one
	// token that routes an incident to the box's own logs, which is why it is
	// modelled rather than left in Raw.
	Code      string
	Message   string
	Hint      string
	RequestID string

	// Raw is the undecoded value, kept for every shape including the two above.
	// Empty only when the key was absent or null.
	Raw json.RawMessage
}

// boxErrorEnvelope is the envelope shape, named so the decode below reads as
// the contract it is rather than as four Map.get calls.
type boxErrorEnvelope struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Hint      string `json:"hint"`
	RequestID string `json:"request_id"`
}

// UnmarshalJSON accepts a string, an object, or null. Anything else is KEPT,
// not rejected and not dropped: this field must never be able to fail the
// record around it again, and it must never answer an absence it did not see.
func (b *BoxError) UnmarshalJSON(data []byte) error {
	*b = BoxError{}
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return nil
	}
	b.Raw = append(json.RawMessage(nil), trimmed...)

	switch trimmed[0] {
	case '"':
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			// A malformed string literal is impossible from a JSON decoder that
			// got this far; Raw already carries it if it ever happens.
			return nil
		}
		b.Slug = s
	case '{':
		var env boxErrorEnvelope
		if err := json.Unmarshal(trimmed, &env); err != nil {
			// An object whose fields are not the envelope's (say, a numeric
			// "code"). Raw keeps it; Line renders it as itself.
			return nil
		}
		b.Code, b.Message, b.Hint, b.RequestID = env.Code, env.Message, env.Hint, env.RequestID
	}
	return nil
}

// MarshalJSON round-trips what arrived, so a structured render of a record
// re-emits the box's own shape rather than a CLI reinterpretation of it.
func (b BoxError) MarshalJSON() ([]byte, error) {
	if len(b.Raw) == 0 {
		return []byte("null"), nil
	}
	return append([]byte(nil), b.Raw...), nil
}

// Empty reports that the wire carried no box_error at all — distinct from an
// envelope whose fields happened to be blank.
func (b BoxError) Empty() bool { return len(b.Raw) == 0 }

// Line renders the box's refusal for a human, and its whole job is to make sure
// request_id survives the last hop. Empty string when there is nothing to say.
//
//	slug shape     build_log_unscrubbed
//	envelope       internal_error: unknown error (FunctionClauseError) [box request_id GNZOQHLsqlWoMDkAE8Vx]
//	anything else  the raw JSON, verbatim
func (b BoxError) Line() string {
	if b.Empty() {
		return ""
	}
	if b.Slug != "" {
		return b.Slug
	}
	var parts []string
	head := b.Code
	if b.Message != "" {
		if head != "" {
			head += ": "
		}
		head += b.Message
	}
	if head != "" {
		parts = append(parts, head)
	}
	if b.RequestID != "" {
		parts = append(parts, fmt.Sprintf("[box request_id %s]", b.RequestID))
	}
	if b.Hint != "" {
		parts = append(parts, "— "+b.Hint)
	}
	if len(parts) == 0 {
		// Neither shape matched: show what arrived rather than nothing.
		return string(b.Raw)
	}
	return strings.Join(parts, " ")
}

// String makes the type printable wherever the old `string` field was.
func (b BoxError) String() string { return b.Line() }

// BoxErrorLine renders the box's refusal from EVERY key the producer's reducer
// puts on the wire, not just the one this type decodes.
//
// WHY IT IS NOT A METHOD. `BoxErrorEnvelope.fields/1` REDUCES the envelope:
// since #19341 the box's generic-500 shape no longer reaches `box_error` as an
// object at all — `box_error` carries the code SLUG and the two facts that
// route an incident travel as SIBLING top-level keys `box_error_message` and
// `box_error_request_id`. A BoxError value therefore cannot see them, and
// `BoxError.Line()` alone now renders "internal_error" and drops the
// request_id — the exact loss the whole box_error work existed to stop, in a
// new spelling.
//
// The legacy object shape still renders through BoxError.Line(); the sibling
// arguments only ADD what that shape already carried in-band, and are skipped
// when they would repeat it.
func BoxErrorLine(boxError BoxError, message, requestID string) string {
	line := boxError.Line()
	if message != "" && message != boxError.Message {
		if line != "" {
			line += ": "
		}
		line += message
	}
	if requestID != "" && requestID != boxError.RequestID {
		if line != "" {
			line += " "
		}
		line += fmt.Sprintf("[box request_id %s]", requestID)
	}
	return line
}
