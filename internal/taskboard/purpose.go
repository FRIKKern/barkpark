package taskboard

import (
	"fmt"
	"strconv"
	"strings"
)

type purposeView struct {
	Authored   bool
	PartOf     string
	Impact     string
	Statement  string
	Why        string
	Endgame    string
	Importance PurposeScore
	Relevance  PurposeScore
	Proof      []PurposeProof
}

func taskPurposeView(d TaskDetail, children []Task) purposeView {
	p := d.Purpose
	authored := p.PartOf != "" || p.Impact != "" || p.Statement != "" || p.Why != "" || p.Endgame != "" || p.Importance.Set || p.Relevance.Set || len(p.Proof) > 0
	v := purposeView{
		Authored:   authored,
		PartOf:     "standalone task",
		Impact:     fmt.Sprintf("blocks %d · blocked by %d", d.DependentCount, d.DependencyCount),
		Statement:  p.Statement,
		Why:        p.Why,
		Endgame:    p.Endgame,
		Importance: p.Importance,
		Relevance:  p.Relevance,
		Proof:      append([]PurposeProof(nil), p.Proof...),
	}
	if p.PartOf != "" {
		v.PartOf = p.PartOf
	}
	if p.Impact != "" {
		v.Impact = p.Impact
	}
	if d.ParentID != "" {
		v.PartOf = bareID(d.ParentID)
	}
	if v.Statement == "" {
		v.Statement = strings.TrimSpace(d.Title)
	}
	if v.Why == "" {
		if d.ParentID != "" {
			v.Why = "Why this task is necessary within " + bareID(d.ParentID) + " is not recorded."
		} else {
			v.Why = "Why this task is worth doing is not recorded."
		}
	}
	if v.Endgame == "" {
		if d.ParentID != "" {
			v.Endgame = "Advance " + bareID(d.ParentID) + " by completing this task."
		} else if n := len(children); n > 0 {
			v.Endgame = fmt.Sprintf("Complete this task and its %d direct %s.", n, plural(n, "child", "children"))
		} else if n := len(d.CriteriaItems); n > 0 {
			v.Endgame = fmt.Sprintf("Meet all %d acceptance %s and close the task.", n, plural(n, "criterion", "criteria"))
		} else {
			v.Endgame = "Define acceptance criteria, then complete the task."
		}
	}
	if !v.Importance.Set {
		reason := "Default score; no priority is recorded."
		if d.Priority != "" {
			reason = "Derived from P" + d.Priority + " queue priority."
		}
		v.Importance = PurposeScore{Score: priorityImportance(d.Priority), Reason: reason, Set: true}
	}
	if !v.Relevance.Set {
		score, reason := 50, "Default score; task is present on this board."
		if d.Lifecycle == "in_progress" {
			score, reason = 90, "Derived from active in-progress status."
		} else if d.DesignDoc != "" || len(d.Papers) > 0 {
			score, reason = 65, "Derived from an explicit design-paper link."
		} else if d.ParentID != "" {
			score, reason = 60, "Derived from explicit parent placement."
		}
		v.Relevance = PurposeScore{Score: score, Reason: reason, Set: true}
	}
	if len(v.Proof) == 0 {
		v.Proof = append(v.Proof, PurposeProof{Claim: "Recorded task intent", Evidence: v.Statement, Source: "document.title"})
		if d.ParentID != "" {
			v.Proof = append(v.Proof, PurposeProof{Claim: "Mission placement", Evidence: bareID(d.ParentID), Source: "content.parent_id"})
		}
		if len(d.CriteriaItems) > 0 {
			n := len(d.CriteriaItems)
			v.Proof = append(v.Proof, PurposeProof{Claim: "Acceptance contract", Evidence: fmt.Sprintf("%d recorded %s", n, plural(n, "criterion", "criteria")), Source: "content.acceptance_criteria"})
		}
	}
	return v
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func priorityImportance(priority string) int {
	n, err := strconv.Atoi(priority)
	if err != nil {
		return 50
	}
	switch n {
	case 0:
		return 100
	case 1:
		return 90
	case 2:
		return 75
	case 3:
		return 55
	case 4:
		return 35
	default:
		return 50
	}
}
