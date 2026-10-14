package agent

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Service restarts that were NOT deploys (task-9d72b5f86487cf9b).
//
// On 2026-10-13 the managed box gyl restarted its Barkpark service about every
// 12 minutes after a 21:53 deploy, each time with about 30 s of 503, and every
// operator surface read `ok`. The slot_units probe could not see it: a unit
// that crashed and was restarted by systemd 5 s later reads `active/running`
// with Result=success on the next 60 s beat, because systemd resets the main
// process status when it starts the new one.
//
// The journal keeps what the beat misses. When systemd restarts a unit on its
// own (Restart=on-failure), PID 1 logs this sequence under UNIT=<unit>:
//
//	Main process exited, code=killed, status=9/KILL         (EXIT_CODE, EXIT_STATUS)
//	A process of this unit has been killed by the OOM killer.  (only on OOM)
//	Failed with result 'oom-kill'.                          (UNIT_RESULT)
//	Scheduled restart job, restart counter is at 3.         (N_RESTARTS)
//
// A deploy never logs "Scheduled restart job". deploy/instance-deploy.sh moves
// traffic with `systemctl restart` and `systemctl disable --now`, which are
// manual jobs: systemd logs Stopping/Stopped/Started for them and schedules no
// automatic restart. So the scheduled-restart line is the marker that separates
// a crash restart from a deploy restart, and no deploy record has to be joined.
//
// The probe is stateless. Each beat reads the last restartWindow of PID 1's own
// messages for the service units and reports every automatic restart in it.

// ServiceRestart is ONE automatic restart of a Barkpark service unit that
// systemd scheduled after the main process died.
type ServiceRestart struct {
	// RestartedAt is when the main process died (the exit line), in RFC 3339
	// UTC. When the exit line is outside the window, it is the time of the
	// scheduled-restart line instead.
	RestartedAt string `json:"restarted_at"`
	// Unit is systemd's UNIT= field, e.g. barkpark-slot@blue.service.
	Unit string `json:"unit"`
	// ExitKind is systemd's EXIT_CODE word: exited, killed or dumped. Empty
	// when no exit line was found.
	ExitKind string `json:"exit_kind"`
	// ExitStatus is the exit code when ExitKind is exited, and the signal
	// number when it is killed or dumped. -1 when unknown.
	ExitStatus int `json:"exit_status"`
	// ExitSignal is the signal name without the SIG prefix (KILL, TERM, SEGV)
	// when the process died on a signal. Empty otherwise.
	ExitSignal string `json:"exit_signal"`
	// Result is systemd's UNIT_RESULT word: exit-code, signal, core-dump,
	// oom-kill, watchdog, timeout. Empty when no result line was found.
	Result string `json:"result"`
	// OOMKilled is true when systemd reported that the kernel OOM killer
	// killed a process of the unit, or the unit failed with result oom-kill.
	OOMKilled bool `json:"oom_killed"`
	// RestartCounter is systemd's N_RESTARTS after this restart. -1 when the
	// line did not carry it.
	RestartCounter int `json:"restart_counter"`
}

// restartWindow is how far back each beat reads. One hour matches the
// attention threshold the CLI applies (more than 3 restarts in the window).
const restartWindow = time.Hour

// restartsListLimit caps the rows on the beat. The count is never capped, so
// a short list still says how many restarts there were.
const restartsListLimit = 5

// restartUnitNames are the units whose restarts take the service down. The
// blue/green pair is the current layout; barkpark.service is the legacy
// single unit some boxes still run.
var restartUnitNames = []string{
	"barkpark-slot@blue.service",
	"barkpark-slot@green.service",
	"barkpark.service",
}

// serviceRestartsProbeTimeout bounds the journalctl call. The match is on
// indexed fields (_PID, UNIT) over one hour, which reads a few lines.
var serviceRestartsProbeTimeout = 5 * time.Second

// systemd catalog message ids (sd-messages.h). The MESSAGE text is matched as
// well, so an older systemd that logs the line without the id still counts.
const (
	msgIDUnitProcessExit     = "98e322203f7a4ed290d09fe03c09fe15"
	msgIDUnitOutOfMemory     = "fe6faa94e7774663a0da52717891d8ef"
	msgIDUnitFailureResult   = "d9b373ed55a64feb8242e02dbe79a49c"
	msgIDUnitRestartSchedule = "5eb03494b6584870a536b337290809b3"
	msgIDUnitStarted         = "39f53479d3a045ac8e11786248231fbf"
)

// serviceRestartsArgs is the journalctl argv. `_PID=1` with the UNIT= matches
// selects only systemd's own lines about these units (different fields are
// ANDed, the same field is ORed), so the service's own stdout never reaches
// the agent. DIRECT argv, no shell.
func serviceRestartsArgs() []string {
	args := []string{"--no-pager", "-q", "-o", "json",
		"--output-fields=MESSAGE,MESSAGE_ID,UNIT,EXIT_CODE,EXIT_STATUS,UNIT_RESULT,N_RESTARTS",
		"--since", "-" + strconv.Itoa(int(restartWindow/time.Second)) + "s",
		"_PID=1"}
	for _, u := range restartUnitNames {
		args = append(args, "UNIT="+u)
	}
	return args
}

// NewServiceRestartsProbe builds the production probe: one bounded journalctl
// call per beat. It returns the newest restarts first (capped), the full count
// and the window in seconds. A journalctl that fails is an error, so the beat
// carries null (unmeasured) rather than an empty list that reads "no restarts".
func NewServiceRestartsProbe() func() ([]ServiceRestart, int, int, error) {
	return newServiceRestartsProbeWith(boundedSpaceRunner(serviceRestartsProbeTimeout))
}

func newServiceRestartsProbeWith(run probeRunner) func() ([]ServiceRestart, int, int, error) {
	return func() ([]ServiceRestart, int, int, error) {
		out, err := run(nil, "journalctl", serviceRestartsArgs()...)
		if err != nil {
			return nil, -1, -1, fmt.Errorf("journalctl: %w: %s", err, truncate(strings.TrimSpace(out), 120))
		}
		all := parseServiceRestarts(out)
		count := len(all)
		// Newest first, so the cap keeps the restarts an operator asks about.
		sort.SliceStable(all, func(i, j int) bool { return all[i].RestartedAt > all[j].RestartedAt })
		if len(all) > restartsListLimit {
			all = all[:restartsListLimit]
		}
		return all, count, int(restartWindow / time.Second), nil
	}
}

// journalEntry is one `journalctl -o json` line. Values are strings in the
// export format; a field that held binary data arrives as an array and is
// decoded as empty by journalString.
type journalEntry map[string]json.RawMessage

func journalString(e journalEntry, key string) string {
	raw, ok := e[key]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}

// pendingExit is what has been seen for one unit since its last start.
type pendingExit struct {
	at     string
	kind   string
	status int
	signal string
	result string
	oom    bool
}

// parseServiceRestarts reads `journalctl -o json` output in journal order and
// returns one ServiceRestart per "Scheduled restart job" line. The exit, OOM
// and result lines before it are attached to it. A "Started" line clears what
// was pending for that unit, so the exit status of a deploy's stop never leaks
// into a later crash. Lines that are not JSON are skipped.
func parseServiceRestarts(out string) []ServiceRestart {
	var restarts []ServiceRestart
	pending := map[string]*pendingExit{}
	get := func(unit string) *pendingExit {
		p := pending[unit]
		if p == nil {
			p = &pendingExit{status: -1}
			pending[unit] = p
		}
		return p
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] != '{' {
			continue
		}
		var e journalEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			continue
		}
		unit := journalString(e, "UNIT")
		if unit == "" {
			continue
		}
		// systemd prefixes most unit lines with "<unit>: ". "Started" lines
		// carry no prefix.
		msg := strings.TrimPrefix(journalString(e, "MESSAGE"), unit+": ")
		id := journalString(e, "MESSAGE_ID")
		at := journalTime(journalString(e, "__REALTIME_TIMESTAMP"))

		switch {
		case id == msgIDUnitRestartSchedule || strings.HasPrefix(msg, "Scheduled restart job"):
			p := get(unit)
			r := ServiceRestart{
				RestartedAt:    p.at,
				Unit:           unit,
				ExitKind:       p.kind,
				ExitStatus:     p.status,
				ExitSignal:     p.signal,
				Result:         p.result,
				OOMKilled:      p.oom || p.result == "oom-kill",
				RestartCounter: restartCounter(journalString(e, "N_RESTARTS"), msg),
			}
			if r.RestartedAt == "" {
				r.RestartedAt = at
			}
			restarts = append(restarts, r)
			delete(pending, unit)
		case id == msgIDUnitStarted || strings.HasPrefix(msg, "Started "):
			delete(pending, unit)
		case id == msgIDUnitProcessExit || strings.HasPrefix(msg, "Main process exited"):
			p := get(unit)
			p.at = at
			p.kind, p.status, p.signal = exitFrom(journalString(e, "EXIT_CODE"), journalString(e, "EXIT_STATUS"), msg)
		case id == msgIDUnitOutOfMemory || strings.Contains(msg, "killed by the OOM killer"):
			p := get(unit)
			p.oom = true
			if p.at == "" {
				p.at = at
			}
		case id == msgIDUnitFailureResult || strings.HasPrefix(msg, "Failed with result"):
			p := get(unit)
			p.result = journalString(e, "UNIT_RESULT")
			if p.result == "" {
				p.result = quotedResult(msg)
			}
			if p.at == "" {
				p.at = at
			}
		}
	}
	return restarts
}

// journalTime turns __REALTIME_TIMESTAMP (microseconds since the epoch, as a
// decimal string) into RFC 3339 UTC. Empty when unreadable.
func journalTime(us string) string {
	n, err := strconv.ParseInt(strings.TrimSpace(us), 10, 64)
	if err != nil || n <= 0 {
		return ""
	}
	return time.UnixMicro(n).UTC().Format(time.RFC3339)
}

// exitFrom reads the exit kind, status and signal from the structured fields,
// falling back to the message text "code=killed, status=9/KILL".
func exitFrom(code, status, msg string) (kind string, st int, signal string) {
	kind = strings.TrimSpace(code)
	st = -1
	if n, err := strconv.Atoi(strings.TrimSpace(status)); err == nil {
		st = n
	}
	if i := strings.Index(msg, "code="); i >= 0 && kind == "" {
		rest := msg[i+len("code="):]
		if j := strings.IndexAny(rest, ", "); j >= 0 {
			rest = rest[:j]
		}
		kind = rest
	}
	// The text form carries the name: status=9/KILL or status=1/FAILURE.
	var name string
	if i := strings.Index(msg, "status="); i >= 0 {
		rest := msg[i+len("status="):]
		if j := strings.IndexAny(rest, ", "); j >= 0 {
			rest = rest[:j]
		}
		num, nm, _ := strings.Cut(rest, "/")
		if st < 0 {
			if n, err := strconv.Atoi(num); err == nil {
				st = n
			}
		}
		name = nm
	}
	if kind == "killed" || kind == "dumped" {
		signal = strings.TrimPrefix(name, "SIG")
		if signal == "" {
			signal = signalName(st)
		}
	}
	return kind, st, signal
}

// signalName names the signals a crashed BEAM dies on. Others stay numeric in
// ExitStatus and leave the name empty.
func signalName(n int) string {
	switch n {
	case 1:
		return "HUP"
	case 2:
		return "INT"
	case 6:
		return "ABRT"
	case 9:
		return "KILL"
	case 11:
		return "SEGV"
	case 15:
		return "TERM"
	}
	return ""
}

// quotedResult reads oom-kill out of "Failed with result 'oom-kill'.".
func quotedResult(msg string) string {
	i := strings.Index(msg, "'")
	if i < 0 {
		return ""
	}
	rest := msg[i+1:]
	j := strings.Index(rest, "'")
	if j < 0 {
		return ""
	}
	return rest[:j]
}

// restartCounter reads N_RESTARTS, or the number at the end of "restart
// counter is at 3.". -1 when neither is readable.
func restartCounter(field, msg string) int {
	if n, err := strconv.Atoi(strings.TrimSpace(field)); err == nil {
		return n
	}
	if i := strings.LastIndex(msg, " at "); i >= 0 {
		s := strings.TrimSuffix(strings.TrimSpace(msg[i+4:]), ".")
		if n, err := strconv.Atoi(s); err == nil {
			return n
		}
	}
	return -1
}
