package cloudclient

// site_build_log_box_error_test.go — THE OBSERVED 502, NOT A HAND-MADE ONE.
//
// Every envelope fixture in this file is the body measured live on 2026-09-18
// against site `app`, deployment 91fe0b3f-0371-431d-8248-d437059dda84
// (task-3468f99ad5a4e9b8). It is pasted, not paraphrased: the whole class of
// defect here is a decoder written against a shape somebody IMAGINED the
// producer sends, so a fixture invented for the fix would reproduce the fault
// it is meant to catch.
//
// RED-WITHOUT / GREEN-WITH: revert SiteBuildLogRecord.BoxError to `string` and
// TestRecordDecodesTheObservedBoxErrorEnvelope fails with the operator's exact
// message — "json: cannot unmarshal object into Go struct field
// SiteBuildLogRecord.box_error of type string".

import (
	"encoding/json"
	"strings"
	"testing"
)

// observedBoxUnreachableBody is the 502 the control plane answered with, copied
// from the row's curl capture. Nothing is trimmed: the surrounding keys are
// part of the proof that ONE field used to fail the WHOLE record.
const observedBoxUnreachableBody = `{
  "error": "box_unreachable",
  "detail": "the box refused the record read",
  "deployment_id": "91fe0b3f-0371-431d-8248-d437059dda84",
  "build_id": "0bc2581994dea0f8",
  "box_error": {
    "code": "internal_error",
    "hint": "Retry shortly; if it persists the box needs attention",
    "message": "unknown error (FunctionClauseError)",
    "request_id": "GNZOQHLsqlWoMDkAE8Vx"
  },
  "box_status": 500
}`

// historicalSlugBody is the shape box_error/1 was WRITTEN for, and the control
// this fix may not break: a slug string must keep decoding byte-identically.
const historicalSlugBody = `{
  "error": "box_unreachable",
  "detail": "the box refused the record read",
  "deployment_id": "dep-1",
  "box_error": "build_log_unscrubbed",
  "box_status": 409
}`

// THE DEFECT ARM. On origin/main this call returns the operator's error.
func TestRecordDecodesTheObservedBoxErrorEnvelope(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(observedBoxUnreachableBody), &rec); err != nil {
		t.Fatalf("the observed 502 body did not decode: %v\n"+
			"This is the live defect: one field's shape failed the whole record, "+
			"so every 502 branch below the decode was dead code.", err)
	}
	if rec.Error != "box_unreachable" {
		t.Errorf("Error = %q, want box_unreachable — the record around the field must survive", rec.Error)
	}
	if rec.BoxStatus != 500 {
		t.Errorf("BoxStatus = %d, want 500", rec.BoxStatus)
	}
	if rec.BoxError.RequestID != "GNZOQHLsqlWoMDkAE8Vx" {
		t.Errorf("BoxError.RequestID = %q, want GNZOQHLsqlWoMDkAE8Vx — it is the ONE token "+
			"that routes the incident to the box's own logs", rec.BoxError.RequestID)
	}
	if rec.BoxError.Code != "internal_error" {
		t.Errorf("BoxError.Code = %q, want internal_error", rec.BoxError.Code)
	}
	if rec.BoxError.Message != "unknown error (FunctionClauseError)" {
		t.Errorf("BoxError.Message = %q, want the box's own message", rec.BoxError.Message)
	}
	if rec.BoxError.Slug != "" {
		t.Errorf("BoxError.Slug = %q — an envelope is not a slug and must not be "+
			"flattened into one", rec.BoxError.Slug)
	}
}

// THE RENDER ARM. Decoding is not the deliverable: a fix that merely stops the
// crash while printing nothing about request_id leaves the operator exactly as
// stranded as the crash did.
func TestBoxErrorLineCarriesRequestIDAndMessage(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(observedBoxUnreachableBody), &rec); err != nil {
		t.Fatalf("decode: %v", err)
	}
	line := rec.BoxError.Line()
	for _, want := range []string{"GNZOQHLsqlWoMDkAE8Vx", "unknown error (FunctionClauseError)", "internal_error"} {
		if !strings.Contains(line, want) {
			t.Errorf("BoxError.Line() = %q, missing %q", line, want)
		}
	}
	// THE FAILURE DIRECTION THE ROW NAMES: an inspect/1-style dump is still
	// unusable. The rendered line must read as prose, not as a map literal.
	if strings.Contains(line, "map[") || strings.Contains(line, "=>") {
		t.Errorf("BoxError.Line() = %q — that is a map dump, not something an "+
			"operator can act on", line)
	}
}

// THE CONTROL. The historical slug shape must be unchanged by all of this.
func TestRecordStillDecodesTheHistoricalSlugString(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(historicalSlugBody), &rec); err != nil {
		t.Fatalf("the slug shape stopped decoding — the fix broke the case that always worked: %v", err)
	}
	if rec.BoxError.Slug != "build_log_unscrubbed" {
		t.Errorf("BoxError.Slug = %q, want build_log_unscrubbed", rec.BoxError.Slug)
	}
	if got := rec.BoxError.Line(); got != "build_log_unscrubbed" {
		t.Errorf("BoxError.Line() = %q — a slug is relayed VERBATIM, never decorated", got)
	}
	if rec.BoxError.Code != "" || rec.BoxError.RequestID != "" {
		t.Errorf("a slug invented envelope fields: %+v", rec.BoxError)
	}
}

// ABSENCE IS NOT EMPTINESS. A body with no box_error key must read as "the
// server said nothing", never as a blank refusal we then print.
func TestAbsentBoxErrorIsEmptyAndPrintsNothing(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(`{"error":"box_unreachable","box_status":500}`), &rec); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !rec.BoxError.Empty() {
		t.Errorf("an absent box_error decoded as present: %+v", rec.BoxError)
	}
	if got := rec.BoxError.Line(); got != "" {
		t.Errorf("Line() = %q for an absent field, want \"\"", got)
	}
	var withNull SiteBuildLogRecord
	if err := json.Unmarshal([]byte(`{"box_error":null}`), &withNull); err != nil {
		t.Fatalf("explicit null did not decode: %v", err)
	}
	if !withNull.BoxError.Empty() {
		t.Errorf("an explicit null decoded as present: %+v", withNull.BoxError)
	}
}

// NO SWALLOWING. A shape nobody has modelled must still reach the operator as
// itself — turning a loud failure into a silent empty record is worse than the
// crash this file removes.
func TestUnmodelledBoxErrorShapeIsRelayedVerbatim(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(`{"box_error":[1,2,3]}`), &rec); err != nil {
		t.Fatalf("an array shape failed the whole record — the field is still a decode hazard: %v", err)
	}
	if got := rec.BoxError.Line(); got != "[1,2,3]" {
		t.Errorf("Line() = %q, want the raw JSON verbatim — an unrecognised shape may be "+
			"unparsed but may never be silently dropped", got)
	}
}

// THE BYTES ROUTE, MEASURED. BuildLogBytes merges box_status/box_error from the
// byte-for-byte identical box_error/1 clause; this struct declared NEITHER, so
// json.Unmarshal dropped them silently. A route that never crashed is not a
// route that was fine.
func TestBytesRouteDecodesTheSameEnvelope(t *testing.T) {
	var b SiteBuildLogBytes
	if err := json.Unmarshal([]byte(observedBoxUnreachableBody), &b); err != nil {
		t.Fatalf("the bytes decoder failed the observed 502: %v", err)
	}
	if b.BoxStatus != 500 {
		t.Errorf("SiteBuildLogBytes.BoxStatus = %d, want 500 — the key was on the wire all along", b.BoxStatus)
	}
	if b.BoxError.RequestID != "GNZOQHLsqlWoMDkAE8Vx" {
		t.Errorf("SiteBuildLogBytes.BoxError.RequestID = %q, want the box's own id", b.BoxError.RequestID)
	}
	var slug SiteBuildLogBytes
	if err := json.Unmarshal([]byte(historicalSlugBody), &slug); err != nil {
		t.Fatalf("the bytes decoder broke on the slug shape: %v", err)
	}
	if slug.BoxError.Slug != "build_log_unscrubbed" {
		t.Errorf("bytes slug arm = %q, want build_log_unscrubbed", slug.BoxError.Slug)
	}
}

// ROUND TRIP. A structured render re-emits the producer's own shape rather than
// a CLI reinterpretation of it.
func TestBoxErrorMarshalsBackToWhatArrived(t *testing.T) {
	var rec SiteBuildLogRecord
	if err := json.Unmarshal([]byte(observedBoxUnreachableBody), &rec); err != nil {
		t.Fatalf("decode: %v", err)
	}
	out, err := json.Marshal(rec.BoxError)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var back map[string]any
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("the re-emitted value is not the object that arrived: %v (%s)", err, out)
	}
	if back["request_id"] != "GNZOQHLsqlWoMDkAE8Vx" {
		t.Errorf("round trip lost request_id: %s", out)
	}
}
