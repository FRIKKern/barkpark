package cli

// sites_logs_box_error_test.go — THE LAST HOP OF A DIAGNOSIS THAT ARRIVED.
//
// THE DEFECT THIS EXISTS FOR (task-3468f99ad5a4e9b8). On 2026-09-18 the control
// plane answered `bp sites logs app 91fe0b3f-…` with a perfectly informative
// 502 — box_error.request_id GNZOQHLsqlWoMDkAE8Vx, box_error.message "unknown
// error (FunctionClauseError)" — and the operator saw:
//
//	{"error":{"code":"failed","message":"read build log record: decode build log
//	 response: json: cannot unmarshal object into Go struct field
//	 SiteBuildLogRecord.box_error of type string"},"ok":false}
//
// One string-typed field failed the whole record, so runSitesBuildLogRecord
// returned at its FIRST line and the entire 502 branch — the one that names
// box_unreachable — never ran. The message reads as a CLIENT bug, so nobody
// chased the box, and a 16-day outage went unreported.
//
// WHAT THESE ARMS ASSERT, in both directions:
//   - the box_unreachable line is printed, NOT a Go decode error;
//   - request_id appears in it, because a decode that merely SUCCEEDS while
//     printing nothing leaves the operator exactly as stranded as the crash;
//   - the record around the failure survives (the render did not go silent).
//
// The fixture is the body measured live, pasted from the row's curl capture.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// observedBoxUnreachable502 is the 502 record body as the plane sent it.
const observedBoxUnreachable502 = `{
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

// runSitesLogsRecordFixture scripts the record route with one body and returns
// what `bp sites logs blog dep-9` printed.
func runSitesLogsRecordFixture(t *testing.T, status int, body string, output string) (string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", buildLogPath, status, body)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	return runCloudCapture(t, false, func(out *writer) int {
		out.output = output
		return runSites(out, globals{}, []string{"logs", "blog", "dep-9"})
	})
}

// THE KEY TEST. Red on origin/main's decoder, green on this one.
func TestSitesLogsPrintsBoxUnreachableForTheObservedEnvelope(t *testing.T) {
	stdout, stderr, code := runSitesLogsRecordFixture(t, http.StatusBadGateway, observedBoxUnreachable502, "")
	all := stdout + stderr

	if strings.Contains(all, "cannot unmarshal") || strings.Contains(all, "decode build log response") {
		t.Fatalf("the operator got a Go decode error instead of the plane's answer:\n%s", all)
	}
	if !strings.Contains(all, "box_unreachable") {
		t.Fatalf("the designed 502 branch did not run — no box_unreachable in:\n%s", all)
	}
	// THE TOKEN THAT ROUTES THE INCIDENT. Without it the operator is as
	// stranded as the crash left them.
	if !strings.Contains(all, "GNZOQHLsqlWoMDkAE8Vx") {
		t.Errorf("the box's request_id never reached the operator:\n%s", all)
	}
	if !strings.Contains(all, "unknown error (FunctionClauseError)") {
		t.Errorf("the box's own message never reached the operator:\n%s", all)
	}
	if code == 0 {
		t.Errorf("exit = 0 for a 502 — a box we could not reach is not a definite answer")
	}
}

// THE CONTROL, and the half a presence assertion cannot make: the SLUG shape
// box_error was originally typed for must render exactly as it always did, with
// no envelope decoration invented around it.
func TestSitesLogsStillRendersTheHistoricalSlugBoxError(t *testing.T) {
	const slugBody = `{
	  "error":"box_unreachable","detail":"the box refused the record read",
	  "deployment_id":"dep-9","box_error":"build_log_unscrubbed","box_status":409
	}`
	stdout, stderr, _ := runSitesLogsRecordFixture(t, http.StatusBadGateway, slugBody, "")
	all := stdout + stderr

	if !strings.Contains(all, "box_unreachable") {
		t.Fatalf("the slug arm lost its 502 render:\n%s", all)
	}
	if !strings.Contains(all, "build_log_unscrubbed") {
		t.Errorf("the box's slug was relayed to nobody:\n%s", all)
	}
	// FAILURE DIRECTION THE ROW NAMES: a map dump is not a fix.
	if strings.Contains(all, "map[") || strings.Contains(all, "=>") {
		t.Errorf("the render leaked a map literal:\n%s", all)
	}
}

// THE STRUCTURED SURFACE. A machine consumer must get the box's refusal in the
// SHAPE IT ARRIVED IN, plus request_id hoisted where a script can read it
// without re-parsing prose.
func TestSitesLogsJSONCarriesBoxErrorObjectAndRequestID(t *testing.T) {
	stdout, _, _ := runSitesLogsRecordFixture(t, http.StatusBadGateway, observedBoxUnreachable502, "json")

	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("structured output is not JSON: %v\n%s", err, stdout)
	}
	if payload["box_request_id"] != "GNZOQHLsqlWoMDkAE8Vx" {
		t.Errorf("box_request_id = %v, want the box's own id\n%s", payload["box_request_id"], stdout)
	}
	obj, ok := payload["box_error"].(map[string]any)
	if !ok {
		t.Fatalf("box_error is not the object the producer sent (%T) — a structured "+
			"consumer must see the wire, not a CLI flattening of it\n%s", payload["box_error"], stdout)
	}
	if obj["message"] != "unknown error (FunctionClauseError)" {
		t.Errorf("box_error.message = %v\n%s", obj["message"], stdout)
	}
	if payload["box_status"] != float64(500) {
		t.Errorf("box_status = %v, want 500\n%s", payload["box_status"], stdout)
	}
}
