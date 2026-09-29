package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

// THE READY PAGE IS A DIFFERENT SHAPE FROM `bp task get`, AND THE DIFFERENCE
// MANUFACTURES A CONFIDENT ZERO.
//
// `bp task ready -o json` answers `{"ok":…, "page":{…}, "docs":[…]}`, and every
// row in `docs` is FLAT: doc_id, priority, title, claim, child_count,
// criteria_met, criteria_total, labels, parent_id, updated_at at the TOP level,
// with NO `content` object. `bp task get` nests the same facts under
// `.doc.content` (tasks_get_misread.go closes the two dangerous paths there).
// A reader written against `get` prints null for every field of every ready row
// while the titles come back correctly, which reads as missing DATA rather than
// a wrong KEY.
//
// The expensive one is `lifecycle_status`. It is emitted ONLY when the row is
// NOT ready — in practice `blocked`. A ready row OMITS it entirely. So the
// natural filter
//
//	jq '[.docs[] | select(.lifecycle_status == "open")] | length'
//
// answers EXACTLY ZERO on a full page of work, and zero from a 1500-row list is
// byte-identical to a lane with nothing in it. ABSENCE MEANS READY; PRESENCE
// MEANS NOT READY. Measured 2026-09-07 by lead-cloud-c5 (1502 rows: 21 carried
// it, all blocked) and again 2026-09-10 on the same server (300 rows: 284
// omitted it, 16 blocked). The committed fixture in
// testdata/task_ready_page.json is a verbatim slice of that second capture.
//
// This file is the machine-checkable example the contract in
// docs/setup/TASK-SYSTEM.md is written against, so the contract cannot rot
// silently: checkTaskReadyPageShape asserts BOTH arms in ONE run — at least one
// ready row with NO lifecycle_status AND at least one non-ready row that HAS
// one — and refuses loudly on a page it could not read. It does not change the
// wire shape; it pins it.
//
// THE REFUSAL IS THE POINT. Every failure this class produces is a command that
// SUCCEEDED, so a checker that returns "0 violations" on an empty or
// unparseable page reproduces the very defect it exists to catch. An
// unreadable page therefore never returns a verdict: it returns
// ErrReadyPageUnreadable, whose message begins with the distinct token
// `CANNOT READ:` and which callers map to a non-zero exit. A failed read is
// never byte-identical to a pass.

// ErrReadyPageUnreadable is returned INSTEAD OF a verdict whenever the page
// could not be read as a ready page at all: empty input, invalid JSON, a
// non-object envelope, no `docs` key (`bp doc ls` answers `documents` — a pager
// keyed on the wrong one writes zero rows and exits 0), a `docs` that is not a
// list, or a `docs` with zero rows. errors.Is against it is the supported test.
var ErrReadyPageUnreadable = errors.New("CANNOT READ")

// readyPageUnreadable wraps ErrReadyPageUnreadable with the specific reason,
// keeping the `CANNOT READ:` prefix at the head of the rendered message.
func readyPageUnreadable(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrReadyPageUnreadable, fmt.Sprintf(format, args...))
}

// TaskReadyShapeReport is the verdict over one ready page.
type TaskReadyShapeReport struct {
	// Rows is how many entries `docs` carried.
	Rows int
	// ReadyRows is the count with NO `lifecycle_status` key (= ready).
	ReadyRows int
	// NonReadyRows is the count that HAS one (= not ready).
	NonReadyRows int
	// NonReadyStatuses are the distinct lifecycle_status values seen, sorted.
	NonReadyStatuses []string
	// NestedRows is the count carrying a `content` object. A ready row is FLAT;
	// any non-zero value here means the wire shape moved.
	NestedRows int
	// OpenFiltered is what the natural-but-wrong filter
	// `select(.lifecycle_status == "open")` returns on this page. The contract
	// says zero, and this field is what makes that claim checkable rather than
	// assertable.
	OpenFiltered int
	// Violations names every way the page departed from the documented
	// contract. Empty = the contract holds.
	Violations []string
}

// OK reports whether the page matched the documented contract.
func (r TaskReadyShapeReport) OK() bool { return len(r.Violations) == 0 }

// checkTaskReadyPageShape reads one `bp task ready -o json` page and asserts
// the contract documented in docs/setup/TASK-SYSTEM.md. It returns
// ErrReadyPageUnreadable (never a verdict) when the page cannot be read, and
// otherwise a report whose Violations are empty exactly when the contract
// holds. Pure: no network, no writes.
func checkTaskReadyPageShape(raw []byte) (TaskReadyShapeReport, error) {
	var report TaskReadyShapeReport

	if len(raw) == 0 {
		return report, readyPageUnreadable("the page was empty (0 bytes); a ready page is at minimum {\"docs\":[…]}")
	}
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		return report, readyPageUnreadable("the page is not a JSON object: %v", err)
	}
	rawDocs, present := env["docs"]
	if !present {
		keys := sortedReadyKeys(env)
		hint := ""
		if _, wrong := env["documents"]; wrong {
			hint = "; this envelope is keyed `documents`, which is what `bp doc ls` answers — `bp task ready` answers `docs`"
		}
		return report, readyPageUnreadable("the envelope has no `docs` key (top-level keys: %v)%s", keys, hint)
	}
	docs, ok := rawDocs.([]any)
	if !ok {
		return report, readyPageUnreadable("`docs` is %T, not a list", rawDocs)
	}
	if len(docs) == 0 {
		return report, readyPageUnreadable("`docs` carried zero rows; an empty page proves nothing about the shape, and a verdict over it would be the same confident zero this check exists to catch")
	}

	report.Rows = len(docs)
	statuses := map[string]bool{}
	for i, entry := range docs {
		row, ok := entry.(map[string]any)
		if !ok {
			return TaskReadyShapeReport{}, readyPageUnreadable("docs[%d] is %T, not an object", i, entry)
		}
		if _, nested := row["content"]; nested {
			report.NestedRows++
		}
		status, has := row["lifecycle_status"]
		if !has {
			report.ReadyRows++
			continue
		}
		report.NonReadyRows++
		text, _ := status.(string)
		statuses[text] = true
		if text == "open" {
			report.OpenFiltered++
		}
	}
	report.NonReadyStatuses = sortedReadyKeys(statuses)

	// BOTH ARMS, IN ONE RUN. Either one alone is satisfiable by a page that
	// disproves nothing: a page of only ready rows cannot show that presence
	// means NOT ready, and a page of only blocked rows cannot show that ready
	// rows omit the key.
	if report.ReadyRows == 0 {
		report.Violations = append(report.Violations,
			"ARM 1 UNPROVEN: no row OMITTED `lifecycle_status`. The contract says a ready row has no such key; this page cannot show it.")
	}
	if report.NonReadyRows == 0 {
		report.Violations = append(report.Violations,
			"ARM 2 UNPROVEN: no row CARRIED `lifecycle_status`. The contract says presence marks a NOT-ready row; this page cannot show it.")
	}
	if report.OpenFiltered > 0 {
		report.Violations = append(report.Violations, fmt.Sprintf(
			"CONTRACT BROKEN: %d row(s) carry lifecycle_status==\"open\". The doc tells readers that filtering ready rows for ==\"open\" returns ZERO and that the absence of the key is what marks a row ready. If the server now emits it on ready rows, docs/setup/TASK-SYSTEM.md is wrong and every reader written against it silently changed meaning.",
			report.OpenFiltered))
	}
	if report.NestedRows > 0 {
		report.Violations = append(report.Violations, fmt.Sprintf(
			"CONTRACT BROKEN: %d row(s) carry a `content` object. The doc says ready rows are FLAT (doc_id/priority/criteria_met/criteria_total at the top level) and that only `bp task get` nests under `.doc.content`.",
			report.NestedRows))
	}
	return report, nil
}

func sortedReadyKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
