package taskboard

import (
	"fmt"
	"strings"
)

// Completeness is the task-authoring rubric read shared by the board, detail
// view, and `bp task lint <id>`. Total is always seven for decoded tasks; Gaps
// uses the stable author-facing rubric names in display order.
type Completeness struct {
	Score int
	Total int
	Gaps  []string
}

// CompletenessInput is the seven-field authoring surface. It is intentionally
// small: callers may derive it from an API envelope without retaining the full
// content document in every compact board row.
type CompletenessInput struct {
	Title           string
	Description     string
	HasCriteria     bool
	Placement       string
	Priority        string
	HasDependencies bool
	HasPaper        bool
}

// ScoreCompleteness applies the canonical seven-field rubric.
func ScoreCompleteness(in CompletenessInput) Completeness {
	checks := []struct {
		name string
		ok   bool
	}{
		{"title", strings.TrimSpace(in.Title) != ""},
		{"description", strings.TrimSpace(in.Description) != ""},
		{"criteria", in.HasCriteria},
		{"placement", strings.TrimSpace(in.Placement) != ""},
		{"priority", strings.TrimSpace(in.Priority) != ""},
		{"deps", in.HasDependencies},
		{"paper", in.HasPaper},
	}

	c := Completeness{Total: len(checks)}
	for _, check := range checks {
		if check.ok {
			c.Score++
		} else {
			c.Gaps = append(c.Gaps, check.name)
		}
	}
	return c
}

func completenessBadge(c Completeness) string {
	if c.Total <= 0 {
		return ""
	}
	return fmt.Sprintf("C%d/%d", c.Score, c.Total)
}
