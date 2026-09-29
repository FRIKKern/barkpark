package cli

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// tasks_dispatch_advisory.go — THE READER HALF of task-46e82dc40c385ed2.
//
// `bp task ready` answers a LIGHTWEIGHT PROJECTION with no `content` key at
// all. Every marker that says a row must not be built — "DO NOT commission a
// builder for c0", "OWNER-GATED", "do not work it" — lives under `content.*`,
// so a lead triaging from the listing could not see one. Measured on the studio
// fence 2026-09-22: 9 of 22 unclaimed ready rows carried a defer or forbid
// marker, and a builder was dispatched at `task-ae82ac9ec98a49fd` whose
// operating_instruction refuses it in capitals. The builder caught it. The
// listing did not.
//
// The server now derives the class into the brief card's existing `dispatch`
// key (Barkpark.Tasks.Dispatchability.classify_markers/1). This file is what
// makes a lead who reads ONLY the listing unable to miss it: ONE loud stderr
// line naming every row on the page that carries a do-not-build class.
//
// STDERR, NEVER STDOUT — in BOTH human and machine mode. The claim-path sibling
// next door (emitTaskClaimPathAdvisory) fires only on `-o json`, because its
// failure mode is a jq reader. This one's failure mode is a HUMAN reading a
// table at 4 a.m., so it must fire there too; writing to stderr keeps `-o json`
// stdout one byte-identical document either way.
//
// ── THE MIRROR HAZARD, AND WHERE THE LOCK IS ────────────────────────────────
//
// The vocabulary and its PRECEDENCE now live on two surfaces, Elixir and Go.
// Two green suites prove nothing about drift: change one side and both stay
// green while users see two answers. So there is exactly ONE authored copy —
// `api/priv/tasks/dispatch_markers.json`, which the server module reads at
// COMPILE TIME — and `dispatch_markers.json` beside this file is a byte copy
// pinned to it by TestDispatchMarkerSpecMirrorsTheServerCopy, which decodes
// BOTH and compares the value set AND the array ORDER. The expected side is
// read from the source of truth, never hand-written here, because a guard whose
// expected value is a second transcript of the guarded thing is a tautology
// that reads exactly like coverage.

//go:embed dispatch_markers.json
var dispatchMarkerSpecJSON []byte

// dispatchMarkerSpec is the decoded shape of dispatch_markers.json. Only the
// fields this side USES are typed; the mirror test compares the raw decoded
// documents, so a field added to the JSON cannot slip past the pin by being
// absent from this struct.
type dispatchMarkerSpec struct {
	Version      int               `json:"version"`
	Fields       []string          `json:"fields"`
	Classes      []string          `json:"classes"`
	ClassMeaning map[string]string `json:"class_meaning"`
	Markers      []dispatchMarker  `json:"markers"`
}

type dispatchMarker struct {
	Class         string `json:"class"`
	Needle        string `json:"needle"`
	CaseSensitive bool   `json:"case_sensitive"`
}

// loadDispatchMarkerSpec decodes the embedded spec. A decode failure or an
// empty class list is a PROGRAMMING error caught by the tests, not a runtime
// condition — but the advisory must never panic a working `bp task ready`, so
// it degrades to "no known classes", which makes the advisory silent rather
// than wrong.
func loadDispatchMarkerSpec() dispatchMarkerSpec {
	var spec dispatchMarkerSpec
	_ = json.Unmarshal(dispatchMarkerSpecJSON, &spec)
	return spec
}

// TaskDispatchReport is the verdict over one task read payload.
type TaskDispatchReport struct {
	// Rows is how many rows the payload carried, across every RowsKey.
	Rows int
	// DispatchKeyPresent is how many rows carry a `dispatch` key AT ALL. This
	// is the ANTI-VACUITY field: zero here on a non-empty page means the server
	// never emits the signal (an old build, or the key renamed), which is a
	// different answer from "no row is marked" and must not be reported as one.
	DispatchKeyPresent int
	// Blocked maps each do-not-build class to the doc_ids carrying it, in page
	// order.
	Blocked map[string][]string
	// Other are the distinct dispatch values seen that are NOT do-not-build
	// classes (today: delegated, undecided, upstream), sorted.
	Other []string
}

// BlockedCount is how many rows carry any do-not-build class.
func (r TaskDispatchReport) BlockedCount() int {
	n := 0
	for _, ids := range r.Blocked {
		n += len(ids)
	}
	return n
}

// readTaskDispatch reads `raw` AS the shape `shape` describes and reports which
// rows carry a do-not-build dispatch class — or REFUSES. It never returns a
// verdict it could not measure: every failure is ErrReadyPageUnreadable, whose
// message begins `CANNOT READ:`, so an unreadable page is never byte-identical
// to "nothing on this page is forbidden". Pure: no network, no writes.
func readTaskDispatch(raw []byte, id string, shape taskReadShape, classes []string) (TaskDispatchReport, error) {
	report := TaskDispatchReport{Blocked: map[string][]string{}}

	if len(raw) == 0 {
		return report, readyPageUnreadable("the page was empty (0 bytes)")
	}
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		return report, readyPageUnreadable("the page is not a JSON object: %v", err)
	}
	known := map[string]bool{}
	for _, c := range classes {
		known[c] = true
	}
	other := map[string]bool{}

	for _, key := range shape.RowsKeys {
		rows, err := taskShapeRows(id, key, shape, env[key])
		if err != nil {
			return TaskDispatchReport{Blocked: map[string][]string{}}, err
		}
		for i, entry := range rows {
			row, ok := entry.(map[string]any)
			if !ok {
				return TaskDispatchReport{Blocked: map[string][]string{}}, readyPageUnreadable("%s[%d] is %T, not an object", key, i, entry)
			}
			report.Rows++
			value, present := row["dispatch"]
			if !present {
				continue
			}
			report.DispatchKeyPresent++
			class, _ := value.(string)
			if class == "" {
				continue
			}
			if !known[class] {
				other[class] = true
				continue
			}
			docID, _ := row["doc_id"].(string)
			if docID == "" {
				docID = "(no doc_id)"
			}
			report.Blocked[class] = append(report.Blocked[class], docID)
		}
	}
	report.Other = sortedReadyKeys(other)
	return report, nil
}

// formatTaskDispatchAdvisory renders the ONE stderr line, or "" when the page
// carries nothing to say. Split out from the emitter so the line itself is
// testable without a writer, and so the CONTROL (a page with a marked row and a
// page without, through this same function) compares two strings.
func formatTaskDispatchAdvisory(report TaskDispatchReport, spec dispatchMarkerSpec) string {
	if report.BlockedCount() == 0 {
		return ""
	}
	var parts []string
	for _, class := range spec.Classes {
		ids := report.Blocked[class]
		if len(ids) == 0 {
			continue
		}
		shown := ids
		const maxShown = 6
		suffix := ""
		if len(shown) > maxShown {
			shown = shown[:maxShown]
			suffix = fmt.Sprintf(" +%d more", len(ids)-maxShown)
		}
		parts = append(parts, fmt.Sprintf("%d %s (%s%s)", len(ids), strings.ToUpper(class), strings.Join(shown, ", "), suffix))
	}
	// Defensive: a class present in Blocked but absent from spec.Classes would
	// be silently dropped by the loop above, turning a refusal into silence.
	if len(parts) == 0 {
		keys := make([]string, 0, len(report.Blocked))
		for k := range report.Blocked {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts = append(parts, "unrecognised dispatch class(es): "+strings.Join(keys, ", "))
	}
	return fmt.Sprintf(
		"bp: DO NOT DISPATCH — %d of %d rows on this page carry a do-not-build marker their AUTHOR wrote: %s. "+
			"The marker text is in .content.description / .content.disposition_reason / .content.operating_instruction, none of which this projection carries — read the row with `bp task get <doc_id>` before claiming it.",
		report.BlockedCount(), report.Rows, strings.Join(parts, "; "))
}

// emitTaskDispatchAdvisory writes the line, on a successful task LIST read,
// when and only when the page actually carries a marked row — a banner on every
// call trains the fleet to ignore it. Never touches stdout.
func emitTaskDispatchAdvisory(out *writer, cmd manifest.Command, status int, respBody []byte) {
	if status < 200 || status >= 300 {
		return
	}
	shape, ok := taskReadShapes()[cmd.ID]
	if !ok || shape.SingleRow {
		return
	}
	spec := loadDispatchMarkerSpec()
	report, err := readTaskDispatch(respBody, cmd.ID, shape, spec.Classes)
	if err != nil {
		return
	}
	if line := formatTaskDispatchAdvisory(report, spec); line != "" {
		out.errf("%s", line)
	}
}
