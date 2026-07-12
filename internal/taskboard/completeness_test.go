package taskboard

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func TestScoreCompleteness(t *testing.T) {
	full := ScoreCompleteness(CompletenessInput{
		Title: "Implement it", Description: "Why and how", HasCriteria: true,
		Placement: "parent", Priority: "2", HasDependencies: true, HasPaper: true,
	})
	if full.Score != 7 || full.Total != 7 || len(full.Gaps) != 0 {
		t.Fatalf("full completeness = %+v, want 7/7 with no gaps", full)
	}

	thin := ScoreCompleteness(CompletenessInput{Title: "Only a title"})
	if thin.Score != 1 || thin.Total != 7 {
		t.Fatalf("thin completeness = %+v, want 1/7", thin)
	}
	wantGaps := []string{"description", "criteria", "placement", "priority", "deps", "paper"}
	if !reflect.DeepEqual(thin.Gaps, wantGaps) {
		t.Fatalf("thin gaps = %v, want %v", thin.Gaps, wantGaps)
	}
}

func TestCompletenessBadgeAppearsOnBoardAndDetail(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	task := Task{
		DocID: "task", Title: "Task", Lifecycle: lifeOpen,
		Completeness: Completeness{Score: 5, Total: 7, Gaps: []string{"deps", "paper"}},
	}
	drop, _ := richRowMeta(task, now, 0)
	if len(drop) == 0 || drop[0].plain != "C5/7" {
		t.Fatalf("board metadata = %+v, want leading C5/7 badge", drop)
	}
	meta := ansi.Strip(detailMetaLine(TaskDetail{Task: task}, 80, now))
	if !strings.Contains(meta, "C5/7") {
		t.Fatalf("detail metadata %q missing C5/7", meta)
	}
}

func TestTaskWireCarriesCompleteness(t *testing.T) {
	content := json.RawMessage(`{
		"description":"Defined work",
		"acceptance_criteria":[{"criterion":"It works","met":false}],
		"dependencies":["prep"],
		"design_doc":"design-paper"
	}`)
	task := (taskWire{
		DocID: "complete-task", Title: "Complete task", ParentID: "parent",
		Priority: json.RawMessage(`2`), Content: content,
	}).toTask()
	if task.Completeness.Score != 7 || task.Completeness.Total != 7 {
		t.Fatalf("decoded completeness = %+v, want 7/7", task.Completeness)
	}
}
