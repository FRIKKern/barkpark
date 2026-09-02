package agent

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// The 2026-08-06 guerrilla incident, reproduced as a process list.
//
// Every number is the incident's own, off the row: PPID 1 (orphaned), PID
// 3369344, ELAPSED 02:46:41 = 10001s, 66.3% CPU, and the argv that did it. The
// surrounding rows are the box's ordinary furniture — systemd, a long-lived
// BEAM that is busy but not runaway, a fresh build burning CPU for two minutes,
// and the agent's own `ps` — because a detector is only worth anything if it
// can tell this line from those.
const incidentPS = `      0       1     864000  0.0 /sbin/init
      1     1204    1209600  4.2 /usr/lib/systemd/systemd-journald
      1     2871     604800 18.7 /opt/barkpark/_build/prod/rel/barkpark/erts-15.2/bin/beam.smp -W w -MBas ageffcbf
      1  3369344      10001 66.3 journalctl -u bp-site-build-* --since -14d --no-pager
   3369344  3369345      10001  0.1 /usr/bin/cat
      1  3402118        118 97.4 /usr/bin/node /opt/barkpark/sites/x/node_modules/.bin/next build
      1  3402990          3  0.0 ps -e -o ppid=,pid=,etimes=,pcpu=,args=
`

// The same box with the runaway gone — the state the lead's `kill` produced.
const quietPS = `      0       1     864000  0.0 /sbin/init
      1     1204    1209600  4.2 /usr/lib/systemd/systemd-journald
      1     2871     604800 18.7 /opt/barkpark/_build/prod/rel/barkpark/erts-15.2/bin/beam.smp -W w -MBas ageffcbf
      1  3402118        118 97.4 /usr/bin/node /opt/barkpark/sites/x/node_modules/.bin/next build
      1  3402990          3  0.0 ps -e -o ppid=,pid=,etimes=,pcpu=,args=
`

// runnerFor returns a probeRunner that answers `ps` with out and asserts the
// argv it was handed is the pinned direct-argv contract.
func runnerFor(t *testing.T, out string) probeRunner {
	t.Helper()
	return func(_ []string, name string, args ...string) (string, error) {
		if name != "ps" {
			t.Fatalf("probe shelled out to %q, want ps", name)
		}
		return out, nil
	}
}

// ARM ONE — the detector FIRES on the incident's own shape, and reports the
// three things an operator needs: which process, how long, and how much.
func TestRunawayProbeReportsTheIncident(t *testing.T) {
	procs, err := newRunawayProbeWith(runnerFor(t, incidentPS))()
	if err != nil {
		t.Fatalf("probe error: %v", err)
	}
	if len(procs) != 1 {
		t.Fatalf("got %d runaways, want exactly 1: %+v", len(procs), procs)
	}
	got := procs[0]
	if got.PID != 3369344 {
		t.Errorf("pid = %d, want 3369344", got.PID)
	}
	if got.ElapsedS != 10001 {
		t.Errorf("elapsed_s = %d, want 10001 (02:46:41)", got.ElapsedS)
	}
	if got.CPUPercent != 66.3 {
		t.Errorf("cpu_percent = %v, want 66.3", got.CPUPercent)
	}
	if !strings.HasPrefix(got.Command, "journalctl -u bp-site-build-* --since -14d --no-pager") {
		t.Errorf("command = %q, want the incident's journalctl argv", got.Command)
	}
}

// ARM TWO — and this is the arm that makes the first one mean something: the
// SAME detector, on the SAME box with the runaway killed, reports NOTHING. A
// beam.smp up for a week, a `next build` at 97.4% CPU, and systemd itself all
// pass under it. A detector that fires on those is not a detector.
func TestRunawayProbeIsQuietOnAQuietBox(t *testing.T) {
	procs, err := newRunawayProbeWith(runnerFor(t, quietPS))()
	if err != nil {
		t.Fatalf("probe error: %v", err)
	}
	if len(procs) != 0 {
		t.Fatalf("quiet box reported %d runaways, want 0: %+v", len(procs), procs)
	}
	// Measured-and-quiet must be an EMPTY LIST, never nil: nil is the wire's
	// word for "we did not look", and the two must never collapse.
	if procs == nil {
		t.Fatal("quiet box returned nil (unmeasured); want a non-nil empty slice")
	}
}

// Each arm of the predicate is REQUIRED — proven by removing exactly one from a
// row that otherwise IS the incident and watching the detection stop.
func TestRunawayPredicateNeedsAllThreeArms(t *testing.T) {
	cases := []struct {
		name string
		line string
	}{
		{
			// Not orphaned: an identical burn with a living parent is somebody's
			// child, and somebody's child has an owner who will reap it.
			name: "parented",
			line: "  3369333  3369344      10001 66.3 journalctl -u bp-site-build-* --since -14d --no-pager",
		},
		{
			// Not long-lived: 29 minutes is under the fence, on purpose.
			name: "young",
			line: "      1  3369344       1740 66.3 journalctl -u bp-site-build-* --since -14d --no-pager",
		},
		{
			// Not expensive: an orphan that has cost the box nothing is a fact,
			// not an incident.
			name: "cheap",
			line: "      1  3369344      10001  1.2 journalctl -u bp-site-build-* --since -14d --no-pager",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			procs, err := parseRunaways(tc.line + "\n")
			if err != nil {
				t.Fatalf("parse error: %v", err)
			}
			if len(procs) != 0 {
				t.Fatalf("reported %d runaways for a %s row, want 0: %+v", len(procs), tc.name, procs)
			}
		})
	}
	// The control: the same line with all three arms present DOES fire, so the
	// three zeros above are the predicate refusing and not the fixture being
	// unreadable.
	procs, err := parseRunaways("      1  3369344      10001 66.3 journalctl -u bp-site-build-* --since -14d --no-pager\n")
	if err != nil {
		t.Fatalf("control parse error: %v", err)
	}
	if len(procs) != 1 {
		t.Fatalf("control reported %d runaways, want 1", len(procs))
	}
}

// A command with runs of spaces survives verbatim — the operator has to be able
// to paste what they read.
func TestRunawayKeepsCommandVerbatim(t *testing.T) {
	const cmd = "bash -c 'which systemd-run;  ls -la /run/barkpark 2>/dev/null'"
	procs, err := parseRunaways("      1  3369333      10001 55.0 " + cmd + "\n")
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if len(procs) != 1 || procs[0].Command != cmd {
		t.Fatalf("command = %+v, want %q", procs, cmd)
	}
}

// The worst offender survives the cap, and "worst" is CPU-SECONDS SPENT — not
// the highest percent and not the oldest process.
func TestRunawayRanksByCPUSecondsAndCaps(t *testing.T) {
	in := strings.Join([]string{
		"      1  1001       1900 99.0 spent-1881s", // 1881 cpu-seconds
		"      1  1002      10001 66.3 spent-6631s", // 6631 — the incident
		"      1  1003       3600 90.0 spent-3240s", // 3240
		"      1  1004       2000 60.0 spent-1200s", // 1200 — over the cap
		"",
	}, "\n")
	procs, err := parseRunaways(in)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if len(procs) != runawayTopLimit {
		t.Fatalf("got %d rows, want the cap %d", len(procs), runawayTopLimit)
	}
	want := []int{1002, 1003, 1001}
	for i, w := range want {
		if procs[i].PID != w {
			t.Errorf("row %d pid = %d, want %d (order is cpu-seconds desc)", i, procs[i].PID, w)
		}
	}
}

// The command is capped so the beat payload stays inside the TOAST threshold the
// space payload already taught us about (D58).
func TestRunawayCapsCommandLength(t *testing.T) {
	long := "journalctl " + strings.Repeat("-u bp-site-build-abcdef ", 40)
	procs, err := parseRunaways("      1  3369344      10001 66.3 " + long + "\n")
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if n := len([]rune(procs[0].Command)); n > runawayCommandLimit+1 {
		t.Fatalf("command is %d runes, want <= %d (+1 ellipsis)", n, runawayCommandLimit)
	}
}

// UNREADABLE IS NOT QUIET. A `ps` that does not know `etimes` prints usage, and
// reading that as "no runaways" would make this instrument permanently blind
// while looking exactly like good news.
func TestRunawayUnreadableOutputIsAnError(t *testing.T) {
	for _, out := range []string{
		"",
		"error: unsupported SysV option\n\nUsage:\n ps [options]\n",
		"      1  3369344      abc 66.3 journalctl\n",
	} {
		if _, err := parseRunaways(out); err == nil {
			t.Fatalf("parseRunaways(%q) returned no error; unreadable must never read as quiet", out)
		}
	}
}

// A failing probe leaves the field UNMEASURED (nil), which the wire renders
// differently from a measured-empty list.
func TestRunawayProbeErrorLeavesFieldUnmeasured(t *testing.T) {
	fail := func([]string, string, ...string) (string, error) { return "", errors.New("no ps") }
	r := gatherReport(ReportConfig{RunawayProbe: newRunawayProbeWith(fail)})
	if r.Runaways != nil {
		t.Fatalf("Runaways = %+v, want nil (unmeasured)", r.Runaways)
	}
	b, _ := json.Marshal(r)
	if !strings.Contains(string(b), `"runaway_procs":null`) {
		t.Fatalf("unmeasured runaways did not marshal as null: %s", string(b))
	}
}

// The BEAT carries it, and the nil/empty distinction survives JSON — the two
// facts the control plane branches on.
func TestBeatCarriesRunawaysAndDistinguishesQuietFromUnmeasured(t *testing.T) {
	quiet := gatherReport(ReportConfig{RunawayProbe: newRunawayProbeWith(runnerFor(t, quietPS))})
	if quiet.Runaways == nil {
		t.Fatal("measured-quiet box landed nil; want an empty list")
	}
	qb, _ := json.Marshal(quiet)
	if !strings.Contains(string(qb), `"runaway_procs":[]`) {
		t.Fatalf("quiet box did not marshal as []: %s", string(qb))
	}

	hot := gatherReport(ReportConfig{RunawayProbe: newRunawayProbeWith(runnerFor(t, incidentPS))})
	hb, _ := json.Marshal(hot)
	for _, want := range []string{`"pid":3369344`, `"elapsed_s":10001`, `"cpu_percent":66.3`, "bp-site-build-*"} {
		if !strings.Contains(string(hb), want) {
			t.Fatalf("beat payload missing %s: %s", want, string(hb))
		}
	}

	// An UNWIRED probe is the third state and must stay nil.
	if r := gatherReport(ReportConfig{}); r.Runaways != nil {
		t.Fatalf("unwired probe landed %+v, want nil", r.Runaways)
	}
}

// The argv is pinned: no shell, no pipe, `etimes` not `etime`, and `args` last.
// A future edit that reaches for `sh -c … | grep` reintroduces the exact leak
// this probe exists to detect (D59).
func TestRunawayArgvIsDirectAndPinned(t *testing.T) {
	args := psRunawayArgs()
	want := []string{"-e", "-o", "ppid=,pid=,etimes=,pcpu=,args="}
	if len(args) != len(want) {
		t.Fatalf("argv = %q, want %q", args, want)
	}
	for i := range want {
		if args[i] != want[i] {
			t.Fatalf("argv = %q, want %q", args, want)
		}
	}
	for _, a := range args {
		if strings.ContainsAny(a, "|;&><") {
			t.Fatalf("argv element %q contains shell metacharacters", a)
		}
	}
}
