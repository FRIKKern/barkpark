package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// lintFixture exercises every lint branch in one snapshot:
//   - epic-goal:    a ready PARENT (owns a child), no area — EXCLUDED (not a leaf)
//   - leaf-child:   the epic's ready child, area-less leaf — FLAGGED (no suggestion)
//   - tagged-leaf:  a ready leaf carrying an authored area: label — NOT flagged
//   - derived-leaf: a ready area-less leaf whose phase band names a surface —
//     FLAGGED with a "web" suggestion
//   - done-leaf:    a leaf that is not ready — EXCLUDED (not workable)
func lintFixture() taskboard.Snapshot {
	return taskboard.Snapshot{
		Tasks: []taskboard.Task{
			{DocID: "drafts.epic-goal", Title: "big epic", Lifecycle: "ready"},
			{DocID: "drafts.leaf-child", Title: "area-less child", Lifecycle: "ready", ParentID: "epic-goal"},
			{DocID: "drafts.tagged-leaf", Title: "already tagged", Lifecycle: "ready", Labels: []string{"area:studio"}},
			{DocID: "drafts.derived-leaf", Title: "phase-band leaf", Lifecycle: "ready", Labels: []string{"phase:2-web"}},
			{DocID: "drafts.done-leaf", Title: "finished work", Lifecycle: "done"},
		},
	}
}

func TestAreaLintFindings(t *testing.T) {
	findings, readyLeaves := areaLintFindings(lintFixture())

	// leaf-child, tagged-leaf, derived-leaf are ready leaves; the epic (a parent)
	// and the done task are not.
	if readyLeaves != 3 {
		t.Fatalf("readyLeaves = %d, want 3", readyLeaves)
	}

	got := map[string]string{}
	for _, f := range findings {
		got[f.ID] = f.Suggested
	}

	// (a) an area-less ready LEAF is flagged.
	if _, ok := got["leaf-child"]; !ok {
		t.Errorf("area-less ready leaf not flagged; findings=%v", got)
	}
	if got["leaf-child"] != "" {
		t.Errorf("leaf-child suggestion = %q, want \"\" (no phase band)", got["leaf-child"])
	}

	// (b) a goal/epic (has children) is NOT flagged, even though it has no area.
	if _, ok := got["epic-goal"]; ok {
		t.Errorf("epic-goal (a parent) must not be flagged; findings=%v", got)
	}

	// (c) an already area:-tagged ready leaf is NOT flagged.
	if _, ok := got["tagged-leaf"]; ok {
		t.Errorf("authored-area leaf must not be flagged; findings=%v", got)
	}

	// derived phase-band area becomes a suggestion (not an authored tag → still flagged).
	if got["derived-leaf"] != "web" {
		t.Errorf("derived-leaf suggestion = %q, want \"web\"", got["derived-leaf"])
	}

	// a non-ready leaf is not even scanned.
	if _, ok := got["done-leaf"]; ok {
		t.Errorf("done leaf must not be flagged; findings=%v", got)
	}

	if len(findings) != 2 {
		t.Fatalf("findings = %d, want 2 (leaf-child, derived-leaf)", len(findings))
	}
	// id-sorted, stable.
	if findings[0].ID != "derived-leaf" || findings[1].ID != "leaf-child" {
		t.Errorf("findings not id-sorted: %q, %q", findings[0].ID, findings[1].ID)
	}
}

func TestRenderCompletenessLint(t *testing.T) {
	snap := taskboard.Snapshot{Tasks: []taskboard.Task{{
		DocID: "drafts.thin-task", Title: "Thin task",
		Completeness: taskboard.Completeness{
			Score: 3, Total: 7, Gaps: []string{"criteria", "deps", "paper", "placement"},
		},
	}}}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.color = false
	if code := renderCompletenessLint(w, snap, "thin-task"); code != exitOK {
		t.Fatalf("table exit = %d, want %d", code, exitOK)
	}
	for _, want := range []string{"COMPLETENESS · thin-task · 3/7", "gaps: criteria, deps, paper, placement"} {
		if !strings.Contains(so.String(), want) {
			t.Errorf("table missing %q\n%s", want, so.String())
		}
	}

	so.Reset()
	w.output = "json"
	if code := renderCompletenessLint(w, snap, "drafts.thin-task"); code != exitOK {
		t.Fatalf("json exit = %d, want %d", code, exitOK)
	}
	var payload struct {
		Score int      `json:"score"`
		Total int      `json:"total"`
		Gaps  []string `json:"gaps"`
	}
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatalf("decode JSON: %v\n%s", err, so.String())
	}
	if payload.Score != 3 || payload.Total != 7 || len(payload.Gaps) != 4 {
		t.Fatalf("JSON payload = %+v", payload)
	}
}

// TestAreaLintAdvisoryExit — the CRITICAL guarantee: both render paths return
// exitOK even when findings EXIST. The nudge is never an error.
func TestAreaLintAdvisoryExit(t *testing.T) {
	findings, readyLeaves := areaLintFindings(lintFixture())
	if len(findings) == 0 {
		t.Fatal("fixture must produce findings to prove the advisory exit")
	}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.color = false
	if code := renderAreaLintTable(w, findings, readyLeaves); code != exitOK {
		t.Errorf("renderAreaLintTable with findings = %d, want exitOK (%d) — nudge must never error", code, exitOK)
	}

	filesFindings, _ := filesLintFindings(lintFixture())
	var jo, je bytes.Buffer
	jw := newWriter(&jo, &je)
	jw.output = "json"
	if code := emitLintJSON(jw, findings, filesFindings, readyLeaves); code != exitOK {
		t.Errorf("emitLintJSON with findings = %d, want exitOK (%d) — nudge must never error", code, exitOK)
	}

	var fo, fe bytes.Buffer
	fw := newWriter(&fo, &fe)
	fw.color = false
	if code := renderFilesLintTable(fw, filesFindings, readyLeaves); code != exitOK {
		t.Errorf("renderFilesLintTable with findings = %d, want exitOK (%d) — nudge must never error", code, exitOK)
	}
}

func TestRenderAreaLintTable(t *testing.T) {
	findings, readyLeaves := areaLintFindings(lintFixture())
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.color = false
	renderAreaLintTable(w, findings, readyLeaves)
	got := so.String()

	for _, want := range []string{
		"LINT · 2 of 3 ready leaves carry no area: label",
		"advisory",
		"leaf-child", // bareID-stripped
		"area-less child",
		"derived-leaf",
		"~web ?", // the derived suggestion, marked provisional + queried
		"dispatch-areas.md",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("table missing %q\n---\n%s", want, got)
		}
	}
}

func TestRenderAreaLintTableClean(t *testing.T) {
	// Every ready leaf is authored → no findings; the table says so and exits OK.
	snap := taskboard.Snapshot{Tasks: []taskboard.Task{
		{DocID: "drafts.a", Title: "tagged", Lifecycle: "ready", Labels: []string{"area:cli"}},
	}}
	findings, readyLeaves := areaLintFindings(snap)
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if code := renderAreaLintTable(w, findings, readyLeaves); code != exitOK {
		t.Errorf("clean table exit = %d, want exitOK", code)
	}
	if !strings.Contains(so.String(), "every workable leaf is area-tagged") {
		t.Errorf("clean table should confirm all tagged, got:\n%s", so.String())
	}
}

func TestEmitAreaLintJSON(t *testing.T) {
	findings, readyLeaves := areaLintFindings(lintFixture())
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	filesFindings, _ := filesLintFindings(lintFixture())
	emitLintJSON(w, findings, filesFindings, readyLeaves)

	var payload struct {
		OK          bool `json:"ok"`
		Advisory    bool `json:"advisory"`
		ReadyLeaves int  `json:"ready_leaves"`
		AreaLess    int  `json:"area_less"`
		FilesLess   int  `json:"files_less"`
		Findings    []struct {
			ID        string `json:"id"`
			Title     string `json:"title"`
			Suggested string `json:"suggested_area"`
		} `json:"findings"`
		FilesFindings []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"files_findings"`
	}
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatalf("json unmarshal: %v\n%s", err, so.String())
	}
	if !payload.OK || !payload.Advisory {
		t.Errorf("ok/advisory = %v/%v, want true/true", payload.OK, payload.Advisory)
	}
	if payload.ReadyLeaves != 3 || payload.AreaLess != 2 {
		t.Errorf("ready_leaves/area_less = %d/%d, want 3/2", payload.ReadyLeaves, payload.AreaLess)
	}
	// files_less sits beside area_less. In the fixture NO leaf carries a files:
	// label, so all 3 ready leaves are files-less.
	if payload.FilesLess != 3 {
		t.Errorf("files_less = %d, want 3 (no fixture leaf declares files:)", payload.FilesLess)
	}
	if len(payload.FilesFindings) != 3 {
		t.Fatalf("files_findings = %d, want 3", len(payload.FilesFindings))
	}
	if len(payload.Findings) != 2 {
		t.Fatalf("findings = %d, want 2", len(payload.Findings))
	}
	byID := map[string]string{}
	for _, f := range payload.Findings {
		byID[f.ID] = f.Suggested
	}
	if byID["derived-leaf"] != "web" {
		t.Errorf("derived-leaf suggested_area = %q, want web", byID["derived-leaf"])
	}
	if s, ok := byID["leaf-child"]; !ok || s != "" {
		t.Errorf("leaf-child suggested_area = %q (present=%v), want empty", s, ok)
	}
}

// filesFixture exercises the files: nudge branches:
//   - epic-goal:    a ready PARENT — EXCLUDED (not a leaf)
//   - naked-leaf:   ready leaf, no files: label — FLAGGED
//   - scoped-leaf:  ready leaf carrying an authored files: label — NOT flagged
//   - dir-leaf:     ready leaf carrying a trailing-slash directory files: label — NOT flagged
//   - done-leaf:    a leaf that is not ready — EXCLUDED (not workable)
func filesFixture() taskboard.Snapshot {
	return taskboard.Snapshot{
		Tasks: []taskboard.Task{
			{DocID: "drafts.epic-goal", Title: "big epic", Lifecycle: "ready"},
			{DocID: "drafts.naked-leaf", Title: "files-less child", Lifecycle: "ready", ParentID: "epic-goal"},
			{DocID: "drafts.scoped-leaf", Title: "scoped", Lifecycle: "ready", Labels: []string{"area:cli", "files:internal/cli/x.go"}},
			{DocID: "drafts.dir-leaf", Title: "dir scoped", Lifecycle: "ready", Labels: []string{"files:internal/taskboard/"}},
			{DocID: "drafts.done-leaf", Title: "finished", Lifecycle: "done"},
		},
	}
}

// TestFilesLintFindings is the deny-path proof: a KNOWN files-less leaf IS caught,
// while a leaf that declared files: (path or trailing-slash directory) is silent.
// A nudge that never fires on a real gap would be vacuous.
func TestFilesLintFindings(t *testing.T) {
	findings, readyLeaves := filesLintFindings(filesFixture())

	// naked-leaf, scoped-leaf, dir-leaf are ready leaves; epic (parent) + done are not.
	if readyLeaves != 3 {
		t.Fatalf("readyLeaves = %d, want 3", readyLeaves)
	}

	got := map[string]bool{}
	for _, f := range findings {
		got[f.ID] = true
	}

	// (a) the files-less leaf IS flagged — the known-collision deny path.
	if !got["naked-leaf"] {
		t.Errorf("files-less ready leaf not flagged; findings=%v", got)
	}
	// (b) a leaf with an authored files:<path> label is silent.
	if got["scoped-leaf"] {
		t.Errorf("files-scoped leaf must not be flagged; findings=%v", got)
	}
	// (c) a trailing-slash directory files: label also counts as declared.
	if got["dir-leaf"] {
		t.Errorf("files-dir leaf must not be flagged; findings=%v", got)
	}
	// (d) parent + non-ready excluded.
	if got["epic-goal"] || got["done-leaf"] {
		t.Errorf("parent/done leaves must not be flagged; findings=%v", got)
	}

	if len(findings) != 1 {
		t.Fatalf("findings = %d, want 1 (naked-leaf only)", len(findings))
	}
	if findings[0].ID != "naked-leaf" {
		t.Errorf("finding ID = %q, want naked-leaf", findings[0].ID)
	}
}

// TestFilesLintSilentWhenAllScoped — when every ready leaf declares files:, the
// nudge is fully silent and the clean table confirms it, exit 0.
func TestFilesLintSilentWhenAllScoped(t *testing.T) {
	snap := taskboard.Snapshot{Tasks: []taskboard.Task{
		{DocID: "drafts.a", Title: "scoped", Lifecycle: "ready", Labels: []string{"files:internal/cli/a.go"}},
	}}
	findings, readyLeaves := filesLintFindings(snap)
	if len(findings) != 0 {
		t.Fatalf("findings = %d, want 0 (all leaves declare files:)", len(findings))
	}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.color = false
	if code := renderFilesLintTable(w, findings, readyLeaves); code != exitOK {
		t.Errorf("clean files table exit = %d, want exitOK", code)
	}
	if !strings.Contains(so.String(), "every workable leaf declares a files:") {
		t.Errorf("clean files table should confirm all scoped, got:\n%s", so.String())
	}
}

// TestRenderFilesLintTable — the nudge lists the files-less leaf and the exact
// suggested syntax (files:<repo-relative-path>), and exits OK despite findings.
func TestRenderFilesLintTable(t *testing.T) {
	findings, readyLeaves := filesLintFindings(filesFixture())
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.color = false
	if code := renderFilesLintTable(w, findings, readyLeaves); code != exitOK {
		t.Errorf("files table with findings exit = %d, want exitOK — nudge never gates", code)
	}
	got := so.String()
	for _, want := range []string{
		"LINT · 1 of 3 ready leaves carry no files: label",
		"advisory",
		"naked-leaf",
		"files-less child",
		"files:<repo-relative-path>",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("files table missing %q\n---\n%s", want, got)
		}
	}
}

// TestLintFetchFailureEmitsJSONEnvelope pins the fetchSnapshotErr fix
// (wbqs-go-board-fetch-error-envelope): before the fix, a failed
// taskboard.FetchSnapshotFull hit `out.userErr(...); return exitGeneric` with
// no machineOut() check, so `bp task lint -o json | jq` on a broken board fetch
// got EMPTY stdout. It must now emit a parseable
// {"ok":false,"error":{"code":...,"message":...}} envelope on stdout.
func TestLintFetchFailureEmitsJSONEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	code := runTaskLint(w, globals{}, dispatchCtx(srv.URL), nil)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)", code, exitGeneric)
	}
	if se.Len() != 0 {
		t.Errorf("json mode must not also leak the human stderr line:\n%s", se.String())
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout not parseable (empty stdout is exactly the pre-fix bug): %v\n%s", err, so.String())
	}
	if env.OK || env.Error.Code == "" || env.Error.Message == "" {
		t.Errorf("bad fetch-failure envelope:\n%s", so.String())
	}
}
