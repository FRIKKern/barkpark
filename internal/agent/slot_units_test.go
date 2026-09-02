package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// dr-bl-w5-failed-slot-unit-is-invisible — the AGENT half.
//
// Every fixture below is REAL `systemctl show` output, captured from guerrilla
// (157.180.90.121) on 2026-09-01. The property ORDER in these strings is
// systemd's own and is deliberately NOT the order `-p` asked for — that is the
// trap a positional parser falls into, and the reason parseSystemctlShow reads
// blocks into a map and looks properties up by name.

// The live blue/green pair: blue cleanly stopped (and never started since boot,
// so ALL THREE timestamps are empty), green running on pid 1604014.
const liveSlotPairShow = `MainPID=0
Result=success
ExecMainCode=0
ExecMainStatus=0
Id=barkpark-slot@blue.service
ActiveState=inactive
SubState=dead
StateChangeTimestamp=
ActiveEnterTimestamp=
InactiveEnterTimestamp=

MainPID=1604014
Result=success
ExecMainCode=0
ExecMainStatus=0
Id=barkpark-slot@green.service
ActiveState=active
SubState=running
StateChangeTimestamp=Tue 2026-09-01 21:37:14 UTC
ActiveEnterTimestamp=Tue 2026-09-01 21:37:14 UTC
InactiveEnterTimestamp=
`

// The two failed site units, live on the same box: Result=exit-code with
// ExecMainStatus=143 — 128+15, a clean SIGTERM retire that systemd files as an
// exit code because the unit lacks SuccessExitStatus=143 (PR #14863).
const liveFailedSitesShow = `MainPID=0
Result=exit-code
ExecMainCode=1
ExecMainStatus=143
Id=barkpark-site@search__b.service
ActiveState=failed
SubState=failed
InactiveEnterTimestamp=Tue 2026-09-01 11:07:52 UTC

MainPID=0
Result=exit-code
ExecMainCode=1
ExecMainStatus=143
Id=barkpark-site@search-capstone__a.service
ActiveState=failed
SubState=failed
InactiveEnterTimestamp=Tue 2026-09-01 11:11:51 UTC
`

const liveFailedSitesList = `barkpark-site@search-capstone__a.service loaded failed failed  Barkpark spawned node SSR site (slot search-capstone__a)
barkpark-site@search__b.service          loaded failed failed  Barkpark spawned node SSR site (slot search__b)
`

// fakeSystemctl is the probeRunner seam: it answers by the SUBCOMMAND, so a
// test can fail one call and leave the other working — which is the degradation
// contract (a broken site listing must never cost the blue/green pair).
type fakeSystemctl struct {
	show     func(units []string) (string, error)
	list     func() (string, error)
	showArgs [][]string
	calls    int
}

func (f *fakeSystemctl) run(_ []string, name string, args ...string) (string, error) {
	f.calls++
	if name != "systemctl" {
		return "", fmt.Errorf("unexpected command %q", name)
	}
	switch args[0] {
	case "show":
		// args = show -p <props> unit…
		units := append([]string(nil), args[3:]...)
		f.showArgs = append(f.showArgs, units)
		if f.show == nil {
			return "", errors.New("no show fixture")
		}
		return f.show(units)
	case "list-units":
		if f.list == nil {
			return "", errors.New("no list fixture")
		}
		return f.list()
	}
	return "", fmt.Errorf("unexpected subcommand %q", args[0])
}

func TestSlotUnitsProbeReadsTheLivePairShape(t *testing.T) {
	f := &fakeSystemctl{
		show: func([]string) (string, error) { return liveSlotPairShow, nil },
		list: func() (string, error) { return "", nil },
	}
	units, truncated, err := newSlotUnitsProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if truncated != 0 {
		t.Errorf("truncated = %d, want 0 — nothing was hidden", truncated)
	}
	if len(units) != 2 {
		t.Fatalf("got %d units, want the blue/green pair: %#v", len(units), units)
	}

	// THE PAIR IS ASKED FOR BY NAME. A discovery listing would return the healthy
	// half and silently omit the dead one — the precise blindness this closes.
	if got := f.showArgs[0]; len(got) != 2 ||
		got[0] != "barkpark-slot@blue.service" || got[1] != "barkpark-slot@green.service" {
		t.Errorf("first show argv = %v, want the blue/green pair by name", got)
	}

	blue, green := units[0], units[1]
	if blue.Unit != "barkpark-slot@blue.service" || blue.ActiveState != "inactive" ||
		blue.SubState != "dead" || blue.Result != "success" {
		t.Errorf("blue = %#v", blue)
	}
	// MainPID 0 is a MEASUREMENT (systemd said 0), not the -1 unknown.
	if blue.MainPID != 0 || blue.ExecMainStatus != 0 {
		t.Errorf("blue pid/status = %d/%d, want a measured 0/0", blue.MainPID, blue.ExecMainStatus)
	}
	// All three timestamps empty on the live box — carried through as empty
	// rather than invented.
	if blue.StateSince != "" {
		t.Errorf("blue state_since = %q, want empty — systemd had none", blue.StateSince)
	}
	if green.Unit != "barkpark-slot@green.service" || green.ActiveState != "active" ||
		green.SubState != "running" || green.MainPID != 1604014 {
		t.Errorf("green = %#v", green)
	}
	if green.StateSince != "Tue 2026-09-01 21:37:14 UTC" {
		t.Errorf("green state_since = %q, want systemd's string VERBATIM", green.StateSince)
	}
}

func TestSlotUnitsProbeCarriesTheFailedSiteUnitsWithTheirExitStatus(t *testing.T) {
	f := &fakeSystemctl{
		show: func(units []string) (string, error) {
			if strings.HasPrefix(units[0], "barkpark-slot@") {
				return liveSlotPairShow, nil
			}
			return liveFailedSitesShow, nil
		},
		list: func() (string, error) { return liveFailedSitesList, nil },
	}
	units, truncated, err := newSlotUnitsProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if truncated != 0 {
		t.Errorf("truncated = %d, want 0 — two sites fit under the cap", truncated)
	}
	if len(units) != 4 {
		t.Fatalf("got %d units, want the pair plus two failed sites: %#v", len(units), units)
	}
	site := units[2]
	if site.Unit != "barkpark-site@search__b.service" || site.ActiveState != "failed" {
		t.Fatalf("site = %#v", site)
	}
	// The pair that must never be split: "exit-code" alone reads a deliberate
	// retire as a crash; 143 is what says it was a SIGTERM.
	if site.Result != "exit-code" || site.ExecMainStatus != 143 {
		t.Errorf("site result/status = %q/%d, want exit-code/143", site.Result, site.ExecMainStatus)
	}
	if site.StateSince != "Tue 2026-09-01 11:07:52 UTC" {
		t.Errorf("site state_since = %q", site.StateSince)
	}
}

// The cap ANNOUNCES ITSELF (the rule sitesTopLimit/SitesCount already keep): a
// short list must never pass for a whole one. And the blue/green pair is never
// what the cap eats.
func TestSlotUnitsProbeCapReportsWhatItHidAndNeverEatsThePair(t *testing.T) {
	var names []string
	var show strings.Builder
	for i := 0; i < 20; i++ {
		unit := fmt.Sprintf("barkpark-site@spam%02d.service", i)
		names = append(names, unit+" loaded failed failed  spam")
		fmt.Fprintf(&show, "Id=%s\nActiveState=failed\nSubState=failed\nResult=exit-code\nMainPID=0\nExecMainStatus=143\n\n", unit)
	}
	f := &fakeSystemctl{
		show: func(units []string) (string, error) {
			if strings.HasPrefix(units[0], "barkpark-slot@") {
				return liveSlotPairShow, nil
			}
			// Only the units actually asked for come back.
			var b strings.Builder
			for _, u := range units {
				fmt.Fprintf(&b, "Id=%s\nActiveState=failed\nSubState=failed\nResult=exit-code\nMainPID=0\nExecMainStatus=143\n\n", u)
			}
			return b.String(), nil
		},
		list: func() (string, error) { return strings.Join(names, "\n"), nil },
	}
	units, truncated, err := newSlotUnitsProbeWith(f.run)()
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if len(units) != slotUnitsLimit {
		t.Fatalf("got %d units, want the cap %d", len(units), slotUnitsLimit)
	}
	if truncated != 20-(slotUnitsLimit-2) {
		t.Errorf("truncated = %d, want %d — the cap must report what it hid",
			truncated, 20-(slotUnitsLimit-2))
	}
	if units[0].Unit != "barkpark-slot@blue.service" || units[1].Unit != "barkpark-slot@green.service" {
		t.Fatalf("the cap ate a SLOT unit: %#v", units[:2])
	}
}

// The site listing degrades INDEPENDENTLY: a `list-units` that errors costs the
// site rows and never the pair, because the pair is the row's whole subject.
func TestSlotUnitsProbeKeepsThePairWhenTheSiteListingFails(t *testing.T) {
	f := &fakeSystemctl{
		show: func([]string) (string, error) { return liveSlotPairShow, nil },
		list: func() (string, error) { return "", errors.New("dbus timeout") },
	}
	units, truncated, err := newSlotUnitsProbeWith(f.run)()
	if err != nil {
		t.Fatalf("a failed site listing must not fail the probe: %v", err)
	}
	if len(units) != 2 || truncated != 0 {
		t.Fatalf("units = %#v, truncated = %d", units, truncated)
	}
}

// A `systemctl` that is not there, or a dbus that is not answering, is
// UNMEASURED — never an empty list, which would read "we looked at the pair and
// there is nothing to say".
func TestSlotUnitsProbeErrorsRatherThanReportingAnEmptyPair(t *testing.T) {
	for _, tc := range []struct {
		name string
		f    *fakeSystemctl
	}{
		{"no systemctl", &fakeSystemctl{show: func([]string) (string, error) {
			return "", errors.New("exec: \"systemctl\": executable file not found in $PATH")
		}}},
		{"a busybox systemctl that prints nothing parseable", &fakeSystemctl{
			show: func([]string) (string, error) { return "Failed to connect to bus\n", nil },
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			units, truncated, err := newSlotUnitsProbeWith(tc.f.run)()
			if err == nil {
				t.Fatalf("want an error, got units %#v", units)
			}
			if units != nil {
				t.Errorf("units = %#v, want nil (UNMEASURED)", units)
			}
			if truncated != -1 {
				t.Errorf("truncated = %d, want the -1 unmeasured sentinel", truncated)
			}
		})
	}
}

// A block with no Id= cannot be attributed to a unit. Attributing it by argv
// POSITION is the guess beam_slot already taught this tree not to make.
func TestParseSystemctlShowDropsAnUnlabelledBlock(t *testing.T) {
	units := parseSystemctlShow("ActiveState=failed\nSubState=failed\n\n" + liveSlotPairShow)
	if len(units) != 2 {
		t.Fatalf("got %d units, want 2 — the unlabelled block must be dropped: %#v", len(units), units)
	}
}

// An unreadable pid is UNKNOWN (-1), never pid 0. Those are different facts and
// the CLI branches on the difference (an `active` unit with pid 0 is not
// serving; an `active` unit with an unread pid does not get to vouch either).
func TestUnparseableNumericPropertiesAreMinusOneNotZero(t *testing.T) {
	units := parseSystemctlShow("Id=x.service\nActiveState=active\nSubState=running\nMainPID=[not set]\n")
	if len(units) != 1 {
		t.Fatalf("got %#v", units)
	}
	if units[0].MainPID != -1 {
		t.Errorf("MainPID = %d, want -1 — an unread pid must never render as pid 0", units[0].MainPID)
	}
	if units[0].ExecMainStatus != -1 {
		t.Errorf("ExecMainStatus = %d, want -1 (the property was absent)", units[0].ExecMainStatus)
	}
}

// ---------------------------------------------------------------------------
// The beat's own nil-vs-empty law.
// ---------------------------------------------------------------------------

func TestReportSlotUnitsNilWhenUnwiredEmptyWhenMeasured(t *testing.T) {
	unwired := gatherReport(ReportConfig{})
	if unwired.SlotUnits != nil {
		t.Errorf("SlotUnits = %#v, want nil — an unwired probe is UNMEASURED", unwired.SlotUnits)
	}
	if unwired.SlotUnitsTruncated != -1 {
		t.Errorf("SlotUnitsTruncated = %d, want the -1 sentinel", unwired.SlotUnitsTruncated)
	}
	blob, err := json.Marshal(unwired)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(blob), `"slot_units":null`) {
		t.Errorf("an unmeasured beat must send null, not []:\n%s", blob)
	}

	// A probe that RAN and found nothing lands a non-nil empty list — measured,
	// and nothing to report. `[]` on the wire, never null.
	measured := gatherReport(ReportConfig{
		SlotUnitsProbe: func() ([]SlotUnit, int, error) { return nil, 0, nil },
	})
	if measured.SlotUnits == nil {
		t.Fatal("a probe that ran must land a non-nil list")
	}
	blob, err = json.Marshal(measured)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(blob), `"slot_units":[]`) {
		t.Errorf("a measured-quiet beat must send [], not null:\n%s", blob)
	}

	// A probe that ERRORED leaves BOTH fields unmeasured — a truncation count
	// beside no list is a number about nothing.
	failed := gatherReport(ReportConfig{
		SlotUnitsProbe: func() ([]SlotUnit, int, error) { return nil, 4, errors.New("boom") },
	})
	if failed.SlotUnits != nil || failed.SlotUnitsTruncated != -1 {
		t.Errorf("a failed probe landed %#v / %d", failed.SlotUnits, failed.SlotUnitsTruncated)
	}
}

func TestReportCarriesTheUnitsToTheWireUnderTheDocumentedKeys(t *testing.T) {
	r := gatherReport(ReportConfig{
		SlotUnitsProbe: func() ([]SlotUnit, int, error) {
			return parseSystemctlShow(liveSlotPairShow), 2, nil
		},
	})
	blob, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`"slot_units":[`,
		`"unit":"barkpark-slot@blue.service"`,
		`"active_state":"inactive"`,
		`"sub_state":"dead"`,
		`"result":"success"`,
		`"main_pid":1604014`,
		`"exec_main_status":0`,
		`"state_since":"Tue 2026-09-01 21:37:14 UTC"`,
		`"slot_units_truncated":2`,
	} {
		if !strings.Contains(string(blob), want) {
			t.Errorf("beat missing %s:\n%s", want, blob)
		}
	}
}
