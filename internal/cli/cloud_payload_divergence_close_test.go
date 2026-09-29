package cli

// cloud_payload_divergence_close_test.go — dr-w11-payload-divergence-close.
//
// The payload census (cloud/test/barkpark_cloud/payload_key_set_census_test.exs)
// proves a key the control plane emits is DECLARED by a Go struct. It cannot
// prove anything READS it — "decode is not readership". These tests are the
// reader half for every key that task closed: each one decodes the REAL wire
// shape (a JSON literal, not a hand-built struct) and asserts the render.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

func decodeBarkpark(t *testing.T, raw string) cloudclient.Barkpark {
	t.Helper()
	var b cloudclient.Barkpark
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	return b
}

// The missed-check counter and the alert latch are the EVIDENCE behind a
// non-up verdict. Before this task `bp` printed "degraded" and nothing else.
func TestDegradedRowCarriesReachabilityEvidence(t *testing.T) {
	b := decodeBarkpark(t, `{"host":"h","last_seen_at":"2026-09-25T00:00:00Z","health_status":"down","agent_status":"online",
		"queued_deploy_age_seconds":null,"unreachable_count":3,"unreachable_notification_sent":true}`)
	status := attentionStatus(b)
	if status != "degraded" {
		t.Fatalf("status = %q, want degraded (fixture precondition)", status)
	}
	got := attentionDetail(b, status)
	for _, want := range []string{"3 consecutive missed health checks", "unreachable alert sent for this outage"} {
		if !strings.Contains(got, want) {
			t.Errorf("detail = %q, want it to carry %q", got, want)
		}
	}
}

// Silence for absent or zero — never "0 missed checks" — and singular for one.
func TestReachabilityEvidenceSilenceAndSingular(t *testing.T) {
	cases := map[string]struct {
		raw, want string
	}{
		"older plane omits both": {`{}`, ""},
		"measured zero":          {`{"unreachable_count":0}`, ""},
		"one miss":               {`{"unreachable_count":1}`, "1 consecutive missed health check"},
		"latch alone":            {`{"unreachable_notification_sent":true}`, "unreachable alert sent for this outage"},
	}
	for name, c := range cases {
		if got := reachabilityEvidence(decodeBarkpark(t, c.raw)); got != c.want {
			t.Errorf("%s: reachabilityEvidence = %q, want %q", name, got, c.want)
		}
	}
}

// An in-flight rollout outranks the cached verdict, exactly as the console's
// SETTLE pill does: "1.4.2 → 1.5.0" over a landing rollout reads as stuck.
func TestUpdateCellInFlightOutranksCachedVerdict(t *testing.T) {
	b := decodeBarkpark(t, `{"update_running_release":"1.4.2","update_latest_release":"1.5.0","update_state":"behind",
		"autoupdate_triggered_at":"2026-09-25T10:00:00Z"}`)
	if got := updateCell(b); got != "updating → 1.5.0" {
		t.Fatalf("updateCell = %q, want %q", got, "updating → 1.5.0")
	}
	cleared := decodeBarkpark(t, `{"update_running_release":"1.4.2","update_latest_release":"1.5.0","autoupdate_triggered_at":null}`)
	if got := updateCell(cleared); got != "1.4.2 → 1.5.0" {
		t.Fatalf("a null marker must leave the verdict alone: updateCell = %q", got)
	}
}

// D103: the 5xx rate and its denominator travel together, in both renders.
func TestErr5xxCarriesItsDenominator(t *testing.T) {
	b := decodeBarkpark(t, `{"pressure":{"err_5xx_per_s":0.22,"req_per_s":1.53,"p95_ms":412}}`)
	if m := err5xxMarker(b); !strings.Contains(m, "0.22 5xx/s of 1.53 req/s") {
		t.Errorf("marker = %q, want the request rate beside the error rate", m)
	}
	if row := err5xxRow(b); row["req_per_s"] != 1.53 {
		t.Errorf("err5xxRow req_per_s = %v, want 1.53", row["req_per_s"])
	}
	// Unmeasured volume (nil, or the -1 sentinel) is null, never 0, and the
	// marker invents no volume clause.
	for _, raw := range []string{`{"pressure":{"err_5xx_per_s":0.22}}`, `{"pressure":{"err_5xx_per_s":0.22,"req_per_s":-1}}`} {
		nb := decodeBarkpark(t, raw)
		if row := err5xxRow(nb); row["req_per_s"] != nil {
			t.Errorf("%s: req_per_s = %v, want nil (unmeasured)", raw, row["req_per_s"])
		}
		if m := err5xxMarker(nb); strings.Contains(m, "req/s") {
			t.Errorf("%s: marker %q invents a volume the beat did not carry", raw, m)
		}
	}
}

// The `-o json` row carries every newly decoded fleet key, and the tri-states
// stay absent when the plane sent nothing.
func TestStatusRowCarriesClosedFleetKeys(t *testing.T) {
	b := decodeBarkpark(t, `{"id":"b1","name":"n","host":"h","region":"nbg1","server_type":"cax11",
		"unreachable_count":2,"unreachable_notification_sent":false,"autoupdate_triggered_at":"2026-09-25T10:00:00Z",
		"custom_host":"barkpark.example.com","pressure":{"p95_ms":412}}`)
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{b})[0])
	want := map[string]any{
		"region": "nbg1", "server_type": "cax11", "unreachable_count": 2,
		"unreachable_notification_sent": false, "autoupdate_triggered_at": "2026-09-25T10:00:00Z",
		"custom_host": "barkpark.example.com", "p95_ms": 412.0,
	}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("row[%q] = %#v, want %#v", k, row[k], v)
		}
	}

	bare := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{decodeBarkpark(t, `{"id":"b2","host":"h","pressure":{"p95_ms":-1}}`)})[0])
	for _, k := range []string{"unreachable_count", "autoupdate_triggered_at", "custom_host", "p95_ms"} {
		if v, ok := bare[k]; ok {
			t.Errorf("row emitted %q = %v for a plane that sent no reading", k, v)
		}
	}
}

// A preview deployment names ITS surface. The deployment's `url` is the site's
// production URL (deployment_url/3), so the receipt must not hand that over for
// a preview build.
func TestSiteLivePreviewNamesThePreviewSurface(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-p","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-p","site_id":"` + testSiteID + `","status":"live","stage":"RETIRE",` +
		`"environment":"preview","branch":"feat-x","preview_host":"feat-x--blog.acme.barkpark.cloud","preview_url":"https://feat-x--blog.acme.barkpark.cloud",` +
		`"url":"https://acme.barkpark.cloud/sites/blog/","stages":[{"name":"SWITCH","status":"done"},{"name":"RETIRE","status":"done"}]}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "preview live — https://feat-x--blog.acme.barkpark.cloud of branch feat-x") {
		t.Fatalf("the preview receipt must name the preview URL and branch:\n%s", stdout)
	}
	if strings.Contains(stdout, "site live — https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("a preview build must not be announced on the production URL:\n%s", stdout)
	}

	jout, _, jcode := runSite(t, "json", "deploy", testSiteID)
	if jcode != exitOK {
		t.Fatalf("json exit=%d", jcode)
	}
	var env struct {
		Deployment map[string]any `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(jout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, jout)
	}
	if env.Deployment["preview_host"] != "feat-x--blog.acme.barkpark.cloud" || env.Deployment["preview_url"] != "https://feat-x--blog.acme.barkpark.cloud" {
		t.Fatalf("-o json dropped the preview identity: %+v", env.Deployment)
	}
}
