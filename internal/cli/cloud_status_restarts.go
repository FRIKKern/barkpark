package cli

import (
	"fmt"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// Service restarts that were not deploys (task-9d72b5f86487cf9b).
//
// The agent reads PID 1's journal lines for the Barkpark service units every
// beat and reports each automatic restart systemd made in the last hour. A
// deploy restart is a manual job and is never in the list. On 2026-10-13 gyl
// restarted about every 12 minutes after a deploy, each time with about 30 s
// of 503, and this screen read `ok` with an empty detail.

// restartingThreshold is the most automatic restarts a box may make in the
// agent's window (one hour) and stay out of the attention bucket. Three an
// hour covers a one-off crash and its retry. gyl's pattern, one every 12
// minutes, is five an hour and fires the rung.
const restartingThreshold = 3

// serviceRestartCount returns the restart count the agent measured and the
// window it covers in seconds. ok is false when the box did not measure it
// (an agent predating the probe, or a journalctl that failed).
func serviceRestartCount(b cloudclient.Barkpark) (count int, windowS float64, ok bool) {
	p := b.Pressure
	if p == nil || p.ServiceRestartsCount == nil {
		return 0, 0, false
	}
	if p.ServiceRestartsWindowS != nil {
		windowS = *p.ServiceRestartsWindowS
	}
	return int(*p.ServiceRestartsCount), windowS, true
}

// restarting is the rung predicate: more than restartingThreshold automatic
// restarts in the window. An unmeasured box never fires it.
func restarting(b cloudclient.Barkpark) bool {
	n, _, ok := serviceRestartCount(b)
	return ok && n > restartingThreshold
}

// restartMarker is the detail-line sentence, on any row with at least one
// automatic restart in the window, including an `ok` row below the threshold:
//
//	restarted 5x in 1h, last 22:53 UTC on blue: killed by SIGKILL, OOM kill
//
// It is "" for a box with no restarts and for an unmeasured box. `-o json`
// tells those two apart (serviceRestartsRow).
func restartMarker(b cloudclient.Barkpark) string {
	n, windowS, ok := serviceRestartCount(b)
	if !ok || n <= 0 {
		return ""
	}
	s := fmt.Sprintf("restarted %dx", n)
	if windowS > 0 {
		s += " in " + restartWindowPhrase(windowS)
	}
	if rs := b.Pressure.ServiceRestarts; len(rs) > 0 {
		last := rs[0]
		s += ", last " + restartClock(last.RestartedAt)
		if unit := restartUnitShort(last.Unit); unit != "" {
			s += " on " + unit
		}
		if reason := restartReason(last); reason != "" {
			s += ": " + reason
		}
	}
	return s
}

// restartWindowPhrase says 3600 as "1h" and 1800 as "30m".
func restartWindowPhrase(seconds float64) string {
	d := time.Duration(seconds) * time.Second
	if d%time.Hour == 0 {
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	return fmt.Sprintf("%dm", int(d/time.Minute))
}

// restartClock renders an RFC 3339 time as "22:53 UTC", or verbatim when it
// does not parse.
func restartClock(at string) string {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(at))
	if err != nil {
		return at
	}
	return t.UTC().Format("15:04 UTC")
}

// restartUnitShort says "blue" for barkpark-slot@blue.service and "barkpark"
// for the legacy barkpark.service.
func restartUnitShort(unit string) string {
	name := strings.TrimSuffix(strings.TrimSpace(unit), ".service")
	if i := strings.Index(name, "@"); i >= 0 {
		return name[i+1:]
	}
	return name
}

// restartReason names how the main process died: the signal or the exit
// code, then an OOM mark when the kernel killed it. systemd's result word is
// added only when the exit is unknown, since "killed by SIGKILL" already says
// what "signal" would.
func restartReason(r cloudclient.ServiceRestart) string {
	parts := make([]string, 0, 2)
	kind := ""
	if r.ExitKind != nil {
		kind = *r.ExitKind
	}
	switch {
	case (kind == "killed" || kind == "dumped") && r.ExitSignal != nil && *r.ExitSignal != "":
		s := "killed by SIG" + *r.ExitSignal
		if kind == "dumped" {
			s += " (core dumped)"
		}
		parts = append(parts, s)
	case (kind == "killed" || kind == "dumped") && r.ExitStatus != nil:
		parts = append(parts, fmt.Sprintf("killed by signal %d", int(*r.ExitStatus)))
	case kind == "exited" && r.ExitStatus != nil:
		parts = append(parts, fmt.Sprintf("exit code %d", int(*r.ExitStatus)))
	case r.Result != nil && *r.Result != "" && *r.Result != "oom-kill":
		parts = append(parts, *r.Result)
	}
	if r.OOMKilled {
		parts = append(parts, "OOM kill")
	}
	return strings.Join(parts, ", ")
}

// serviceRestartsRow is the `-o json` projection. nil (the key is left out)
// when the box did not measure restarts; otherwise the count, the window and
// every row the control plane sent.
func serviceRestartsRow(b cloudclient.Barkpark) map[string]any {
	n, windowS, ok := serviceRestartCount(b)
	if !ok {
		return nil
	}
	rows := make([]any, 0, len(b.Pressure.ServiceRestarts))
	for _, r := range b.Pressure.ServiceRestarts {
		row := map[string]any{
			"unit":         r.Unit,
			"restarted_at": r.RestartedAt,
			"oom_killed":   r.OOMKilled,
		}
		if r.ExitKind != nil {
			row["exit_kind"] = *r.ExitKind
		}
		if r.ExitStatus != nil {
			row["exit_status"] = int(*r.ExitStatus)
		}
		if r.ExitSignal != nil {
			row["exit_signal"] = *r.ExitSignal
		}
		if r.Result != nil {
			row["result"] = *r.Result
		}
		if r.RestartCounter != nil {
			row["restart_counter"] = int(*r.RestartCounter)
		}
		rows = append(rows, row)
	}
	return map[string]any{
		"count":     n,
		"window_s":  int(windowS),
		"threshold": restartingThreshold,
		"recent":    rows,
	}
}
