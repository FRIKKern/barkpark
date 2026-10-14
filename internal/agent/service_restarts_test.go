package agent

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// task-9d72b5f86487cf9b: the agent half of "restarts that were not deploys".
//
// The fixtures are `journalctl -o json` lines in the shape systemd 255 writes
// for PID 1's unit messages: string values, __REALTIME_TIMESTAMP in
// microseconds, the catalog MESSAGE_ID and the structured EXIT_CODE,
// EXIT_STATUS, UNIT_RESULT and N_RESTARTS fields.

// An OOM kill of the blue slot, restarted by systemd, at 22:05:12 UTC on
// 2026-10-13 (1791929112 s).
const journalOOMRestart = `{"__REALTIME_TIMESTAMP":"1791929112000000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"fe6faa94e7774663a0da52717891d8ef","MESSAGE":"barkpark-slot@blue.service: A process of this unit has been killed by the OOM killer."}
{"__REALTIME_TIMESTAMP":"1791929112100000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"98e322203f7a4ed290d09fe03c09fe15","MESSAGE":"barkpark-slot@blue.service: Main process exited, code=killed, status=9/KILL","EXIT_CODE":"killed","EXIT_STATUS":"9"}
{"__REALTIME_TIMESTAMP":"1791929112200000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"d9b373ed55a64feb8242e02dbe79a49c","MESSAGE":"barkpark-slot@blue.service: Failed with result 'oom-kill'.","UNIT_RESULT":"oom-kill"}
{"__REALTIME_TIMESTAMP":"1791929117300000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"5eb03494b6584870a536b337290809b3","MESSAGE":"barkpark-slot@blue.service: Scheduled restart job, restart counter is at 1.","N_RESTARTS":"1"}
{"__REALTIME_TIMESTAMP":"1791929117400000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"Started barkpark-slot@blue.service - Barkpark content instance (slot blue)."}
`

// A deploy: instance-deploy.sh's `systemctl restart` of green, then `disable
// --now` of blue. Both are manual jobs, so no scheduled restart is logged.
const journalDeploy = `{"__REALTIME_TIMESTAMP":"1791929600000000","_PID":"1","UNIT":"barkpark-slot@green.service","MESSAGE":"Started barkpark-slot@green.service - Barkpark content instance (slot green).","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf"}
{"__REALTIME_TIMESTAMP":"1791929630000000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE":"Stopping barkpark-slot@blue.service - Barkpark content instance (slot blue)..."}
{"__REALTIME_TIMESTAMP":"1791929631000000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"98e322203f7a4ed290d09fe03c09fe15","MESSAGE":"barkpark-slot@blue.service: Main process exited, code=exited, status=143/n/a","EXIT_CODE":"exited","EXIT_STATUS":"143"}
{"__REALTIME_TIMESTAMP":"1791929631100000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"d9b373ed55a64feb8242e02dbe79a49c","MESSAGE":"barkpark-slot@blue.service: Failed with result 'exit-code'.","UNIT_RESULT":"exit-code"}
{"__REALTIME_TIMESTAMP":"1791929631200000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE":"Stopped barkpark-slot@blue.service - Barkpark content instance (slot blue)."}
`

// A plain crash of green with exit status 1, at 22:20:00 UTC, followed by its
// restart. Then a crash on legacy barkpark.service logged WITHOUT message ids
// or structured fields (an older systemd), read from the text alone.
const journalExitCrash = `{"__REALTIME_TIMESTAMP":"1791930000000000","_PID":"1","UNIT":"barkpark-slot@green.service","MESSAGE_ID":"98e322203f7a4ed290d09fe03c09fe15","MESSAGE":"barkpark-slot@green.service: Main process exited, code=exited, status=1/FAILURE","EXIT_CODE":"exited","EXIT_STATUS":"1"}
{"__REALTIME_TIMESTAMP":"1791930000100000","_PID":"1","UNIT":"barkpark-slot@green.service","MESSAGE_ID":"d9b373ed55a64feb8242e02dbe79a49c","MESSAGE":"barkpark-slot@green.service: Failed with result 'exit-code'.","UNIT_RESULT":"exit-code"}
{"__REALTIME_TIMESTAMP":"1791930005000000","_PID":"1","UNIT":"barkpark-slot@green.service","MESSAGE_ID":"5eb03494b6584870a536b337290809b3","MESSAGE":"barkpark-slot@green.service: Scheduled restart job, restart counter is at 2.","N_RESTARTS":"2"}
{"__REALTIME_TIMESTAMP":"1791930100000000","_PID":"1","UNIT":"barkpark.service","MESSAGE":"barkpark.service: Main process exited, code=dumped, status=11/SEGV"}
{"__REALTIME_TIMESTAMP":"1791930100100000","_PID":"1","UNIT":"barkpark.service","MESSAGE":"barkpark.service: Failed with result 'core-dump'."}
{"__REALTIME_TIMESTAMP":"1791930105000000","_PID":"1","UNIT":"barkpark.service","MESSAGE":"barkpark.service: Scheduled restart job, restart counter is at 7."}
`

func TestParseServiceRestartsOOMKill(t *testing.T) {
	got := parseServiceRestarts(journalOOMRestart)
	if len(got) != 1 {
		t.Fatalf("restarts = %d, want 1: %+v", len(got), got)
	}
	r := got[0]
	want := ServiceRestart{
		RestartedAt:    "2026-10-13T22:05:12Z",
		Unit:           "barkpark-slot@blue.service",
		ExitKind:       "killed",
		ExitStatus:     9,
		ExitSignal:     "KILL",
		Result:         "oom-kill",
		OOMKilled:      true,
		RestartCounter: 1,
	}
	if r != want {
		t.Fatalf("restart = %+v\nwant      %+v", r, want)
	}
}

func TestParseServiceRestartsIgnoresDeploy(t *testing.T) {
	if got := parseServiceRestarts(journalDeploy); len(got) != 0 {
		t.Fatalf("a deploy's manual restart counted as a crash: %+v", got)
	}
}

// The deploy's stop leaves exit status 143 pending on blue. A later crash of
// blue must carry its own exit, not the deploy's.
func TestParseServiceRestartsDeployExitDoesNotLeak(t *testing.T) {
	later := `{"__REALTIME_TIMESTAMP":"1791930600000000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"Started barkpark-slot@blue.service."}
{"__REALTIME_TIMESTAMP":"1791931200000000","_PID":"1","UNIT":"barkpark-slot@blue.service","MESSAGE_ID":"5eb03494b6584870a536b337290809b3","MESSAGE":"barkpark-slot@blue.service: Scheduled restart job, restart counter is at 1.","N_RESTARTS":"1"}
`
	got := parseServiceRestarts(journalDeploy + later)
	if len(got) != 1 {
		t.Fatalf("restarts = %d, want 1: %+v", len(got), got)
	}
	if got[0].ExitStatus != -1 || got[0].ExitKind != "" || got[0].Result != "" {
		t.Fatalf("the deploy's stop leaked into the crash: %+v", got[0])
	}
	if got[0].RestartedAt != "2026-10-13T22:40:00Z" {
		t.Fatalf("with no exit line the time is the scheduled-restart line's: %q", got[0].RestartedAt)
	}
}

func TestParseServiceRestartsExitCodeAndTextFallback(t *testing.T) {
	got := parseServiceRestarts(journalExitCrash)
	if len(got) != 2 {
		t.Fatalf("restarts = %d, want 2: %+v", len(got), got)
	}
	g := got[0]
	if g.Unit != "barkpark-slot@green.service" || g.ExitKind != "exited" || g.ExitStatus != 1 ||
		g.ExitSignal != "" || g.Result != "exit-code" || g.OOMKilled || g.RestartCounter != 2 ||
		g.RestartedAt != "2026-10-13T22:20:00Z" {
		t.Fatalf("green crash = %+v", g)
	}
	l := got[1]
	if l.Unit != "barkpark.service" || l.ExitKind != "dumped" || l.ExitStatus != 11 ||
		l.ExitSignal != "SEGV" || l.Result != "core-dump" || l.OOMKilled || l.RestartCounter != 7 {
		t.Fatalf("legacy text-only crash = %+v", l)
	}
}

func TestParseServiceRestartsSkipsNoise(t *testing.T) {
	out := "-- No entries --\n\nnot json\n{\"MESSAGE\":\"no unit\"}\n{\"UNIT\":\"x.service\",\"MESSAGE\":[1,2,3]}\n"
	if got := parseServiceRestarts(out); len(got) != 0 {
		t.Fatalf("noise parsed as restarts: %+v", got)
	}
}

// The journalctl argv selects only PID 1's lines for the three service units,
// over one hour, as JSON.
func TestServiceRestartsArgs(t *testing.T) {
	args := strings.Join(serviceRestartsArgs(), " ")
	for _, want := range []string{"-o json", "--since -3600s", "_PID=1",
		"UNIT=barkpark-slot@blue.service", "UNIT=barkpark-slot@green.service", "UNIT=barkpark.service", "--no-pager"} {
		if !strings.Contains(args, want) {
			t.Fatalf("argv %q lacks %q", args, want)
		}
	}
}

func TestServiceRestartsProbeCountsAllAndCapsList(t *testing.T) {
	var b strings.Builder
	// Seven restarts of blue, 12 minutes apart, the gyl pattern.
	for i := 0; i < 7; i++ {
		ts := int64(1791929112+i*720) * 1_000_000
		line, _ := json.Marshal(map[string]string{
			"__REALTIME_TIMESTAMP": itoa64(ts), "_PID": "1", "UNIT": "barkpark-slot@blue.service",
			"MESSAGE_ID": msgIDUnitRestartSchedule, "MESSAGE": "Scheduled restart job, restart counter is at " + itoa64(int64(i+1)) + ".",
			"N_RESTARTS": itoa64(int64(i + 1)),
		})
		b.Write(line)
		b.WriteByte('\n')
	}
	var gotName string
	var gotArgs []string
	probe := newServiceRestartsProbeWith(func(env []string, name string, args ...string) (string, error) {
		gotName, gotArgs = name, args
		return b.String(), nil
	})
	list, count, window, err := probe()
	if err != nil {
		t.Fatal(err)
	}
	if gotName != "journalctl" || len(gotArgs) == 0 {
		t.Fatalf("ran %q %v", gotName, gotArgs)
	}
	if count != 7 || window != 3600 {
		t.Fatalf("count=%d window=%d, want 7 and 3600", count, window)
	}
	if len(list) != restartsListLimit {
		t.Fatalf("list = %d rows, want the cap %d", len(list), restartsListLimit)
	}
	if list[0].RestartCounter != 7 || list[4].RestartCounter != 3 {
		t.Fatalf("list is not newest first: %+v", list)
	}
}

func TestServiceRestartsProbeErrorIsUnmeasured(t *testing.T) {
	probe := newServiceRestartsProbeWith(func(env []string, name string, args ...string) (string, error) {
		return "Failed to open journal", errors.New("exit status 1")
	})
	list, count, window, err := probe()
	if err == nil || list != nil || count != -1 || window != -1 {
		t.Fatalf("a failed journalctl must be unmeasured: %v %d %d %v", list, count, window, err)
	}
}

// The beat carries null and -1 when the probe is unwired or fails, and an
// empty list with a measured 0 when the box had no restarts.
func TestReportServiceRestartsThreeStates(t *testing.T) {
	cases := []struct {
		name      string
		probe     func() ([]ServiceRestart, int, int, error)
		wantList  string
		wantCount int
	}{
		{"unwired", nil, "null", -1},
		{"failed", func() ([]ServiceRestart, int, int, error) { return nil, -1, -1, errors.New("x") }, "null", -1},
		{"quiet", func() ([]ServiceRestart, int, int, error) { return nil, 0, 3600, nil }, "[]", 0},
		{"restarting", func() ([]ServiceRestart, int, int, error) {
			return []ServiceRestart{{RestartedAt: "2026-10-13T22:05:12Z", Unit: "barkpark-slot@blue.service", ExitKind: "killed", ExitStatus: 9, ExitSignal: "KILL", Result: "oom-kill", OOMKilled: true, RestartCounter: 1}}, 5, 3600, nil
		}, "", 5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := gatherReport(ReportConfig{ServiceRestartsProbe: tc.probe})
			raw, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			var m map[string]json.RawMessage
			if err := json.Unmarshal(raw, &m); err != nil {
				t.Fatal(err)
			}
			if tc.wantList != "" && string(m["service_restarts"]) != tc.wantList {
				t.Fatalf("service_restarts = %s, want %s", m["service_restarts"], tc.wantList)
			}
			if string(m["service_restarts_count"]) != itoa64(int64(tc.wantCount)) {
				t.Fatalf("service_restarts_count = %s, want %d", m["service_restarts_count"], tc.wantCount)
			}
			if tc.name == "restarting" {
				if !strings.Contains(string(m["service_restarts"]), `"oom_killed":true`) ||
					string(m["service_restarts_window_s"]) != "3600" {
					t.Fatalf("row did not reach the wire: %s", raw)
				}
			}
		})
	}
}

func itoa64(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
