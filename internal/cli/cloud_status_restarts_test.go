package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// task-9d72b5f86487cf9b: gyl on 2026-10-13 as a fleet row. The service
// restarted about every 12 minutes after a 21:53 deploy; the agent's hour
// window holds five automatic restarts, the newest an OOM kill.
const gylRestartingRow = `{
  "id": "bp-gyl", "name": "gyl", "slug": "gyl", "host": "10.0.0.9",
  "url": "https://gyl.barkpark.cloud",
  "health_status": "up", "agent_status": "online", "update_state": "current",
  "last_seen_at": "2026-10-13T23:00:00Z", "queued_deploy_age_seconds": null,
  "pressure": {
    "service_restarts_count": 5,
    "service_restarts_window_s": 3600,
    "service_restarts": [
      {"unit": "barkpark-slot@blue.service", "restarted_at": "2026-10-13T22:53:12Z",
       "exit_kind": "killed", "exit_status": 9, "exit_signal": "KILL",
       "result": "oom-kill", "oom_killed": true, "restart_counter": 5},
      {"unit": "barkpark-slot@blue.service", "restarted_at": "2026-10-13T22:41:00Z",
       "exit_kind": "exited", "exit_status": 1, "exit_signal": null,
       "result": "exit-code", "oom_killed": false, "restart_counter": 4}
    ],
    "reported_at": "2026-10-13T23:00:00Z"
  }
}`

func decodeRow(t *testing.T, raw string) cloudclient.Barkpark {
	t.Helper()
	var b cloudclient.Barkpark
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return b
}

func withRestartCount(t *testing.T, n float64) cloudclient.Barkpark {
	b := decodeRow(t, gylRestartingRow)
	b.Pressure.ServiceRestartsCount = &n
	return b
}

// Five restarts in the hour puts the box in ATTENTION with the count, the
// last time, the unit and the reason on the detail line.
func TestRestartingRungFiresOverThreshold(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{decodeRow(t, gylRestartingRow)})
	r := ranked[0]
	if r.Status != "restarting" || r.Bucket != "attention" || r.Rank != 5 {
		t.Fatalf("status/bucket/rank = %s/%s/%d, want restarting/attention/5", r.Status, r.Bucket, r.Rank)
	}
	want := "restarted 5x in 1h, last 22:53 UTC on blue: killed by SIGKILL, OOM kill"
	if !strings.Contains(r.Detail, want) {
		t.Fatalf("detail = %q, want it to contain %q", r.Detail, want)
	}
}

// Three restarts is the threshold and stays ok, but the detail still says it
// restarted. One restart says so too. Zero says nothing.
func TestRestartMarkerBelowThreshold(t *testing.T) {
	for _, tc := range []struct {
		n          float64
		wantStatus string
		wantDetail string
	}{
		{4, "restarting", "restarted 4x in 1h"},
		{3, "ok", "restarted 3x in 1h, last 22:53 UTC on blue"},
		{1, "ok", "restarted 1x in 1h"},
		{0, "ok", ""},
	} {
		r := rankBarkparks([]cloudclient.Barkpark{withRestartCount(t, tc.n)})[0]
		if r.Status != tc.wantStatus {
			t.Fatalf("n=%v status = %q, want %q", tc.n, r.Status, tc.wantStatus)
		}
		if tc.wantDetail == "" {
			if strings.Contains(r.Detail, "restarted") {
				t.Fatalf("n=0 rendered a restart: %q", r.Detail)
			}
			continue
		}
		if !strings.Contains(r.Detail, tc.wantDetail) {
			t.Fatalf("n=%v detail = %q, want %q", tc.n, r.Detail, tc.wantDetail)
		}
	}
}

// An unmeasured box (an agent predating the probe) never fires and never
// renders a restart sentence, and its -o json row carries no key.
func TestRestartUnmeasuredIsSilent(t *testing.T) {
	b := decodeRow(t, gylRestartingRow)
	b.Pressure.ServiceRestartsCount = nil
	b.Pressure.ServiceRestarts = nil
	r := rankBarkparks([]cloudclient.Barkpark{b})[0]
	if r.Status != "ok" || strings.Contains(r.Detail, "restarted") {
		t.Fatalf("unmeasured box: status %q detail %q", r.Status, r.Detail)
	}
	if _, present := rankedBarkparkRow(r)["service_restarts"]; present {
		t.Fatalf("unmeasured box emitted service_restarts in -o json")
	}
}

func TestRestartReasonWording(t *testing.T) {
	s := func(v string) *string { return &v }
	f := func(v float64) *float64 { return &v }
	for _, tc := range []struct {
		r    cloudclient.ServiceRestart
		want string
	}{
		{cloudclient.ServiceRestart{ExitKind: s("killed"), ExitStatus: f(9), ExitSignal: s("KILL"), Result: s("oom-kill"), OOMKilled: true}, "killed by SIGKILL, OOM kill"},
		{cloudclient.ServiceRestart{ExitKind: s("exited"), ExitStatus: f(1), Result: s("exit-code")}, "exit code 1"},
		{cloudclient.ServiceRestart{ExitKind: s("dumped"), ExitStatus: f(11), ExitSignal: s("SEGV")}, "killed by SIGSEGV (core dumped)"},
		{cloudclient.ServiceRestart{ExitKind: s("killed"), ExitStatus: f(31)}, "killed by signal 31"},
		{cloudclient.ServiceRestart{Result: s("watchdog")}, "watchdog"},
		{cloudclient.ServiceRestart{Result: s("oom-kill"), OOMKilled: true}, "OOM kill"},
		{cloudclient.ServiceRestart{}, ""},
	} {
		if got := restartReason(tc.r); got != tc.want {
			t.Errorf("restartReason(%+v) = %q, want %q", tc.r, got, tc.want)
		}
	}
}

// The table shows the row in the ATTENTION bucket with the sentence, and
// -o json carries the count, window, threshold and every row.
func TestCloudStatusRendersRestarts(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{decodeRow(t, gylRestartingRow)})
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderStatusBucket(w, "ATTENTION", "attention", ranked)
	got := stdout.String()
	for _, want := range []string{"ATTENTION", "gyl", "restarting", "restarted 5x in 1h", "OOM kill"} {
		if !strings.Contains(got, want) {
			t.Fatalf("table is missing %q:\n%s", want, got)
		}
	}

	row := rankedBarkparkRow(ranked[0])
	raw, err := json.Marshal(row["service_restarts"])
	if err != nil {
		t.Fatal(err)
	}
	var sr struct {
		Count     int              `json:"count"`
		WindowS   int              `json:"window_s"`
		Threshold int              `json:"threshold"`
		Recent    []map[string]any `json:"recent"`
	}
	if err := json.Unmarshal(raw, &sr); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	if sr.Count != 5 || sr.WindowS != 3600 || sr.Threshold != restartingThreshold || len(sr.Recent) != 2 {
		t.Fatalf("service_restarts = %s", raw)
	}
	if sr.Recent[0]["oom_killed"] != true || sr.Recent[0]["exit_signal"] != "KILL" || sr.Recent[1]["exit_status"] != float64(1) {
		t.Fatalf("rows lost their fields: %s", raw)
	}
}
