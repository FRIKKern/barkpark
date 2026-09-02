package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// dr-bl-w5-failed-slot-unit-is-invisible.
//
// THE MEASUREMENT THIS FILE IS BUILT FROM, 2026-08-06 on guerrilla:
// `systemctl is-active barkpark-slot@blue barkpark-slot@green` read
// `failed / active`. Blue had died on an 8m30s stop-sigterm timeout and been
// SIGKILLed. Caddy proxied localhost:4001 = green, so the box WAS serving and
// `bp cloud status` reading `ok` was correct — and correct for the wrong reason:
// the verdict had zero unit-state inputs and would have read `ok` with either
// half dead, and with both.
//
// So the criterion is a BOTH-DIRECTIONS one and these tests are written as a
// pair: failed-but-the-other-slot-is-serving must stay `ok` AND say so in the
// detail; failed-and-nothing-serving must say THAT, and name the contradiction
// with a health gate that still claims up.

// slotUnit builds one unit row the way the control plane relays it — pointers
// throughout, because nil is "the CP could not read this property" and a
// fabricated 0 for a pid is a claim nobody measured.
func slotUnit(unit, active, sub, result string, pid, status float64, since string) cloudclient.SlotUnit {
	u := cloudclient.SlotUnit{Unit: unit, ActiveState: active, SubState: sub}
	if result != "" {
		u.Result = strPtr(result)
	}
	u.MainPID = f64(pid)
	u.ExecMainStatus = f64(status)
	if since != "" {
		u.StateSince = strPtr(since)
	}
	return u
}

// slotBox is a healthy-by-every-other-measure box: beating, health up, agent
// online, release current, vitals readable. Everything that could make the row
// something OTHER than `ok` is deliberately absent, so a status that is not `ok`
// in these tests can only have come from the unit block.
func slotBox(units ...cloudclient.SlotUnit) cloudclient.Barkpark {
	cores, load1, load15, disk := 2.0, 0.31, 0.28, 41.0
	at := seen
	b := pressed("guerrilla", &cloudclient.Pressure{
		CPUCores:        &cores,
		Load1:           &load1,
		Load15:          &load15,
		DiskUsedPercent: &disk,
		ReportedAt:      &at,
		SlotUnits:       units,
	})
	b.Host = "157.180.90.121"
	return b
}

// The blue/green pair AS MEASURED on 2026-08-06: blue failed on the stop
// timeout, green serving on pid 1604014.
func blueFailedGreenServing() []cloudclient.SlotUnit {
	return []cloudclient.SlotUnit{
		slotUnit("barkpark-slot@blue.service", "failed", "failed", "timeout", 0, 1,
			"Wed 2026-08-06 14:22:49 UTC"),
		slotUnit("barkpark-slot@green.service", "active", "running", "success", 1604014, 0,
			"Tue 2026-09-01 21:37:14 UTC"),
	}
}

// ---------------------------------------------------------------------------
// DIRECTION ONE — failed, but the OTHER slot is serving.
// ---------------------------------------------------------------------------

func TestSlotUnitFailedButOtherSlotServingKeepsTheVerdictOK(t *testing.T) {
	b := slotBox(blueFailedGreenServing()...)

	if got := attentionStatus(b); got != "ok" {
		t.Fatalf("a box SERVING on green must stay ok, got %q — a failed half must not "+
			"be traded for a false positive", got)
	}
	if got := attentionBucket(attentionStatus(b)); got != "healthy" {
		t.Fatalf("bucket = %q, want healthy — the marker is a DETAIL LINE, it moves no rank", got)
	}

	detail := attentionDetail(b, attentionStatus(b))
	for _, want := range []string{
		"serving on green",
		"blue slot FAILED",
		"timeout 1",
		"since Wed 2026-08-06 14:22:49 UTC",
	} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail %q missing %q", detail, want)
		}
	}
	if strings.Contains(detail, "NO slot is serving") {
		t.Errorf("detail %q claims nothing is serving about a box that IS serving", detail)
	}
}

func TestCloudStatusRendersTheFailedHalfOnAnOKRow(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderStatusRows(w, rankBarkparks([]cloudclient.Barkpark{slotBox(blueFailedGreenServing()...)}))
	got := stdout.String()

	for _, want := range []string{"DETAIL", "serving on green", "blue slot FAILED"} {
		if !strings.Contains(got, want) {
			t.Errorf("table missing %q:\n%s", want, got)
		}
	}
}

// ---------------------------------------------------------------------------
// DIRECTION TWO — failed, and NOTHING is serving.
// ---------------------------------------------------------------------------

func TestSlotUnitFailedAndNothingServingSaysSoAndNamesTheContradiction(t *testing.T) {
	units := blueFailedGreenServing()
	// Green goes down too. This is the case the old surface could not express at
	// all: the health column is a CACHED gate reading, so a box can read `up`
	// here with no BEAM under it.
	units[1] = slotUnit("barkpark-slot@green.service", "failed", "failed", "signal", 0, 9,
		"Tue 2026-09-01 21:40:00 UTC")
	b := slotBox(units...)

	detail := attentionDetail(b, attentionStatus(b))
	for _, want := range []string{
		"NO slot is serving",
		"blue slot FAILED (timeout 1)",
		"green slot FAILED (signal 9)",
		"health says up",
	} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail %q missing %q", detail, want)
		}
	}
	if strings.Contains(detail, "serving on") {
		t.Errorf("detail %q says something is serving when both halves are failed", detail)
	}
}

func TestNeitherSlotActiveWhileHealthSaysUpIsNamed(t *testing.T) {
	// Nothing FAILED — both halves merely inactive. A mid-cutover beat looks
	// exactly like this, so the sentence is owed only when health disagrees.
	quiet := []cloudclient.SlotUnit{
		slotUnit("barkpark-slot@blue.service", "inactive", "dead", "success", 0, 0, ""),
		slotUnit("barkpark-slot@green.service", "inactive", "dead", "success", 0, 0, ""),
	}

	up := slotBox(quiet...)
	if d := attentionDetail(up, attentionStatus(up)); !strings.Contains(d, "no blue/green slot is active") ||
		!strings.Contains(d, "health says up") {
		t.Errorf("detail %q must name both readings when they disagree", d)
	}

	// The SAME units on a box whose health does NOT claim up: no contradiction to
	// report, so no sentence. This is the arm that keeps the marker from
	// narrating every cutover.
	down := slotBox(quiet...)
	down.HealthStatus = "down"
	if d := attentionDetail(down, attentionStatus(down)); strings.Contains(d, "no blue/green slot is active") {
		t.Errorf("detail %q invents a contradiction where the two readings AGREE", d)
	}
}

// ---------------------------------------------------------------------------
// The marker never fabricates.
// ---------------------------------------------------------------------------

func TestSlotUnitMarkerSaysNothingWhenUnmeasuredOrIntact(t *testing.T) {
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
	}{
		{"no pressure block at all", pressed("a", nil)},
		{"UNMEASURED — nil list (no systemd, or an agent predating the probe)", slotBox()},
		{"MEASURED AND INTACT — green serving, blue cleanly stopped", slotBox(
			slotUnit("barkpark-slot@blue.service", "inactive", "dead", "success", 0, 0, ""),
			slotUnit("barkpark-slot@green.service", "active", "running", "success", 1604014, 0,
				"Tue 2026-09-01 21:37:14 UTC"),
		)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := slotUnitMarker(tc.bp); got != "" {
				t.Errorf("marker = %q, want empty — neither absence nor good news is a happening", got)
			}
		})
	}
}

// An `active` unit with MainPID 0 has NO process. Reading it as serving is
// exactly how a box with nothing running would go on reading healthy — the
// failure this whole row exists to end, re-entered through a different door.
func TestActiveWithNoMainPIDIsNotServing(t *testing.T) {
	b := slotBox(
		slotUnit("barkpark-slot@blue.service", "failed", "failed", "timeout", 0, 1,
			"Wed 2026-08-06 14:22:49 UTC"),
		slotUnit("barkpark-slot@green.service", "active", "exited", "success", 0, 0,
			"Tue 2026-09-01 21:37:14 UTC"),
	)
	if d := attentionDetail(b, attentionStatus(b)); !strings.Contains(d, "NO slot is serving") {
		t.Errorf("detail %q treats an active unit with pid 0 as serving", d)
	}

	// And an UNREAD pid does not vouch either: unmeasured must never become
	// evidence for the reassuring answer.
	unknown := slotBox(
		slotUnit("barkpark-slot@blue.service", "failed", "failed", "timeout", 0, 1, ""),
		cloudclient.SlotUnit{Unit: "barkpark-slot@green.service", ActiveState: "active", SubState: "running"},
	)
	if d := attentionDetail(unknown, attentionStatus(unknown)); !strings.Contains(d, "NO slot is serving") {
		t.Errorf("detail %q let a nil pid vouch for serving", d)
	}
}

// ---------------------------------------------------------------------------
// Result WITH the exit status — the PR #14863 case, measured 2026-09-01.
// ---------------------------------------------------------------------------

func TestFailedSiteUnitsCarryTheirExitStatusAndTheCapAnnouncesItself(t *testing.T) {
	units := append(blueFailedGreenServing(),
		// Both live on guerrilla right now: Result=exit-code, ExecMainStatus=143.
		// 143 is 128+15 — Next.js exiting on the SIGTERM of its own retire, filed
		// by systemd as an exit code because the unit lacks SuccessExitStatus=143.
		slotUnit("barkpark-site@search__b.service", "failed", "failed", "exit-code", 0, 143,
			"Tue 2026-09-01 11:07:52 UTC"),
		slotUnit("barkpark-site@search-capstone__a.service", "failed", "failed", "exit-code", 0, 143,
			"Tue 2026-09-01 11:11:51 UTC"),
	)
	b := slotBox(units...)
	b.Pressure.SlotUnitsTruncated = f64(3)

	d := attentionDetail(b, attentionStatus(b))
	for _, want := range []string{
		"2 site unit(s) failed",
		"search__b",
		"search-capstone__a",
		"(+3 more)",
	} {
		if !strings.Contains(d, want) {
			t.Errorf("detail %q missing %q", d, want)
		}
	}
	// The status stays the exit code's OWN number so a reader can tell 143 (a
	// clean SIGTERM) from a real crash. `-o json` carries it too.
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{b})[0])
	blob, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(blob), `"exec_main_status":143`) {
		t.Errorf("-o json dropped the exit status:\n%s", blob)
	}
}

// ---------------------------------------------------------------------------
// -o json keeps the three states three.
// ---------------------------------------------------------------------------

func TestSlotUnitsJSONKeepsTheThreeStatesThree(t *testing.T) {
	unmeasured := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{slotBox()})[0])
	if _, ok := unmeasured["slot_units"]; ok {
		t.Error("an UNMEASURED box must omit slot_units — an empty list would read " +
			"'we looked and the pair is fine' about a box nobody looked at")
	}

	intact := slotBox()
	intact.Pressure.SlotUnits = []cloudclient.SlotUnit{}
	measured := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{intact})[0])
	got, ok := measured["slot_units"]
	if !ok {
		t.Fatal("a MEASURED box must emit slot_units, even when the list is empty")
	}
	if rows, isSlice := got.([]any); !isSlice || len(rows) != 0 {
		t.Fatalf("slot_units = %#v, want an empty list", got)
	}

	full := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{slotBox(blueFailedGreenServing()...)})[0])
	blob, err := json.Marshal(full["slot_units"])
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`"unit":"barkpark-slot@blue.service"`,
		`"active_state":"failed"`,
		`"serving":false`,
		`"serving":true`,
		`"main_pid":1604014`,
		`"state_since":"Tue 2026-09-01 21:37:14 UTC"`,
	} {
		if !strings.Contains(string(blob), want) {
			t.Errorf("slot_units json missing %s:\n%s", want, blob)
		}
	}
}
