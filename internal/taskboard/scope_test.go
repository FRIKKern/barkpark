package taskboard

import (
	"reflect"
	"testing"
	"time"
)

func scopeFixture() Snapshot {
	at := time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)
	return Snapshot{
		Tasks: []Task{
			{DocID: "goal", Lifecycle: lifeOpen},
			{DocID: "j1", ParentID: "goal", Lifecycle: lifeDone},
			{DocID: "drafts.j2", ParentID: "drafts.goal", Lifecycle: lifeReady},
			{DocID: "j2a", ParentID: "j2", Lifecycle: lifeInProgress},
			{DocID: "other", Lifecycle: lifeOpen},
			{DocID: "other-child", ParentID: "other", Lifecycle: lifeInProgress},
		},
		Counts: map[string]int{lifeOpen: 400, lifeDone: 900, lifeInProgress: 7},
		Events: []Event{
			{Mutation: "task.closed", DocID: "j1", At: at},
			{Mutation: "task.claimed", DocID: "other-child", At: at},
		},
		Exhaustive: true,
	}
}

func TestScopeToGoalKeepsSubtreeOnly(t *testing.T) {
	got := scopeToGoal(scopeFixture(), "goal")
	if want := []string{"goal", "j1", "drafts.j2", "j2a"}; !reflect.DeepEqual(docIDs(got.Tasks), want) {
		t.Fatalf("tasks = %v, want %v", docIDs(got.Tasks), want)
	}
	// Counts describe the subtree, with the ready overlay counted as open.
	if want := map[string]int{lifeOpen: 2, lifeDone: 1, lifeInProgress: 1}; !reflect.DeepEqual(got.Counts, want) {
		t.Fatalf("counts = %v, want %v", got.Counts, want)
	}
	if len(got.Events) != 1 || got.Events[0].DocID != "j1" {
		t.Fatalf("events = %v, want only j1's", got.Events)
	}
	if !got.Exhaustive {
		t.Fatal("scoping must not change Exhaustive")
	}
}

func TestScopeToGoalDraftsSpelledGoal(t *testing.T) {
	got := scopeToGoal(scopeFixture(), "drafts.goal")
	if len(got.Tasks) != 4 {
		t.Fatalf("a drafts.-spelled goal must scope like the bare id, got %v", docIDs(got.Tasks))
	}
}

func TestScopeToGoalEmptyIsIdentity(t *testing.T) {
	in := scopeFixture()
	if got := scopeToGoal(in, ""); !reflect.DeepEqual(got, in) {
		t.Fatal("an empty goal must return the snapshot unchanged")
	}
}

func TestScopeToGoalUnknownGoalIsEmpty(t *testing.T) {
	got := scopeToGoal(scopeFixture(), "no-such-task")
	if len(got.Tasks) != 0 || len(got.Events) != 0 {
		t.Fatalf("an unknown goal must yield an empty board, got %v", docIDs(got.Tasks))
	}
}

func TestBoardCacheKeySeparatesScopedBoard(t *testing.T) {
	cfg := Config{BaseURL: "https://guerrilla.test", Workspace: "default", Project: "default", Dataset: "production"}
	if boardCacheKey(cfg) != cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset) {
		t.Fatal("an unscoped board must keep its existing cache key")
	}
	scoped := cfg
	scoped.Goal = "task-130be6b834d485ae"
	if boardCacheKey(scoped) == boardCacheKey(cfg) {
		t.Fatal("a goal-scoped board must not share the unscoped cache key")
	}
	draft := scoped
	draft.Goal = "drafts.task-130be6b834d485ae"
	if boardCacheKey(draft) != boardCacheKey(scoped) {
		t.Fatal("the drafts. spelling of a goal must map to the same cache key")
	}
}
