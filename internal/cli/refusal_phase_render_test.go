package cli

// refusal_phase_render_test.go is the READER half of
// dr-w15-s3-followup-decode-refusal-phase, proved the way the row demands: by a
// RUN THROUGH THE CLI against a fake control plane, not by calling
// `siteDeploymentMap` with a hand-built struct.
//
// The distinction matters because the defect was never in the map. The key was
// emitted by `deployment_json/1` for a whole wave, `SiteDeployment` declared no
// json tag for it, `json.Unmarshal` dropped it in silence, and every map-level
// assertion in this package would have kept passing. Only a run that puts the
// producer's own bytes on a socket and reads what `bp cloud site status -o json`
// prints can see the whole chain — wire -> decoder -> envelope.
//
// HONEST LIMIT, carried from the producer so nothing here implies more: this is
// a TRIPWIRE for the first poll refusal, not a live discriminator. cloud-db-1
// holds ZERO poll-phase rows all-time against 14,848 start-phase ones, so the
// "poll" fixture below is a shape the corpus has never contained. No taxonomy
// splits on this key and no human line is derived from it.

import (
	"encoding/json"
	"testing"
)

// siteStatusDeploymentEnvelope runs the real `status` command at `-o json`
// against the fake and returns the `deployment` object as a raw map — a map and
// not a typed struct on purpose, because the property under test is whether a
// KEY IS PRESENT AT ALL, and a typed field cannot tell an absent key from a
// zero value. That is the exact confusion the assertions below exist to refuse.
func siteStatusDeploymentEnvelope(t *testing.T) map[string]any {
	t.Helper()
	stdout, stderr, code := runSite(t, "json", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	var env struct {
		Deployment map[string]any `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("status -o json is not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment == nil {
		t.Fatalf("status -o json carried no deployment object:\n%s", stdout)
	}
	return env.Deployment
}

// siteWithDeployment seeds the fake's GET /v1/sites/:id with a site whose
// current_deployment is the raw JSON handed in — the producer's bytes, verbatim,
// so the fixture is the wire and not a Go struct's idea of it.
func siteWithDeployment(t *testing.T, deployment string) *siteCP {
	t.Helper()
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID +
		`","name":"blog","slug":"blog","kind":"static","framework":"astro",` +
		`"workspace":"acme","project":"blog","dataset":"production",` +
		`"url":"https://acme.barkpark.cloud/sites/blog/",` +
		`"current_deployment":` + deployment + `}}`}
	cp.serve()
	return cp
}

// TestRunCloudSiteStatusSurfacesRefusalPhase is the RED-when-reverted arm. Drop
// the `json:"refusal_phase"` tag from SiteDeployment, or the emit from
// siteDeploymentMap, and both subtests below fail: the key vanishes from the
// envelope entirely.
func TestRunCloudSiteStatusSurfacesRefusalPhase(t *testing.T) {
	t.Run("poll — a build already running was killed", func(t *testing.T) {
		siteWithDeployment(t, `{"id":"dep-poll","status":"failed","stage":"BUILD",`+
			`"failure_reason":"the instance refused the deploy (HTTP 500): boom",`+
			`"failure_class":"BOX_TRANSPORT","refusal_phase":"poll"}`)
		dep := siteStatusDeploymentEnvelope(t)
		if got, ok := dep["refusal_phase"]; !ok || got != "poll" {
			t.Fatalf("deployment.refusal_phase = %v (present=%v), want poll — the "+
				"control plane sent it and the CLI must carry it: %+v", got, ok, dep)
		}
	})

	t.Run("start — the trigger was refused, no build began", func(t *testing.T) {
		siteWithDeployment(t, `{"id":"dep-start","status":"failed","stage":"PLAN",`+
			`"failure_reason":"the instance refused the deploy (HTTP 503): no runner available",`+
			`"failure_class":"BOX_TRANSPORT","refusal_phase":"start"}`)
		dep := siteStatusDeploymentEnvelope(t)
		if got, ok := dep["refusal_phase"]; !ok || got != "start" {
			t.Fatalf("deployment.refusal_phase = %v (present=%v), want start: %+v", got, ok, dep)
		}
	})
}

// TestRunCloudSiteStatusAbsentRefusalPhaseStaysAbsent is the row's SECOND
// criterion, and it is the QUIET arm: it passes both before and after this
// slice, because absence was already the honest answer and this change must not
// disturb it. What it refuses is the coercion the producer's own comment spends
// a paragraph forbidding — writing "start" for a row that records no refusal.
//
// Three fixtures, because the producer can leave the key in three different
// states and all three mean the same thing to a reader:
//
//   - explicit null — a FAILED row that was never a box refusal (the ~14,000-row
//     majority: a build that died in BUILD, a health gate that failed);
//   - key absent — a row written before the W15 S3 producer slice landed;
//   - empty string — a value the producer sent with no phase in it.
//
// NOT VACUOUS. The first fixture asserts a NEIGHBOURING key IS present, so a
// mutation that broke the run, the fake, or the envelope shape outright would
// red here rather than sliding through as a satisfying "key absent".
func TestRunCloudSiteStatusAbsentRefusalPhaseStaysAbsent(t *testing.T) {
	cases := map[string]string{
		"explicit null on a failed row that was never a refusal": `{"id":"dep-null",` +
			`"status":"failed","stage":"BUILD",` +
			`"failure_reason":"BUILD failed (exit 12): boom",` +
			`"failure_class":"BUILD_COMMAND_FAILED","refusal_phase":null}`,
		"a pre-W15-S3 row that carries no such key": `{"id":"dep-old",` +
			`"status":"failed","stage":"BUILD",` +
			`"failure_reason":"BUILD failed (exit 12): boom",` +
			`"failure_class":"BUILD_COMMAND_FAILED"}`,
		"an empty string is no phase to print": `{"id":"dep-empty",` +
			`"status":"failed","stage":"BUILD",` +
			`"failure_reason":"BUILD failed (exit 12): boom",` +
			`"failure_class":"BUILD_COMMAND_FAILED","refusal_phase":""}`,
		"a LIVE row acquires no refusal at all": `{"id":"dep-live",` +
			`"status":"live","stage":"RETIRE","failure_class":""}`,
	}

	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			siteWithDeployment(t, body)
			dep := siteStatusDeploymentEnvelope(t)
			if got, ok := dep["refusal_phase"]; ok {
				t.Fatalf("a row with no box refusal must render the phase as ABSENT, "+
					"got %q — %q and \"we did not measure a phase\" are different "+
					"sentences and the producer refuses to conflate them: %+v",
					got, got, dep)
			}
		})
	}

	// THE CONTROL for the arm above. An absence assertion proves nothing unless
	// the envelope it read was actually populated — a broken run, a fake that
	// never answered, or an envelope that lost its deployment object would all
	// produce a clean "key absent" and a green test that measured nothing.
	// The failed fixture carries `failure_class`, so assert THAT arrived.
	siteWithDeployment(t, `{"id":"dep-null","status":"failed","stage":"BUILD",`+
		`"failure_reason":"BUILD failed (exit 12): boom",`+
		`"failure_class":"BUILD_COMMAND_FAILED","refusal_phase":null}`)
	dep := siteStatusDeploymentEnvelope(t)
	if got := dep["failure_class"]; got != "BUILD_COMMAND_FAILED" {
		t.Fatalf("CONTROL FAILED: the envelope this test reads its absences out of "+
			"is not carrying the keys the fake sent (failure_class = %v), so every "+
			"\"key absent\" verdict above measured nothing: %+v", got, dep)
	}
}
